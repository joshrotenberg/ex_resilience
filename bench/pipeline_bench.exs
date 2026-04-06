# Measures pipeline overhead with varying numbers of layers.
#
# Run with: mix run bench/pipeline_bench.exs

noop = fn -> {:ok, :done} end

# Build pipelines of increasing depth
pipeline_1 =
  ExResilience.new(:pipe1)
  |> ExResilience.add(:retry, max_attempts: 1)

pipeline_3 =
  ExResilience.new(:pipe3)
  |> ExResilience.add(:bulkhead, max_concurrent: 1000)
  |> ExResilience.add(:circuit_breaker, failure_threshold: 1000)
  |> ExResilience.add(:retry, max_attempts: 1)

pipeline_5 =
  ExResilience.new(:pipe5)
  |> ExResilience.add(:bulkhead, max_concurrent: 1000)
  |> ExResilience.add(:rate_limiter, rate: 1_000_000, interval: 1_000)
  |> ExResilience.add(:circuit_breaker, failure_threshold: 1000)
  |> ExResilience.add(:retry, max_attempts: 1)
  |> ExResilience.add(:fallback, fallback: fn _ -> {:ok, :fb} end)

{:ok, _} = ExResilience.start(pipeline_1)
{:ok, _} = ExResilience.start(pipeline_3)
{:ok, _} = ExResilience.start(pipeline_5)

Benchee.run(
  %{
    "bare call" => fn -> noop.() end,
    "pipeline (1 layer)" => fn -> ExResilience.call(pipeline_1, noop) end,
    "pipeline (3 layers)" => fn -> ExResilience.call(pipeline_3, noop) end,
    "pipeline (5 layers)" => fn -> ExResilience.call(pipeline_5, noop) end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)
