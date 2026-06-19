defmodule Jido.Flow.Validator do
  @moduledoc false

  alias Jido.Instruction
  alias Runic.Workflow

  @doc false
  @spec validate_component_name(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_component_name(value, _opts \\ [])
  def validate_component_name(value, _opts) when is_atom(value) and not is_nil(value), do: :ok
  def validate_component_name(value, _opts) when is_atom(value), do: {:error, "cannot be nil"}
  def validate_component_name(_value, _opts), do: {:error, "must be an atom"}

  @doc false
  @spec validate_optional_component_name(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_optional_component_name(value, _opts \\ [])
  def validate_optional_component_name(nil, _opts), do: :ok
  def validate_optional_component_name(value, opts), do: validate_component_name(value, opts)

  @doc false
  @spec validate_dependency(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_dependency(nil, _opts), do: :ok

  def validate_dependency(values, opts) when is_list(values) do
    cond do
      values == [] ->
        {:error, "cannot be an empty list"}

      Enum.all?(values, &(validate_component_name(&1, opts) == :ok)) ->
        :ok

      true ->
        {:error, "must contain only atom names"}
    end
  end

  def validate_dependency(value, opts), do: validate_component_name(value, opts)

  @doc false
  @spec validate_entry(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_entry(%{type: :step, name: name, action: action}, opts) do
    with :ok <- validate_component_name(name, opts) do
      Instruction.validate_action_module(action)
    end
  end

  def validate_entry(%{type: :project} = entry, opts) do
    with :ok <- validate_component_name(Map.get(entry, :name), opts),
         :ok <- validate_project_from(Map.get(entry, :from), opts),
         :ok <- validate_project_path(Map.get(entry, :path), opts),
         :ok <- validate_project_mode(Map.get(entry, :mode)) do
      :ok
    end
  end

  def validate_entry(%{type: :map, name: name, mapper: mapper}, opts) do
    with :ok <- validate_component_name(name, opts), do: validate_callable(mapper, 1)
  end

  def validate_entry(%{type: :reduce, name: name, reducer: reducer}, opts) do
    with :ok <- validate_component_name(name, opts), do: validate_callable(reducer, 2)
  end

  def validate_entry(%{type: :accumulate, name: name, reducer: reducer}, opts) do
    with :ok <- validate_component_name(name, opts), do: validate_callable(reducer, 2)
  end

  def validate_entry(%{type: :workflow, name: name, workflow: %Workflow{}}, opts),
    do: validate_component_name(name, opts)

  def validate_entry(%{type: :workflow}, _opts),
    do: {:error, "workflow entries must contain a Runic.Workflow"}

  def validate_entry(%{type: :chain, flow: flow}, _opts) when is_list(flow), do: :ok

  def validate_entry(%{type: :chain}, _opts), do: {:error, "chain entries must contain flow"}

  def validate_entry(%{type: :fanout, from: from, flow: flow}, opts) when is_list(flow),
    do: validate_project_from(from, opts)

  def validate_entry(%{type: :fanout}, _opts),
    do: {:error, "fanout entries must contain from and flow"}

  def validate_entry(%{type: :collect, name: name, arguments: arguments}, opts)
      when is_map(arguments),
      do: validate_component_name(name, opts)

  def validate_entry(%{type: :collect}, _opts),
    do: {:error, "collect entries must contain arguments"}

  def validate_entry(%{type: type, name: name}, opts) when type in [:debug, :trace],
    do: validate_component_name(name, opts)

  def validate_entry(%{type: :switch, name: name, matches: matches}, opts)
      when is_list(matches),
      do: validate_component_name(name, opts)

  def validate_entry(%{type: :switch}, _opts),
    do: {:error, "switch entries must contain matches"}

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

  defp validate_project_from(value, opts) do
    case validate_component_name(value, opts) do
      :ok -> :ok
      {:error, _reason} -> {:error, "from must be an atom"}
    end
  end

  defp validate_project_path(path, _opts) when is_list(path) do
    cond do
      path == [] ->
        {:error, "path must be a non-empty list"}

      Enum.all?(path, &project_path_part?/1) ->
        :ok

      true ->
        {:error, "path must contain only atoms or non-negative integers"}
    end
  end

  defp validate_project_path(_path, _opts), do: {:error, "path must be a non-empty list"}

  defp project_path_part?(value) when is_atom(value) and not is_nil(value), do: true
  defp project_path_part?(value) when is_integer(value) and value >= 0, do: true
  defp project_path_part?(_value), do: false

  defp validate_project_mode(:value), do: :ok
  defp validate_project_mode(_mode), do: {:error, "mode must be :value"}
end
