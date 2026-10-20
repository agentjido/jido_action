defmodule Jido.Flow.Codec.Registry do
  @moduledoc false

  alias Jido.Authoring.Registry
  alias Jido.Authoring.Registry.Error, as: RegistryError
  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.Definition
  alias Jido.Flow.Error
  alias Jido.Flow.Ref

  @generated_kinds [:action, :flow, :schema, :atom]
  @generated_namespaces %{
    action: "actions",
    flow: "flows",
    schema: "schemas",
    atom: "atoms"
  }
  @tree_options [
    max_depth: 1_048_576,
    max_nodes: 1_048_576_000,
    max_binary_bytes: 1_048_576_000,
    max_integer_bits: 1_048_576
  ]

  @doc false
  @spec generated(Flow.t()) :: {:ok, Registry.t()} | {:error, Exception.t()}
  def generated(%Flow{} = flow) do
    flow
    |> entries()
    |> Registry.new()
    |> flow_result()
  end

  @doc false
  @spec resolve(Registry.t(), Registry.stable_id(), Registry.kind()) ::
          {:ok, term()} | {:error, Exception.t()}
  def resolve(%Registry{} = registry, identifier, kind) do
    registry
    |> Registry.resolve(identifier, kind)
    |> flow_result()
  end

  @doc false
  @spec identifier(Registry.t(), Registry.kind(), term()) ::
          {:ok, Registry.stable_id()} | {:error, Exception.t()}
  def identifier(%Registry{} = registry, kind, value) do
    registry
    |> Registry.identifier(kind, value)
    |> flow_result()
  end

  defp entries(%Flow{} = flow) do
    values =
      empty_generated_values()
      |> add_generated_value(:schema, flow.schema)
      |> add_generated_value(:schema, flow.output_schema)
      |> collect_components(flow.components)
      |> collect_expression(flow.output)

    @generated_kinds
    |> Enum.flat_map(fn kind ->
      values
      |> Map.fetch!(kind)
      |> MapSet.to_list()
      |> Enum.sort_by(&generated_sort_key(kind, &1))
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} ->
        identifier = "#{Map.fetch!(@generated_namespaces, kind)}/generated-#{index}"
        {identifier, {kind, value}}
      end)
    end)
    |> Map.new()
  end

  defp empty_generated_values,
    do: Map.new(@generated_kinds, &{&1, MapSet.new()})

  defp add_generated_value(values, kind, value),
    do: Map.update!(values, kind, &MapSet.put(&1, value))

  defp generated_sort_key(kind, value) when kind in [:action, :flow, :atom],
    do: Atom.to_string(value)

  defp generated_sort_key(:schema, value), do: :erlang.term_to_binary(value)

  defp collect_components(values, components) do
    Enum.reduce(components, values, fn {_name, node}, values ->
      collect_component(values, node)
    end)
  end

  defp collect_component(values, node) do
    values =
      Enum.reduce(Definition.calls(node), values, fn {_role, instruction, _params}, values ->
        add_generated_value(values, instruction.kind, instruction.target)
      end)

    values =
      Enum.reduce(Definition.values(node), values, fn expression, values ->
        collect_expression(values, expression)
      end)

    values = collect_expression(values, node.meta)

    case node do
      %{kind: :iterate, state: %{schema: schema}} -> add_generated_value(values, :schema, schema)
      _node -> values
    end
  end

  defp collect_expression(values, expression) do
    reducer = fn
      %Ref{path: path}, _value_path, values ->
        {:cont, collect_expression(values, path)}

      value, _path, values when is_map(value) and not is_struct(value) ->
        {:cont, Enum.reduce(Map.keys(value), values, &collect_atom/2)}

      value, _path, values
      when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        {:cont, collect_atom(value, values)}

      _value, _path, values ->
        {:cont, values}
    end

    {:ok, values} = Expr.reduce(expression, values, reducer, @tree_options)
    values
  end

  defp collect_atom(value, values)
       when is_atom(value) and not is_nil(value) and not is_boolean(value),
       do: add_generated_value(values, :atom, value)

  defp collect_atom(_value, values), do: values

  defp flow_result({:error, %RegistryError{} = exception}) do
    message = String.replace(exception.message, "authoring Registry", "flow registry")
    {:error, Error.validation_error(message, exception.details)}
  end

  defp flow_result(result), do: result
end
