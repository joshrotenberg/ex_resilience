defmodule ExResilience.ErrorClassifier do
  @moduledoc """
  Behaviour for classifying function results.

  Implement this behaviour to control how patterns respond to different
  results. A single classifier can be shared across all patterns in a
  pipeline.

  ## Classifications

    * `:ok` -- success. Resets circuit breaker failure count.
    * `:retriable` -- transient error. Retry will attempt again.
      Counts as failure for circuit breaker.
    * `:failure` -- permanent error. Do not retry.
      Counts as failure for circuit breaker.
    * `:ignore` -- do not count as success or failure.
      Circuit breaker ignores. Retry does not retry.

  ## Examples

  A custom classifier that treats timeouts as retriable but authorization
  errors as permanent failures:

      defmodule MyApp.Classifier do
        @behaviour ExResilience.ErrorClassifier

        @impl true
        def classify({:error, :timeout}), do: :retriable
        def classify({:error, :econnrefused}), do: :retriable
        def classify({:error, :unauthorized}), do: :failure
        def classify({:error, _}), do: :failure
        def classify(_), do: :ok
      end

  Pass the module to any pattern via the `:error_classifier` option:

      ExResilience.CircuitBreaker.start_link(
        name: :my_cb,
        error_classifier: MyApp.Classifier
      )

  """

  @type classification :: :ok | :retriable | :failure | :ignore

  @callback classify(result :: term()) :: classification()
end
