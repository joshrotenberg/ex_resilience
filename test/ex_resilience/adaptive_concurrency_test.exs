defmodule ExResilience.AdaptiveConcurrencyTest do
  use ExUnit.Case, async: true

  alias ExResilience.AdaptiveConcurrency

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive, :monotonic])}"
  end

  describe "basic operation" do
    test "executes function and returns result" do
      name = unique_name(:basic)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 5)
      assert {:ok, :hello} = AdaptiveConcurrency.call(name, fn -> :hello end)
    end

    test "wraps ok tuples correctly" do
      name = unique_name(:ok_tuple)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 5)
      assert {:ok, 42} = AdaptiveConcurrency.call(name, fn -> {:ok, 42} end)
    end

    test "passes through error tuples" do
      name = unique_name(:err_tuple)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 5)
      assert {:error, :boom} = AdaptiveConcurrency.call(name, fn -> {:error, :boom} end)
    end

    test "rejects when at limit" do
      name = unique_name(:reject)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 1, min_limit: 1)

      # Hold one slot
      test_pid = self()

      _task =
        Task.async(fn ->
          AdaptiveConcurrency.call(name, fn ->
            send(test_pid, :in_call)
            Process.sleep(500)
            :done
          end)
        end)

      assert_receive :in_call, 1_000

      # Second call should be rejected
      assert {:error, :concurrency_limited} =
               AdaptiveConcurrency.call(name, fn -> :should_not_run end)
    end
  end

  describe "AIMD algorithm" do
    test "limit increases on fast success" do
      name = unique_name(:aimd_inc)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :aimd,
          initial_limit: 5,
          latency_threshold: 100,
          increase_by: 1
        )

      # Fast call
      AdaptiveConcurrency.call(name, fn -> :fast end)
      # Allow the cast to be processed
      _ = AdaptiveConcurrency.get_stats(name)

      assert AdaptiveConcurrency.get_limit(name) == 6
    end

    test "limit decreases on slow response" do
      name = unique_name(:aimd_slow)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :aimd,
          initial_limit: 10,
          latency_threshold: 10,
          decrease_factor: 0.5
        )

      # Slow call (above 10ms threshold)
      AdaptiveConcurrency.call(name, fn ->
        Process.sleep(20)
        :slow
      end)

      _ = AdaptiveConcurrency.get_stats(name)

      assert AdaptiveConcurrency.get_limit(name) == 5
    end

    test "limit decreases on error" do
      name = unique_name(:aimd_err)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :aimd,
          initial_limit: 10,
          decrease_factor: 0.5
        )

      AdaptiveConcurrency.call(name, fn -> {:error, :failed} end)
      _ = AdaptiveConcurrency.get_stats(name)

      assert AdaptiveConcurrency.get_limit(name) == 5
    end

    test "limit respects min_limit floor" do
      name = unique_name(:aimd_floor)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :aimd,
          initial_limit: 2,
          min_limit: 2,
          decrease_factor: 0.5
        )

      AdaptiveConcurrency.call(name, fn -> {:error, :failed} end)
      _ = AdaptiveConcurrency.get_stats(name)

      assert AdaptiveConcurrency.get_limit(name) == 2
    end

    test "limit respects max_limit ceiling" do
      name = unique_name(:aimd_ceil)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :aimd,
          initial_limit: 10,
          max_limit: 10,
          increase_by: 1
        )

      AdaptiveConcurrency.call(name, fn -> :fast end)
      _ = AdaptiveConcurrency.get_stats(name)

      assert AdaptiveConcurrency.get_limit(name) == 10
    end
  end

  describe "Vegas algorithm" do
    test "limit increases when estimated queue < alpha" do
      name = unique_name(:vegas_inc)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :vegas,
          initial_limit: 10,
          alpha: 3,
          beta: 6
        )

      # When min_rtt == sample_rtt, queue = limit * (1 - 1) = 0 < alpha
      # So limit should increase
      AdaptiveConcurrency.call(name, fn ->
        Process.sleep(5)
        :ok
      end)

      _ = AdaptiveConcurrency.get_stats(name)
      # First sample: min_rtt == sample_rtt, queue = 0 < alpha(3), so limit -> 11
      assert AdaptiveConcurrency.get_limit(name) == 11
    end

    test "limit decreases when estimated queue > beta" do
      name = unique_name(:vegas_dec)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :vegas,
          initial_limit: 10,
          alpha: 3,
          beta: 6,
          window_size: 100
        )

      # First, establish a fast min_rtt
      AdaptiveConcurrency.call(name, fn ->
        Process.sleep(1)
        :ok
      end)

      _ = AdaptiveConcurrency.get_stats(name)

      # Now do a much slower call so that queue = limit * (1 - min_rtt/sample_rtt) > beta
      # Need: 11 * (1 - 1/sample_rtt) > 6
      # => 1 - 6/11 < 1/sample_rtt is wrong...
      # => sample_rtt > 11 * min_rtt / (11 - 6) = 11/5 * min_rtt ~= 2.2 * min_rtt
      # With min_rtt ~1ms, we need sample_rtt > ~2.2ms
      # But the limit is now 11 so: 11 * (1 - 1/sample_rtt) > 6
      # => sample_rtt > 11/5 ~= 2.2ms.
      # Let's use a much larger ratio to be safe
      AdaptiveConcurrency.call(name, fn ->
        Process.sleep(50)
        :ok
      end)

      _ = AdaptiveConcurrency.get_stats(name)

      # Limit should have decreased
      assert AdaptiveConcurrency.get_limit(name) < 11
    end

    test "limit holds steady when queue between alpha and beta" do
      name = unique_name(:vegas_hold)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :vegas,
          initial_limit: 10,
          alpha: 3,
          beta: 6,
          window_size: 100
        )

      # With all calls at same latency, min_rtt == sample_rtt, queue = 0 < alpha
      # So first call will increase. Let's verify holding by using alpha: 0
      # Actually, let's just test with a specific setup.
      # For holding, we need alpha <= queue <= beta.
      # queue = limit * (1 - min_rtt / sample_rtt)
      # With min_rtt=1, sample_rtt=3, limit=10: queue = 10*(1-1/3) = 6.67 > beta=6
      # With min_rtt=1, sample_rtt=2, limit=10: queue = 10*(1-0.5) = 5, alpha<5<beta, holds!
      # So we need a fast call then a 2x slower call.
      # But timing is unreliable. Let's use a more controllable approach.
      :ok = GenServer.stop(name)

      {:ok, _} =
        AdaptiveConcurrency.start_link(
          name: name,
          algorithm: :vegas,
          initial_limit: 10,
          alpha: 0,
          beta: 100,
          window_size: 100
        )

      # With alpha=0 and beta=100, any nonzero queue that's < 100 holds steady.
      # First call: min_rtt == sample_rtt, queue = 0. 0 < alpha=0 is false, 0 > beta=100 is false.
      # 0 is not < 0 and not > 100, so it holds.
      AdaptiveConcurrency.call(name, fn ->
        Process.sleep(5)
        :ok
      end)

      _ = AdaptiveConcurrency.get_stats(name)
      assert AdaptiveConcurrency.get_limit(name) == 10
    end
  end

  describe "concurrency" do
    test "multiple concurrent callers up to limit succeed" do
      name = unique_name(:conc_ok)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 5, max_limit: 200)

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            AdaptiveConcurrency.call(name, fn ->
              Process.sleep(50)
              :done
            end)
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, fn r -> r == {:ok, :done} end)
    end

    test "callers beyond limit are rejected immediately" do
      name = unique_name(:conc_reject)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 2, min_limit: 1)

      barrier = :erlang.make_ref()
      test_pid = self()

      # Start 2 tasks that hold their slots
      holders =
        for _ <- 1..2 do
          Task.async(fn ->
            AdaptiveConcurrency.call(name, fn ->
              send(test_pid, {:holding, barrier})

              receive do
                {:release, ^barrier} -> :done
              end
            end)
          end)
        end

      # Wait for both holders to be in their calls
      assert_receive {:holding, ^barrier}, 1_000
      assert_receive {:holding, ^barrier}, 1_000

      # Third call should be rejected
      assert {:error, :concurrency_limited} =
               AdaptiveConcurrency.call(name, fn -> :should_not_run end)

      # Release holders
      for _ <- 1..2, do: send(self(), {:release, barrier})
      # Actually need to send to the holder tasks' inner processes
      # Let's just use a different approach
      # Release by sending to all processes
      for task <- holders do
        send(task.pid, {:release, barrier})
      end

      # Wait a moment for tasks to finish
      Task.await_many(holders, 5_000)
    end
  end

  describe "get_limit/1" do
    test "returns the current limit" do
      name = unique_name(:get_limit)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 42)
      assert AdaptiveConcurrency.get_limit(name) == 42
    end
  end

  describe "get_stats/1" do
    test "returns stats map" do
      name = unique_name(:get_stats)
      {:ok, _} = AdaptiveConcurrency.start_link(name: name, initial_limit: 7)
      stats = AdaptiveConcurrency.get_stats(name)
      assert stats.limit == 7
      assert stats.active == 0
      assert stats.min_rtt == nil
    end
  end
end
