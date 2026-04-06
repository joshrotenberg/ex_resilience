defmodule ExResilience.ErrorClassifier.Default do
  @moduledoc """
  Default error classifier.

  Matches the existing behaviour of all patterns:

    * `{:error, _}` and `:error` are classified as `:retriable`.
    * Everything else is classified as `:ok`.
  """

  @behaviour ExResilience.ErrorClassifier

  @impl true
  @spec classify(term()) :: ExResilience.ErrorClassifier.classification()
  def classify({:error, _}), do: :retriable
  def classify(:error), do: :retriable
  def classify(_), do: :ok
end
