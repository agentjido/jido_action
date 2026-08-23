defmodule Jido.Flow.Compiler.ErrorTagger do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Compiler.TargetContext

  @doc false
  def tag_target_error(result, phase, %TargetContext{} = context) do
    tag(result, phase, context, :target)
  end

  @doc false
  def tag_target_validation_error(result, :input, %TargetContext{} = context) do
    tag(result, :input, context, :validation)
  end

  defp tag({:ok, value}, _phase, _context, _mode), do: {:ok, value}

  defp tag({:error, error}, phase, context, mode) when is_exception(error) do
    tagged_phase = TargetContext.phase(context, phase)

    case TargetContext.exception_strategy(context, tagged_phase, error, mode) do
      {:validation, details} ->
        {:error, Error.validation_error(Exception.message(error), details)}

      {:merge, details} ->
        {:error, %{error | details: details}}

      {:replace, details} ->
        {:error, replace_details(error, details)}
    end
  end

  defp tag({:error, reason}, phase, context, :validation) do
    tagged_phase = TargetContext.phase(context, phase)
    details = TargetContext.validation_details(context, tagged_phase, reason)
    {:error, Error.validation_error(to_error_message(reason), details)}
  end

  defp tag({:error, reason}, _phase, _context, :target), do: {:error, reason}

  defp replace_details(error, details) do
    if Map.has_key?(error, :details) do
      %{error | details: details}
    else
      Map.put(error, :details, details)
    end
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
