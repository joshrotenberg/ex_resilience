defmodule ExResilience.Chaos do
  @moduledoc """
  Stateless fault injection for testing resilience pipelines.

  Injects errors and/or latency into function calls based on configurable
  probabilities. Useful for verifying that upstream resilience layers
  (retry, circuit breaker, etc.) handle failures correctly.

  ## Options

    * `:name` -- optional atom for telemetry metadata. Default `:chaos`.
    * `:error_rate` -- probability of injecting an error (0.0 to 1.0). Default `0.0`.
    * `:error_fn` -- 0-arity function returning the error value.
      Default: `ExResilience.Chaos.default_error/0`.
    * `:latency_rate` -- probability of injecting latency (0.0 to 1.0). Default `0.0`.
    * `:latency_min` -- minimum injected latency in milliseconds. Default `0`.
    * `:latency_max` -- maximum injected latency in milliseconds. Default `100`.
    * `:seed` -- optional integer RNG seed for deterministic behavior.

  ## Execution Order

  1. If `:seed` is provided, seed the process RNG.
  2. Roll for latency injection. If triggered, sleep for a random duration
     in `[latency_min, latency_max]`.
  3. Roll for error injection. If triggered, return `error_fn.()` without
     calling the wrapped function.
  4. Otherwise, call the wrapped function and return its result.

  ## Examples

      iex> ExResilience.Chaos.call(fn -> {:ok, 1} end, error_rate: 0.0, latency_rate: 0.0)
      {:ok, 1}

      iex> ExResilience.Chaos.call(fn -> {:ok, 1} end, error_rate: 1.0)
      {:error, :chaos_fault}

  """

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:error_rate, float()}
          | {:error_fn, (-> term())}
          | {:latency_rate, float()}
          | {:latency_min, non_neg_integer()}
          | {:latency_max, non_neg_integer()}
          | {:seed, integer()}

  @doc """
  Returns the default error value used when no `:error_fn` is provided.
  """
  @spec default_error() :: {:error, :chaos_fault}
  def default_error, do: {:error, :chaos_fault}

  @doc """
  Executes `fun` with optional fault injection.

  See module documentation for available options and execution order.

  ## Examples

      iex> ExResilience.Chaos.call(fn -> :ok end, error_rate: 0.0)
      :ok

      iex> ExResilience.Chaos.call(fn -> :ok end, error_rate: 1.0, error_fn: fn -> {:error, :boom} end)
      {:error, :boom}

  """
  @spec call((-> term()), [option()]) :: term()
  def call(fun, opts \\ []) do
    name = Keyword.get(opts, :name, :chaos)
    error_rate = Keyword.get(opts, :error_rate, 0.0)
    error_fn = Keyword.get(opts, :error_fn, &default_error/0)
    latency_rate = Keyword.get(opts, :latency_rate, 0.0)
    latency_min = Keyword.get(opts, :latency_min, 0)
    latency_max = Keyword.get(opts, :latency_max, 100)
    seed = Keyword.get(opts, :seed)

    if seed do
      :rand.seed(:exsss, {seed, seed, seed})
    end

    injected_latency = maybe_inject_latency(name, latency_rate, latency_min, latency_max)
    maybe_inject_error(name, error_rate, error_fn, fun, injected_latency)
  end

  defp maybe_inject_latency(name, latency_rate, latency_min, latency_max) do
    if :rand.uniform() < latency_rate do
      delay_ms =
        if latency_min == latency_max do
          latency_min
        else
          latency_min + :rand.uniform(latency_max - latency_min + 1) - 1
        end

      Process.sleep(delay_ms)

      Telemetry.emit(
        [:ex_resilience, :chaos, :latency_injected],
        %{delay_ms: delay_ms},
        %{name: name}
      )

      true
    else
      false
    end
  end

  defp maybe_inject_error(name, error_rate, error_fn, fun, injected_latency) do
    if :rand.uniform() < error_rate do
      Telemetry.emit(
        [:ex_resilience, :chaos, :error_injected],
        %{system_time: System.system_time()},
        %{name: name}
      )

      error_fn.()
    else
      if not injected_latency do
        Telemetry.emit(
          [:ex_resilience, :chaos, :passthrough],
          %{system_time: System.system_time()},
          %{name: name}
        )
      end

      fun.()
    end
  end
end
