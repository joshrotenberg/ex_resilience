defmodule ExResilience.PipelineTest do
  use ExUnit.Case, async: false

  alias ExResilience.Pipeline

  setup do
    suffix = System.unique_integer([:positive])
    name = :"pipe_#{suffix}"
    %{name: name}
  end

  describe "new/1 and add/3" do
    test "builds a pipeline with layers", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
        |> Pipeline.add(:retry, max_attempts: 2)

      assert pipeline.name == name
      assert length(pipeline.layers) == 3
    end
  end

  describe "start/1 and call/2" do
    test "executes through all layers", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
        |> Pipeline.add(:retry, max_attempts: 2, base_delay: 1, jitter: false)

      {:ok, _pids} = Pipeline.start(pipeline)

      result = Pipeline.call(pipeline, fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "retry layer retries on error before circuit breaker trips", %{name: name} do
      counter = :counters.new(1, [:atomics])

      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 5)
        |> Pipeline.add(:retry, max_attempts: 3, base_delay: 1, jitter: false)

      {:ok, _pids} = Pipeline.start(pipeline)

      Pipeline.call(pipeline, fn ->
        :counters.add(counter, 1, 1)
        {:error, :fail}
      end)

      # Retry should have made 3 attempts
      assert :counters.get(counter, 1) == 3
    end

    test "rate limiter rejects when exhausted", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:rate_limiter, rate: 1, interval: 60_000)

      {:ok, _pids} = Pipeline.start(pipeline)

      assert Pipeline.call(pipeline, fn -> {:ok, :first} end) == {:ok, :first}
      assert Pipeline.call(pipeline, fn -> {:ok, :second} end) == {:error, :rate_limited}
    end
  end

  describe "child_name/2" do
    test "generates deterministic child names" do
      assert Pipeline.child_name(:my_pipe, :bulkhead) == :my_pipe_bulkhead
      assert Pipeline.child_name(:my_pipe, :circuit_breaker) == :my_pipe_circuit_breaker
    end
  end
end
