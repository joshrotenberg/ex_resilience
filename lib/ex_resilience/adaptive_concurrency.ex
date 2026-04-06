defmodule ExResilience.AdaptiveConcurrency do
  @moduledoc """
  Adaptive concurrency limiter that dynamically adjusts its limit based on
  observed latency.

  Unlike `ExResilience.Bulkhead`, which uses a fixed concurrency limit, this
  module adjusts the limit up or down in response to measured call duration.
  Callers beyond the current limit are rejected immediately (no wait queue),
  keeping latency measurements clean.

  Two algorithms are supported:

  ## AIMD (Additive Increase, Multiplicative Decrease)

  A simple sawtooth pattern. On each completed call:

    * If the call succeeded and latency is below the threshold, the limit
      increases by `:increase_by` (additive).
    * If the call failed or latency exceeds the threshold, the limit is
      multiplied by `:decrease_factor` (multiplicative decrease).

  ## Vegas

  Inspired by TCP Vegas. Tracks a sliding window of RTT samples and estimates
  queue depth:

      queue = limit * (1 - min_rtt / sample_rtt)

    * If `queue < alpha`, the limit increases by 1 (under-utilized).
    * If `queue > beta`, the limit decreases by 1 (overloaded).
    * Otherwise the limit holds steady.

  ## Options

    * `:name` -- required. Registered name for this instance.
    * `:algorithm` -- `:aimd` or `:vegas`. Default `:aimd`.
    * `:initial_limit` -- starting concurrency limit. Default `10`.
    * `:min_limit` -- floor for the limit. Default `1`.
    * `:max_limit` -- ceiling for the limit. Default `200`.

  ### AIMD-specific options

    * `:latency_threshold` -- milliseconds above which a response counts as
      slow. Default `100`.
    * `:increase_by` -- additive increase amount on fast success. Default `1`.
    * `:decrease_factor` -- multiplicative factor applied on slow/failed calls.
      Default `0.5`.

  ### Vegas-specific options

    * `:alpha` -- queue size threshold below which the limit increases.
      Default `3`.
    * `:beta` -- queue size threshold above which the limit decreases.
      Default `6`.
    * `:window_size` -- number of RTT samples kept in the sliding window.
      Default `100`.

  ## Examples

      iex> {:ok, _} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_doc, algorithm: :aimd, initial_limit: 5)
      iex> ExResilience.AdaptiveConcurrency.call(:ac_doc, fn -> :hello end)
      {:ok, :hello}

  """

  use GenServer

  alias ExResilience.Telemetry

  @type algorithm :: :aimd | :vegas

  @type option ::
          {:name, atom()}
          | {:algorithm, algorithm()}
          | {:initial_limit, pos_integer()}
          | {:min_limit, pos_integer()}
          | {:max_limit, pos_integer()}
          | {:latency_threshold, pos_integer()}
          | {:increase_by, pos_integer()}
          | {:decrease_factor, float()}
          | {:alpha, pos_integer()}
          | {:beta, pos_integer()}
          | {:window_size, pos_integer()}

  @type result :: {:ok, term()} | {:error, :concurrency_limited} | {:error, term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:name, :algorithm, :min_limit, :max_limit, :table]
    defstruct [
      :name,
      :algorithm,
      :min_limit,
      :max_limit,
      :table,
      # AIMD fields
      latency_threshold: 100,
      increase_by: 1,
      decrease_factor: 0.5,
      # Vegas fields
      alpha: 3,
      beta: 6,
      window_size: 100,
      rtt_samples: [],
      min_rtt: nil
    ]

    @type t :: %__MODULE__{
            name: atom(),
            algorithm: ExResilience.AdaptiveConcurrency.algorithm(),
            min_limit: pos_integer(),
            max_limit: pos_integer(),
            table: atom(),
            latency_threshold: pos_integer(),
            increase_by: pos_integer(),
            decrease_factor: float(),
            alpha: pos_integer(),
            beta: pos_integer(),
            window_size: pos_integer(),
            rtt_samples: [number()],
            min_rtt: number() | nil
          }
  end

  # -- Public API --

  @doc """
  Starts an adaptive concurrency limiter process.

  See module docs for available options.

  ## Examples

      iex> {:ok, pid} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_start, algorithm: :vegas, initial_limit: 10)
      iex> is_pid(pid)
      true

  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` within the adaptive concurrency limit.

  Returns `{:ok, result}` on success, `{:error, :concurrency_limited}` when the
  current limit is reached, or `{:error, reason}` if the function returns an
  error tuple.

  There is no wait queue. Callers beyond the limit are rejected immediately.

  ## Examples

      iex> {:ok, _} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_call, initial_limit: 5)
      iex> ExResilience.AdaptiveConcurrency.call(:ac_call, fn -> 42 end)
      {:ok, 42}

      iex> {:ok, _} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_call_err, initial_limit: 5)
      iex> ExResilience.AdaptiveConcurrency.call(:ac_call_err, fn -> {:error, :boom} end)
      {:error, :boom}

  """
  @spec call(atom(), (-> term())) :: result()
  def call(name, fun) do
    table = table_name(name)

    case try_acquire(table) do
      :ok ->
        Telemetry.emit(
          [:ex_resilience, :adaptive_concurrency, :call, :start],
          %{system_time: System.system_time()},
          %{name: name}
        )

        start_time = System.monotonic_time()

        try do
          result = fun.()
          duration = System.monotonic_time() - start_time
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)

          Telemetry.emit(
            [:ex_resilience, :adaptive_concurrency, :call, :stop],
            %{duration: duration},
            %{name: name, result: classify_result(result)}
          )

          outcome = classify_result(result)
          GenServer.cast(name, {:sample, outcome, duration_ms})
          wrap_result(result)
        rescue
          e ->
            duration = System.monotonic_time() - start_time
            duration_ms = System.convert_time_unit(duration, :native, :millisecond)
            GenServer.cast(name, {:sample, :error, duration_ms})
            reraise e, __STACKTRACE__
        after
          release(table)
        end

      :full ->
        Telemetry.emit(
          [:ex_resilience, :adaptive_concurrency, :rejected],
          %{system_time: System.system_time()},
          %{name: name}
        )

        {:error, :concurrency_limited}
    end
  end

  @doc """
  Returns the current concurrency limit.

  ## Examples

      iex> {:ok, _} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_gl, initial_limit: 15)
      iex> ExResilience.AdaptiveConcurrency.get_limit(:ac_gl)
      15

  """
  @spec get_limit(atom()) :: pos_integer()
  def get_limit(name) do
    [{:limit, limit}] = :ets.lookup(table_name(name), :limit)
    limit
  end

  @doc """
  Returns stats about the current state of the limiter.

  Returns a map with keys `:limit`, `:min_rtt`, and `:active`.

  ## Examples

      iex> {:ok, _} = ExResilience.AdaptiveConcurrency.start_link(name: :ac_gs, initial_limit: 8)
      iex> stats = ExResilience.AdaptiveConcurrency.get_stats(:ac_gs)
      iex> stats.limit
      8
      iex> stats.active
      0

  """
  @spec get_stats(atom()) :: %{
          limit: pos_integer(),
          min_rtt: number() | nil,
          active: non_neg_integer()
        }
  def get_stats(name) do
    GenServer.call(name, :get_stats)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    algorithm = Keyword.get(opts, :algorithm, :aimd)
    initial_limit = Keyword.get(opts, :initial_limit, 10)
    min_limit = Keyword.get(opts, :min_limit, 1)
    max_limit = Keyword.get(opts, :max_limit, 200)

    table = :ets.new(table_name(name), [:named_table, :public, :set])
    :ets.insert(table, {:active, 0})
    :ets.insert(table, {:limit, initial_limit})

    state = %State{
      name: name,
      algorithm: algorithm,
      min_limit: min_limit,
      max_limit: max_limit,
      table: table,
      latency_threshold: Keyword.get(opts, :latency_threshold, 100),
      increase_by: Keyword.get(opts, :increase_by, 1),
      decrease_factor: Keyword.get(opts, :decrease_factor, 0.5),
      alpha: Keyword.get(opts, :alpha, 3),
      beta: Keyword.get(opts, :beta, 6),
      window_size: Keyword.get(opts, :window_size, 100)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:sample, outcome, duration_ms}, state) do
    new_state =
      case state.algorithm do
        :aimd -> adjust_aimd(state, outcome, duration_ms)
        :vegas -> adjust_vegas(state, duration_ms)
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    [{:limit, limit}] = :ets.lookup(state.table, :limit)
    [{:active, active}] = :ets.lookup(state.table, :active)

    stats = %{
      limit: limit,
      min_rtt: state.min_rtt,
      active: active
    }

    {:reply, stats, state}
  end

  # -- AIMD algorithm --

  defp adjust_aimd(state, outcome, duration_ms) do
    [{:limit, old_limit}] = :ets.lookup(state.table, :limit)

    new_limit =
      if outcome == :ok and duration_ms < state.latency_threshold do
        min(old_limit + state.increase_by, state.max_limit)
      else
        max(floor(old_limit * state.decrease_factor), state.min_limit)
      end

    if new_limit != old_limit do
      :ets.insert(state.table, {:limit, new_limit})

      Telemetry.emit(
        [:ex_resilience, :adaptive_concurrency, :limit_changed],
        %{old_limit: old_limit, new_limit: new_limit},
        %{name: state.name, algorithm: :aimd}
      )
    end

    state
  end

  # -- Vegas algorithm --

  defp adjust_vegas(state, duration_ms) do
    # Add sample to window
    samples = [duration_ms | state.rtt_samples]
    samples = Enum.take(samples, state.window_size)

    # Compute min_rtt from the window
    min_rtt = Enum.min(samples)

    [{:limit, old_limit}] = :ets.lookup(state.table, :limit)

    # Estimate queue size
    queue =
      if duration_ms > 0 do
        old_limit * (1.0 - min_rtt / duration_ms)
      else
        0.0
      end

    new_limit =
      cond do
        queue < state.alpha ->
          min(old_limit + 1, state.max_limit)

        queue > state.beta ->
          max(old_limit - 1, state.min_limit)

        true ->
          old_limit
      end

    if new_limit != old_limit do
      :ets.insert(state.table, {:limit, new_limit})

      Telemetry.emit(
        [:ex_resilience, :adaptive_concurrency, :limit_changed],
        %{old_limit: old_limit, new_limit: new_limit},
        %{name: state.name, algorithm: :vegas}
      )
    end

    %{state | rtt_samples: samples, min_rtt: min_rtt}
  end

  # -- Internal --

  defp table_name(name), do: :"#{name}_adaptive_concurrency"

  defp try_acquire(table) do
    [{:limit, limit}] = :ets.lookup(table, :limit)
    new_val = :ets.update_counter(table, :active, {2, 1})

    if new_val <= limit do
      :ok
    else
      :ets.update_counter(table, :active, {2, -1})
      :full
    end
  end

  defp release(table) do
    :ets.update_counter(table, :active, {2, -1})
  end

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, _} = err), do: err
  defp wrap_result(:ok), do: {:ok, :ok}
  defp wrap_result(:error), do: {:error, :error}
  defp wrap_result(other), do: {:ok, other}

  defp classify_result({:error, _}), do: :error
  defp classify_result(:error), do: :error
  defp classify_result(_), do: :ok
end
