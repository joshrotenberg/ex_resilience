defmodule ExResilience.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias ExResilience.CircuitBreaker

  setup do
    name = :"cb_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "closed state" do
    test "passes calls through", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)
      assert CircuitBreaker.call(name, fn -> {:ok, 42} end) == {:ok, 42}
      assert CircuitBreaker.get_state(name) == :closed
    end

    test "wraps bare values in ok tuple", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)
      assert CircuitBreaker.call(name, fn -> :hello end) == {:ok, :hello}
    end

    test "passes through error tuples", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)
      assert CircuitBreaker.call(name, fn -> {:error, :oops} end) == {:error, :oops}
    end

    test "resets failure count on success", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)

      # Two failures then a success
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:ok, :good} end)

      # Allow cast to be processed
      Process.sleep(10)

      # Should still be closed because success reset the counter
      assert CircuitBreaker.get_state(name) == :closed

      # Two more failures should not trip it (need 3 consecutive)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed
    end
  end

  describe "state transitions" do
    test "opens after reaching failure threshold", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 2)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Allow cast to be processed
      Process.sleep(10)

      assert CircuitBreaker.get_state(name) == :open
    end

    test "rejects calls when open", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(10)

      assert CircuitBreaker.call(name, fn -> :should_not_run end) == {:error, :circuit_open}
    end

    test "transitions to half_open after reset_timeout", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1, reset_timeout: 50)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open

      Process.sleep(60)
      assert CircuitBreaker.get_state(name) == :half_open
    end

    test "closes on successful half_open call", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1, reset_timeout: 50)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(70)
      assert CircuitBreaker.get_state(name) == :half_open

      CircuitBreaker.call(name, fn -> {:ok, :recovered} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed
    end

    test "reopens on failed half_open call", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1, reset_timeout: 50)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(70)
      assert CircuitBreaker.get_state(name) == :half_open

      CircuitBreaker.call(name, fn -> {:error, :still_broken} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end
  end

  describe "manual reset" do
    test "resets breaker to closed", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open

      CircuitBreaker.reset(name)
      assert CircuitBreaker.get_state(name) == :closed
    end
  end

  describe "custom error classifier" do
    test "uses custom classifier", %{name: name} do
      classifier = fn
        {:error, :retryable} -> true
        _ -> false
      end

      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          error_classifier: classifier
        )

      # Non-retryable error should not trip breaker
      CircuitBreaker.call(name, fn -> {:error, :permanent} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed

      # Retryable error should trip it
      CircuitBreaker.call(name, fn -> {:error, :retryable} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end
  end

  describe "exceptions" do
    test "reraises and counts as failure", %{name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      assert_raise RuntimeError, "boom", fn ->
        CircuitBreaker.call(name, fn -> raise "boom" end)
      end

      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end
  end
end
