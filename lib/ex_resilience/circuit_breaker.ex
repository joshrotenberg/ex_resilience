defmodule ExResilience.CircuitBreaker do
  @moduledoc """
  Circuit breaker implemented as a GenServer.

  Tracks consecutive failures and transitions through three states:

    * `:closed` -- calls pass through. Failures increment the counter.
    * `:open` -- calls are rejected immediately with `{:error, :circuit_open}`.
      After `reset_timeout` ms, transitions to `:half_open`.
    * `:half_open` -- allows one trial call. Success resets to `:closed`,
      failure reopens to `:open`.

  ## Options

    * `:name` -- required. Registered name for this breaker instance.
    * `:failure_threshold` -- consecutive failures before opening. Default `5`.
    * `:reset_timeout` -- ms to wait in `:open` before trying `:half_open`. Default `30_000`.
    * `:half_open_max_calls` -- concurrent calls allowed in `:half_open`. Default `1`.
    * `:error_classifier` -- 1-arity function that returns `true` if the result
      should count as a failure. Default: matches `{:error, _}` and `:error`.

  ## Examples

      iex> {:ok, _} = ExResilience.CircuitBreaker.start_link(name: :test_cb, failure_threshold: 2, reset_timeout: 100)
      iex> ExResilience.CircuitBreaker.call(:test_cb, fn -> :ok end)
      {:ok, :ok}

  """

  use GenServer

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:failure_threshold, pos_integer()}
          | {:reset_timeout, pos_integer()}
          | {:half_open_max_calls, pos_integer()}
          | {:error_classifier, (term() -> boolean())}

  @type state_name :: :closed | :open | :half_open

  @type result :: {:ok, term()} | {:error, :circuit_open} | {:error, term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :name,
      :failure_threshold,
      :reset_timeout,
      :half_open_max_calls,
      :error_classifier
    ]
    defstruct [
      :name,
      :failure_threshold,
      :reset_timeout,
      :half_open_max_calls,
      :error_classifier,
      :reset_timer,
      state: :closed,
      failure_count: 0,
      half_open_calls: 0
    ]

    @type t :: %__MODULE__{
            name: atom(),
            failure_threshold: pos_integer(),
            reset_timeout: pos_integer(),
            half_open_max_calls: pos_integer(),
            error_classifier: (term() -> boolean()),
            reset_timer: reference() | nil,
            state: :closed | :open | :half_open,
            failure_count: non_neg_integer(),
            half_open_calls: non_neg_integer()
          }
  end

  @doc false
  @spec default_error_classifier(term()) :: boolean()
  def default_error_classifier({:error, _}), do: true
  def default_error_classifier(:error), do: true
  def default_error_classifier(_), do: false

  # -- Public API --

  @doc """
  Starts a circuit breaker process.

  See module docs for available options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` through the circuit breaker.

  Returns `{:ok, result}` on success, `{:error, :circuit_open}` if the
  breaker is open, or `{:error, reason}` if the function returns an error.

  Raises if the function raises (the raise counts as a failure).
  """
  @spec call(atom(), (-> term())) :: result()
  def call(name, fun) do
    case GenServer.call(name, :acquire) do
      {:ok, cb_state} ->
        Telemetry.emit(
          [:ex_resilience, :circuit_breaker, :call, :start],
          %{system_time: System.system_time()},
          %{name: name, state: cb_state}
        )

        start_time = System.monotonic_time()

        try do
          result = fun.()
          duration = System.monotonic_time() - start_time
          GenServer.cast(name, {:record_result, result})

          Telemetry.emit(
            [:ex_resilience, :circuit_breaker, :call, :stop],
            %{duration: duration},
            %{name: name, state: cb_state, result: classify(result)}
          )

          wrap_result(result)
        rescue
          e ->
            GenServer.cast(name, {:record_result, {:error, e}})
            reraise e, __STACKTRACE__
        end

      {:error, :circuit_open} ->
        Telemetry.emit(
          [:ex_resilience, :circuit_breaker, :rejected],
          %{system_time: System.system_time()},
          %{name: name}
        )

        {:error, :circuit_open}
    end
  end

  @doc """
  Returns the current state of the circuit breaker.
  """
  @spec get_state(atom()) :: state_name()
  def get_state(name) do
    GenServer.call(name, :get_state)
  end

  @doc """
  Manually resets the circuit breaker to `:closed`.
  """
  @spec reset(atom()) :: :ok
  def reset(name) do
    GenServer.call(name, :reset)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :name),
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      reset_timeout: Keyword.get(opts, :reset_timeout, 30_000),
      half_open_max_calls: Keyword.get(opts, :half_open_max_calls, 1),
      error_classifier: Keyword.get(opts, :error_classifier, &default_error_classifier/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, _from, %State{state: :closed} = state) do
    {:reply, {:ok, :closed}, state}
  end

  def handle_call(:acquire, _from, %State{state: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call(:acquire, _from, %State{state: :half_open} = state) do
    if state.half_open_calls < state.half_open_max_calls do
      {:reply, {:ok, :half_open}, %{state | half_open_calls: state.half_open_calls + 1}}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:reset, _from, state) do
    cancel_timer(state.reset_timer)

    new_state = %{state | state: :closed, failure_count: 0, half_open_calls: 0, reset_timer: nil}

    Telemetry.emit(
      [:ex_resilience, :circuit_breaker, :state_change],
      %{system_time: System.system_time()},
      %{name: state.name, from: state.state, to: :closed}
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:record_result, result}, state) do
    is_failure = state.error_classifier.(result)
    {:noreply, handle_result(state, is_failure)}
  end

  @impl true
  def handle_info(:reset_timeout, %State{state: :open} = state) do
    Telemetry.emit(
      [:ex_resilience, :circuit_breaker, :state_change],
      %{system_time: System.system_time()},
      %{name: state.name, from: :open, to: :half_open}
    )

    {:noreply, %{state | state: :half_open, half_open_calls: 0, reset_timer: nil}}
  end

  def handle_info(:reset_timeout, state) do
    {:noreply, state}
  end

  # -- Internal --

  defp handle_result(%State{state: :closed} = state, true) do
    new_count = state.failure_count + 1

    if new_count >= state.failure_threshold do
      trip(state)
    else
      %{state | failure_count: new_count}
    end
  end

  defp handle_result(%State{state: :closed} = state, false) do
    %{state | failure_count: 0}
  end

  defp handle_result(%State{state: :half_open} = state, true) do
    trip(state)
  end

  defp handle_result(%State{state: :half_open} = state, false) do
    Telemetry.emit(
      [:ex_resilience, :circuit_breaker, :state_change],
      %{system_time: System.system_time()},
      %{name: state.name, from: :half_open, to: :closed}
    )

    %{state | state: :closed, failure_count: 0, half_open_calls: 0}
  end

  defp handle_result(state, _is_failure), do: state

  defp trip(state) do
    cancel_timer(state.reset_timer)
    timer = Process.send_after(self(), :reset_timeout, state.reset_timeout)

    Telemetry.emit(
      [:ex_resilience, :circuit_breaker, :state_change],
      %{system_time: System.system_time()},
      %{name: state.name, from: state.state, to: :open}
    )

    %{state | state: :open, failure_count: 0, half_open_calls: 0, reset_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, _} = err), do: err
  defp wrap_result(:ok), do: {:ok, :ok}
  defp wrap_result(:error), do: {:error, :error}
  defp wrap_result(other), do: {:ok, other}

  defp classify({:error, _}), do: :error
  defp classify(:error), do: :error
  defp classify(_), do: :ok
end
