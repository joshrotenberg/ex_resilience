defmodule ExResilience.Cache.EtsBackend do
  @moduledoc """
  Built-in ETS-based cache backend with TTL support.

  Stores entries as `{key, value, expiry_time | nil}` in a named ETS table.
  Expired entries are lazily evicted on read and periodically swept by the
  owning GenServer.

  ## Options

    * `:table_name` -- atom name for the ETS table. Required.
    * `:sweep_interval` -- interval in ms between periodic sweeps.
      Default: `60_000`.

  """

  @behaviour ExResilience.Cache.Backend

  @typedoc false
  @opaque state :: State.t()

  @default_sweep_interval 60_000

  defmodule State do
    @moduledoc false
    @enforce_keys [:table]
    defstruct [:table, sweep_interval: 60_000]

    @type t :: %__MODULE__{
            table: atom(),
            sweep_interval: non_neg_integer()
          }
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:error, term()}
  def init(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    sweep_interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)

    table = :ets.new(table_name, [:named_table, :public, :set])

    {:ok, %State{table: table, sweep_interval: sweep_interval}}
  end

  @impl true
  @spec get(term(), state()) :: {:hit, term(), state()} | {:miss, state()}
  def get(key, %State{table: table} = state) do
    case :ets.lookup(table, key) do
      [{^key, value, nil}] ->
        {:hit, value, state}

      [{^key, value, expiry}] ->
        if System.monotonic_time(:millisecond) < expiry do
          {:hit, value, state}
        else
          :ets.delete(table, key)
          {:miss, state}
        end

      [] ->
        {:miss, state}
    end
  end

  @impl true
  @spec put(term(), term(), non_neg_integer() | nil, state()) :: {:ok, state()}
  def put(key, value, ttl_ms, %State{table: table} = state) do
    expiry =
      case ttl_ms do
        nil -> nil
        ms -> System.monotonic_time(:millisecond) + ms
      end

    :ets.insert(table, {key, value, expiry})
    {:ok, state}
  end

  @impl true
  @spec invalidate(term() | nil, state()) :: {:ok, state()}
  def invalidate(nil, %State{table: table} = state) do
    :ets.delete_all_objects(table)
    {:ok, state}
  end

  def invalidate(key, %State{table: table} = state) do
    :ets.delete(table, key)
    {:ok, state}
  end

  @impl true
  @spec stats(state()) :: map()
  def stats(%State{table: table}) do
    %{size: :ets.info(table, :size)}
  end

  @doc """
  Removes all expired entries from the ETS table.

  Called by the owning GenServer on each sweep tick.
  """
  @spec sweep(state()) :: state()
  def sweep(%State{table: table} = state) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {key, _value, expiry}, acc when is_integer(expiry) and expiry <= now ->
          :ets.delete(table, key)
          acc

        _entry, acc ->
          acc
      end,
      :ok,
      table
    )

    state
  end
end
