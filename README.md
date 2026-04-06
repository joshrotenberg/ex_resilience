# ExResilience

[![CI](https://github.com/joshrotenberg/ex_resilience/actions/workflows/ci.yml/badge.svg)](https://github.com/joshrotenberg/ex_resilience/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_resilience.svg)](https://hex.pm/packages/ex_resilience)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_resilience)

Composable resilience middleware for Elixir. Each pattern is a standalone
GenServer (or stateless module) that can be used independently or composed
into an ordered pipeline.

## Installation

```elixir
def deps do
  [
    {:ex_resilience, "~> 0.1.0"}
  ]
end
```

## Patterns

### Core

| Pattern | Module | Type | Description |
|---------|--------|------|-------------|
| Bulkhead | `ExResilience.Bulkhead` | GenServer | Concurrency limiting with wait queue. ETS-backed permits. |
| Circuit Breaker | `ExResilience.CircuitBreaker` | GenServer | Closed/open/half_open state machine with consecutive failure tracking. |
| Retry | `ExResilience.Retry` | Stateless | Configurable backoff (exponential, linear, fixed) with jitter. |
| Rate Limiter | `ExResilience.RateLimiter` | GenServer | Token bucket with periodic refill. ETS-backed token counter. |

### Extended

| Pattern | Module | Type | Description |
|---------|--------|------|-------------|
| Coalesce | `ExResilience.Coalesce` | GenServer | Deduplicate concurrent identical calls (singleflight). |
| Hedge | `ExResilience.Hedge` | Stateless | Race redundant requests to reduce tail latency. |
| Fallback | `ExResilience.Fallback` | Stateless | Provide alternative results on failure. |
| Chaos | `ExResilience.Chaos` | Stateless | Fault injection for testing (error rate, latency, seeded RNG). |
| Cache | `ExResilience.Cache` | GenServer | Response caching with pluggable backends. |

## Usage

### Standalone

Each pattern works on its own:

```elixir
# Bulkhead -- limit concurrency to 10
{:ok, _} = ExResilience.Bulkhead.start_link(name: :http_pool, max_concurrent: 10)
{:ok, response} = ExResilience.Bulkhead.call(:http_pool, fn -> HTTPClient.get(url) end)

# Circuit breaker -- trip after 5 consecutive failures
{:ok, _} = ExResilience.CircuitBreaker.start_link(name: :db, failure_threshold: 5)
result = ExResilience.CircuitBreaker.call(:db, fn -> Repo.query(sql) end)

# Retry -- 3 attempts with exponential backoff
result = ExResilience.Retry.call(fn -> flaky_api_call() end,
  max_attempts: 3,
  backoff: :exponential,
  base_delay: 100
)

# Rate limiter -- 100 requests per second
{:ok, _} = ExResilience.RateLimiter.start_link(name: :api, rate: 100, interval: 1_000)
result = ExResilience.RateLimiter.call(:api, fn -> external_api_call() end)
```

### Pipeline

Compose multiple patterns into an ordered pipeline:

```elixir
pipeline =
  ExResilience.new(:my_service)
  |> ExResilience.add(:bulkhead, max_concurrent: 10)
  |> ExResilience.add(:circuit_breaker, failure_threshold: 5)
  |> ExResilience.add(:retry, max_attempts: 3, backoff: :exponential)

{:ok, _pids} = ExResilience.start(pipeline)
result = ExResilience.call(pipeline, fn -> do_work() end)
```

Layers execute in the order added (outermost first):

```
Bulkhead -> Circuit Breaker -> Retry -> your function
```

### Coalesce (singleflight)

Deduplicate concurrent calls with the same key. Only one execution runs
per key; all callers receive the same result.

```elixir
{:ok, _} = ExResilience.Coalesce.start_link(name: :dedup)

# These two concurrent calls with the same key only execute once
task1 = Task.async(fn -> ExResilience.Coalesce.call(:dedup, "user:123", fn -> fetch_user(123) end) end)
task2 = Task.async(fn -> ExResilience.Coalesce.call(:dedup, "user:123", fn -> fetch_user(123) end) end)

[result1, result2] = Task.await_many([task1, task2])
# result1 == result2, fetch_user was called only once
```

### Hedge

Reduce tail latency by racing a redundant request after a delay:

```elixir
result = ExResilience.Hedge.call(fn -> slow_api_call() end, delay: 100)
# If the primary doesn't respond in 100ms, a second call races it.
# First success wins; the other is cancelled.
```

### Fallback

Provide a fallback when the primary function fails:

```elixir
result = ExResilience.Fallback.call(
  fn -> fetch_live_data() end,
  fallback: fn _error -> {:ok, cached_data()} end
)
```

### Chaos

Inject faults for testing your resilience pipeline:

```elixir
# Add chaos as the innermost layer to test outer layers
pipeline =
  ExResilience.new(:test_svc)
  |> ExResilience.add(:circuit_breaker, failure_threshold: 3)
  |> ExResilience.add(:retry, max_attempts: 2)
  |> ExResilience.add(:chaos, error_rate: 0.5, seed: 42)

{:ok, _} = ExResilience.start(pipeline)
# 50% of calls will fail, exercising the retry and circuit breaker
```

### Cache

Response caching with pluggable backends:

```elixir
{:ok, _} = ExResilience.Cache.start_link(
  name: :responses,
  backend: ExResilience.Cache.EtsBackend,
  ttl: 30_000
)

# First call executes the function and caches the result
{:ok, data} = ExResilience.Cache.call(:responses, "key", fn -> expensive_query() end)

# Second call returns the cached result without executing
{:ok, ^data} = ExResilience.Cache.call(:responses, "key", fn -> expensive_query() end)
```

Implement `ExResilience.Cache.Backend` to use Cachex, ConCache, or any
other caching library as a backend.

## Telemetry

All patterns emit telemetry events under the `[:ex_resilience, ...]` prefix.
See `ExResilience.Telemetry` for the full list.

```elixir
:telemetry.attach("log-breaker-trip", [:ex_resilience, :circuit_breaker, :state_change], fn
  _event, _measurements, %{from: from, to: to, name: name}, _config ->
    Logger.warning("Circuit breaker #{name} transitioned from #{from} to #{to}")
end, nil)
```

## Why not use existing libraries?

Libraries like `fuse` (circuit breaker), `hammer` (rate limiting), and
`backoff` (delay calculation) are established and battle-tested for their
individual patterns. ExResilience provides value when you need:

- Multiple patterns composed into a single call path
- Consistent API and telemetry across all patterns
- Patterns that aren't covered elsewhere (coalesce, hedge, chaos)

## License

MIT
