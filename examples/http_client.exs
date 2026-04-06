# Example: Wrapping an HTTP client with a resilience pipeline
#
# Simulates a flaky HTTP service and shows how bulkhead, circuit breaker,
# and retry compose to handle failures gracefully.
#
# Run with: mix run examples/http_client.exs

defmodule FlakyHTTP do
  @moduledoc false

  # Simulates an HTTP endpoint that fails ~30% of the time
  # and occasionally takes a long time to respond.
  def get(url) do
    case :rand.uniform(10) do
      n when n <= 3 ->
        {:error, :connection_refused}

      n when n == 4 ->
        Process.sleep(500)
        {:ok, %{status: 200, body: "slow response from #{url}"}}

      _ ->
        Process.sleep(Enum.random(5..20))
        {:ok, %{status: 200, body: "response from #{url}"}}
    end
  end
end

# Build the pipeline
pipeline =
  ExResilience.new(:http)
  |> ExResilience.add(:bulkhead, max_concurrent: 5, max_wait: 2_000)
  |> ExResilience.add(:circuit_breaker, failure_threshold: 5, reset_timeout: 2_000)
  |> ExResilience.add(:retry, max_attempts: 3, backoff: :exponential, base_delay: 50)

{:ok, _pids} = ExResilience.start(pipeline)

# Attach telemetry to observe behavior
:telemetry.attach("log-cb", [:ex_resilience, :circuit_breaker, :state_change], fn
  _event, _measurements, %{name: name, from: from, to: to}, _config ->
    IO.puts("  [circuit_breaker] #{name}: #{from} -> #{to}")
end, nil)

:telemetry.attach("log-retry", [:ex_resilience, :retry, :attempt], fn
  _event, %{attempt: attempt}, %{name: _name}, _config ->
    if attempt > 1, do: IO.puts("  [retry] attempt #{attempt}")
end, nil)

:telemetry.attach("log-rejected", [:ex_resilience, :bulkhead, :rejected], fn
  _event, _measurements, %{name: name}, _config ->
    IO.puts("  [bulkhead] #{name}: rejected (full)")
end, nil)

# Fire 30 requests
IO.puts("Sending 30 requests through the pipeline...\n")

results =
  for i <- 1..30 do
    result =
      ExResilience.call(pipeline, fn ->
        FlakyHTTP.get("https://api.example.com/data/#{i}")
      end)

    status =
      case result do
        {:ok, %{status: 200}} -> "ok"
        {:ok, {:ok, %{status: 200}}} -> "ok"
        {:error, :circuit_open} -> "CIRCUIT OPEN"
        {:error, :bulkhead_full} -> "BULKHEAD FULL"
        {:error, reason} -> "error: #{inspect(reason)}"
        other -> "unexpected: #{inspect(other)}"
      end

    IO.puts("Request #{String.pad_leading("#{i}", 2)}: #{status}")
    result
  end

IO.puts("")

ok_count = Enum.count(results, fn
  {:ok, %{status: 200}} -> true
  {:ok, {:ok, %{status: 200}}} -> true
  _ -> false
end)

error_count = length(results) - ok_count

IO.puts("Results: #{ok_count} succeeded, #{error_count} failed")
IO.puts("Final circuit breaker state: #{ExResilience.CircuitBreaker.get_state(:http_circuit_breaker)}")
