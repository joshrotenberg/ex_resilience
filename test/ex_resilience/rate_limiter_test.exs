defmodule ExResilience.RateLimiterTest do
  use ExUnit.Case, async: false

  alias ExResilience.RateLimiter

  setup do
    name = :"rl_#{System.unique_integer([:positive])}"
    %{name: name}
  end

  describe "basic operation" do
    test "allows calls when tokens available", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 5, interval: 1_000)
      assert RateLimiter.call(name, fn -> :ok end) == {:ok, :ok}
    end

    test "passes through ok tuples", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 5, interval: 1_000)
      assert RateLimiter.call(name, fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "passes through error tuples", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 5, interval: 1_000)
      assert RateLimiter.call(name, fn -> {:error, :oops} end) == {:error, :oops}
    end
  end

  describe "rate limiting" do
    test "rejects when tokens exhausted", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 2, interval: 60_000)

      assert RateLimiter.call(name, fn -> :ok end) == {:ok, :ok}
      assert RateLimiter.call(name, fn -> :ok end) == {:ok, :ok}
      assert RateLimiter.call(name, fn -> :ok end) == {:error, :rate_limited}
    end

    test "refills tokens after interval", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 1, interval: 50)

      assert RateLimiter.call(name, fn -> :ok end) == {:ok, :ok}
      assert RateLimiter.call(name, fn -> :ok end) == {:error, :rate_limited}

      Process.sleep(70)

      assert RateLimiter.call(name, fn -> :ok end) == {:ok, :ok}
    end

    test "does not exceed max_tokens on refill", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 5, interval: 50, max_tokens: 3)

      # Wait for a couple refills
      Process.sleep(120)

      # Should still only have max_tokens (3)
      assert RateLimiter.available_tokens(name) == 3
    end
  end

  describe "available_tokens/1" do
    test "tracks token count", %{name: name} do
      {:ok, _} = RateLimiter.start_link(name: name, rate: 5, interval: 60_000)
      assert RateLimiter.available_tokens(name) == 5

      RateLimiter.call(name, fn -> :ok end)
      assert RateLimiter.available_tokens(name) == 4
    end
  end
end
