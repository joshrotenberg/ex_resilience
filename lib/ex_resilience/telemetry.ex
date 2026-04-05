defmodule ExResilience.Telemetry do
  @moduledoc """
  Telemetry event definitions for ExResilience.

  All events are prefixed with `[:ex_resilience, <pattern>]`.

  ## Bulkhead Events

    * `[:ex_resilience, :bulkhead, :call, :start]` - emitted when a call enters the bulkhead.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom}`.

    * `[:ex_resilience, :bulkhead, :call, :stop]` - emitted when a call completes.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{name: atom, result: :ok | :error}`.

    * `[:ex_resilience, :bulkhead, :call, :exception]` - emitted when a call raises.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{name: atom, kind: atom, reason: term, stacktrace: list}`.

    * `[:ex_resilience, :bulkhead, :rejected]` - emitted when a call is rejected.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, reason: :max_concurrent | :max_wait_exceeded}`.

  ## Circuit Breaker Events

    * `[:ex_resilience, :circuit_breaker, :call, :start]` - emitted when a call enters the breaker.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, state: :closed | :half_open}`.

    * `[:ex_resilience, :circuit_breaker, :call, :stop]` - emitted when a call completes.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{name: atom, state: atom, result: :ok | :error}`.

    * `[:ex_resilience, :circuit_breaker, :rejected]` - emitted when a call is rejected (breaker open).
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom}`.

    * `[:ex_resilience, :circuit_breaker, :state_change]` - emitted on state transitions.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, from: atom, to: atom}`.

  ## Retry Events

    * `[:ex_resilience, :retry, :attempt]` - emitted on each attempt.
      Measurements: `%{attempt: pos_integer, delay_ms: non_neg_integer}`.
      Metadata: `%{name: atom}`.

    * `[:ex_resilience, :retry, :exhausted]` - emitted when all retries are exhausted.
      Measurements: `%{attempts: pos_integer}`.
      Metadata: `%{name: atom, last_result: term}`.

  ## Rate Limiter Events

    * `[:ex_resilience, :rate_limiter, :allowed]` - emitted when a call is allowed.
      Measurements: `%{tokens_remaining: non_neg_integer}`.
      Metadata: `%{name: atom}`.

    * `[:ex_resilience, :rate_limiter, :rejected]` - emitted when a call is rejected.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, retry_after_ms: non_neg_integer}`.

  ## Cache Events

    * `[:ex_resilience, :cache, :hit]` - emitted on cache hit.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, key: term}`.

    * `[:ex_resilience, :cache, :miss]` - emitted on cache miss.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, key: term}`.

    * `[:ex_resilience, :cache, :put]` - emitted when a value is stored.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, key: term}`.

    * `[:ex_resilience, :cache, :invalidate]` - emitted when an entry is invalidated.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, key: term}`.

  ## Pipeline Events

    * `[:ex_resilience, :pipeline, :call, :start]` - emitted when a pipeline call starts.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{name: atom, layers: [atom]}`.

    * `[:ex_resilience, :pipeline, :call, :stop]` - emitted when a pipeline call completes.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{name: atom, result: :ok | :error}`.
  """

  @doc false
  @spec event_prefix() :: [atom()]
  def event_prefix, do: [:ex_resilience]

  @doc """
  Returns the list of all telemetry events emitted by ExResilience.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      # Bulkhead
      [:ex_resilience, :bulkhead, :call, :start],
      [:ex_resilience, :bulkhead, :call, :stop],
      [:ex_resilience, :bulkhead, :call, :exception],
      [:ex_resilience, :bulkhead, :rejected],
      # Circuit breaker
      [:ex_resilience, :circuit_breaker, :call, :start],
      [:ex_resilience, :circuit_breaker, :call, :stop],
      [:ex_resilience, :circuit_breaker, :rejected],
      [:ex_resilience, :circuit_breaker, :state_change],
      # Retry
      [:ex_resilience, :retry, :attempt],
      [:ex_resilience, :retry, :exhausted],
      # Rate limiter
      [:ex_resilience, :rate_limiter, :allowed],
      [:ex_resilience, :rate_limiter, :rejected],
      # Cache
      [:ex_resilience, :cache, :hit],
      [:ex_resilience, :cache, :miss],
      [:ex_resilience, :cache, :put],
      [:ex_resilience, :cache, :invalidate],
      # Pipeline
      [:ex_resilience, :pipeline, :call, :start],
      [:ex_resilience, :pipeline, :call, :stop]
    ]
  end

  @doc false
  @spec emit(list(), map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc false
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event_prefix, metadata, fun) do
    :telemetry.span(event_prefix, metadata, fun)
  end
end
