defmodule ExResilience.FallbackTest do
  use ExUnit.Case, async: true

  alias ExResilience.Fallback

  describe "call/2" do
    test "passes through successful results unchanged" do
      result =
        Fallback.call(
          fn -> {:ok, 42} end,
          fallback: fn _err -> {:ok, 0} end
        )

      assert result == {:ok, 42}
    end

    test "calls fallback on {:error, _}" do
      result =
        Fallback.call(
          fn -> {:error, :down} end,
          fallback: fn {:error, reason} -> {:ok, {:cached, reason}} end
        )

      assert result == {:ok, {:cached, :down}}
    end

    test "calls fallback on bare :error atom" do
      result =
        Fallback.call(
          fn -> :error end,
          fallback: fn :error -> {:ok, :default} end
        )

      assert result == {:ok, :default}
    end

    test "custom :only predicate filters which errors trigger fallback" do
      # Only fall back on :timeout errors, not :auth errors
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

    test "skips fallback when :only predicate does not match" do
      result =
        Fallback.call(
          fn -> {:error, :auth_failed} end,
          fallback: fn _ -> {:ok, :cached} end,
          only: fn
            {:error, :timeout} -> true
            _ -> false
          end
        )

      assert result == {:error, :auth_failed}
    end

    test "emits :applied telemetry when fallback is used" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:ex_resilience, :fallback, :applied]]
        )

      Fallback.call(
        fn -> {:error, :fail} end,
        fallback: fn _ -> {:ok, :recovered} end,
        name: :my_fb
      )

      assert_received {[:ex_resilience, :fallback, :applied], ^ref, _measurements,
                       %{name: :my_fb}}
    end

    test "emits :passthrough telemetry on success" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:ex_resilience, :fallback, :passthrough]]
        )

      Fallback.call(
        fn -> {:ok, 42} end,
        fallback: fn _ -> {:ok, 0} end,
        name: :my_fb
      )

      assert_received {[:ex_resilience, :fallback, :passthrough], ^ref, _measurements,
                       %{name: :my_fb}}
    end

    test "emits :skipped telemetry when custom :only does not match an error" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:ex_resilience, :fallback, :skipped]]
        )

      Fallback.call(
        fn -> {:error, :auth_failed} end,
        fallback: fn _ -> {:ok, :cached} end,
        name: :my_fb,
        only: fn
          {:error, :timeout} -> true
          _ -> false
        end
      )

      assert_received {[:ex_resilience, :fallback, :skipped], ^ref, _measurements,
                       %{name: :my_fb}}
    end
  end
end
