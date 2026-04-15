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
  @type failure :: {Exception.t(), Exception.stacktrace()}
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

    case capture_entries(propagators, failure_mode) do
      {:ok, entries} ->
        %__MODULE__{entries: entries, failure_mode: failure_mode}

      {:error, failure} ->
        reraise_failure(failure)
    end
  end

  @doc """
  Attaches a captured snapshot while executing `fun`.
  """
  @spec with_attached(t(), (-> result)) :: result when result: term()
  def with_attached(%__MODULE__{} = snapshot, fun) when is_function(fun, 0) do
    case attach_entries(snapshot.entries, snapshot.failure_mode) do
      {:ok, attached} ->
        try do
          fun.()
        after
          detach_all(attached, snapshot.failure_mode)
        end

      {:error, failure, attached} ->
        detach_all(attached, snapshot.failure_mode)
        reraise_failure(failure)
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

  defp capture_entries(propagators, failure_mode) do
    propagators
    |> Enum.reduce_while({:ok, []}, fn propagator, {:ok, acc} ->
      case invoke(:capture, propagator, [], failure_mode) do
        {:ok, captured_ctx} ->
          {:cont, {:ok, [{propagator, captured_ctx} | acc]}}

        :skip ->
          {:cont, {:ok, acc}}

        {:error, failure} ->
          {:halt, {:error, failure}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, failure} -> {:error, failure}
    end
  end

  defp attach_entries(entries, failure_mode) do
    Enum.reduce_while(entries, {:ok, []}, fn {propagator, captured_ctx}, {:ok, attached} ->
      case invoke(:attach, propagator, [captured_ctx], failure_mode) do
        {:ok, attached_ctx} ->
          {:cont, {:ok, [{propagator, attached_ctx} | attached]}}

        :skip ->
          {:cont, {:ok, attached}}

        {:error, failure} ->
          {:halt, {:error, failure, attached}}
      end
    end)
  end

  defp detach_all(attached, failure_mode) do
    case Enum.reduce(attached, nil, fn {propagator, attached_ctx}, first_failure ->
           next_failure =
             case invoke(:detach, propagator, [attached_ctx], failure_mode) do
               {:ok, :ok} -> nil
               {:ok, _other} -> nil
               :skip -> nil
               {:error, failure} -> failure
             end

           first_failure || next_failure
         end) do
      nil -> :ok
      failure -> reraise_failure(failure)
    end
  end

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
    exception =
      RuntimeError.exception(
        "Jido.Exec context propagator #{callback}/#{failure_arity(callback)} failed " <>
          "(propagator=#{inspect(propagator)}, failure_mode=:strict): #{format_failure(failure)}"
      )

    {:error, {exception, failure_stacktrace(failure)}}
  end

  defp failure_arity(:capture), do: 0
  defp failure_arity(:attach), do: 1
  defp failure_arity(:detach), do: 1

  defp reraise_failure({exception, []}), do: raise(exception)
  defp reraise_failure({exception, stacktrace}), do: reraise(exception, stacktrace)

  defp failure_stacktrace({_kind, _reason, stacktrace}), do: stacktrace

  defp format_failure({:error, %RuntimeError{message: "missing callback"}, _stacktrace}) do
    "callback not implemented"
  end

  defp format_failure({:error, error, _stacktrace}), do: inspect(error)
  defp format_failure({kind, reason, _stacktrace}), do: inspect({kind, reason})
end
