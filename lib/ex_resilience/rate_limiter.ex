defmodule ExResilience.RateLimiter do
  @moduledoc """
  Token bucket rate limiter implemented as a GenServer.

  Maintains a bucket of tokens that refill at a steady rate. Each call
  consumes one token. When the bucket is empty, calls are rejected with
  `{:error, :rate_limited}`.

  Uses ETS for the hot-path token check and the GenServer for refill
  scheduling.

  ## Options

    * `:name` -- required. Registered name for this rate limiter instance.
    * `:rate` -- tokens added per interval. Default `10`.
    * `:interval` -- refill interval in ms. Default `1_000` (1 second).
    * `:max_tokens` -- bucket capacity. Default equals `:rate`.

  ## Examples

      iex> {:ok, _} = ExResilience.RateLimiter.start_link(name: :test_rl, rate: 5, interval: 1_000)
      iex> ExResilience.RateLimiter.call(:test_rl, fn -> :ok end)
      {:ok, :ok}

  """

  use GenServer

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:rate, pos_integer()}
          | {:interval, pos_integer()}
          | {:max_tokens, pos_integer()}

  @type result :: {:ok, term()} | {:error, :rate_limited} | {:error, term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:name, :rate, :interval, :max_tokens, :table]
    defstruct [:name, :rate, :interval, :max_tokens, :table, :timer]

    @type t :: %__MODULE__{
            name: atom(),
            rate: pos_integer(),
            interval: pos_integer(),
            max_tokens: pos_integer(),
            table: :ets.tid(),
            timer: reference() | nil
          }
  end

  # -- Public API --

  @doc """
  Starts a rate limiter process.

  See module docs for available options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` if a token is available.

  Returns `{:ok, result}` on success or `{:error, :rate_limited}` if
  the bucket is empty.
  """
  @spec call(atom(), (-> term())) :: result()
  def call(name, fun) do
    table = table_name(name)

    case try_acquire(table) do
      {:ok, remaining} ->
        Telemetry.emit(
          [:ex_resilience, :rate_limiter, :allowed],
          %{tokens_remaining: remaining},
          %{name: name}
        )

        result = fun.()
        wrap_result(result)

      :rejected ->
        Telemetry.emit(
          [:ex_resilience, :rate_limiter, :rejected],
          %{system_time: System.system_time()},
          %{name: name, retry_after_ms: retry_after(table)}
        )

        {:error, :rate_limited}
    end
  end

  @doc """
  Returns the current number of available tokens.
  """
  @spec available_tokens(atom()) :: non_neg_integer()
  def available_tokens(name) do
    [{:tokens, count}] = :ets.lookup(table_name(name), :tokens)
    max(count, 0)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    rate = Keyword.get(opts, :rate, 10)
    interval = Keyword.get(opts, :interval, 1_000)
    max_tokens = Keyword.get(opts, :max_tokens, rate)

    table = :ets.new(table_name(name), [:named_table, :public, :set])
    :ets.insert(table, {:tokens, max_tokens})
    :ets.insert(table, {:max_tokens, max_tokens})
    :ets.insert(table, {:interval, interval})
    :ets.insert(table, {:last_refill, System.monotonic_time(:millisecond)})

    timer = schedule_refill(interval)

    state = %State{
      name: name,
      rate: rate,
      interval: interval,
      max_tokens: max_tokens,
      table: table,
      timer: timer
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:refill, state) do
    [{:max_tokens, max}] = :ets.lookup(state.table, :max_tokens)
    [{:tokens, current}] = :ets.lookup(state.table, :tokens)

    new_tokens = min(current + state.rate, max)
    :ets.insert(state.table, {:tokens, new_tokens})
    :ets.insert(state.table, {:last_refill, System.monotonic_time(:millisecond)})

    timer = schedule_refill(state.interval)
    {:noreply, %{state | timer: timer}}
  end

  # -- Internal --

  defp table_name(name), do: :"#{name}_rate_limiter"

  defp try_acquire(table) do
    new_val = :ets.update_counter(table, :tokens, {2, -1})

    if new_val >= 0 do
      {:ok, new_val}
    else
      # Restore the token we just took
      :ets.update_counter(table, :tokens, {2, 1})
      :rejected
    end
  end

  defp retry_after(table) do
    [{:interval, interval}] = :ets.lookup(table, :interval)
    [{:last_refill, last}] = :ets.lookup(table, :last_refill)
    now = System.monotonic_time(:millisecond)
    elapsed = now - last
    max(interval - elapsed, 0)
  end

  defp schedule_refill(interval) do
    Process.send_after(self(), :refill, interval)
  end

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, _} = err), do: err
  defp wrap_result(:ok), do: {:ok, :ok}
  defp wrap_result(:error), do: {:error, :error}
  defp wrap_result(other), do: {:ok, other}
end
