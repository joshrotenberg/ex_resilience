defmodule ExResilience.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias ExResilience.{Backoff, Bulkhead, CircuitBreaker, RateLimiter, Retry}

  defp unique_name, do: :"prop_#{System.unique_integer([:positive])}"

  defp strategy_gen, do: member_of([:fixed, :linear, :exponential])

  # -- Backoff properties --

  describe "Backoff" do
    property "delay is always non-negative" do
      check all(
              strategy <- strategy_gen(),
              base_ms <- integer(0..1000),
              attempt <- integer(1..20)
            ) do
        assert Backoff.delay(strategy, base_ms, attempt) >= 0
      end
    end

    property "exponential delay is monotonically increasing" do
      check all(
              strategy <- member_of([:exponential, :linear]),
              base_ms <- integer(0..1000),
              attempt <- integer(1..19)
            ) do
        assert Backoff.delay(strategy, base_ms, attempt) <=
                 Backoff.delay(strategy, base_ms, attempt + 1)
      end
    end

    property "delay_capped never exceeds the cap" do
      check all(
              strategy <- strategy_gen(),
              base_ms <- integer(0..1000),
              attempt <- integer(1..20),
              max <- integer(1..100_000)
            ) do
        assert Backoff.delay_capped(strategy, base_ms, attempt, max) <= max
      end
    end

    property "delay_with_jitter is always in [0, delay]" do
      check all(
              strategy <- strategy_gen(),
              base_ms <- integer(0..1000),
              attempt <- integer(1..20)
            ) do
        jittered = Backoff.delay_with_jitter(strategy, base_ms, attempt)
        base = Backoff.delay(strategy, base_ms, attempt)
        assert jittered >= 0
        assert jittered <= base
      end
    end
  end

  # -- Circuit breaker state machine --

  describe "CircuitBreaker" do
    property "state is always one of :closed, :open, :half_open" do
      check all(
              results <- list_of(member_of([:ok, :error]), min_length: 1, max_length: 20),
              failure_threshold <- integer(1..10),
              max_runs: 100
            ) do
        name = unique_name()

        {:ok, _pid} =
          CircuitBreaker.start_link(
            name: name,
            failure_threshold: failure_threshold,
            reset_timeout: 60_000
          )

        for result <- results do
          state = CircuitBreaker.get_state(name)
          assert state in [:closed, :open, :half_open]

          case state do
            :open ->
              assert {:error, :circuit_open} = CircuitBreaker.call(name, fn -> result end)

            _ ->
              CircuitBreaker.call(name, fn -> result end)
          end
        end

        final_state = CircuitBreaker.get_state(name)
        assert final_state in [:closed, :open, :half_open]

        GenServer.stop(name)
      end
    end

    property "consecutive failures trip the breaker" do
      check all(
              failure_threshold <- integer(1..10),
              max_runs: 100
            ) do
        name = unique_name()

        {:ok, _pid} =
          CircuitBreaker.start_link(
            name: name,
            failure_threshold: failure_threshold,
            reset_timeout: 60_000
          )

        for _ <- 1..failure_threshold do
          CircuitBreaker.call(name, fn -> {:error, :fail} end)
        end

        # Give the cast time to process
        Process.sleep(10)

        assert CircuitBreaker.get_state(name) == :open

        GenServer.stop(name)
      end
    end
  end

  # -- Bulkhead invariants --

  describe "Bulkhead" do
    property "active_count never exceeds max_concurrent" do
      check all(
              max_concurrent <- integer(1..20),
              num_tasks <- integer(1..50),
              max_runs: 100
            ) do
        name = unique_name()

        {:ok, _pid} =
          Bulkhead.start_link(
            name: name,
            max_concurrent: max_concurrent,
            max_wait: 5_000
          )

        results_ref = make_ref()
        parent = self()

        tasks =
          for _ <- 1..num_tasks do
            Task.async(fn ->
              Bulkhead.call(name, fn ->
                count = Bulkhead.active_count(name)
                send(parent, {results_ref, count})
                # Brief pause to create overlap
                Process.sleep(1)
                :ok
              end)
            end)
          end

        Task.await_many(tasks, 10_000)

        # Collect all observed active counts
        observed_counts = flush_messages(results_ref, [])

        for count <- observed_counts do
          assert count <= max_concurrent,
                 "active_count #{count} exceeded max_concurrent #{max_concurrent}"
        end

        # After completion, active_count should settle to 0
        Process.sleep(50)
        assert Bulkhead.active_count(name) == 0

        GenServer.stop(name)
      end
    end
  end

  # -- Rate limiter token invariants --

  describe "RateLimiter" do
    property "consuming N tokens from fresh limiter leaves max(M - N, 0) available" do
      check all(
              max_tokens <- integer(1..100),
              consume_count <- integer(0..200),
              max_runs: 100
            ) do
        name = unique_name()

        {:ok, _pid} =
          RateLimiter.start_link(
            name: name,
            rate: max_tokens,
            max_tokens: max_tokens,
            # Long interval so no refill during test
            interval: 60_000
          )

        Enum.each(1..consume_count//1, fn _ ->
          RateLimiter.call(name, fn -> :ok end)
        end)

        expected = max(max_tokens - consume_count, 0)
        assert RateLimiter.available_tokens(name) == expected

        GenServer.stop(name)
      end
    end

    property "available_tokens never exceeds max_tokens" do
      check all(
              max_tokens <- integer(1..100),
              max_runs: 100
            ) do
        name = unique_name()

        {:ok, _pid} =
          RateLimiter.start_link(
            name: name,
            rate: max_tokens,
            max_tokens: max_tokens,
            # Short interval to trigger refills
            interval: 10
          )

        # Let a few refill cycles happen
        Process.sleep(50)

        tokens = RateLimiter.available_tokens(name)
        assert tokens <= max_tokens

        GenServer.stop(name)
      end
    end
  end

  # -- Retry invariants --

  describe "Retry" do
    property "total call count never exceeds max_attempts" do
      check all(
              max_attempts <- integer(1..10),
              max_runs: 100
            ) do
        counter = :counters.new(1, [:atomics])

        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          max_attempts: max_attempts,
          backoff: :fixed,
          base_delay: 0,
          jitter: false
        )

        assert :counters.get(counter, 1) <= max_attempts
      end
    end

    property "at least 1 call always happens" do
      check all(
              max_attempts <- integer(1..10),
              max_runs: 100
            ) do
        counter = :counters.new(1, [:atomics])

        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :done}
          end,
          max_attempts: max_attempts,
          backoff: :fixed,
          base_delay: 0,
          jitter: false
        )

        assert :counters.get(counter, 1) >= 1
      end
    end
  end

  # -- Helpers --

  defp flush_messages(ref, acc) do
    receive do
      {^ref, value} -> flush_messages(ref, [value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
