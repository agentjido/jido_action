defmodule Jido.Exec.Telemetry do
  @moduledoc """
  Telemetry boundary for Jido action execution.

  These events intentionally keep the historical `[:jido, :action]` span
  surface while the execution engine delegates scheduling, retry, timeout, and
  fallback policy to Runic.
  """

  alias Jido.Action.Error
  alias Runic.Workflow.Runnable

  @event_prefix [:jido, :action]

  @doc false
  @spec span(module(), map(), keyword(), (-> term())) :: term()
  def span(action, context, opts, fun) when is_atom(action) and is_function(fun, 0) do
    start_metadata = span_start_metadata(action, context, opts)

    :telemetry.span(@event_prefix, start_metadata, fn ->
      result = fun.()
      {result, Map.merge(start_metadata, span_stop_metadata(result))}
    end)
  end

  defp span_start_metadata(action, context, opts) do
    %{action: action}
    |> maybe_put(:jido, Keyword.get(opts, :jido) || extract_jido(context))
  end

  defp span_stop_metadata({:ok, {%Runnable{} = runnable, _events}}),
    do: runnable_metadata(runnable)

  defp span_stop_metadata({:error, error}), do: error_metadata(error)

  defp runnable_metadata(%Runnable{status: :completed, result: result}) do
    %{outcome: :ok}
    |> maybe_put(:directive?, directive?(result))
  end

  defp runnable_metadata(%Runnable{status: status, error: error})
       when status in [:failed, :skipped] do
    error_metadata(error)
  end

  defp error_metadata(error, opts \\ [])

  defp error_metadata({:timeout, timeout}, opts) when is_integer(timeout) do
    %{
      outcome: :error,
      error_type: :timeout,
      retryable?: true
    }
    |> maybe_put(:directive?, Keyword.get(opts, :directive?))
  end

  defp error_metadata({:deadline_exceeded, _remaining}, opts) do
    %{
      outcome: :error,
      error_type: :timeout,
      retryable?: true
    }
    |> maybe_put(:directive?, Keyword.get(opts, :directive?))
  end

  defp error_metadata(error, opts) do
    normalized = Error.to_map(error)

    %{
      outcome: :error,
      error_type: normalized.type,
      retryable?: normalized.retryable?
    }
    |> maybe_put(:directive?, Keyword.get(opts, :directive?))
  end

  defp directive?(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :jido_directives) do
      nil -> nil
      _directives -> true
    end
  end

  defp extract_jido(context) when is_map(context) do
    Map.get(context, :jido) || Map.get(context, "jido")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
