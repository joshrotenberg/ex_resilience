# Example: Cache + Coalesce to prevent thundering herd
#
# Shows how coalesce deduplicates concurrent requests while cache
# stores the results for subsequent calls.
#
# Run with: mix run examples/cache_with_coalesce.exs

defmodule SlowDatabase do
  @moduledoc false

  # Simulates an expensive database query
  def fetch_user(id) do
    IO.puts("  [database] Executing query for user #{id}...")
    Process.sleep(100)
    {:ok, %{id: id, name: "User #{id}", fetched_at: System.system_time(:millisecond)}}
  end
end

# Start the coalesce and cache layers
{:ok, _} = ExResilience.Coalesce.start_link(name: :user_dedup)

{:ok, _} =
  ExResilience.Cache.start_link(
    name: :user_cache,
    backend: ExResilience.Cache.EtsBackend,
    ttl: 5_000
  )

fetch_user = fn id ->
  # First check cache, then coalesce, then database
  ExResilience.Cache.call(:user_cache, "user:#{id}", fn ->
    ExResilience.Coalesce.call(:user_dedup, "user:#{id}", fn ->
      SlowDatabase.fetch_user(id)
    end)
  end)
end

# Scenario 1: 10 concurrent requests for the same user
IO.puts("--- Scenario 1: 10 concurrent requests for user 42 ---")
IO.puts("(Should see exactly 1 database query)\n")

tasks = for _ <- 1..10, do: Task.async(fn -> fetch_user.(42) end)
results = Task.await_many(tasks)

IO.puts("\nAll 10 callers got the same result: #{Enum.uniq(results) |> length() == 1}")

# Scenario 2: Subsequent call hits cache
IO.puts("\n--- Scenario 2: Subsequent call (should hit cache) ---\n")
{time_us, result} = :timer.tc(fn -> fetch_user.(42) end)
IO.puts("Cache hit in #{time_us}us: #{inspect(result)}")

# Scenario 3: Different user triggers new query
IO.puts("\n--- Scenario 3: Different user (new query) ---\n")
{_time_us, _result} = :timer.tc(fn -> fetch_user.(99) end)

# Scenario 4: Wait for TTL expiry
IO.puts("\n--- Scenario 4: Wait for cache TTL (5s) ---")
Process.sleep(5_100)
IO.puts("Cache expired, fetching again:\n")
{_time_us, _result} = :timer.tc(fn -> fetch_user.(42) end)

IO.puts("\nDone.")
