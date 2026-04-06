# Measures the overhead each pattern adds to a no-op function call.
#
# Run with: mix run bench/overhead_bench.exs

alias ExResilience.{Bulkhead, Cache, CircuitBreaker, Coalesce, RateLimiter}

# Start GenServer-backed patterns
{:ok, _} = Bulkhead.start_link(name: :bench_bh, max_concurrent: 1000, max_wait: 5_000)
{:ok, _} = CircuitBreaker.start_link(name: :bench_cb, failure_threshold: 1000)
{:ok, _} = RateLimiter.start_link(name: :bench_rl, rate: 1_000_000, interval: 1_000)
{:ok, _} = Coalesce.start_link(name: :bench_coal)

{:ok, _} =
  Cache.start_link(
    name: :bench_cache,
    backend: ExResilience.Cache.EtsBackend,
    ttl: 60_000
  )

noop = fn -> {:ok, :done} end
counter = :counters.new(1, [:atomics])

Benchee.run(
  %{
    "bare function call" => fn ->
      noop.()
    end,
    "bulkhead" => fn ->
      Bulkhead.call(:bench_bh, noop)
    end,
    "circuit_breaker" => fn ->
      CircuitBreaker.call(:bench_cb, noop)
    end,
    "retry (1 attempt)" => fn ->
      ExResilience.Retry.call(noop, max_attempts: 1)
    end,
    "rate_limiter" => fn ->
      RateLimiter.call(:bench_rl, noop)
    end,
    "coalesce (unique keys)" => fn ->
      :counters.add(counter, 1, 1)
      key = :counters.get(counter, 1)
      Coalesce.call(:bench_coal, key, noop)
    end,
    "cache (miss)" => fn ->
      :counters.add(counter, 1, 1)
      key = "miss_#{:counters.get(counter, 1)}"
      Cache.call(:bench_cache, key, noop)
    end,
    "fallback (no error)" => fn ->
      ExResilience.Fallback.call(noop, fallback: fn _ -> {:ok, :fallback} end)
    end,
    "chaos (passthrough)" => fn ->
      ExResilience.Chaos.call(noop, error_rate: 0.0, latency_rate: 0.0)
    end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)
