defmodule ExResilience.Pipeline do
  @moduledoc """
  Composable pipeline of resilience layers.

  A pipeline is an ordered list of layers that wrap a function call
  inside-out. The first layer added is the outermost wrapper.

  ## Execution Order

  Given layers `[bulkhead, circuit_breaker, retry]`, execution is:

      Bulkhead -> Circuit Breaker -> Retry -> function

  Each layer wraps the next, so the function sees retry first, then
  circuit breaker, then bulkhead.

  ## Examples

      pipeline = ExResilience.Pipeline.new(:my_pipeline)
      |> ExResilience.Pipeline.add(:bulkhead, max_concurrent: 5)
      |> ExResilience.Pipeline.add(:circuit_breaker, failure_threshold: 3)
      |> ExResilience.Pipeline.add(:retry, max_attempts: 2)

  """

  alias ExResilience.{Bulkhead, Cache, Chaos, CircuitBreaker, Coalesce, Fallback, Hedge, RateLimiter, Retry, Telemetry}

  @type layer :: {atom(), keyword()}

  @type t :: %__MODULE__{
          name: atom(),
          layers: [layer()]
        }

  @enforce_keys [:name]
  defstruct [:name, layers: []]

  @doc """
  Creates a new pipeline with the given name.

  The name is used as a prefix for child process names and in
  telemetry metadata.
  """
  @spec new(atom()) :: t()
  def new(name) when is_atom(name) do
    %__MODULE__{name: name}
  end

  @doc """
  Adds a layer to the pipeline.

  Layers are executed in the order they are added (outermost first).

  ## Supported Layers

    * `:bulkhead` -- see `ExResilience.Bulkhead` for options.
    * `:circuit_breaker` -- see `ExResilience.CircuitBreaker` for options.
    * `:retry` -- see `ExResilience.Retry` for options.
    * `:rate_limiter` -- see `ExResilience.RateLimiter` for options.
    * `:coalesce` -- see `ExResilience.Coalesce` for options.
      Requires a `:key` option, either a static term or a 0-arity
      function returning the key.
    * `:hedge` -- see `ExResilience.Hedge` for options.
    * `:chaos` -- see `ExResilience.Chaos` for options.
    * `:fallback` -- see `ExResilience.Fallback` for options.
    * `:cache` -- see `ExResilience.Cache` for options.
      Requires a `:key` option, either a static term or a 0-arity
      function returning the key.

  """
  @spec add(t(), atom(), keyword()) :: t()
  def add(%__MODULE__{} = pipeline, layer, opts \\ [])
      when layer in [
             :bulkhead,
             :circuit_breaker,
             :retry,
             :rate_limiter,
             :coalesce,
             :hedge,
             :chaos,
             :fallback,
             :cache
           ] do
    %{pipeline | layers: pipeline.layers ++ [{layer, opts}]}
  end

  @doc """
  Starts all GenServer-backed layers in the pipeline.

  Returns `{:ok, pids}` where `pids` is a list of started process pids.
  Layers that don't require a process (like retry) are skipped.
  """
  @spec start(t()) :: {:ok, [pid()]}
  def start(%__MODULE__{} = pipeline) do
    pids =
      pipeline.layers
      |> Enum.filter(fn {layer, _} -> layer in [:bulkhead, :circuit_breaker, :rate_limiter, :coalesce, :cache] end)
      |> Enum.map(fn {layer, opts} ->
        opts = Keyword.put_new(opts, :name, child_name(pipeline.name, layer))
        {:ok, pid} = start_layer(layer, opts)
        pid
      end)

    {:ok, pids}
  end

  @doc """
  Executes `fun` through the pipeline layers.

  Layers must be started first via `start/1` or individually.
  """
  @spec call(t(), (-> term())) :: term()
  def call(%__MODULE__{} = pipeline, fun) do
    layers = Enum.reverse(pipeline.layers)
    layer_names = Enum.map(pipeline.layers, fn {layer, _} -> layer end)

    Telemetry.emit(
      [:ex_resilience, :pipeline, :call, :start],
      %{system_time: System.system_time()},
      %{name: pipeline.name, layers: layer_names}
    )

    start_time = System.monotonic_time()

    wrapped =
      Enum.reduce(layers, fun, fn {layer, opts}, inner ->
        wrap_layer(layer, opts, inner, pipeline.name)
      end)

    result = wrapped.()
    duration = System.monotonic_time() - start_time

    Telemetry.emit(
      [:ex_resilience, :pipeline, :call, :stop],
      %{duration: duration},
      %{name: pipeline.name, result: classify(result)}
    )

    result
  end

  @doc """
  Returns the child process name for a layer in this pipeline.
  """
  @spec child_name(atom(), atom()) :: atom()
  def child_name(pipeline_name, layer) do
    :"#{pipeline_name}_#{layer}"
  end

  # -- Internal --

  defp start_layer(:bulkhead, opts), do: Bulkhead.start_link(opts)
  defp start_layer(:circuit_breaker, opts), do: CircuitBreaker.start_link(opts)
  defp start_layer(:rate_limiter, opts), do: RateLimiter.start_link(opts)
  defp start_layer(:coalesce, opts), do: Coalesce.start_link(opts)
  defp start_layer(:cache, opts), do: Cache.start_link(opts)

  defp wrap_layer(:bulkhead, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :bulkhead))
    fn -> Bulkhead.call(name, inner) end
  end

  defp wrap_layer(:circuit_breaker, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :circuit_breaker))
    fn -> CircuitBreaker.call(name, inner) end
  end

  defp wrap_layer(:rate_limiter, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :rate_limiter))
    fn -> RateLimiter.call(name, inner) end
  end

  defp wrap_layer(:retry, opts, inner, _pipeline_name) do
    fn -> Retry.call(inner, opts) end
  end

  defp wrap_layer(:coalesce, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :coalesce))
    key = Keyword.fetch!(opts, :key)

    fn ->
      resolved_key = if is_function(key, 0), do: key.(), else: key
      Coalesce.call(name, resolved_key, inner)
    end
  end

  defp wrap_layer(:hedge, opts, inner, _pipeline_name) do
    fn -> Hedge.call(inner, opts) end
  end

  defp wrap_layer(:chaos, opts, inner, _pipeline_name) do
    fn -> Chaos.call(inner, opts) end
  end

  defp wrap_layer(:fallback, opts, inner, _pipeline_name) do
    fn -> Fallback.call(inner, opts) end
  end

  defp wrap_layer(:cache, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :cache))
    key = Keyword.fetch!(opts, :key)

    fn ->
      resolved_key = if is_function(key, 0), do: key.(), else: key
      Cache.call(name, resolved_key, inner)
    end
  end

  defp classify({:ok, _}), do: :ok
  defp classify({:error, _}), do: :error
  defp classify(:ok), do: :ok
  defp classify(:error), do: :error
  defp classify(_), do: :ok
end
