defmodule ExResilienceTest do
  use ExUnit.Case
  doctest ExResilience

  test "greets the world" do
    assert ExResilience.hello() == :world
  end
end
