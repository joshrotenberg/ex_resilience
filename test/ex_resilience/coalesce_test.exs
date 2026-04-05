defmodule ExResilience.CoalesceTest do
  use ExUnit.Case, async: false

  alias ExResilience.Coalesce

  setup do
    name = :"coal_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "basic operation" do
    test "single call executes and returns result", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      assert Coalesce.call(name, :key1, fn -> 42 end) == {:ok, 42}
    end

    test "wraps ok tuples", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      assert Coalesce.call(name, :key1, fn -> {:ok, :data} end) == {:ok, :data}
    end

    test "passes through error tuples", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      assert Coalesce.call(name, :key1, fn -> {:error, :fail} end) == {:error, :fail}
    end
  end

  describe "deduplication" do
    test "two concurrent calls with same key only execute once", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      counter = :counters.new(1, [:atomics])
      test_pid = self()

      # First call holds execution until we signal it
      fun = fn ->
        :counters.add(counter, 1, 1)
        send(test_pid, :executing)
        Process.sleep(100)
        :result
      end

      task1 = Task.async(fn -> Coalesce.call(name, :shared_key, fun) end)

      # Wait for execution to start
      receive do
        :executing -> :ok
      end

      # Second call with same key should join, not execute again
      task2 = Task.async(fn -> Coalesce.call(name, :shared_key, fn -> :should_not_run end) end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      assert result1 == {:ok, :result}
      assert result2 == {:ok, :result}
      assert :counters.get(counter, 1) == 1
    end

    test "different keys execute independently", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      counter = :counters.new(1, [:atomics])

      task1 =
        Task.async(fn ->
          Coalesce.call(name, :key_a, fn ->
            :counters.add(counter, 1, 1)
            Process.sleep(50)
            :result_a
          end)
        end)

      # Small delay to ensure ordering
      Process.sleep(10)

      task2 =
        Task.async(fn ->
          Coalesce.call(name, :key_b, fn ->
            :counters.add(counter, 1, 1)
            :result_b
          end)
        end)

      assert Task.await(task1) == {:ok, :result_a}
      assert Task.await(task2) == {:ok, :result_b}
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "error handling" do
    test "error results are broadcast to all waiters", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      test_pid = self()

      fun = fn ->
        send(test_pid, :executing)
        Process.sleep(100)
        {:error, :something_broke}
      end

      task1 = Task.async(fn -> Coalesce.call(name, :err_key, fun) end)

      receive do
        :executing -> :ok
      end

      task2 = Task.async(fn -> Coalesce.call(name, :err_key, fn -> :ignored end) end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      assert result1 == {:error, :something_broke}
      assert result2 == {:error, :something_broke}
    end
  end

  describe "re-execution after completion" do
    test "after completion, same key triggers a new execution", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      counter = :counters.new(1, [:atomics])

      result1 =
        Coalesce.call(name, :reuse_key, fn ->
          :counters.add(counter, 1, 1)
          :first
        end)

      assert result1 == {:ok, :first}

      result2 =
        Coalesce.call(name, :reuse_key, fn ->
          :counters.add(counter, 1, 1)
          :second
        end)

      assert result2 == {:ok, :second}
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "telemetry" do
    test "emits execute, join, and complete events", %{name: name} do
      {:ok, _} = Coalesce.start_link(name: name)
      test_pid = self()

      :telemetry.attach_many(
        "coalesce-test-#{name}",
        [
          [:ex_resilience, :coalesce, :execute],
          [:ex_resilience, :coalesce, :join],
          [:ex_resilience, :coalesce, :complete]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      fun = fn ->
        send(test_pid, :executing)
        Process.sleep(100)
        :done
      end

      task1 = Task.async(fn -> Coalesce.call(name, :tel_key, fun) end)

      receive do
        :executing -> :ok
      end

      task2 = Task.async(fn -> Coalesce.call(name, :tel_key, fn -> :ignored end) end)

      Task.await(task1)
      Task.await(task2)

      # Allow GenServer to process the task result and emit complete event
      Process.sleep(50)

      assert_received {:telemetry, [:ex_resilience, :coalesce, :execute], _, %{key: :tel_key}}
      assert_received {:telemetry, [:ex_resilience, :coalesce, :join], _, %{key: :tel_key}}

      assert_received {:telemetry, [:ex_resilience, :coalesce, :complete],
                       %{waiters: waiters_count}, %{key: :tel_key}}

      assert waiters_count >= 1

      :telemetry.detach("coalesce-test-#{name}")
    end
  end
end
