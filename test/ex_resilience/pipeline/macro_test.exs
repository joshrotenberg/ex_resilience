defmodule ExResilience.Pipeline.MacroTest do
  use ExUnit.Case, async: false

  # Define test modules using the macro.
  # Each gets a unique pipeline name to avoid collisions.

  defmodule BasicPipeline do
    use ExResilience.Pipeline,
      name: :basic_macro_test,
      bulkhead: [max_concurrent: 5],
      circuit_breaker: [failure_threshold: 3],
      retry: [max_attempts: 2, base_delay: 1, jitter: false]
  end

  defmodule StatelessOnly do
    use ExResilience.Pipeline,
      name: :stateless_macro_test,
      retry: [max_attempts: 2, base_delay: 1, jitter: false],
      fallback: [fallback: fn _reason -> {:ok, :fallback} end]
  end

  defmodule RateLimitedPipeline do
    use ExResilience.Pipeline,
      name: :rate_limited_macro_test,
      rate_limiter: [rate: 1, interval: 60_000]
  end

  defmodule DefaultNamePipeline do
    use ExResilience.Pipeline,
      bulkhead: [max_concurrent: 5]
  end

  describe "pipeline/0" do
    test "returns a Pipeline struct with correct layers" do
      pipeline = BasicPipeline.pipeline()
      assert pipeline.name == :basic_macro_test
      assert length(pipeline.layers) == 3

      [{l1, _}, {l2, _}, {l3, _}] = pipeline.layers
      assert l1 == :bulkhead
      assert l2 == :circuit_breaker
      assert l3 == :retry
    end

    test "preserves layer options" do
      pipeline = BasicPipeline.pipeline()
      {_, bulkhead_opts} = Enum.find(pipeline.layers, fn {l, _} -> l == :bulkhead end)
      assert bulkhead_opts[:max_concurrent] == 5
    end

    test "generates default name from module name" do
      pipeline = DefaultNamePipeline.pipeline()
      # Module is ExResilience.Pipeline.MacroTest.DefaultNamePipeline
      assert is_atom(pipeline.name)
      assert pipeline.name != nil
    end
  end

  describe "child_spec/1" do
    test "returns a supervisor child spec" do
      spec = BasicPipeline.child_spec([])
      assert spec.id == BasicPipeline
      assert spec.type == :supervisor
      assert spec.start == {BasicPipeline, :start_link, [[]]}
    end
  end

  describe "start_link/1 and call/1" do
    test "starts supervisor and calls through pipeline" do
      {:ok, sup} =
        BasicPipeline.start_link(
          supervisor_name: :"basic_macro_sup_#{System.unique_integer([:positive])}"
        )

      assert Process.alive?(sup)

      result = BasicPipeline.call(fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "stateless-only pipeline starts with no children" do
      {:ok, sup} =
        StatelessOnly.start_link(
          supervisor_name: :"stateless_macro_sup_#{System.unique_integer([:positive])}"
        )

      assert Supervisor.which_children(sup) == []
    end

    test "rate limiter works through macro-defined module" do
      {:ok, _sup} =
        RateLimitedPipeline.start_link(
          supervisor_name: :"rl_macro_sup_#{System.unique_integer([:positive])}"
        )

      assert RateLimitedPipeline.call(fn -> {:ok, :first} end) == {:ok, :first}
      assert RateLimitedPipeline.call(fn -> {:ok, :second} end) == {:error, :rate_limited}
    end
  end

  describe "call/2" do
    test "accepts opts as second argument" do
      {:ok, _sup} =
        BasicPipeline.start_link(
          supervisor_name: :"basic_macro_call2_#{System.unique_integer([:positive])}"
        )

      result = BasicPipeline.call(fn -> {:ok, :with_opts} end, [])
      assert result == {:ok, :with_opts}
    end
  end

  describe "in a supervision tree" do
    test "can be added as a child to a supervisor" do
      sup_name = :"tree_test_sup_#{System.unique_integer([:positive])}"

      children = [
        {RateLimitedPipeline, supervisor_name: :"tree_rl_#{System.unique_integer([:positive])}"}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: sup_name)
      assert Process.alive?(sup)

      assert RateLimitedPipeline.call(fn -> {:ok, :tree} end) == {:ok, :tree}
    end
  end

  describe "compile-time validation" do
    test "raises on invalid layer name" do
      assert_raise ArgumentError, ~r/unknown layer :invalid_layer/, fn ->
        Code.compile_string("""
        defmodule InvalidLayerTest do
          use ExResilience.Pipeline,
            name: :invalid_test,
            invalid_layer: [some: :opt]
        end
        """)
      end
    end
  end
end
