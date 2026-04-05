defmodule ExResilience.Fallback do
  @moduledoc """
  Stateless fallback layer for graceful degradation.

  When the wrapped function returns an error, calls a fallback function
  instead. The fallback receives the error result and returns a replacement
  value.

  ## Options

    * `:name` -- optional atom for telemetry metadata. Default `:fallback`.
    * `:fallback` -- required 1-arity function receiving the error result,
      returns the fallback value.
    * `:only` -- optional 1-arity predicate; fallback only triggers when
      this returns `true`. Default: matches `{:error, _}` and `:error`.

  ## Examples

      iex> ExResilience.Fallback.call(fn -> {:error, :down} end, fallback: fn _err -> {:ok, :cached} end)
      {:ok, :cached}

      iex> ExResilience.Fallback.call(fn -> {:ok, 42} end, fallback: fn _err -> {:ok, 0} end)
      {:ok, 42}

  """

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:fallback, (term() -> term())}
          | {:only, (term() -> boolean())}

  @doc """
  Executes `fun` and applies the fallback if the result matches the error predicate.

  The `:fallback` option is required and must be a 1-arity function that receives
  the error result.

  ## Examples

      iex> ExResilience.Fallback.call(
      ...>   fn -> {:error, :timeout} end,
      ...>   fallback: fn {:error, reason} -> {:ok, {:default, reason}} end
      ...> )
      {:ok, {:default, :timeout}}

      iex> ExResilience.Fallback.call(
      ...>   fn -> {:ok, :fast} end,
      ...>   fallback: fn _ -> {:ok, :slow} end
      ...> )
      {:ok, :fast}

  """
  @spec call((-> term()), [option()]) :: term()
  def call(fun, opts) do
    fallback_fn = Keyword.fetch!(opts, :fallback)
    name = Keyword.get(opts, :name, :fallback)
    only = Keyword.get(opts, :only, &default_error_check/1)

    result = fun.()

    has_custom_only = Keyword.has_key?(opts, :only)

    cond do
      only.(result) ->
        fallback_result = fallback_fn.(result)

        Telemetry.emit(
          [:ex_resilience, :fallback, :applied],
          %{system_time: System.system_time()},
          %{name: name}
        )

        fallback_result

      has_custom_only and default_error_check(result) ->
        # Result is an error but the custom :only predicate didn't match
        Telemetry.emit(
          [:ex_resilience, :fallback, :skipped],
          %{system_time: System.system_time()},
          %{name: name}
        )

        result

      true ->
        Telemetry.emit(
          [:ex_resilience, :fallback, :passthrough],
          %{system_time: System.system_time()},
          %{name: name}
        )

        result
    end
  end

  @doc false
  @spec default_error_check(term()) :: boolean()
  def default_error_check({:error, _}), do: true
  def default_error_check(:error), do: true
  def default_error_check(_), do: false
end
