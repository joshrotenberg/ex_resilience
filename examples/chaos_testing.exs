# Example: Using chaos to test your resilience pipeline
#
# Injects faults to verify that retry and circuit breaker handle
# failures correctly under controlled conditions.
#
# Run with: mix run examples/chaos_testing.exs

IO.puts("--- Testing retry behavior under chaos ---\n")

# Track attempts
attempt_count = :counters.new(1, [:atomics])

result =
  ExResilience.Retry.call(
    fn ->
      :counters.add(attempt_count, 1, 1)

      ExResilience.Chaos.call(
        fn -> {:ok, "success"} end,
        error_rate: 0.9,
        error_fn: fn -> {:error, :injected_fault} end
      )
    end,
    max_attempts: 5,
    backoff: :fixed,
    base_delay: 10,
    jitter: false
  )

IO.puts("Result after #{:counters.get(attempt_count, 1)} attempts: #{inspect(result)}")

IO.puts("\n--- Testing circuit breaker trip under chaos ---\n")

{:ok, _} =
  ExResilience.CircuitBreaker.start_link(
    name: :chaos_cb,
    failure_threshold: 3,
    reset_timeout: 1_000
  )

# 100% error rate to trip the breaker fast
for i <- 1..5 do
  result =
    ExResilience.CircuitBreaker.call(:chaos_cb, fn ->
      ExResilience.Chaos.call(
        fn -> {:ok, "should not reach"} end,
        error_rate: 1.0,
        error_fn: fn -> {:error, :chaos_fault} end
      )
    end)

  state = ExResilience.CircuitBreaker.get_state(:chaos_cb)
  IO.puts("Call #{i}: #{inspect(result)} (breaker: #{state})")
end

IO.puts("\nCircuit breaker tripped after 3 failures, calls 4-5 rejected immediately.")

IO.puts("\n--- Testing latency injection ---\n")

for label <- ["no latency", "50-100ms latency"] do
  opts =
    case label do
      "no latency" -> [latency_rate: 0.0]
      _ -> [latency_rate: 1.0, latency_min: 50, latency_max: 100, seed: 1]
    end

  {time_us, _} =
    :timer.tc(fn ->
      ExResilience.Chaos.call(fn -> {:ok, :done} end, opts)
    end)

  IO.puts("#{label}: #{div(time_us, 1000)}ms")
end

IO.puts("\nDone.")
