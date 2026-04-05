defmodule ExResilience.ChaosTest do
  use ExUnit.Case, async: true

  alias ExResilience.Chaos

  describe "passthrough" do
    test "calls function and returns result when rates are 0.0" do
      result = Chaos.call(fn -> {:ok, 42} end, error_rate: 0.0, latency_rate: 0.0)
      assert result == {:ok, 42}
    end

    test "rate 0.0 never injects over 100 iterations" do
      results =
        for _ <- 1..100 do
          Chaos.call(fn -> :ok end, error_rate: 0.0, latency_rate: 0.0)
        end

      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "error injection" do
    test "error_rate 1.0 always injects an error" do
      result = Chaos.call(fn -> {:ok, :should_not_reach} end, error_rate: 1.0, seed: 1)
      assert result == {:error, :chaos_fault}
    end

    test "does not call the wrapped function when error is injected" do
      ref = make_ref()

      Chaos.call(
        fn -> send(self(), {:called, ref}) end,
        error_rate: 1.0,
        seed: 1
      )

      refute_received {:called, ^ref}
    end

    test "custom error_fn is used" do
      result =
        Chaos.call(
          fn -> {:ok, 1} end,
          error_rate: 1.0,
          error_fn: fn -> {:error, :custom_fault} end,
          seed: 1
        )

      assert result == {:error, :custom_fault}
    end
  end

  describe "latency injection" do
    test "latency_rate 1.0 always adds delay" do
      start = System.monotonic_time(:millisecond)

      Chaos.call(
        fn -> :ok end,
        latency_rate: 1.0,
        latency_min: 50,
        latency_max: 50,
        error_rate: 0.0,
        seed: 1
      )

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed >= 45
    end

    test "latency_min equals latency_max produces exact delay" do
      start = System.monotonic_time(:millisecond)

      Chaos.call(
        fn -> :ok end,
        latency_rate: 1.0,
        latency_min: 30,
        latency_max: 30,
        error_rate: 0.0,
        seed: 1
      )

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed >= 25
    end
  end

  describe "combined error and latency" do
    test "both error and latency can be injected (latency first, then error)" do
      start = System.monotonic_time(:millisecond)

      result =
        Chaos.call(
          fn -> {:ok, :should_not_reach} end,
          error_rate: 1.0,
          latency_rate: 1.0,
          latency_min: 50,
          latency_max: 50,
          seed: 1
        )

      elapsed = System.monotonic_time(:millisecond) - start
      assert result == {:error, :chaos_fault}
      assert elapsed >= 45
    end
  end

  describe "deterministic seeding" do
    test "same seed produces same outcome across two runs" do
      opts = [error_rate: 0.5, latency_rate: 0.5, latency_min: 0, latency_max: 0, seed: 42]

      result1 = Chaos.call(fn -> {:ok, :value} end, opts)
      result2 = Chaos.call(fn -> {:ok, :value} end, opts)

      assert result1 == result2
    end

    test "different seeds can produce different outcomes" do
      # Run enough seeds to find at least one that differs.
      # With error_rate 0.5, this is very likely.
      results =
        for seed <- 1..20 do
          Chaos.call(
            fn -> {:ok, :value} end,
            error_rate: 0.5,
            latency_rate: 0.0,
            seed: seed
          )
        end

      # We should see both :ok and :error results
      unique = Enum.uniq(results)
      assert length(unique) > 1
    end
  end

  describe "telemetry" do
    test "emits passthrough event when no fault injected" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "chaos-passthrough-#{inspect(ref)}",
        [:ex_resilience, :chaos, :passthrough],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Chaos.call(fn -> :ok end, error_rate: 0.0, latency_rate: 0.0, name: :test_chaos)

      assert_received {:telemetry, [:ex_resilience, :chaos, :passthrough], %{system_time: _},
                        %{name: :test_chaos}}

      :telemetry.detach("chaos-passthrough-#{inspect(ref)}")
    end

    test "emits error_injected event" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "chaos-error-#{inspect(ref)}",
        [:ex_resilience, :chaos, :error_injected],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Chaos.call(fn -> :ok end, error_rate: 1.0, seed: 1, name: :test_chaos)

      assert_received {:telemetry, [:ex_resilience, :chaos, :error_injected], %{system_time: _},
                        %{name: :test_chaos}}

      :telemetry.detach("chaos-error-#{inspect(ref)}")
    end

    test "emits latency_injected event with delay_ms" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "chaos-latency-#{inspect(ref)}",
        [:ex_resilience, :chaos, :latency_injected],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Chaos.call(fn -> :ok end,
        latency_rate: 1.0,
        latency_min: 10,
        latency_max: 10,
        error_rate: 0.0,
        seed: 1,
        name: :test_chaos
      )

      assert_received {:telemetry, [:ex_resilience, :chaos, :latency_injected],
                        %{delay_ms: 10}, %{name: :test_chaos}}

      :telemetry.detach("chaos-latency-#{inspect(ref)}")
    end
  end
end
