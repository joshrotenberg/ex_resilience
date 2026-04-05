defmodule ExResilience.BulkheadTest do
  use ExUnit.Case, async: false

  alias ExResilience.Bulkhead

  setup do
    name = :"bh_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "basic operation" do
    test "executes function and returns result", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 2)
      assert Bulkhead.call(name, fn -> 42 end) == {:ok, 42}
    end

    test "wraps ok tuples", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 2)
      assert Bulkhead.call(name, fn -> {:ok, :data} end) == {:ok, :data}
    end

    test "passes through error tuples", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 2)
      assert Bulkhead.call(name, fn -> {:error, :fail} end) == {:error, :fail}
    end

    test "reraises exceptions", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 2)

      assert_raise RuntimeError, "boom", fn ->
        Bulkhead.call(name, fn -> raise "boom" end)
      end
    end

    test "releases permit after exception", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 1)

      assert_raise RuntimeError, fn ->
        Bulkhead.call(name, fn -> raise "boom" end)
      end

      # Release is async via GenServer cast
      Process.sleep(10)
      assert Bulkhead.active_count(name) == 0
      assert Bulkhead.call(name, fn -> :ok end) == {:ok, :ok}
    end
  end

  describe "concurrency limiting" do
    test "tracks active count", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 5)
      assert Bulkhead.active_count(name) == 0

      Bulkhead.call(name, fn ->
        assert Bulkhead.active_count(name) == 1
        :ok
      end)

      # After call completes, permit is released asynchronously
      Process.sleep(10)
      assert Bulkhead.active_count(name) == 0
    end

    test "rejects when at max concurrent with zero wait", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 1, max_wait: 0)

      # Hold a permit
      test_pid = self()

      task =
        Task.async(fn ->
          Bulkhead.call(name, fn ->
            send(test_pid, :holding)
            Process.sleep(200)
            :held
          end)
        end)

      receive do
        :holding -> :ok
      end

      # Should be rejected immediately
      assert Bulkhead.call(name, fn -> :should_not_run end, 0) == {:error, :bulkhead_full}

      Task.await(task)
    end

    test "queues and serves waiters in order", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 1, max_wait: 2_000)
      test_pid = self()

      # Hold the permit
      holder =
        Task.async(fn ->
          Bulkhead.call(name, fn ->
            send(test_pid, :holding)
            Process.sleep(100)
            :first
          end)
        end)

      receive do
        :holding -> :ok
      end

      # Queue a waiter
      waiter =
        Task.async(fn ->
          Bulkhead.call(name, fn -> :second end)
        end)

      assert Task.await(holder) == {:ok, :first}
      assert Task.await(waiter) == {:ok, :second}
    end
  end

  describe "queue_length/1" do
    test "reports queue size", %{name: name} do
      {:ok, _} = Bulkhead.start_link(name: name, max_concurrent: 1, max_wait: 2_000)
      assert Bulkhead.queue_length(name) == 0
    end
  end
end
