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
