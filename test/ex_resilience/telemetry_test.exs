defmodule ExResilience.TelemetryTest do
  use ExUnit.Case, async: true

  alias ExResilience.Telemetry

  describe "events/0" do
    test "returns all event names as lists of atoms" do
      events = Telemetry.events()
      assert [_ | _] = events

      for event <- events do
        assert is_list(event)
        assert Enum.all?(event, &is_atom/1)
        assert hd(event) == :ex_resilience
      end
    end
  end
end
