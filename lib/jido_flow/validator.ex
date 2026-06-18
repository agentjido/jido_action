defmodule Jido.Flow.Validator do
  @moduledoc false

  alias Jido.Action.Util
  alias Jido.Flow.Step
  alias Runic.Workflow

  @doc false
  @spec validate_dependency(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_dependency(value, _opts \\ [])
  def validate_dependency(nil, _opts), do: :ok

  def validate_dependency(values, opts) when is_list(values) do
    cond do
      values == [] ->
        {:error, "cannot be an empty list"}

      Enum.all?(values, &(Util.validate_component_name(&1, opts) == :ok)) ->
        :ok

      true ->
        {:error, "must contain only atom or string names"}
    end
  end

  def validate_dependency(value, opts), do: Util.validate_component_name(value, opts)

  @doc false
  @spec validate_entry(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_entry(%{type: :step, action: action}, _opts), do: validate_action(action)

  def validate_entry(%{type: :map, mapper: mapper}, _opts), do: validate_callable(mapper, 1)

  def validate_entry(%{type: :reduce, reducer: reducer}, _opts), do: validate_callable(reducer, 2)

  def validate_entry(%{type: :accumulate, reducer: reducer}, _opts),
    do: validate_callable(reducer, 2)

  def validate_entry(%{type: :workflow, workflow: %Workflow{}}, _opts), do: :ok

  def validate_entry(%{type: :workflow}, _opts),
    do: {:error, "workflow entries must contain a Runic.Workflow"}

  defp validate_action(action) do
    case Step.validate_action(action) do
      :ok -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp validate_callable(value, arity) when is_function(value, arity),
    do: {:error, "must be an external function/#{arity} capture or MFA tuple"}

  defp validate_callable(nil, arity),
    do: {:error, "must be an external function/#{arity} capture or MFA tuple"}

  defp validate_callable({module, function}, arity)
       when is_atom(module) and is_atom(function) do
    validate_exported_callable(module, function, arity)
  end

  defp validate_callable({:mfa, module, function}, arity)
       when is_atom(module) and is_atom(function) do
    validate_exported_callable(module, function, arity)
  end

  defp validate_callable(_value, arity),
    do: {:error, "must be an external function/#{arity} capture or MFA tuple"}

  defp validate_exported_callable(module, function, arity) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      :ok
    else
      {:error, "must reference an existing function/#{arity}"}
    end
  end
end
