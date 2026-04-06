defmodule ExResilience.Bulkhead do
  @moduledoc """
  Concurrency-limiting bulkhead implemented as a GenServer.

  Limits the number of concurrent executions of a function. Callers beyond
  the limit are queued and served in order. If the queue wait exceeds
  `max_wait`, the caller receives `{:error, :bulkhead_full}`.

  Uses `:atomics` for the permit counter (lock-free CAS) and the GenServer
  for queue management.

  ## Options

    * `:name` -- required. Registered name for this bulkhead instance.
    * `:max_concurrent` -- maximum concurrent executions. Default `10`.
    * `:max_wait` -- maximum time in ms a caller waits in the queue.
      Default `5_000`. Set to `0` to reject immediately when full.

  ## Examples

      iex> {:ok, _} = ExResilience.Bulkhead.start_link(name: :test_bh, max_concurrent: 2)
      iex> ExResilience.Bulkhead.call(:test_bh, fn -> :done end)
      {:ok, :done}

  """

  use GenServer

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:max_concurrent, pos_integer()}
          | {:max_wait, non_neg_integer()}

  @type result :: {:ok, term()} | {:error, :bulkhead_full} | {:error, term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:name, :max_concurrent, :max_wait, :table, :counter]
    defstruct [
      :name,
      :max_concurrent,
      :max_wait,
      :table,
      :counter,
      queue: :queue.new(),
      timers: %{}
    ]

    @type t :: %__MODULE__{
            name: atom(),
            max_concurrent: pos_integer(),
            max_wait: non_neg_integer(),
            table: :ets.tid(),
            counter: :atomics.atomics_ref(),
            queue: :queue.queue({reference(), pid()}),
            timers: %{reference() => reference()}
          }
  end

  # -- Public API --

  @doc """
  Starts a bulkhead process.

  See module docs for available options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` within the bulkhead's concurrency limit.

  Returns `{:ok, result}` on success, `{:error, :bulkhead_full}` if the
  bulkhead is at capacity and the wait queue times out, or `{:error, reason}`
  if the function returns an error tuple.

  Raises if the function raises.
  """
  @spec call(atom(), (-> term()), non_neg_integer() | :infinity) :: result()
  def call(name, fun, timeout \\ :infinity) do
    table = table_name(name)

    case try_acquire(table) do
      :ok ->
        execute_and_release(name, table, fun)

      :full ->
        Telemetry.emit(
          [:ex_resilience, :bulkhead, :call, :start],
          %{system_time: System.system_time()},
          %{name: name}
        )

        ref = make_ref()
        GenServer.cast(name, {:enqueue, ref, self()})

        receive do
          {:bulkhead_permit, ^ref} ->
            execute_and_release(name, table, fun)
        after
          effective_timeout(name, timeout) ->
            GenServer.cast(name, {:dequeue, ref})

            Telemetry.emit(
              [:ex_resilience, :bulkhead, :rejected],
              %{system_time: System.system_time()},
              %{name: name, reason: :max_wait_exceeded}
            )

            {:error, :bulkhead_full}
        end
    end
  end

  @doc """
  Returns the current number of active (in-use) permits.
  """
  @spec active_count(atom()) :: non_neg_integer()
  def active_count(name) do
    [{:counter, counter}] = :ets.lookup(table_name(name), :counter)
    max(:atomics.get(counter, 1), 0)
  end

  @doc """
  Returns the current queue length.
  """
  @spec queue_length(atom()) :: non_neg_integer()
  def queue_length(name) do
    GenServer.call(name, :queue_length)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    max_concurrent = Keyword.get(opts, :max_concurrent, 10)
    max_wait = Keyword.get(opts, :max_wait, 5_000)

    table = :ets.new(table_name(name), [:named_table, :public, :set])
    # Index 1 = active count
    counter = :atomics.new(1, signed: true)
    :ets.insert(table, {:counter, counter})
    :ets.insert(table, {:max, max_concurrent})
    :ets.insert(table, {:max_wait, max_wait})

    state = %State{
      name: name,
      max_concurrent: max_concurrent,
      max_wait: max_wait,
      table: table,
      counter: counter
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, ref, pid}, state) do
    queue = :queue.in({ref, pid}, state.queue)
    {:noreply, %{state | queue: queue}}
  end

  def handle_cast({:dequeue, ref}, state) do
    queue =
      :queue.filter(fn {r, _pid} -> r != ref end, state.queue)

    {:noreply, %{state | queue: queue}}
  end

  def handle_cast(:release, state) do
    case :queue.out(state.queue) do
      {{:value, {ref, pid}}, rest} ->
        send(pid, {:bulkhead_permit, ref})
        {:noreply, %{state | queue: rest}}

      {:empty, _} ->
        :atomics.sub(state.counter, 1, 1)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:queue_length, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  # -- Internal --

  defp table_name(name), do: :"#{name}_bulkhead"

  defp try_acquire(table) do
    [{:max, max}] = :ets.lookup(table, :max)
    [{:counter, counter}] = :ets.lookup(table, :counter)
    cas_acquire(counter, max)
  end

  # Compare-and-swap loop: atomically increment only if below max.
  defp cas_acquire(counter, max) do
    current = :atomics.get(counter, 1)

    if current < max do
      case :atomics.compare_exchange(counter, 1, current, current + 1) do
        :ok -> :ok
        _val -> cas_acquire(counter, max)
      end
    else
      :full
    end
  end

  defp release(name, _table) do
    GenServer.cast(name, :release)
  end

  defp execute_and_release(name, table, fun) do
    Telemetry.emit(
      [:ex_resilience, :bulkhead, :call, :start],
      %{system_time: System.system_time()},
      %{name: name}
    )

    start_time = System.monotonic_time()

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      Telemetry.emit(
        [:ex_resilience, :bulkhead, :call, :stop],
        %{duration: duration},
        %{name: name, result: classify_result(result)}
      )

      wrap_result(result)
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        Telemetry.emit(
          [:ex_resilience, :bulkhead, :call, :exception],
          %{duration: duration},
          %{name: name, kind: :error, reason: e, stacktrace: __STACKTRACE__}
        )

        reraise e, __STACKTRACE__
    after
      release(name, table)
    end
  end

  defp effective_timeout(name, :infinity) do
    table = table_name(name)
    [{:max_wait, max_wait}] = :ets.lookup(table, :max_wait)
    max_wait
  end

  defp effective_timeout(_name, timeout), do: timeout

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, _} = err), do: err
  defp wrap_result(:ok), do: {:ok, :ok}
  defp wrap_result(:error), do: {:error, :error}
  defp wrap_result(other), do: {:ok, other}

  defp classify_result({:error, _}), do: :error
  defp classify_result(:error), do: :error
  defp classify_result(_), do: :ok
end
