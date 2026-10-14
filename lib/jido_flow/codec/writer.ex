defmodule Jido.Flow.Codec.Writer do
  @moduledoc false

  alias Jido.Flow.{Component, Error, Graph, Registry}
  alias Jido.Flow.Codec.{Limits, Value}

  @doc false
  @spec encode(Jido.Flow.t(), Registry.t()) :: {:ok, map()} | {:error, Exception.t()}
  def encode(flow, registry) do
    with {:ok, schema} <- Registry.identifier(registry, :schema, flow.schema),
         {:ok, output_schema} <- Registry.identifier(registry, :schema, flow.output_schema),
         {:ok, components} <-
           sequence(Graph.canonical_components(flow.components), fn {name, node} ->
             record = Map.put(node, :name, name)

             with {:ok, values} <-
                    record(
                      record,
                      Component.common_fields() ++ Component.fields(node.kind),
                      registry
                    ) do
               {:ok, Map.put(values, "kind", Atom.to_string(node.kind))}
             end
           end),
         {:ok, output} <- Value.encode_expression(flow.output, registry, 0) do
      document = %{
        "type" => "jido.flow",
        "version" => 1,
        "name" => flow.name,
        "description" => flow.description,
        "schema" => schema,
        "output_schema" => output_schema,
        "components" => components,
        "output" => output
      }

      with :ok <- Limits.check(document), do: {:ok, document}
    end
  end

  defp record(values, fields, registry) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {name, type}, {:ok, result} ->
      case field(type, Map.fetch!(values, name), registry) do
        {:ok, value} -> {:cont, {:ok, Map.put(result, Atom.to_string(name), value)}}
        {:error, error} -> {:halt, {:error, Error.prefix_path(error, [name])}}
      end
    end)
  end

  defp field({:value, _}, value, registry), do: Value.encode_expression(value, registry, 0)
  defp field({:condition, _}, value, registry), do: Value.encode_expression(value, registry, 0)
  defp field(:meta, value, registry), do: Value.encode_data(value, registry, 0)
  defp field(:schema, value, registry), do: Registry.identifier(registry, :schema, value)

  defp field({:call, _, _}, call, registry) do
    with {:ok, target} <- target(call, registry),
         {:ok, params} <- Value.encode_expression(call.params, registry, 0) do
      {:ok, Map.put(target, "params", params)}
    end
  end

  defp field({:target, _}, target, registry), do: target(target, registry)

  defp field(:options, options, registry),
    do: sequence(options, &record(&1, Component.option_fields(), registry))

  defp field(:state, state, registry), do: record(state, Component.state_fields(), registry)
  defp field(:on_error, value, _registry), do: {:ok, Atom.to_string(value)}
  defp field(_type, value, _registry), do: {:ok, value}

  defp target(target, registry) do
    with {:ok, id} <- Registry.identifier(registry, target.kind, target.target) do
      {:ok, %{"kind" => Atom.to_string(target.kind), "target" => id}}
    end
  end

  defp sequence(values, encoder) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, result} ->
      case encoder.(value) do
        {:ok, value} -> {:cont, {:ok, [value | result]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end
end
