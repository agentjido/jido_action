defmodule Jido.Flow.ActionRegistry do
  @moduledoc false

  alias Jido.Action.Error

  @spec normalize(map() | keyword()) :: {:ok, %{String.t() => module()}} | {:error, Exception.t()}
  def normalize(actions) when is_list(actions) do
    if Keyword.keyword?(actions), do: reduce_pairs(actions, actions), else: invalid(actions)
  end

  def normalize(%{} = actions), do: reduce_pairs(actions, actions)
  def normalize(actions), do: invalid(actions)

  @spec lookup(%{String.t() => module()}, term()) :: {:ok, module()} | {:error, Exception.t()}
  def lookup(actions, identifier) when is_binary(identifier) do
    case Map.fetch(actions, identifier) do
      {:ok, action} ->
        {:ok, action}

      :error ->
        error("unknown flow action identifier: #{inspect(identifier)}", %{identifier: identifier})
    end
  end

  def lookup(_actions, identifier) do
    error("stored flow node action must be a registered identifier", %{action: identifier})
  end

  defp reduce_pairs(actions, original) do
    Enum.reduce_while(actions, {:ok, %{}}, fn
      {identifier, action}, {:ok, acc}
      when (is_binary(identifier) or (is_atom(identifier) and not is_nil(identifier))) and
             is_atom(action) and not is_nil(action) ->
        identifier = if is_atom(identifier), do: Atom.to_string(identifier), else: identifier

        if Map.has_key?(acc, identifier) do
          {:halt,
           error("duplicate flow action registry identifier: #{inspect(identifier)}", %{
             identifier: identifier
           })}
        else
          {:cont, {:ok, Map.put(acc, identifier, action)}}
        end

      {_identifier, _action}, {:ok, _acc} ->
        {:halt, invalid(original)}
    end)
  end

  defp invalid(actions),
    do:
      error("flow action registry must map string or atom identifiers to modules", %{
        actions: actions
      })

  defp error(message, details), do: {:error, Error.validation_error(message, details)}
end
