defmodule ExResilience.Backoff do
  @moduledoc """
  Backoff strategy implementations for retry delays.

  Supports fixed, linear, and exponential strategies with optional jitter.

  ## Strategies

    * `:fixed` -- constant delay between attempts.
    * `:linear` -- delay increases linearly: `base * attempt`.
    * `:exponential` -- delay doubles each attempt: `base * 2^(attempt - 1)`.

  ## Jitter

  Jitter adds randomness to avoid thundering herd effects. When enabled,
  the actual delay is a random value between 0 and the computed delay.

  ## Examples

      iex> ExResilience.Backoff.delay(:fixed, 100, 1)
      100

      iex> ExResilience.Backoff.delay(:fixed, 100, 5)
      100

      iex> ExResilience.Backoff.delay(:linear, 100, 3)
      300

      iex> ExResilience.Backoff.delay(:exponential, 100, 1)
      100

      iex> ExResilience.Backoff.delay(:exponential, 100, 4)
      800

  """

  @type strategy :: :fixed | :linear | :exponential
  @type milliseconds :: non_neg_integer()

  @doc """
  Computes the delay in milliseconds for the given strategy and attempt number.

  `attempt` is 1-based.

  ## Examples

      iex> ExResilience.Backoff.delay(:exponential, 50, 3)
      200

  """
  @spec delay(strategy(), milliseconds(), pos_integer()) :: milliseconds()
  def delay(:fixed, base_ms, _attempt), do: base_ms
  def delay(:linear, base_ms, attempt), do: base_ms * attempt
  def delay(:exponential, base_ms, attempt), do: base_ms * Integer.pow(2, attempt - 1)

  @doc """
  Computes delay with jitter applied.

  Returns a random value in `[0, delay]`. Uses `:rand.uniform/1` internally,
  so seed your PRNG if you need deterministic results.

  ## Examples

      iex> delay = ExResilience.Backoff.delay_with_jitter(:fixed, 100, 1)
      iex> delay >= 0 and delay <= 100
      true

  """
  @spec delay_with_jitter(strategy(), milliseconds(), pos_integer()) :: milliseconds()
  def delay_with_jitter(strategy, base_ms, attempt) do
    max_delay = delay(strategy, base_ms, attempt)

    case max_delay do
      0 -> 0
      d -> :rand.uniform(d + 1) - 1
    end
  end

  @doc """
  Computes delay with an optional max cap.

  The delay is clamped to `max_ms` if it would exceed it.

  ## Examples

      iex> ExResilience.Backoff.delay_capped(:exponential, 100, 10, 5_000)
      5000

  """
  @spec delay_capped(strategy(), milliseconds(), pos_integer(), milliseconds()) :: milliseconds()
  def delay_capped(strategy, base_ms, attempt, max_ms) do
    min(delay(strategy, base_ms, attempt), max_ms)
  end
end
