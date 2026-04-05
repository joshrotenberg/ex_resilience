defmodule ExResilience.Cache do
  @moduledoc """
  GenServer-based caching layer with pluggable backends.

  Caches successful results of function calls, keyed by a caller-provided key.
  On cache hit the function is not executed. Errors pass through uncached.

  ## Options

    * `:name` -- required. Registered name for this cache instance.
    * `:backend` -- module implementing `ExResilience.Cache.Backend`.
      Default: `ExResilience.Cache.EtsBackend`.
    * `:ttl` -- default TTL in milliseconds for cached entries.
      Default: `nil` (no expiry).

  Backend-specific options are passed through to `backend.init/1`.

  ## Examples

      iex> opts = [name: :doc_cache, ttl: 5_000]
      iex> {:ok, _} = ExResilience.Cache.start_link(opts)
      iex> ExResilience.Cache.call(:doc_cache, :my_key, fn -> {:ok, 42} end)
      {:ok, 42}
      iex> ExResilience.Cache.call(:doc_cache, :my_key, fn -> raise "not called" end)
      {:ok, 42}

  """

  use GenServer

  alias ExResilience.Cache.EtsBackend
  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:backend, module()}
          | {:ttl, non_neg_integer() | nil}

  defmodule State do
    @moduledoc false
    @enforce_keys [:name, :backend, :backend_state, :ttl]
    defstruct [:name, :backend, :backend_state, :ttl]

    @type t :: %__MODULE__{
            name: atom(),
            backend: module(),
            backend_state: term(),
            ttl: non_neg_integer() | nil
          }
  end

  # -- Public API --

  @doc """
  Starts a cache process.

  See module docs for available options.
  """
  @spec start_link([option() | {atom(), term()}]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Looks up `key` in the cache. On miss, executes `fun` and caches
  a successful result.

  Successful results are `{:ok, _}` tuples or any non-error value.
  Error results (`{:error, _}` or `:error`) are returned without caching.

  ## Examples

      ExResilience.Cache.call(:my_cache, "user:1", fn ->
        {:ok, fetch_user(1)}
      end)

  """
  @spec call(atom(), term(), (-> term())) :: term()
  def call(name, key, fun) do
    case GenServer.call(name, {:get, key}) do
      {:hit, value} ->
        Telemetry.emit(
          [:ex_resilience, :cache, :hit],
          %{system_time: System.system_time()},
          %{name: name, key: key}
        )

        value

      :miss ->
        Telemetry.emit(
          [:ex_resilience, :cache, :miss],
          %{system_time: System.system_time()},
          %{name: name, key: key}
        )

        result = fun.()

        if cacheable?(result) do
          GenServer.cast(name, {:put, key, result})

          Telemetry.emit(
            [:ex_resilience, :cache, :put],
            %{system_time: System.system_time()},
            %{name: name, key: key}
          )
        end

        result
    end
  end

  @doc """
  Removes the cached entry for `key`.

  Pass `nil` to clear all entries.
  """
  @spec invalidate(atom(), term() | nil) :: :ok
  def invalidate(name, key) do
    GenServer.call(name, {:invalidate, key})

    Telemetry.emit(
      [:ex_resilience, :cache, :invalidate],
      %{system_time: System.system_time()},
      %{name: name, key: key}
    )

    :ok
  end

  @doc """
  Returns backend statistics for this cache instance.
  """
  @spec stats(atom()) :: map()
  def stats(name) do
    GenServer.call(name, :stats)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    backend = Keyword.get(opts, :backend, EtsBackend)
    ttl = Keyword.get(opts, :ttl)

    backend_opts =
      opts
      |> Keyword.drop([:name, :backend, :ttl])
      |> Keyword.put_new(:table_name, :"#{name}_cache")

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        state = %State{
          name: name,
          backend: backend,
          backend_state: backend_state,
          ttl: ttl
        }

        schedule_sweep(backend_state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case state.backend.get(key, state.backend_state) do
      {:hit, value, new_backend_state} ->
        {:reply, {:hit, value}, %{state | backend_state: new_backend_state}}

      {:miss, new_backend_state} ->
        {:reply, :miss, %{state | backend_state: new_backend_state}}
    end
  end

  def handle_call({:invalidate, key}, _from, state) do
    {:ok, new_backend_state} = state.backend.invalidate(key, state.backend_state)
    {:reply, :ok, %{state | backend_state: new_backend_state}}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.backend.stats(state.backend_state), state}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    {:ok, new_backend_state} = state.backend.put(key, value, state.ttl, state.backend_state)
    {:noreply, %{state | backend_state: new_backend_state}}
  end

  @impl true
  def handle_info(:sweep, state) do
    new_backend_state =
      if function_exported?(state.backend, :sweep, 1) do
        state.backend.sweep(state.backend_state)
      else
        state.backend_state
      end

    schedule_sweep(new_backend_state)
    {:noreply, %{state | backend_state: new_backend_state}}
  end

  # -- Internal --

  defp schedule_sweep(%EtsBackend.State{sweep_interval: interval}) do
    Process.send_after(self(), :sweep, interval)
  end

  defp schedule_sweep(_backend_state), do: :ok

  defp cacheable?({:error, _}), do: false
  defp cacheable?(:error), do: false
  defp cacheable?(_), do: true
end
