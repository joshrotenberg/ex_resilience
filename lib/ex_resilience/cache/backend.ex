defmodule ExResilience.Cache.Backend do
  @moduledoc """
  Behaviour for pluggable cache backends.

  Implement this behaviour to use a custom caching library
  (Cachex, ConCache, etc.) as a cache layer backend.

  ## Example

  A minimal in-memory backend:

      defmodule MyBackend do
        @behaviour ExResilience.Cache.Backend

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def get(key, state) do
          case Map.fetch(state, key) do
            {:ok, value} -> {:hit, value, state}
            :error -> {:miss, state}
          end
        end

        @impl true
        def put(key, value, _ttl, state), do: {:ok, Map.put(state, key, value)}

        @impl true
        def invalidate(key, state), do: {:ok, Map.delete(state, key)}

        @impl true
        def stats(state), do: %{size: map_size(state)}
      end

  """

  @type state :: term()
  @type key :: term()
  @type value :: term()
  @type ttl_ms :: non_neg_integer() | nil

  @doc """
  Initializes the backend state from the given options.
  """
  @callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}

  @doc """
  Looks up a key. Returns `{:hit, value, state}` on cache hit,
  or `{:miss, state}` on cache miss.
  """
  @callback get(key, state) :: {:hit, value, state} | {:miss, state}

  @doc """
  Stores a value under `key` with an optional TTL in milliseconds.
  A `nil` TTL means the entry does not expire.
  """
  @callback put(key, value, ttl_ms, state) :: {:ok, state}

  @doc """
  Removes the entry for `key`. If `key` is `nil`, removes all entries.
  """
  @callback invalidate(key, state) :: {:ok, state}

  @doc """
  Returns a map of backend statistics (at minimum `%{size: non_neg_integer()}`).
  """
  @callback stats(state) :: map()
end
