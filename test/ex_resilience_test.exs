defmodule ExResilienceTest do
  use ExUnit.Case

  doctest ExResilience

  describe "top-level API delegates" do
    test "new/1 creates a pipeline" do
      pipeline = ExResilience.new(:test_svc)
      assert pipeline.name == :test_svc
      assert pipeline.layers == []
    end

    test "add/3 appends layers" do
      pipeline =
        ExResilience.new(:test_svc)
        |> ExResilience.add(:retry, max_attempts: 2)
        |> ExResilience.add(:bulkhead, max_concurrent: 5)

      assert length(pipeline.layers) == 2
      assert [{:retry, _}, {:bulkhead, _}] = pipeline.layers
    end
  end
end
