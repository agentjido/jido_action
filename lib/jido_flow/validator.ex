defmodule Jido.Flow.Validator do
  @moduledoc false

  alias Jido.Flow.Ref
  alias Jido.Flow.Switch.Branch
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

  def validate_entry(%{type: :map, name: name, mapper: mapper} = entry, opts) do
    with :ok <- validate_component_name(name, opts),
         :ok <- validate_callable(mapper, 1),
         :ok <- validate_source_and_over(entry, opts) do
      :ok
    end
  end

  def validate_entry(%{type: :reduce, name: name, reducer: reducer} = entry, opts) do
    with :ok <- validate_component_name(name, opts),
         :ok <- validate_callable(reducer, 2),
         :ok <- validate_source_and_over(entry, opts) do
      :ok
    end
  end

  def validate_entry(%{type: :accumulate, name: name, reducer: reducer} = entry, opts) do
    with :ok <- validate_component_name(name, opts),
         :ok <- validate_callable(reducer, 2),
         :ok <- validate_source_and_over(entry, opts) do
      :ok
    end
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
      when is_map(arguments) do
    with :ok <- validate_component_name(name, opts) do
      validate_argument_refs(arguments, opts)
    end
  end

  def validate_entry(%{type: :collect}, _opts),
    do: {:error, "collect entries must contain arguments"}

  def validate_entry(%{type: type, name: name} = entry, opts) when type in [:debug, :trace] do
    with :ok <- validate_component_name(name, opts) do
      validate_optional_value_ref(Map.get(entry, :source), opts)
    end
  end

  def validate_entry(%{type: :switch, name: name, matches: matches} = entry, opts)
      when is_list(matches) do
    with :ok <- validate_component_name(name, opts),
         :ok <- validate_value_ref(Map.get(entry, :on), opts),
         :ok <- validate_switch_matches(matches, opts),
         :ok <- validate_switch_return(Map.get(entry, :return?)) do
      validate_switch_default(Map.get(entry, :default), opts)
    end
  end

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

  defp validate_project_path(path, _opts), do: Ref.validate_path(path)

  defp validate_project_mode(:value), do: :ok
  defp validate_project_mode(_mode), do: {:error, "mode must be :value"}

  defp validate_source_and_over(entry, opts) do
    source = Map.get(entry, :source)
    over = Map.get(entry, :over)

    cond do
      not is_nil(source) and not is_nil(over) ->
        {:error, "must contain only one of source or over"}

      not is_nil(source) ->
        validate_value_ref(source, opts)

      true ->
        validate_over(over, opts)
    end
  end

  defp validate_optional_value_ref(nil, _opts), do: :ok
  defp validate_optional_value_ref(value, opts), do: validate_value_ref(value, opts)

  defp validate_argument_refs(arguments, opts) do
    Enum.reduce_while(arguments, :ok, fn
      {name, value}, :ok when is_atom(name) and not is_nil(name) ->
        case validate_value_ref(value, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "argument #{inspect(name)} #{reason}"}}
        end

      {_name, _value}, :ok ->
        {:halt, {:error, "argument names must be atoms"}}
    end)
  end

  defp validate_value_ref(value, _opts), do: Ref.validate(value)

  defp validate_over(over, _opts) do
    case Ref.normalize_over(over) do
      {:ok, _normalized} ->
        :ok

      {:error, "over expects an atom or {:name, from: :source, path: [...]}"} ->
        {:error, "over must be an atom or {:name, from: :source, path: [...]}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_switch_matches([], _opts), do: {:error, "switch matches cannot be empty"}

  defp validate_switch_matches(matches, opts) do
    Enum.reduce_while(matches, :ok, fn match, :ok ->
      case validate_switch_match(match, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_switch_match(%{name: name, predicate: predicate} = match, opts) do
    with :ok <- validate_component_name(name, opts),
         :ok <- validate_callable(predicate, 1) do
      Branch.validate_match(match)
    end
  end

  defp validate_switch_match(_match, _opts), do: {:error, "switch matches must be maps"}

  defp validate_switch_default(default, _opts), do: Branch.validate_default(default)

  defp validate_switch_return(value) when is_boolean(value), do: :ok
  defp validate_switch_return(_value), do: {:error, "switch return must be a boolean"}
end
