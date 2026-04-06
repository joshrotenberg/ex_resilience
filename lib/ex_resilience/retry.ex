defmodule ExResilience.Retry do
  @moduledoc """
  Retry logic with configurable backoff strategies.

  Wraps a function call and retries on failure according to the configured
  strategy. Does not use a GenServer -- retry is stateless per-call.

  ## Options

    * `:name` -- optional atom used in telemetry metadata. Default `:retry`.
    * `:max_attempts` -- total attempts (including the first). Default `3`.
    * `:backoff` -- backoff strategy (`:fixed`, `:linear`, `:exponential`). Default `:exponential`.
    * `:base_delay` -- base delay in ms. Default `100`.
    * `:max_delay` -- cap on delay in ms. Default `10_000`.
    * `:jitter` -- jitter setting. Can be `true` (full jitter, delay randomized
      in `[0, delay]`), `false` (no jitter), or a float between 0.0 and 1.0
      for proportional jitter (delay adjusted by +/- `delay * fraction`).
      Default `true`.
    * `:retry_on` -- 1-arity predicate that returns `true` if the result
      should be retried. Default: retries `{:error, _}` and `:error`.
      Takes precedence over `:error_classifier` when both are provided.
    * `:error_classifier` -- module implementing `ExResilience.ErrorClassifier`.
      When provided (and `:retry_on` is not), retries results classified as
      `:retriable`. Ignored if `:retry_on` is also set.

  ## Examples

      iex> ExResilience.Retry.call(fn -> {:ok, 42} end, max_attempts: 3)
      {:ok, 42}

      iex> ExResilience.Retry.call(fn -> {:error, :fail} end, max_attempts: 2)
      {:error, :fail}

  """

  alias ExResilience.{Backoff, Telemetry}

  @type option ::
          {:name, atom()}
          | {:max_attempts, pos_integer()}
          | {:backoff, Backoff.strategy()}
          | {:base_delay, Backoff.milliseconds()}
          | {:max_delay, Backoff.milliseconds()}
          | {:jitter, boolean() | float()}
          | {:retry_on, (term() -> boolean())}
          | {:error_classifier, module()}

  defmodule Config do
    @moduledoc false
    @enforce_keys [:name, :max_attempts, :backoff, :base_delay, :max_delay, :jitter, :retry_on]
    defstruct [:name, :max_attempts, :backoff, :base_delay, :max_delay, :jitter, :retry_on]
  end

  @doc """
  Executes `fun` with retry logic.

  Returns the result of the first successful call, or the last result
  after all attempts are exhausted.
  """
  @spec call((-> term()), [option()]) :: term()
  def call(fun, opts \\ []) do
    retry_on = resolve_retry_on(opts)

    config = %Config{
      name: Keyword.get(opts, :name, :retry),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      backoff: Keyword.get(opts, :backoff, :exponential),
      base_delay: Keyword.get(opts, :base_delay, 100),
      max_delay: Keyword.get(opts, :max_delay, 10_000),
      jitter: Keyword.get(opts, :jitter, true),
      retry_on: retry_on
    }

    do_retry(fun, config, 1)
  end

  defp resolve_retry_on(opts) do
    cond do
      Keyword.has_key?(opts, :retry_on) ->
        Keyword.fetch!(opts, :retry_on)

      Keyword.has_key?(opts, :error_classifier) ->
        classifier = Keyword.fetch!(opts, :error_classifier)
        fn result -> classifier.classify(result) == :retriable end

      true ->
        &default_retry_on/1
    end
  end

  defp do_retry(fun, config, attempt) do
    delay_ms =
      if attempt > 1 do
        raw =
          Backoff.delay_capped(config.backoff, config.base_delay, attempt - 1, config.max_delay)

        apply_jitter(raw, config.jitter)
      else
        0
      end

    if attempt > 1 and delay_ms > 0 do
      Process.sleep(delay_ms)
    end

    Telemetry.emit(
      [:ex_resilience, :retry, :attempt],
      %{attempt: attempt, delay_ms: delay_ms},
      %{name: config.name}
    )

    result = fun.()

    if config.retry_on.(result) and attempt < config.max_attempts do
      do_retry(fun, config, attempt + 1)
    else
      if config.retry_on.(result) do
        Telemetry.emit(
          [:ex_resilience, :retry, :exhausted],
          %{attempts: attempt},
          %{name: config.name, last_result: result}
        )
      end

      result
    end
  end

  defp apply_jitter(delay, false), do: delay
  defp apply_jitter(delay, true), do: jitter_delay(delay)

  defp apply_jitter(delay, fraction) when is_float(fraction),
    do: proportional_jitter(delay, fraction)

  defp jitter_delay(0), do: 0
  defp jitter_delay(max), do: :rand.uniform(max + 1) - 1

  defp proportional_jitter(0, _fraction), do: 0

  defp proportional_jitter(delay, fraction) do
    range = delay * fraction
    offset = :rand.uniform() * range * 2 - range
    max(round(delay + offset), 0)
  end

  @doc false
  @spec default_retry_on(term()) :: boolean()
  def default_retry_on({:error, _}), do: true
  def default_retry_on(:error), do: true
  def default_retry_on(_), do: false
end
