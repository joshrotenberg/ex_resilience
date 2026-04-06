defmodule ExResilience.Coalesce do
  @moduledoc """
  Request deduplication (singleflight) implemented as a GenServer.

  When multiple callers request the same key concurrently, only one
  execution runs and all callers receive the same result. Once the
  execution completes, subsequent calls for the same key trigger a
  new execution.

  Uses ETS for the in-flight key lookup (hot path) and GenServer
  for waiter coordination.

  ## Options

    * `:name` -- required. Registered name for this coalesce instance.

  ## Examples

      iex> {:ok, _} = ExResilience.Coalesce.start_link(name: :test_coal)
      iex> ExResilience.Coalesce.call(:test_coal, :my_key, fn -> 42 end)
      {:ok, 42}

  """

  use GenServer

  alias ExResilience.Telemetry

  @type option :: {:name, atom()}

  @type result :: {:ok, term()} | {:error, term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:name, :table]
    defstruct [:name, :table, in_flight: %{}]

    @type waiter :: {reference(), pid()}

    @type t :: %__MODULE__{
            name: atom(),
            table: :ets.tid(),
            in_flight: %{term() => {reference(), [waiter()]}}
          }
  end

  # -- Public API --

  @doc """
  Starts a coalesce process.

  See module docs for available options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` with request deduplication keyed by `key`.

  If no in-flight request exists for `key`, spawns a task to execute
  `fun` and registers the caller as the first waiter. If an in-flight
  request already exists, the caller joins the existing execution.

  All waiters receive the same result when the execution completes.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, _} = ExResilience.Coalesce.start_link(name: :test_coal2)
      iex> ExResilience.Coalesce.call(:test_coal2, :key_a, fn -> :hello end)
      {:ok, :hello}

  """
  @spec call(atom(), term(), (-> term())) :: result()
  def call(name, key, fun) do
    table = table_name(name)

    case :ets.lookup(table, key) do
      [{^key, :in_flight}] ->
        # Join existing in-flight request
        ref = make_ref()
        GenServer.cast(name, {:join, key, {ref, self()}})

        Telemetry.emit(
          [:ex_resilience, :coalesce, :join],
          %{system_time: System.system_time()},
          %{name: name, key: key}
        )

        await_result(ref)

      [] ->
        # Start new execution
        ref = make_ref()
        :ets.insert(table, {key, :in_flight})
        GenServer.cast(name, {:register, key, fun, {ref, self()}})

        Telemetry.emit(
          [:ex_resilience, :coalesce, :execute],
          %{system_time: System.system_time()},
          %{name: name, key: key}
        )

        await_result(ref)
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(table_name(name), [:named_table, :public, :set])

    state = %State{
      name: name,
      table: table
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:register, key, fun, waiter}, state) do
    task = Task.async(fn -> execute(fun) end)

    in_flight = Map.put(state.in_flight, key, {task.ref, [waiter]})
    {:noreply, %{state | in_flight: in_flight}}
  end

  def handle_cast({:join, key, waiter}, state) do
    case Map.get(state.in_flight, key) do
      nil ->
        # Race condition: execution completed between ETS lookup and cast.
        # Send an error so the caller can retry.
        {ref, pid} = waiter
        send(pid, {:coalesce_result, ref, {:error, :not_found}})
        {:noreply, state}

      {task_ref, waiters} ->
        in_flight = Map.put(state.in_flight, key, {task_ref, [waiter | waiters]})
        {:noreply, %{state | in_flight: in_flight}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully. Find the key for this task ref.
    Process.demonitor(ref, [:flush])

    case find_key_by_task_ref(state.in_flight, ref) do
      {key, waiters} ->
        broadcast(waiters, result)
        :ets.delete(state.table, key)

        Telemetry.emit(
          [:ex_resilience, :coalesce, :complete],
          %{waiters: length(waiters)},
          %{name: state.name, key: key, result: classify(result)}
        )

        in_flight = Map.delete(state.in_flight, key)
        {:noreply, %{state | in_flight: in_flight}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task crashed. Broadcast error to all waiters.
    case find_key_by_task_ref(state.in_flight, ref) do
      {key, waiters} ->
        error_result = {:error, {:task_crashed, reason}}
        broadcast(waiters, error_result)
        :ets.delete(state.table, key)

        Telemetry.emit(
          [:ex_resilience, :coalesce, :complete],
          %{waiters: length(waiters)},
          %{name: state.name, key: key, result: :error}
        )

        in_flight = Map.delete(state.in_flight, key)
        {:noreply, %{state | in_flight: in_flight}}

      nil ->
        {:noreply, state}
    end
  end

  # -- Internal --

  defp table_name(name), do: :"#{name}_coalesce"

  defp execute(fun) do
    result = fun.()
    wrap_result(result)
  rescue
    e -> {:error, {e, __STACKTRACE__}}
  end

  defp await_result(ref) do
    receive do
      {:coalesce_result, ^ref, result} -> result
    end
  end

  defp broadcast(waiters, result) do
    Enum.each(waiters, fn {ref, pid} ->
      send(pid, {:coalesce_result, ref, result})
    end)
  end

  defp find_key_by_task_ref(in_flight, ref) do
    Enum.find_value(in_flight, fn {key, {task_ref, waiters}} ->
      if task_ref == ref, do: {key, waiters}
    end)
  end

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, _} = err), do: err
  defp wrap_result(:ok), do: {:ok, :ok}
  defp wrap_result(:error), do: {:error, :error}
  defp wrap_result(other), do: {:ok, other}

  defp classify({:error, _}), do: :error
  defp classify(:error), do: :error
  defp classify(_), do: :ok
end
