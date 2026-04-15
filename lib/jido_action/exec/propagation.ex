defmodule Jido.Exec.Propagation do
  @moduledoc """
  Resolves and applies runtime-context propagators across supervised execution.

  `jido_action` uses this helper to preserve ambient process-local state when it
  crosses `Task.Supervisor` boundaries for timeouts, async execution,
  compensation, and async chains.
  """

  require Logger

  @type failure_mode :: :warn | :strict
  @type propagator :: module()
  @type snapshot_entry :: {propagator(), term()}

  @type t :: %__MODULE__{
          entries: [snapshot_entry()],
          failure_mode: failure_mode()
        }

  defstruct entries: [],
            failure_mode: :warn

  @observability_key :observability
  @default_failure_mode :warn

  @doc """
  Captures the configured runtime-context propagators for the current process.
  """
  @spec capture(keyword()) :: t()
  def capture(opts \\ []) when is_list(opts) do
    failure_mode = failure_mode(opts)
    propagators = context_propagators(opts)

    entries =
      Enum.reduce(propagators, [], fn propagator, acc ->
        case invoke(:capture, propagator, [], failure_mode) do
          {:ok, captured_ctx} -> [{propagator, captured_ctx} | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()

    %__MODULE__{entries: entries, failure_mode: failure_mode}
  end

  @doc """
  Attaches a captured snapshot while executing `fun`.
  """
  @spec with_attached(t(), (-> result)) :: result when result: term()
  def with_attached(%__MODULE__{} = snapshot, fun) when is_function(fun, 0) do
    attached =
      Enum.reduce(snapshot.entries, [], fn {propagator, captured_ctx}, acc ->
        case invoke(:attach, propagator, [captured_ctx], snapshot.failure_mode) do
          {:ok, attached_ctx} -> [{propagator, attached_ctx} | acc]
          :skip -> acc
        end
      end)

    try do
      fun.()
    after
      Enum.each(attached, fn {propagator, attached_ctx} ->
        case invoke(:detach, propagator, [attached_ctx], snapshot.failure_mode) do
          {:ok, :ok} -> :ok
          {:ok, _other} -> :ok
          :skip -> :ok
        end
      end)
    end
  end

  @doc """
  Resolves the configured context propagator modules.
  """
  @spec context_propagators(keyword()) :: [propagator()]
  def context_propagators(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get_lazy(:context_propagators, fn ->
      :jido_action
      |> Application.get_env(@observability_key, [])
      |> Keyword.get(:context_propagators, [])
    end)
    |> normalize_context_propagators()
  end

  @doc """
  Resolves the effective failure mode for propagator callbacks.
  """
  @spec failure_mode(keyword()) :: failure_mode()
  def failure_mode(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get_lazy(:context_propagator_failure_mode, fn ->
      :jido_action
      |> Application.get_env(@observability_key, [])
      |> Keyword.get(:context_propagator_failure_mode, @default_failure_mode)
    end)
    |> normalize_failure_mode()
  end

  defp normalize_context_propagators(propagators) when is_list(propagators) do
    propagators
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp normalize_context_propagators(_), do: []

  defp normalize_failure_mode(mode) when mode in [:warn, :strict], do: mode
  defp normalize_failure_mode(_invalid), do: @default_failure_mode

  defp invoke(callback, propagator, args, failure_mode) do
    if function_exported?(propagator, callback, length(args)) do
      try do
        {:ok, apply(propagator, callback, args)}
      rescue
        error ->
          handle_failure(propagator, callback, {:error, error, __STACKTRACE__}, failure_mode)
      catch
        kind, reason ->
          handle_failure(propagator, callback, {kind, reason, __STACKTRACE__}, failure_mode)
      end
    else
      handle_failure(
        propagator,
        callback,
        {:error, RuntimeError.exception("missing callback"), []},
        failure_mode
      )
    end
  end

  defp handle_failure(propagator, callback, failure, :warn) do
    Logger.warning(
      "Jido.Exec context propagator #{callback}/#{failure_arity(callback)} failed " <>
        "(propagator=#{inspect(propagator)}, failure_mode=:warn): #{format_failure(failure)}"
    )

    :skip
  end

  defp handle_failure(propagator, callback, failure, :strict) do
    raise RuntimeError,
          "Jido.Exec context propagator #{callback}/#{failure_arity(callback)} failed " <>
            "(propagator=#{inspect(propagator)}, failure_mode=:strict): #{format_failure(failure)}"
  end

  defp failure_arity(:capture), do: 0
  defp failure_arity(:attach), do: 1
  defp failure_arity(:detach), do: 1

  defp format_failure({:error, %RuntimeError{message: "missing callback"}, _stacktrace}) do
    "callback not implemented"
  end

  defp format_failure({:error, error, _stacktrace}), do: inspect(error)
  defp format_failure({kind, reason, _stacktrace}), do: inspect({kind, reason})
end
