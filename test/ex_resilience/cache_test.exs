defmodule ExResilience.CacheTest do
  use ExUnit.Case, async: false

  alias ExResilience.Cache

  setup do
    name = :"cache_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "basic operation" do
    test "cache miss executes function and returns result", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      assert Cache.call(name, :key, fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "cache hit returns stored value without executing function", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      assert Cache.call(name, :key, fn -> {:ok, 42} end) == {:ok, 42}

      # The put is async (cast), give it a moment
      Process.sleep(5)

      assert Cache.call(name, :key, fn -> raise "should not be called" end) == {:ok, 42}
    end

    test "caches bare non-error values", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      assert Cache.call(name, :key, fn -> 42 end) == 42
      Process.sleep(5)
      assert Cache.call(name, :key, fn -> raise "should not be called" end) == 42
    end

    test "caches :ok atom", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      assert Cache.call(name, :key, fn -> :ok end) == :ok
      Process.sleep(5)
      assert Cache.call(name, :key, fn -> raise "should not be called" end) == :ok
    end
  end

  describe "error handling" do
    test "does not cache {:error, _} results", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      counter = :counters.new(1, [:atomics])

      result =
        Cache.call(name, :key, fn ->
          :counters.add(counter, 1, 1)
          {:error, :fail}
        end)

      assert result == {:error, :fail}
      Process.sleep(5)

      result =
        Cache.call(name, :key, fn ->
          :counters.add(counter, 1, 1)
          {:error, :fail_again}
        end)

      assert result == {:error, :fail_again}
      assert :counters.get(counter, 1) == 2
    end

    test "does not cache :error atom", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      counter = :counters.new(1, [:atomics])

      Cache.call(name, :key, fn ->
        :counters.add(counter, 1, 1)
        :error
      end)

      Process.sleep(5)

      Cache.call(name, :key, fn ->
        :counters.add(counter, 1, 1)
        :error
      end)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "TTL" do
    test "entries expire after TTL", %{name: name} do
      {:ok, _} = Cache.start_link(name: name, ttl: 10)
      counter = :counters.new(1, [:atomics])

      Cache.call(name, :key, fn ->
        :counters.add(counter, 1, 1)
        {:ok, :first}
      end)

      Process.sleep(5)

      # Should still be cached
      result =
        Cache.call(name, :key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, :second}
        end)

      assert result == {:ok, :first}

      # Wait for TTL to expire
      Process.sleep(20)

      result =
        Cache.call(name, :key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, :third}
        end)

      assert result == {:ok, :third}
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "invalidate/2" do
    test "removes a specific cached entry", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      Cache.call(name, :key, fn -> {:ok, 42} end)
      Process.sleep(5)

      :ok = Cache.invalidate(name, :key)

      counter = :counters.new(1, [:atomics])

      Cache.call(name, :key, fn ->
        :counters.add(counter, 1, 1)
        {:ok, 99}
      end)

      assert :counters.get(counter, 1) == 1
    end

    test "clears all entries when key is nil", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      Cache.call(name, :a, fn -> {:ok, 1} end)
      Cache.call(name, :b, fn -> {:ok, 2} end)
      Process.sleep(5)

      :ok = Cache.invalidate(name, nil)
      assert Cache.stats(name) == %{size: 0}
    end
  end

  describe "stats/1" do
    test "returns cache size", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      assert Cache.stats(name) == %{size: 0}

      Cache.call(name, :a, fn -> {:ok, 1} end)
      Process.sleep(5)
      assert Cache.stats(name) == %{size: 1}

      Cache.call(name, :b, fn -> {:ok, 2} end)
      Process.sleep(5)
      assert Cache.stats(name) == %{size: 2}
    end
  end

  describe "telemetry" do
    test "emits hit and miss events", %{name: name} do
      {:ok, _} = Cache.start_link(name: name)
      id = System.unique_integer([:positive])
      test_pid = self()

      :telemetry.attach(
        "cache-test-#{id}-miss",
        [:ex_resilience, :cache, :miss],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "cache-test-#{id}-hit",
        [:ex_resilience, :cache, :hit],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Cache.call(name, :key, fn -> {:ok, 1} end)
      assert_receive {:telemetry, [:ex_resilience, :cache, :miss], _, %{name: ^name, key: :key}}

      Process.sleep(5)
      Cache.call(name, :key, fn -> {:ok, 2} end)
      assert_receive {:telemetry, [:ex_resilience, :cache, :hit], _, %{name: ^name, key: :key}}

      :telemetry.detach("cache-test-#{id}-miss")
      :telemetry.detach("cache-test-#{id}-hit")
    end
  end
end
