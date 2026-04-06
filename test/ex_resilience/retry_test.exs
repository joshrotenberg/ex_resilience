defmodule ExResilience.RetryTest do
  use ExUnit.Case, async: true

  alias ExResilience.Retry

  describe "call/2" do
    test "returns immediately on success" do
      assert Retry.call(fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "retries on error and returns last result" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false
        )

      assert result == {:error, :fail}
      assert :counters.get(counter, 1) == 3
    end

    test "stops retrying on success" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            attempt = :counters.get(counter, 1)

            if attempt < 3 do
              {:error, :not_yet}
            else
              {:ok, :done}
            end
          end,
          max_attempts: 5,
          base_delay: 1,
          jitter: false
        )

      assert result == {:ok, :done}
      assert :counters.get(counter, 1) == 3
    end

    test "respects max_attempts: 1 (no retry)" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          max_attempts: 1
        )

      assert result == {:error, :fail}
      assert :counters.get(counter, 1) == 1
    end

    test "uses custom retry_on predicate" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :but_wrong}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          retry_on: fn
            {:ok, :but_wrong} -> true
            _ -> false
          end
        )

      assert result == {:ok, :but_wrong}
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry bare ok values by default" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            :ok
          end,
          max_attempts: 3
        )

      assert result == :ok
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "jitter fraction" do
    test "proportional jitter keeps delay within expected range" do
      :rand.seed(:exsss, {100, 200, 300})

      start = System.monotonic_time(:millisecond)

      Retry.call(
        fn -> {:error, :fail} end,
        max_attempts: 2,
        backoff: :fixed,
        base_delay: 1000,
        jitter: 0.1
      )

      elapsed = System.monotonic_time(:millisecond) - start
      # With jitter 0.1 on a 1000ms fixed delay, the sleep should be in [900, 1100]
      assert elapsed >= 850, "elapsed #{elapsed}ms was below expected minimum"
      assert elapsed <= 1200, "elapsed #{elapsed}ms was above expected maximum"
    end

    test "jitter 0.0 is effectively no jitter" do
      start = System.monotonic_time(:millisecond)

      Retry.call(
        fn -> {:error, :fail} end,
        max_attempts: 2,
        backoff: :fixed,
        base_delay: 50,
        jitter: 0.0
      )

      elapsed = System.monotonic_time(:millisecond) - start
      # With jitter 0.0, the delay should be exactly 50ms (within timing tolerance)
      assert elapsed >= 45
      assert elapsed <= 100
    end

    test "jitter true still works as full jitter" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: true
        )

      assert result == {:error, :fail}
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "backoff strategies" do
    test "fixed backoff has constant delay" do
      start = System.monotonic_time(:millisecond)

      Retry.call(
        fn -> {:error, :fail} end,
        max_attempts: 3,
        backoff: :fixed,
        base_delay: 20,
        jitter: false
      )

      elapsed = System.monotonic_time(:millisecond) - start
      # 2 delays of 20ms each (first attempt has no delay)
      assert elapsed >= 35
    end
  end
end
