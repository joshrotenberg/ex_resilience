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

  alias ExResilience.{
    AdaptiveConcurrency,
    Bulkhead,
    Cache,
    Chaos,
    CircuitBreaker,
    Coalesce,
    Fallback,
    Hedge,
    RateLimiter,
    Retry,
    Telemetry
  }

  @valid_layers [
    :bulkhead,
    :circuit_breaker,
    :retry,
    :rate_limiter,
    :coalesce,
    :hedge,
    :chaos,
    :fallback,
    :cache
  ]

  @doc """
  Generates a supervised pipeline module.

  When a module does `use ExResilience.Pipeline`, it gets:

    * `child_spec/1` -- returns a supervisor child spec
    * `start_link/1` -- starts the pipeline supervisor
    * `pipeline/0` -- returns the built `%Pipeline{}` struct
    * `call/1` -- executes a function through the pipeline
    * `call/2` -- executes a function through the pipeline (second arg reserved for future options)

  ## Options

    * `:name` -- pipeline name atom. Defaults to the module name converted to an atom.
    * Layer keys -- any of #{inspect(@valid_layers)}. Each takes a keyword list of
      options for that layer. Layers are added in the order specified.

  ## Examples

      defmodule MyApp.Resilience do
        use ExResilience.Pipeline,
          name: :my_service,
          bulkhead: [max_concurrent: 10],
          circuit_breaker: [failure_threshold: 5],
          retry: [max_attempts: 3]
      end

      # In your supervision tree:
      children = [MyApp.Resilience]
      Supervisor.start_link(children, strategy: :one_for_one)

      # Then call through the pipeline:
      MyApp.Resilience.call(fn -> HTTPClient.get(url) end)

  """
  defmacro __using__(opts) do
    valid_layers = @valid_layers

    {name, layer_opts} = Keyword.pop(opts, :name)

    # Validate layer keys at compile time
    for {key, _} <- layer_opts do
      unless key in valid_layers do
        raise ArgumentError,
              "unknown layer #{inspect(key)} in use ExResilience.Pipeline. " <>
                "Valid layers: #{inspect(valid_layers)}"
      end
    end

    # Build layers as a list of {atom, keyword} tuples
    layers =
      Enum.map(layer_opts, fn {layer, layer_config} ->
        {layer, layer_config}
      end)

    quote do
      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      @doc """
      Starts the pipeline supervisor.

      Accepts an optional keyword list of options. Passes through to
      `ExResilience.Pipeline.Supervisor.start_link/1`.
      """
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts \\ []) do
        ExResilience.Pipeline.Supervisor.start_link({pipeline(), opts})
      end

      @doc """
      Returns the pipeline struct for this module.
      """
      @spec pipeline() :: ExResilience.Pipeline.t()
      def pipeline do
        name =
          case unquote(name) do
            nil ->
              __MODULE__
              |> Module.split()
              |> Enum.join("_")
              |> Macro.underscore()
              |> String.replace("/", "_")
              |> String.to_atom()

            n ->
              n
          end

        layers = unquote(Macro.escape(layers))

        Enum.reduce(layers, ExResilience.Pipeline.new(name), fn {layer, layer_opts}, acc ->
          ExResilience.Pipeline.add(acc, layer, layer_opts)
        end)
      end

      @doc """
      Executes `fun` through the pipeline layers.
      """
      @spec call((-> term())) :: term()
      def call(fun) do
        ExResilience.Pipeline.call(pipeline(), fun)
      end

      @doc """
      Executes `fun` through the pipeline layers.

      The second argument is reserved for future options and is currently ignored.
      """
      @spec call((-> term()), keyword()) :: term()
      def call(fun, _opts) do
        ExResilience.Pipeline.call(pipeline(), fun)
      end
    end
  end

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
    * `:adaptive_concurrency` -- see `ExResilience.AdaptiveConcurrency`
      for options.

  """
  @spec add(t(), atom(), keyword()) :: t()
  def add(%__MODULE__{} = pipeline, layer, opts \\ [])
      when layer in [
             :adaptive_concurrency,
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
      |> Enum.filter(fn {layer, _} ->
        layer in [
          :adaptive_concurrency,
          :bulkhead,
          :circuit_breaker,
          :rate_limiter,
          :coalesce,
          :cache
        ]
      end)
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
  Sets the error classifier for all layers in the pipeline that support it.

  Layers that already have an `:error_classifier` option are not overwritten.
  Only `:circuit_breaker`, `:retry`, and `:fallback` layers are affected.

  ## Examples

      pipeline = Pipeline.new(:my_pipe)
      |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
      |> Pipeline.add(:retry, max_attempts: 2)
      |> Pipeline.with_classifier(MyApp.Classifier)

  """
  @spec with_classifier(t(), module()) :: t()
  def with_classifier(%__MODULE__{} = pipeline, classifier) when is_atom(classifier) do
    layers =
      Enum.map(pipeline.layers, fn {layer, opts} ->
        if layer in [:circuit_breaker, :retry, :fallback] do
          {layer, Keyword.put_new(opts, :error_classifier, classifier)}
        else
          {layer, opts}
        end
      end)

    %{pipeline | layers: layers}
  end

  @doc """
  Returns the child process name for a layer in this pipeline.
  """
  @spec child_name(atom(), atom()) :: atom()
  def child_name(pipeline_name, layer) do
    :"#{pipeline_name}_#{layer}"
  end

  # -- Internal --

  defp start_layer(:adaptive_concurrency, opts), do: AdaptiveConcurrency.start_link(opts)
  defp start_layer(:bulkhead, opts), do: Bulkhead.start_link(opts)
  defp start_layer(:circuit_breaker, opts), do: CircuitBreaker.start_link(opts)
  defp start_layer(:rate_limiter, opts), do: RateLimiter.start_link(opts)
  defp start_layer(:coalesce, opts), do: Coalesce.start_link(opts)
  defp start_layer(:cache, opts), do: Cache.start_link(opts)

  defp wrap_layer(:adaptive_concurrency, opts, inner, pipeline_name) do
    name = Keyword.get(opts, :name, child_name(pipeline_name, :adaptive_concurrency))
    fn -> AdaptiveConcurrency.call(name, inner) end
  end

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
