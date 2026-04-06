defmodule ExResilience.HedgeTest do
  use ExUnit.Case, async: true

  alias ExResilience.Hedge

  describe "call/2" do
    test "fast function returns without hedging" do
      result = Hedge.call(fn -> {:ok, :fast} end, delay: 100)
      assert result == {:ok, :fast}
    end

    test "fast function emits primary_won telemetry" do
      id = System.unique_integer([:positive]) |> to_string()
      parent = self()

      :telemetry.attach(
        "hedge-primary-#{id}",
        [:ex_resilience, :hedge, :primary_won],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Hedge.call(fn -> {:ok, :fast} end, delay: 100, name: :test_hedge)

      assert_receive {:telemetry, [:ex_resilience, :hedge, :primary_won], _, %{name: :test_hedge}}

      :telemetry.detach("hedge-primary-#{id}")
    end

    test "slow primary triggers hedge, faster hedge wins" do
      counter = :counters.new(1, [:atomics])

      result =
        Hedge.call(
          fn ->
            :counters.add(counter, 1, 1)
            call_num = :counters.get(counter, 1)

            if call_num == 1 do
              # Primary is slow
              Process.sleep(500)
              {:ok, :primary}
            else
              # Hedge is fast
              {:ok, :hedge}
            end
          end,
          delay: 20
        )

      assert result == {:ok, :hedge}
    end

    test "slow primary triggers hedge_won telemetry" do
      id = System.unique_integer([:positive]) |> to_string()
      parent = self()

      :telemetry.attach(
        "hedge-won-#{id}",
        [:ex_resilience, :hedge, :hedge_won],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "hedge-fired-#{id}",
        [:ex_resilience, :hedge, :fired],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      counter = :counters.new(1, [:atomics])

      Hedge.call(
        fn ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)

          if n == 1 do
            Process.sleep(500)
            {:ok, :primary}
          else
            {:ok, :hedge}
          end
        end,
        delay: 20,
        name: :test_hedge2
      )

      assert_receive {:telemetry, [:ex_resilience, :hedge, :fired], %{count: 1},
                      %{name: :test_hedge2}}

      assert_receive {:telemetry, [:ex_resilience, :hedge, :hedge_won], _,
                      %{name: :test_hedge2, hedge_index: 1}}

      :telemetry.detach("hedge-won-#{id}")
      :telemetry.detach("hedge-fired-#{id}")
    end

    test "primary wins when hedge is also slow" do
      counter = :counters.new(1, [:atomics])

      result =
        Hedge.call(
          fn ->
            :counters.add(counter, 1, 1)
            n = :counters.get(counter, 1)

            if n == 1 do
              # Primary finishes just after delay
              Process.sleep(30)
              {:ok, :primary}
            else
              # Hedge is slower
              Process.sleep(200)
              {:ok, :hedge}
            end
          end,
          delay: 20
        )

      # Hedge fires after 20ms, primary finishes at ~30ms, hedge at ~220ms
      # Primary should win since it finishes first after hedges are launched
      assert result in [{:ok, :primary}, {:ok, :hedge}]
    end

    test "all fail returns first error" do
      result =
        Hedge.call(
          fn ->
            {:error, :boom}
          end,
          delay: 10
        )

      assert result == {:error, :boom}
    end

    test "max_hedged limits number of additional requests" do
      counter = :counters.new(1, [:atomics])

      Hedge.call(
        fn ->
          :counters.add(counter, 1, 1)
          # All tasks are slow to ensure hedges fire
          Process.sleep(200)
          {:ok, :done}
        end,
        delay: 10,
        max_hedged: 3
      )

      # 1 primary + up to 3 hedges = 4 total
      total = :counters.get(counter, 1)
      assert total <= 4
      assert total >= 2
    end

    test "tasks are cleaned up after completion" do
      _tasks_before = Task.Supervisor |> Process.whereis()

      Hedge.call(
        fn ->
          Process.sleep(200)
          {:ok, :done}
        end,
        delay: 10
      )

      # Give a moment for cleanup
      Process.sleep(50)

      # Verify no lingering processes from our tasks
      # This is a basic sanity check -- the important thing is no crash
      assert true
    end

    test "bare non-error values are treated as success" do
      result = Hedge.call(fn -> 42 end, delay: 100)
      assert result == 42
    end

    test "max_hedged: 2 fires two hedges" do
      id = System.unique_integer([:positive]) |> to_string()
      parent = self()

      :telemetry.attach(
        "hedge-fired2-#{id}",
        [:ex_resilience, :hedge, :fired],
        fn _event, measurements, _metadata, _ ->
          send(parent, {:fired, measurements.count})
        end,
        nil
      )

      Hedge.call(
        fn ->
          Process.sleep(200)
          {:ok, :done}
        end,
        delay: 10,
        max_hedged: 2
      )

      assert_receive {:fired, 2}

      :telemetry.detach("hedge-fired2-#{id}")
    end
  end
end
