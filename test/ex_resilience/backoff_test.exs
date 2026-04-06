defmodule ExResilience.BackoffTest do
  use ExUnit.Case, async: true

  alias ExResilience.Backoff

  doctest ExResilience.Backoff

  describe "delay/3" do
    test "fixed returns constant delay regardless of attempt" do
      assert Backoff.delay(:fixed, 100, 1) == 100
      assert Backoff.delay(:fixed, 100, 5) == 100
      assert Backoff.delay(:fixed, 100, 100) == 100
    end

    test "linear scales linearly with attempt" do
      assert Backoff.delay(:linear, 100, 1) == 100
      assert Backoff.delay(:linear, 100, 2) == 200
      assert Backoff.delay(:linear, 100, 5) == 500
    end

    test "exponential doubles each attempt" do
      assert Backoff.delay(:exponential, 100, 1) == 100
      assert Backoff.delay(:exponential, 100, 2) == 200
      assert Backoff.delay(:exponential, 100, 3) == 400
      assert Backoff.delay(:exponential, 100, 4) == 800
    end

    test "zero base returns zero" do
      assert Backoff.delay(:fixed, 0, 1) == 0
      assert Backoff.delay(:linear, 0, 5) == 0
      assert Backoff.delay(:exponential, 0, 5) == 0
    end
  end

  describe "delay_with_jitter/3" do
    test "returns value in [0, delay]" do
      for _ <- 1..100 do
        result = Backoff.delay_with_jitter(:fixed, 100, 1)
        assert result >= 0 and result <= 100
      end
    end

    test "zero base returns zero" do
      assert Backoff.delay_with_jitter(:fixed, 0, 1) == 0
    end
  end

  describe "delay_capped/4" do
    test "caps delay at max" do
      assert Backoff.delay_capped(:exponential, 100, 10, 5_000) == 5_000
    end

    test "returns uncapped delay when under max" do
      assert Backoff.delay_capped(:exponential, 100, 2, 5_000) == 200
    end
  end
end
