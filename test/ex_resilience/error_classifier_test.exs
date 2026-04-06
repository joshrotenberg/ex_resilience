defmodule ExResilience.ErrorClassifierTest do
  use ExUnit.Case, async: false

  alias ExResilience.{CircuitBreaker, Fallback, Pipeline, Retry}
  alias ExResilience.ErrorClassifier.Default

  defmodule TestClassifier do
    @behaviour ExResilience.ErrorClassifier

    @impl true
    def classify({:error, :timeout}), do: :retriable
    def classify({:error, :not_found}), do: :ignore
    def classify({:error, _}), do: :failure
    def classify(_), do: :ok
  end

  setup do
    name = :"ec_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "Default classifier" do
    test "classifies {:error, _} as :retriable" do
      assert Default.classify({:error, :something}) == :retriable
    end

    test "classifies bare :error as :retriable" do
      assert Default.classify(:error) == :retriable
    end

    test "classifies {:ok, _} as :ok" do
      assert Default.classify({:ok, 42}) == :ok
    end

    test "classifies bare :ok as :ok" do
      assert Default.classify(:ok) == :ok
    end

    test "classifies other values as :ok" do
      assert Default.classify(42) == :ok
      assert Default.classify(:hello) == :ok
    end
  end

  describe "circuit breaker with module classifier" do
    test "treats :retriable as failure", %{name: name} do
      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          error_classifier: TestClassifier
        )

      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end

    test "treats :failure as failure", %{name: name} do
      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          error_classifier: TestClassifier
        )

      CircuitBreaker.call(name, fn -> {:error, :permanent} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end

    test "treats :ignore as neither success nor failure", %{name: name} do
      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 2,
          error_classifier: TestClassifier
        )

      # :not_found is :ignore -- should not increment failure count
      CircuitBreaker.call(name, fn -> {:error, :not_found} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed

      # One actual failure should not trip (threshold is 2)
      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed
    end

    test ":ignore does not reset failure count", %{name: name} do
      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 2,
          error_classifier: TestClassifier
        )

      # One failure
      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)

      # :ignore should not reset failure count
      CircuitBreaker.call(name, fn -> {:error, :not_found} end)
      Process.sleep(10)

      # One more failure should trip it (total 2 consecutive failures)
      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end

    test "treats :ok as success (resets failure count)", %{name: name} do
      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 2,
          error_classifier: TestClassifier
        )

      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)

      # :ok resets the failure count
      CircuitBreaker.call(name, fn -> {:ok, :good} end)
      Process.sleep(10)

      # Need 2 more consecutive failures to trip
      CircuitBreaker.call(name, fn -> {:error, :timeout} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed
    end
  end

  describe "retry with module classifier" do
    test "retries :retriable results" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :timeout}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          error_classifier: TestClassifier
        )

      assert result == {:error, :timeout}
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry :failure results" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :permanent}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          error_classifier: TestClassifier
        )

      assert result == {:error, :permanent}
      assert :counters.get(counter, 1) == 1
    end

    test "does not retry :ignore results" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :not_found}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          error_classifier: TestClassifier
        )

      assert result == {:error, :not_found}
      assert :counters.get(counter, 1) == 1
    end

    test ":retry_on takes precedence over :error_classifier" do
      counter = :counters.new(1, [:atomics])

      # :retry_on says retry everything, :error_classifier says :failure
      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :permanent}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          retry_on: fn
            {:error, _} -> true
            _ -> false
          end,
          error_classifier: TestClassifier
        )

      assert result == {:error, :permanent}
      # :retry_on won, so all 3 attempts were made
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "fallback with module classifier" do
    test "triggers fallback on :retriable" do
      result =
        Fallback.call(
          fn -> {:error, :timeout} end,
          fallback: fn _ -> {:ok, :cached} end,
          error_classifier: TestClassifier
        )

      assert result == {:ok, :cached}
    end

    test "triggers fallback on :failure" do
      result =
        Fallback.call(
          fn -> {:error, :permanent} end,
          fallback: fn _ -> {:ok, :default} end,
          error_classifier: TestClassifier
        )

      assert result == {:ok, :default}
    end

    test "does not trigger fallback on :ignore" do
      result =
        Fallback.call(
          fn -> {:error, :not_found} end,
          fallback: fn _ -> {:ok, :default} end,
          error_classifier: TestClassifier
        )

      assert result == {:error, :not_found}
    end

    test "does not trigger fallback on :ok" do
      result =
        Fallback.call(
          fn -> {:ok, 42} end,
          fallback: fn _ -> {:ok, 0} end,
          error_classifier: TestClassifier
        )

      assert result == {:ok, 42}
    end

    test ":only takes precedence over :error_classifier" do
      result =
        Fallback.call(
          fn -> {:error, :timeout} end,
          fallback: fn _ -> {:ok, :cached} end,
          only: fn _ -> false end,
          error_classifier: TestClassifier
        )

      # :only returns false for everything, so fallback is not triggered
      assert result == {:error, :timeout}
    end
  end

  describe "backward compatibility" do
    test "circuit breaker still accepts function-based :error_classifier", %{name: name} do
      classifier = fn
        {:error, :special} -> true
        _ -> false
      end

      {:ok, _} =
        CircuitBreaker.start_link(
          name: name,
          failure_threshold: 1,
          error_classifier: classifier
        )

      CircuitBreaker.call(name, fn -> {:error, :other} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :closed

      CircuitBreaker.call(name, fn -> {:error, :special} end)
      Process.sleep(10)
      assert CircuitBreaker.get_state(name) == :open
    end

    test "retry still accepts function-based :retry_on" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.call(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :but_wrong}
          end,
          max_attempts: 3,
          base_delay: 1,
          jitter: false,
          retry_on: fn
            {:ok, :but_wrong} -> true
            _ -> false
          end
        )

      assert result == {:ok, :but_wrong}
      assert :counters.get(counter, 1) == 3
    end

    test "fallback still accepts function-based :only" do
      result =
        Fallback.call(
          fn -> {:error, :timeout} end,
          fallback: fn _ -> {:ok, :cached} end,
          only: fn
            {:error, :timeout} -> true
            _ -> false
          end
        )

      assert result == {:ok, :cached}
    end
  end

  describe "Pipeline.with_classifier/2" do
    test "propagates classifier to applicable layers", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:bulkhead, max_concurrent: 5)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3)
        |> Pipeline.add(:retry, max_attempts: 2)
        |> Pipeline.add(:fallback, fallback: fn _ -> {:ok, :default} end)
        |> Pipeline.with_classifier(TestClassifier)

      # Check the structure layer by layer (can't compare funs directly)
      assert length(pipeline.layers) == 4

      [{:bulkhead, bh_opts}, {:circuit_breaker, cb_opts}, {:retry, r_opts}, {:fallback, fb_opts}] =
        pipeline.layers

      refute Keyword.has_key?(bh_opts, :error_classifier)
      assert Keyword.get(cb_opts, :error_classifier) == TestClassifier
      assert Keyword.get(r_opts, :error_classifier) == TestClassifier
      assert Keyword.get(fb_opts, :error_classifier) == TestClassifier
    end

    test "does not overwrite existing classifier on a layer", %{name: name} do
      pipeline =
        Pipeline.new(name)
        |> Pipeline.add(:circuit_breaker, failure_threshold: 3, error_classifier: Default)
        |> Pipeline.add(:retry, max_attempts: 2)
        |> Pipeline.with_classifier(TestClassifier)

      [{:circuit_breaker, cb_opts}, {:retry, r_opts}] = pipeline.layers

      # Circuit breaker already had Default, should not be overwritten
      assert Keyword.get(cb_opts, :error_classifier) == Default
      # Retry had none, should get TestClassifier
      assert Keyword.get(r_opts, :error_classifier) == TestClassifier
    end
  end
end
