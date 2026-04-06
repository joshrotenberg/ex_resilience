defmodule ExResilience.Pipeline.SupervisorTest do
  use ExUnit.Case, async: false

  alias ExResilience.Pipeline

  setup do
    suffix = System.unique_integer([:positive])
    name = :"sup_test_#{suffix}"
    %{name: name}
  end

  describe "start_link/1" do
    test "starts supervisor for pipeline with stateful layers", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)

      {:ok, sup} = Pipeline.Supervisor.start_link({pipeline, []})
      assert Process.alive?(sup)

      # Both GenServer layers should be running
      assert Process.whereis(Pipeline.child_name(name, :bulkhead)) != nil
      assert Process.whereis(Pipeline.child_name(name, :circuit_breaker)) != nil
    end

    test "starts supervisor with custom name", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)

      sup_name = :"custom_sup_#{name}"
      {:ok, sup} = Pipeline.Supervisor.start_link({pipeline, supervisor_name: sup_name})
      assert Process.whereis(sup_name) == sup
    end

    test "skips stateless layers (retry, hedge, chaos, fallback)", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:retry, max_attempts: 3)
        |> Pipeline.add(:hedge, delay: 100)
        |> Pipeline.add(:chaos, error_rate: 0.5)
        |> Pipeline.add(:fallback, fallback: fn _reason -> {:ok, :default} end)

      {:ok, sup} = Pipeline.Supervisor.start_link({pipeline, []})
      assert Process.alive?(sup)

      # Supervisor should have no children since all layers are stateless
      assert Supervisor.which_children(sup) == []
    end

    test "starts all five stateful layer types", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
        |> Pipeline.add(:rate_limiter, rate: 100, interval: 1_000)
        |> Pipeline.add(:coalesce, [])
        |> Pipeline.add(:cache, [])

      {:ok, sup} = Pipeline.Supervisor.start_link({pipeline, []})
      children = Supervisor.which_children(sup)
      assert length(children) == 5
    end
  end

  describe "supervised layers are functional" do
    test "can call through a supervised pipeline", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
        |> Pipeline.add(:retry, max_attempts: 2, base_delay: 1, jitter: false)

      {:ok, _sup} = Pipeline.Supervisor.start_link({pipeline, []})

      result = Pipeline.call(pipeline, fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "rate limiter works under supervision", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:rate_limiter, rate: 1, interval: 60_000)

      {:ok, _sup} = Pipeline.Supervisor.start_link({pipeline, []})

      assert Pipeline.call(pipeline, fn -> {:ok, :first} end) == {:ok, :first}
      assert Pipeline.call(pipeline, fn -> {:ok, :second} end) == {:error, :rate_limited}
    end
  end

  describe "crash recovery" do
    test "crashed layer is restarted by supervisor", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)

      {:ok, _sup} = Pipeline.Supervisor.start_link({pipeline, []})

      bulkhead_name = Pipeline.child_name(name, :bulkhead)
      original_pid = Process.whereis(bulkhead_name)
      assert original_pid != nil

      # Kill the bulkhead process
      Process.exit(original_pid, :kill)

      # Give the supervisor time to restart it
      Process.sleep(50)

      new_pid = Process.whereis(bulkhead_name)
      assert new_pid != nil
      assert new_pid != original_pid

      # The restarted process should be functional
      result =
        ExResilience.Bulkhead.call(bulkhead_name, fn -> {:ok, :recovered} end)

      assert result == {:ok, :recovered}
    end
  end

  describe "ExResilience.start_link/2" do
    test "delegates to Pipeline.Supervisor", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)

      {:ok, sup} = ExResilience.start_link(pipeline)
      assert Process.alive?(sup)
      assert Process.whereis(Pipeline.child_name(name, :bulkhead)) != nil
    end
  end

  describe "child_spec/1 on GenServer modules" do
    test "Bulkhead.child_spec/1 returns valid spec" do
      spec = ExResilience.Bulkhead.child_spec(name: :test_bh_spec)
      assert spec.id == ExResilience.Bulkhead
      assert spec.start == {ExResilience.Bulkhead, :start_link, [[name: :test_bh_spec]]}
    end

    test "CircuitBreaker.child_spec/1 returns valid spec" do
      spec = ExResilience.CircuitBreaker.child_spec(name: :test_cb_spec)
      assert spec.id == ExResilience.CircuitBreaker
      assert spec.start == {ExResilience.CircuitBreaker, :start_link, [[name: :test_cb_spec]]}
    end

    test "RateLimiter.child_spec/1 returns valid spec" do
      spec = ExResilience.RateLimiter.child_spec(name: :test_rl_spec)
      assert spec.id == ExResilience.RateLimiter
      assert spec.start == {ExResilience.RateLimiter, :start_link, [[name: :test_rl_spec]]}
    end

    test "Coalesce.child_spec/1 returns valid spec" do
      spec = ExResilience.Coalesce.child_spec(name: :test_co_spec)
      assert spec.id == ExResilience.Coalesce
      assert spec.start == {ExResilience.Coalesce, :start_link, [[name: :test_co_spec]]}
    end

    test "Cache.child_spec/1 returns valid spec" do
      spec = ExResilience.Cache.child_spec(name: :test_ca_spec)
      assert spec.id == ExResilience.Cache
      assert spec.start == {ExResilience.Cache, :start_link, [[name: :test_ca_spec]]}
    end
  end
end
