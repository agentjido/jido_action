defmodule Jido.Action.Telemetry do
  @moduledoc false

  alias Jido.Action.Error

  @type span :: %{
          event: [atom()],
          metadata: map(),
          started_at: integer()
        }

  @spec execution_id() :: String.t()
  def execution_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec start([atom()], map()) :: span()
  def start(event, metadata) do
    started_at = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time(), monotonic_time: started_at},
      metadata
    )

    %{event: event, metadata: metadata, started_at: started_at}
  end

  @spec stop(span()) :: :ok
  def stop(span) do
    emit_terminal(span, :stop, %{})
  end

  @spec error(span(), term()) :: :ok
  def error(span, error) do
    emit_terminal(span, :error, %{error: error, error_type: error_type(error)})
  end

  @spec finish(span(), term()) :: term()
  def finish(span, result) do
    case result do
      {:error, error} -> error(span, error)
      {:error, error, _extras} -> error(span, error)
      _success -> stop(span)
    end

    result
  end

  defp emit_terminal(span, suffix, extra_metadata) do
    stopped_at = System.monotonic_time()

    :telemetry.execute(
      span.event ++ [suffix],
      %{duration: stopped_at - span.started_at, monotonic_time: stopped_at},
      Map.merge(span.metadata, extra_metadata)
    )
  end

  defp error_type(error) when is_exception(error) do
    error
    |> Error.to_map()
    |> Map.get(:type, error.__struct__)
  rescue
    _exception -> error.__struct__
  end

  defp error_type(error), do: error |> value_type()

  defp value_type(value) when is_atom(value), do: value
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_list(value), do: :list
  defp value_type(_value), do: :other
end
