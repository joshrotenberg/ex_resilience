defmodule ExResilience.Hedge do
  @moduledoc """
  Tail latency reduction by racing redundant requests.

  Starts the given function in a Task, waits for `:delay` milliseconds,
  and if no result has arrived, fires up to `:max_hedged` additional
  Tasks running the same function. The first successful result wins.

  This is useful when a backend has variable latency and you would rather
  pay the cost of a redundant request than wait for a slow one.

  ## Options

    * `:name` -- optional atom for telemetry metadata. Default `:hedge`.
    * `:delay` -- milliseconds to wait before firing hedge requests. Required.
    * `:max_hedged` -- max additional requests to fire. Default `1`.

  ## Examples

      iex> ExResilience.Hedge.call(fn -> {:ok, 42} end, delay: 100)
      {:ok, 42}

  """

  alias ExResilience.Telemetry

  @type option ::
          {:name, atom()}
          | {:delay, non_neg_integer()}
          | {:max_hedged, pos_integer()}

  @doc """
  Executes `fun` with hedge logic for tail latency reduction.

  Starts `fun` as the primary request. If it does not complete within
  `:delay` milliseconds, fires up to `:max_hedged` additional copies.
  Returns the first successful result, or the first error if all fail.

  ## Examples

      iex> ExResilience.Hedge.call(fn -> {:ok, :fast} end, delay: 50)
      {:ok, :fast}

  """
  @spec call((-> term()), [option()]) :: term()
  def call(fun, opts) do
    name = Keyword.get(opts, :name, :hedge)
    delay = Keyword.fetch!(opts, :delay)
    max_hedged = Keyword.get(opts, :max_hedged, 1)

    primary = Task.async(fun)

    case receive_result([{primary, :primary}], delay) do
      {:ok, result, remaining} ->
        Telemetry.emit(
          [:ex_resilience, :hedge, :primary_won],
          %{system_time: System.system_time()},
          %{name: name}
        )

        shutdown_tasks(remaining)
        result

      :timeout ->
        hedges =
          for i <- 1..max_hedged do
            {Task.async(fun), {:hedge, i}}
          end

        Telemetry.emit(
          [:ex_resilience, :hedge, :fired],
          %{count: length(hedges)},
          %{name: name}
        )

        all_tasks = [{primary, :primary} | hedges]
        await_first_success(all_tasks, name)
    end
  end

  # Wait for the first result from any task in the list, with a timeout.
  # Returns {:ok, result, remaining_tasks} or :timeout.
  defp receive_result(tasks, timeout) do
    refs = Map.new(tasks, fn {task, tag} -> {task.ref, {task, tag}} end)

    receive do
      {ref, result} when is_map_key(refs, ref) ->
        Process.demonitor(ref, [:flush])
        {task, _tag} = refs[ref]
        remaining = Enum.reject(tasks, fn {t, _} -> t == task end)

        if success?(result) do
          {:ok, result, remaining}
        else
          # Non-success on the only task before timeout -- keep waiting
          if remaining == [] do
            {:ok, result, []}
          else
            receive_result(remaining, timeout)
          end
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(refs, ref) ->
        {task, _tag} = refs[ref]
        remaining = Enum.reject(tasks, fn {t, _} -> t == task end)

        if remaining == [] do
          {:ok, {:error, reason}, []}
        else
          receive_result(remaining, timeout)
        end
    after
      timeout -> :timeout
    end
  end

  # Await the first successful result from all tasks, or return the first error.
  defp await_first_success(tasks, name) do
    collect_results(tasks, name, nil)
  end

  defp collect_results([], _name, first_error) do
    first_error
  end

  defp collect_results(tasks, name, first_error) do
    refs = Map.new(tasks, fn {task, tag} -> {task.ref, {task, tag}} end)

    receive do
      {ref, result} when is_map_key(refs, ref) ->
        Process.demonitor(ref, [:flush])
        {task, tag} = refs[ref]
        remaining = Enum.reject(tasks, fn {t, _} -> t == task end)

        if success?(result) do
          emit_winner(tag, name)
          shutdown_tasks(remaining)
          result
        else
          error = first_error || result
          collect_results(remaining, name, error)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(refs, ref) ->
        {task, _tag} = refs[ref]
        remaining = Enum.reject(tasks, fn {t, _} -> t == task end)
        error = first_error || {:error, reason}
        collect_results(remaining, name, error)
    end
  end

  defp emit_winner(:primary, name) do
    Telemetry.emit(
      [:ex_resilience, :hedge, :primary_won],
      %{system_time: System.system_time()},
      %{name: name}
    )
  end

  defp emit_winner({:hedge, index}, name) do
    Telemetry.emit(
      [:ex_resilience, :hedge, :hedge_won],
      %{system_time: System.system_time()},
      %{name: name, hedge_index: index}
    )
  end

  defp success?({:ok, _}), do: true
  defp success?({:error, _}), do: false
  defp success?(:ok), do: true
  defp success?(:error), do: false
  defp success?(_), do: true

  defp shutdown_tasks(tasks) do
    Enum.each(tasks, fn {task, _tag} ->
      Task.shutdown(task, :brutal_kill)
    end)
  end
end
