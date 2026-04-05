defmodule ExResilience do
  @moduledoc """
  Composable resilience middleware for Elixir.

  Provides bulkhead, circuit breaker, retry, and rate limiter patterns
  as independently usable GenServer-based layers that compose into
  an ordered pipeline.

  ## Standalone Usage

  Each pattern can be used on its own:

      {:ok, _} = ExResilience.Bulkhead.start_link(name: :http_pool, max_concurrent: 10)
      {:ok, response} = ExResilience.Bulkhead.call(:http_pool, fn -> HTTPClient.get(url) end)

  ## Pipeline Usage

      pipeline =
        ExResilience.new(:my_service)
        |> ExResilience.add(:bulkhead, max_concurrent: 10)
        |> ExResilience.add(:circuit_breaker, failure_threshold: 5)
        |> ExResilience.add(:retry, max_attempts: 3)

      {:ok, _pids} = ExResilience.start(pipeline)
      result = ExResilience.call(pipeline, fn -> HTTPClient.get(url) end)

  Layers execute in the order added (outermost first). The example above
  runs: Bulkhead -> Circuit Breaker -> Retry -> function.
  """

  alias ExResilience.Pipeline

  @doc """
  Creates a new pipeline with the given name.

  The name is used as a prefix for child process names and in
  telemetry metadata.

  ## Examples

      iex> pipeline = ExResilience.new(:my_service)
      iex> pipeline.name
      :my_service

  """
  @spec new(atom()) :: Pipeline.t()
  defdelegate new(name), to: Pipeline

  @doc """
  Adds a layer to the pipeline.

  See `ExResilience.Pipeline.add/3` for supported layers and options.

  ## Examples

      iex> pipeline = ExResilience.new(:svc) |> ExResilience.add(:retry, max_attempts: 2)
      iex> length(pipeline.layers)
      1

  """
  @spec add(Pipeline.t(), atom(), keyword()) :: Pipeline.t()
  defdelegate add(pipeline, layer, opts \\ []), to: Pipeline

  @doc """
  Starts all GenServer-backed layers in the pipeline.

  Returns `{:ok, pids}`.
  """
  @spec start(Pipeline.t()) :: {:ok, [pid()]}
  defdelegate start(pipeline), to: Pipeline

  @doc """
  Executes `fun` through the pipeline layers.

  Layers must be started first via `start/1`.
  """
  @spec call(Pipeline.t(), (-> term())) :: term()
  defdelegate call(pipeline, fun), to: Pipeline
end
