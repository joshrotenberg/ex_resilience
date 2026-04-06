defmodule ExResilience.StressTest do
  use ExUnit.Case, async: false

  @moduletag :stress

  describe "bulkhead under concurrent load" do
    test "handles 1000 concurrent callers without deadlock" do
      {:ok, _} =
        ExResilience.Bulkhead.start_link(name: :stress_bh, max_concurrent: 50, max_wait: 10_000)

      tasks =
        for _ <- 1..1000 do
          Task.async(fn ->
            ExResilience.Bulkhead.call(:stress_bh, fn ->
              Process.sleep(Enum.random(1..5))
              {:ok, :done}
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      ok_count =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert ok_count > 0
      # All should succeed since max_wait is generous
      assert ok_count == 1000

      Process.sleep(10)
      assert ExResilience.Bulkhead.active_count(:stress_bh) == 0
    end

    test "rejects excess callers when max_wait is short" do
      {:ok, _} =
        ExResilience.Bulkhead.start_link(
          name: :stress_bh_reject,
          max_concurrent: 5,
          max_wait: 50
        )

      tasks =
        for _ <- 1..200 do
          Task.async(fn ->
            ExResilience.Bulkhead.call(:stress_bh_reject, fn ->
              Process.sleep(50)
              {:ok, :done}
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      rejected_count = Enum.count(results, &match?({:error, :bulkhead_full}, &1))

      assert ok_count > 0
      assert rejected_count > 0
      assert ok_count + rejected_count == 200
    end
  end

  describe "rate limiter under burst" do
    test "rate limits burst of 500 requests with rate 50/s" do
      {:ok, _} =
        ExResilience.RateLimiter.start_link(
          name: :stress_rl,
          rate: 50,
          interval: 1_000,
          max_tokens: 50
        )

      results =
        for _ <- 1..500 do
          ExResilience.RateLimiter.call(:stress_rl, fn -> {:ok, :done} end)
        end

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      limited_count = Enum.count(results, &match?({:error, :rate_limited}, &1))

      # Should allow exactly 50, reject the rest
      assert ok_count == 50
      assert limited_count == 450
    end
  end

  describe "circuit breaker rapid transitions" do
    test "handles rapid open/close cycles" do
      {:ok, _} =
        ExResilience.CircuitBreaker.start_link(
          name: :stress_cb,
          failure_threshold: 3,
          reset_timeout: 20
        )

      for _ <- 1..50 do
        # Trip the breaker
        for _ <- 1..3 do
          ExResilience.CircuitBreaker.call(:stress_cb, fn -> {:error, :fail} end)
        end

        Process.sleep(5)

        # Verify it's open
        assert ExResilience.CircuitBreaker.get_state(:stress_cb) == :open

        # Wait for half_open
        Process.sleep(25)

        # Recover
        ExResilience.CircuitBreaker.call(:stress_cb, fn -> {:ok, :recovered} end)
        Process.sleep(5)
        assert ExResilience.CircuitBreaker.get_state(:stress_cb) == :closed
      end
    end
  end

  describe "coalesce under contention" do
    test "deduplicates 100 concurrent calls to same key" do
      {:ok, _} = ExResilience.Coalesce.start_link(name: :stress_coal)
      call_count = :counters.new(1, [:atomics])

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            ExResilience.Coalesce.call(:stress_coal, "shared_key", fn ->
              :counters.add(call_count, 1, 1)
              Process.sleep(50)
              {:ok, :result}
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, &match?({:ok, :result}, &1))
      # Should have executed only once (or very few times if timing is tight)
      assert :counters.get(call_count, 1) <= 3
    end
  end

  describe "pipeline under concurrent load" do
    test "full pipeline handles 200 concurrent calls" do
      pipeline =
        ExResilience.new(:stress_pipe)
        |> ExResilience.add(:bulkhead, max_concurrent: 50, max_wait: 10_000)
        |> ExResilience.add(:circuit_breaker, failure_threshold: 100)
        |> ExResilience.add(:retry, max_attempts: 2, base_delay: 1, jitter: false)

      {:ok, _} = ExResilience.start(pipeline)

      tasks =
        for _ <- 1..200 do
          Task.async(fn ->
            ExResilience.call(pipeline, fn ->
              Process.sleep(Enum.random(1..5))
              {:ok, :done}
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      assert ok_count == 200
    end
  end
end
