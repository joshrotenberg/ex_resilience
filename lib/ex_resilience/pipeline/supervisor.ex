defmodule ExResilience.Pipeline.Supervisor do
  @moduledoc """
  Supervisor for GenServer-backed layers in a pipeline.

  Starts and supervises all stateful layers (bulkhead, circuit breaker,
  rate limiter, coalesce, cache) defined in a pipeline. Stateless layers
  (retry, hedge, chaos, fallback) do not require processes and are skipped.

  Uses a `:one_for_one` strategy so individual layer crashes are
  isolated and restarted independently.

  ## Examples

      pipeline =
        ExResilience.Pipeline.new(:my_service)
        |> ExResilience.Pipeline.add(:bulkhead, max_concurrent: 10)
        |> ExResilience.Pipeline.add(:circuit_breaker, failure_threshold: 5)
        |> ExResilience.Pipeline.add(:retry, max_attempts: 3)

      {:ok, sup} = ExResilience.Pipeline.Supervisor.start_link({pipeline, []})

  """

  use Supervisor

  @stateful_layers [:bulkhead, :circuit_breaker, :rate_limiter, :coalesce, :cache]

  @doc """
  Starts a supervisor for the given pipeline.

  Accepts a tuple of `{pipeline, opts}` where `opts` is a keyword list.

  ## Options

    * `:supervisor_name` -- registered name for the supervisor process.
      Defaults to `:"<pipeline_name>_supervisor"`.

  """
  @spec start_link({ExResilience.Pipeline.t(), keyword()}) :: Supervisor.on_start()
  def start_link({pipeline, opts}) do
    name = Keyword.get(opts, :supervisor_name, :"#{pipeline.name}_supervisor")
    Supervisor.start_link(__MODULE__, pipeline, name: name)
  end

  @impl true
  def init(pipeline) do
    children =
      pipeline.layers
      |> Enum.filter(fn {layer, _} -> layer in @stateful_layers end)
      |> Enum.map(fn {layer, opts} ->
        opts =
          Keyword.put_new(opts, :name, ExResilience.Pipeline.child_name(pipeline.name, layer))

        child_spec_for(layer, opts)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec child_spec_for(atom(), keyword()) :: Supervisor.child_spec()
  def child_spec_for(:bulkhead, opts), do: {ExResilience.Bulkhead, opts}
  def child_spec_for(:circuit_breaker, opts), do: {ExResilience.CircuitBreaker, opts}
  def child_spec_for(:rate_limiter, opts), do: {ExResilience.RateLimiter, opts}
  def child_spec_for(:coalesce, opts), do: {ExResilience.Coalesce, opts}
  def child_spec_for(:cache, opts), do: {ExResilience.Cache, opts}
end
