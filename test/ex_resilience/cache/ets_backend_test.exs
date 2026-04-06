defmodule ExResilience.Cache.EtsBackendTest do
  use ExUnit.Case, async: false

  alias ExResilience.Cache.EtsBackend

  setup do
    table_name = :"ets_backend_#{System.unique_integer([:positive])}"
    {:ok, state} = EtsBackend.init(table_name: table_name)
    %{state: state, table_name: table_name}
  end

  describe "init/1" do
    test "creates ETS table", %{table_name: table_name} do
      assert :ets.info(table_name) != :undefined
    end

    test "sets default sweep interval", %{state: state} do
      assert state.sweep_interval == 60_000
    end

    test "accepts custom sweep interval" do
      table = :"ets_custom_#{System.unique_integer([:positive])}"
      {:ok, state} = EtsBackend.init(table_name: table, sweep_interval: 10_000)
      assert state.sweep_interval == 10_000
    end
  end

  describe "get/2" do
    test "returns miss for absent key", %{state: state} do
      assert {:miss, ^state} = EtsBackend.get(:absent, state)
    end

    test "returns hit after put", %{state: state} do
      {:ok, state} = EtsBackend.put(:key, :value, nil, state)
      assert {:hit, :value, ^state} = EtsBackend.get(:key, state)
    end

    test "returns miss for expired entry", %{state: state} do
      {:ok, state} = EtsBackend.put(:key, :value, 1, state)
      Process.sleep(5)
      assert {:miss, ^state} = EtsBackend.get(:key, state)
    end

    test "returns hit for non-expired entry", %{state: state} do
      {:ok, state} = EtsBackend.put(:key, :value, 5_000, state)
      assert {:hit, :value, ^state} = EtsBackend.get(:key, state)
    end
  end

  describe "put/4" do
    test "stores entry without TTL", %{state: state} do
      {:ok, state} = EtsBackend.put(:key, 42, nil, state)
      assert {:hit, 42, _} = EtsBackend.get(:key, state)
    end

    test "stores entry with TTL", %{state: state} do
      {:ok, state} = EtsBackend.put(:key, 42, 10_000, state)
      assert {:hit, 42, _} = EtsBackend.get(:key, state)
    end
  end

  describe "invalidate/2" do
    test "removes a specific key", %{state: state} do
      {:ok, state} = EtsBackend.put(:a, 1, nil, state)
      {:ok, state} = EtsBackend.put(:b, 2, nil, state)
      {:ok, state} = EtsBackend.invalidate(:a, state)

      assert {:miss, _} = EtsBackend.get(:a, state)
      assert {:hit, 2, _} = EtsBackend.get(:b, state)
    end

    test "removes all entries when key is nil", %{state: state} do
      {:ok, state} = EtsBackend.put(:a, 1, nil, state)
      {:ok, state} = EtsBackend.put(:b, 2, nil, state)
      {:ok, state} = EtsBackend.invalidate(nil, state)

      assert {:miss, _} = EtsBackend.get(:a, state)
      assert {:miss, _} = EtsBackend.get(:b, state)
    end
  end

  describe "stats/1" do
    test "returns size", %{state: state} do
      assert %{size: 0} = EtsBackend.stats(state)
      {:ok, state} = EtsBackend.put(:a, 1, nil, state)
      assert %{size: 1} = EtsBackend.stats(state)
    end
  end

  describe "sweep/1" do
    test "removes expired entries", %{state: state} do
      {:ok, state} = EtsBackend.put(:expired, :val, 1, state)
      {:ok, state} = EtsBackend.put(:alive, :val, 60_000, state)
      {:ok, state} = EtsBackend.put(:no_ttl, :val, nil, state)

      Process.sleep(5)
      _state = EtsBackend.sweep(state)

      assert %{size: 2} = EtsBackend.stats(state)
      assert {:miss, _} = EtsBackend.get(:expired, state)
      assert {:hit, :val, _} = EtsBackend.get(:alive, state)
      assert {:hit, :val, _} = EtsBackend.get(:no_ttl, state)
    end
  end
end
