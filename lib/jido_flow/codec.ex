defmodule Jido.Flow.Codec do
  @moduledoc """
  Encodes and decodes the stored Flow document.

  The document contains JSON-compatible data. A trusted `Jido.Flow.Registry`
  resolves all Action, Flow, schema, and user-data atom identifiers.
  """

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Data
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Registry
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow

  @type document :: %{required(String.t()) => term()}

  @version 1
  @maximum_depth 100
  @maximum_collection_size 10_000

  @component_kinds %{
    "step" => :step,
    "subflow" => :subflow,
    "choice" => :choice,
    "map" => :map,
    "reduce" => :reduce,
    "iterate" => :iterate
  }

  @sources %{
    "input" => :input,
    "context" => :context,
    "result" => :result,
    "item" => :item,
    "item_index" => :item_index,
    "item_id" => :item_id,
    "accumulator" => :accumulator,
    "state" => :state,
    "iteration_index" => :iteration_index,
    "body_result" => :body_result
  }

  @operators %{
    "eq" => :eq,
    "neq" => :neq,
    "lt" => :lt,
    "lte" => :lte,
    "gt" => :gt,
    "gte" => :gte,
    "in" => :in,
    "all" => :all,
    "any" => :any,
    "not" => :not
  }

  @on_error %{"fail_fast" => :fail_fast, "collect_errors" => :collect_errors}

  @doc "Encodes one canonical Flow as a JSON-compatible document."
  @spec encode(Flow.t(), Registry.t()) :: {:ok, document()} | {:error, Exception.t()}
  def encode(%Flow{} = flow, %Registry{} = registry) do
    with {:ok, flow} <- Flow.validate(flow),
         {:ok, schema} <- Registry.identifier(registry, :schema, flow.schema),
         {:ok, output_schema} <- Registry.identifier(registry, :schema, flow.output_schema),
         {:ok, components} <- encode_components(flow.components, registry),
         {:ok, output} <- encode_expression(flow.output, registry, 0) do
      {:ok,
       %{
         "type" => "jido.flow",
         "version" => @version,
         "name" => flow.name,
         "description" => flow.description,
         "schema" => schema,
         "output_schema" => output_schema,
         "components" => components,
         "output" => output
       }}
    end
  end

  def encode(value, %Registry{}) do
    {:error, Error.validation_error("expected a Jido.Flow artifact", %{value: value})}
  end

  def encode(%Flow{}, registry) do
    {:error,
     Error.validation_error("flow codec registry must be a Jido.Flow.Registry", %{value: registry})}
  end

  @doc "Decodes one stored Flow document through a trusted Registry."
  @spec decode(document(), Registry.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def decode(document, %Registry{} = registry)
      when is_map(document) and not is_struct(document) do
    with :ok <- exact_keys(document, root_keys(), []),
         :ok <- exact_value(document, "type", "jido.flow", []),
         :ok <- exact_value(document, "version", @version, []),
         {:ok, name} <- string_field(document, "name", []),
         {:ok, description} <- optional_string_field(document, "description", []),
         {:ok, schema} <- resolve_field(document, "schema", :schema, registry, []),
         {:ok, output_schema} <- resolve_field(document, "output_schema", :schema, registry, []),
         {:ok, components} <- decode_components(Map.fetch!(document, "components"), registry),
         {:ok, output} <-
           decode_expression(Map.fetch!(document, "output"), registry, 0, ["output"]) do
      Flow.new(%{
        name: name,
        description: description,
        schema: schema,
        output_schema: output_schema,
        components: components,
        output: output
      })
    end
  end

  def decode(document, %Registry{}) do
    {:error, Error.validation_error("stored Flow document must be a map", %{value: document})}
  end

  def decode(_document, registry) do
    {:error,
     Error.validation_error("flow codec registry must be a Jido.Flow.Registry", %{value: registry})}
  end

  defp root_keys do
    [
      "type",
      "version",
      "name",
      "description",
      "schema",
      "output_schema",
      "components",
      "output"
    ]
  end

  defp encode_components(components, registry) do
    components
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {component, index}, {:ok, encoded} ->
      case encode_component(component, registry) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, error} -> {:halt, {:error, prefix(error, ["components", index])}}
      end
    end)
    |> reverse_ok()
  end

  defp encode_component(%Step{} = step, registry) do
    with {:ok, action} <- Registry.identifier(registry, :action, step.action),
         {:ok, params} <- encode_expression(step.params, registry, 0),
         {:ok, meta} <- encode_data(step.meta, registry, 0) do
      {:ok,
       common_component("step", step, params, meta)
       |> Map.put("action", action)}
    end
  end

  defp encode_component(%Subflow{} = subflow, registry) do
    with {:ok, flow} <- Registry.identifier(registry, :flow, subflow.flow),
         {:ok, params} <- encode_expression(subflow.params, registry, 0),
         {:ok, meta} <- encode_data(subflow.meta, registry, 0) do
      {:ok,
       common_component("subflow", subflow, params, meta)
       |> Map.delete("params")
       |> Map.put("flow", flow)
       |> Map.put("params", params)}
    end
  end

  defp encode_component(%Choice{} = choice, registry) do
    with {:ok, options} <- encode_choice_options(choice.options, registry),
         {:ok, fallback} <- encode_fallback(choice.fallback, registry),
         {:ok, meta} <- encode_data(choice.meta, registry, 0) do
      {:ok,
       %{
         "kind" => "choice",
         "name" => choice.name,
         "options" => options,
         "fallback" => fallback,
         "after" => choice.after,
         "meta" => meta
       }}
    end
  end

  defp encode_component(%FlowMap{} = map, registry) do
    with {:ok, collection} <- encode_expression(map.collection, registry, 0),
         {:ok, action} <- Registry.identifier(registry, :action, map.action),
         {:ok, params} <- encode_expression(map.params, registry, 0),
         {:ok, meta} <- encode_data(map.meta, registry, 0) do
      {:ok,
       %{
         "kind" => "map",
         "name" => map.name,
         "collection" => collection,
         "action" => action,
         "params" => params,
         "on_error" => Atom.to_string(map.on_error),
         "after" => map.after,
         "meta" => meta
       }}
    end
  end

  defp encode_component(%Reduce{} = reduce, registry) do
    with {:ok, collection} <- encode_expression(reduce.collection, registry, 0),
         {:ok, initial} <- encode_expression(reduce.initial, registry, 0),
         {:ok, action} <- Registry.identifier(registry, :action, reduce.action),
         {:ok, params} <- encode_expression(reduce.params, registry, 0),
         {:ok, meta} <- encode_data(reduce.meta, registry, 0) do
      {:ok,
       %{
         "kind" => "reduce",
         "name" => reduce.name,
         "collection" => collection,
         "initial" => initial,
         "action" => action,
         "params" => params,
         "after" => reduce.after,
         "meta" => meta
       }}
    end
  end

  defp encode_component(%Iterate{} = iterate, registry) do
    with {:ok, action} <- Registry.identifier(registry, :action, iterate.action),
         {:ok, params} <- encode_expression(iterate.params, registry, 0),
         {:ok, schema} <- Registry.identifier(registry, :schema, iterate.state.schema),
         {:ok, initial} <- encode_expression(iterate.state.initial, registry, 0),
         {:ok, update} <- encode_expression(iterate.state.update, registry, 0),
         {:ok, completion} <- encode_condition(iterate.completion, registry, 0),
         {:ok, meta} <- encode_data(iterate.meta, registry, 0) do
      {:ok,
       %{
         "kind" => "iterate",
         "name" => iterate.name,
         "action" => action,
         "params" => params,
         "state" => %{
           "schema" => schema,
           "initial" => initial,
           "update" => update
         },
         "completion" => completion,
         "max_iterations" => iterate.max_iterations,
         "after" => iterate.after,
         "meta" => meta
       }}
    end
  end

  defp common_component(kind, component, params, meta) do
    %{
      "kind" => kind,
      "name" => component.name,
      "params" => params,
      "after" => component.after,
      "meta" => meta
    }
  end

  defp encode_choice_options(options, registry) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, encoded} ->
      result =
        with {:ok, condition} <- encode_condition(option.condition, registry, 0),
             {:ok, action} <- Registry.identifier(registry, :action, option.action),
             {:ok, params} <- encode_expression(option.params, registry, 0) do
          {:ok,
           %{
             "name" => option.name,
             "condition" => condition,
             "action" => action,
             "params" => params
           }}
        end

      case result do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, error} -> {:halt, {:error, prefix(error, ["options", index])}}
      end
    end)
    |> reverse_ok()
  end

  defp encode_fallback(fallback, registry) do
    with {:ok, action} <- Registry.identifier(registry, :action, fallback.action),
         {:ok, params} <- encode_expression(fallback.params, registry, 0) do
      {:ok, %{"action" => action, "params" => params}}
    end
  end

  defp encode_expression(%Ref{} = ref, registry, depth) do
    with :ok <- depth(depth),
         {:ok, path} <- encode_list(ref.path, registry, depth + 1, &encode_data/3) do
      {:ok,
       %{
         "$ref" => %{
           "source" => Atom.to_string(ref.source),
           "component" => ref.component,
           "path" => path
         }
       }}
    end
  end

  defp encode_expression(value, registry, depth) when is_list(value) do
    encode_list(value, registry, depth, &encode_expression/3)
  end

  defp encode_expression(value, registry, depth) when is_map(value) and not is_struct(value) do
    encode_map(value, registry, depth, &encode_expression/3)
  end

  defp encode_expression(value, registry, depth), do: encode_data(value, registry, depth)

  defp encode_condition(%Condition{} = condition, registry, depth) do
    with :ok <- depth(depth),
         {:ok, operands} <- encode_condition_operands(condition.operands, registry, depth + 1) do
      {:ok,
       %{
         "$condition" => %{
           "operator" => Atom.to_string(condition.operator),
           "operands" => operands
         }
       }}
    end
  end

  defp encode_condition_operands(operands, registry, depth) do
    encode_list(operands, registry, depth, fn
      %Condition{} = condition, registry, depth -> encode_condition(condition, registry, depth)
      expression, registry, depth -> encode_expression(expression, registry, depth)
    end)
  end

  defp encode_data(value, _registry, depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    with :ok <- depth(depth), do: {:ok, value}
  end

  defp encode_data(value, registry, depth) when is_atom(value) do
    with :ok <- depth(depth),
         {:ok, identifier} <- Registry.identifier(registry, :atom, value) do
      {:ok, %{"$type" => "atom", "id" => identifier}}
    end
  end

  defp encode_data(value, registry, depth) when is_list(value) do
    encode_list(value, registry, depth, &encode_data/3)
  end

  defp encode_data(value, registry, depth) when is_map(value) and not is_struct(value) do
    encode_map(value, registry, depth, &encode_data/3)
  end

  defp encode_data(value, _registry, _depth) do
    {:error, Error.validation_error("flow data contains an unsupported value", %{value: value})}
  end

  defp encode_list(list, registry, depth, encoder) do
    with :ok <- depth(depth),
         :ok <- collection_size(list) do
      list
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, encoded} ->
        case encoder.(value, registry, depth + 1) do
          {:ok, value} -> {:cont, {:ok, [value | encoded]}}
          {:error, error} -> {:halt, {:error, prefix(error, [index])}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp encode_map(map, registry, depth, value_encoder) do
    with :ok <- depth(depth),
         :ok <- collection_size(Map.to_list(map)),
         {:ok, entries} <- encode_entries(map, registry, depth, value_encoder) do
      entries = Enum.sort_by(entries, fn %{"key" => key} -> :erlang.term_to_binary(key) end)
      {:ok, %{"$type" => "map", "entries" => entries}}
    end
  end

  defp encode_entries(map, registry, depth, value_encoder) do
    Enum.reduce_while(map, {:ok, []}, fn {key, value}, {:ok, encoded} ->
      result =
        with :ok <- Data.validate_key(key),
             {:ok, key} <- encode_data(key, registry, depth + 1),
             {:ok, value} <- value_encoder.(value, registry, depth + 1) do
          {:ok, %{"key" => key, "value" => value}}
        end

      case result do
        {:ok, entry} -> {:cont, {:ok, [entry | encoded]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp decode_components(values, registry) when is_list(values) do
    with :ok <- collection_size(values),
         false <- values == [] do
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, decoded} ->
        case decode_component(value, registry, ["components", index]) do
          {:ok, component} -> {:cont, {:ok, [component | decoded]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> reverse_ok()
    else
      true ->
        {:error,
         Error.validation_error("stored Flow must contain at least one component", %{
           path: ["components"]
         })}

      {:error, error} ->
        {:error, prefix(error, ["components"])}
    end
  end

  defp decode_components(_values, _registry) do
    {:error,
     Error.validation_error("stored Flow components must be a list", %{path: ["components"]})}
  end

  defp decode_component(%{} = record, registry, path) when not is_struct(record) do
    with {:ok, kind_name} <- string_field(record, "kind", path),
         {:ok, kind} <-
           closed_value(@component_kinds, kind_name, "component kind", path ++ ["kind"]) do
      decode_component_kind(kind, record, registry, path)
    end
  end

  defp decode_component(_record, _registry, path) do
    {:error, Error.validation_error("stored Flow component must be a map", %{path: path})}
  end

  defp decode_component_kind(:step, record, registry, path) do
    with :ok <- exact_keys(record, ["kind", "name", "action", "params", "after", "meta"], path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, action} <- resolve_field(record, "action", :action, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]) do
      Step.new(Map.merge(common, %{action: action, params: params}))
    end
  end

  defp decode_component_kind(:subflow, record, registry, path) do
    with :ok <- exact_keys(record, ["kind", "name", "flow", "params", "after", "meta"], path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, flow} <- resolve_field(record, "flow", :flow, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]) do
      Subflow.new(Map.merge(common, %{flow: flow, params: params}))
    end
  end

  defp decode_component_kind(:choice, record, registry, path) do
    with :ok <- exact_keys(record, ["kind", "name", "options", "fallback", "after", "meta"], path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, options} <-
           decode_choice_options(Map.fetch!(record, "options"), registry, path ++ ["options"]),
         {:ok, fallback} <-
           decode_fallback(Map.fetch!(record, "fallback"), registry, path ++ ["fallback"]) do
      Choice.new(Map.merge(common, %{options: options, fallback: fallback}))
    end
  end

  defp decode_component_kind(:map, record, registry, path) do
    keys = ["kind", "name", "collection", "action", "params", "on_error", "after", "meta"]

    with :ok <- exact_keys(record, keys, path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, collection} <-
           decode_expression(
             Map.fetch!(record, "collection"),
             registry,
             0,
             path ++ ["collection"]
           ),
         {:ok, action} <- resolve_field(record, "action", :action, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]),
         {:ok, on_error_name} <- string_field(record, "on_error", path),
         {:ok, on_error} <-
           closed_value(@on_error, on_error_name, "Map on_error", path ++ ["on_error"]) do
      FlowMap.new(
        Map.merge(common, %{
          collection: collection,
          action: action,
          params: params,
          on_error: on_error
        })
      )
    end
  end

  defp decode_component_kind(:reduce, record, registry, path) do
    keys = ["kind", "name", "collection", "initial", "action", "params", "after", "meta"]

    with :ok <- exact_keys(record, keys, path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, collection} <-
           decode_expression(
             Map.fetch!(record, "collection"),
             registry,
             0,
             path ++ ["collection"]
           ),
         {:ok, initial} <-
           decode_expression(Map.fetch!(record, "initial"), registry, 0, path ++ ["initial"]),
         {:ok, action} <- resolve_field(record, "action", :action, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]) do
      Reduce.new(
        Map.merge(common, %{
          collection: collection,
          initial: initial,
          action: action,
          params: params
        })
      )
    end
  end

  defp decode_component_kind(:iterate, record, registry, path) do
    keys = [
      "kind",
      "name",
      "action",
      "params",
      "state",
      "completion",
      "max_iterations",
      "after",
      "meta"
    ]

    with :ok <- exact_keys(record, keys, path),
         {:ok, common} <- decode_common(record, registry, path),
         {:ok, action} <- resolve_field(record, "action", :action, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]),
         {:ok, state} <-
           decode_iterate_state(Map.fetch!(record, "state"), registry, path ++ ["state"]),
         {:ok, completion} <-
           decode_condition(Map.fetch!(record, "completion"), registry, 0, path ++ ["completion"]),
         {:ok, max_iterations} <- positive_integer_field(record, "max_iterations", path) do
      Iterate.new(
        Map.merge(common, %{
          action: action,
          params: params,
          state: state,
          completion: completion,
          max_iterations: max_iterations
        })
      )
    end
  end

  defp decode_common(record, registry, path) do
    with {:ok, name} <- string_field(record, "name", path),
         {:ok, after_names} <- string_list_field(record, "after", path),
         {:ok, meta} <- decode_data(Map.fetch!(record, "meta"), registry, 0, path ++ ["meta"]),
         :ok <- Data.validate_object(meta) do
      {:ok, %{name: name, after: after_names, meta: meta}}
    end
  end

  defp decode_choice_options(values, registry, path) when is_list(values) do
    with :ok <- collection_size(values),
         false <- values == [] do
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, decoded} ->
        option_path = path ++ [index]

        result =
          with :ok <- plain_map(record, "choice option", option_path),
               :ok <- exact_keys(record, ["name", "condition", "action", "params"], option_path),
               {:ok, name} <- string_field(record, "name", option_path),
               {:ok, condition} <-
                 decode_condition(
                   Map.fetch!(record, "condition"),
                   registry,
                   0,
                   option_path ++ ["condition"]
                 ),
               {:ok, action} <- resolve_field(record, "action", :action, registry, option_path),
               {:ok, params} <-
                 decode_expression(
                   Map.fetch!(record, "params"),
                   registry,
                   0,
                   option_path ++ ["params"]
                 ) do
            {:ok, %{name: name, condition: condition, action: action, params: params}}
          end

        case result do
          {:ok, option} -> {:cont, {:ok, [option | decoded]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> reverse_ok()
    else
      true -> {:error, Error.validation_error("choice options must not be empty", %{path: path})}
      {:error, error} -> {:error, prefix(error, path)}
    end
  end

  defp decode_choice_options(_values, _registry, path) do
    {:error, Error.validation_error("choice options must be a list", %{path: path})}
  end

  defp decode_fallback(record, registry, path) do
    with :ok <- plain_map(record, "choice fallback", path),
         :ok <- exact_keys(record, ["action", "params"], path),
         {:ok, action} <- resolve_field(record, "action", :action, registry, path),
         {:ok, params} <-
           decode_expression(Map.fetch!(record, "params"), registry, 0, path ++ ["params"]) do
      {:ok, %{action: action, params: params}}
    end
  end

  defp decode_iterate_state(record, registry, path) do
    with :ok <- plain_map(record, "iterate state", path),
         :ok <- exact_keys(record, ["schema", "initial", "update"], path),
         {:ok, schema} <- resolve_field(record, "schema", :schema, registry, path),
         {:ok, initial} <-
           decode_expression(Map.fetch!(record, "initial"), registry, 0, path ++ ["initial"]),
         {:ok, update} <-
           decode_expression(Map.fetch!(record, "update"), registry, 0, path ++ ["update"]) do
      {:ok, %{schema: schema, initial: initial, update: update}}
    end
  end

  defp decode_expression(value, registry, depth, path) when is_list(value) do
    decode_list(value, registry, depth, path, &decode_expression/4)
  end

  defp decode_expression(%{"$ref" => record} = value, registry, depth, path) do
    with :ok <- exact_keys(value, ["$ref"], path),
         :ok <- depth(depth),
         :ok <- plain_map(record, "Flow reference", path ++ ["$ref"]),
         :ok <- exact_keys(record, ["source", "component", "path"], path ++ ["$ref"]),
         {:ok, source_name} <- string_field(record, "source", path ++ ["$ref"]),
         {:ok, source} <-
           closed_value(@sources, source_name, "reference source", path ++ ["$ref", "source"]),
         {:ok, component} <- optional_string_field(record, "component", path ++ ["$ref"]),
         {:ok, ref_path} <-
           decode_list(
             Map.fetch!(record, "path"),
             registry,
             depth + 1,
             path ++ ["$ref", "path"],
             &decode_data/4
           ) do
      {:ok, %Ref{source: source, component: component, path: ref_path}}
    end
  end

  defp decode_expression(%{"$type" => "map"} = value, registry, depth, path) do
    decode_map(value, registry, depth, path, &decode_expression/4)
  end

  defp decode_expression(value, registry, depth, path) when is_map(value) do
    decode_data(value, registry, depth, path)
  end

  defp decode_expression(value, registry, depth, path),
    do: decode_data(value, registry, depth, path)

  defp decode_condition(%{"$condition" => record} = value, registry, depth, path) do
    with :ok <- exact_keys(value, ["$condition"], path),
         :ok <- depth(depth),
         :ok <- plain_map(record, "Flow condition", path ++ ["$condition"]),
         :ok <- exact_keys(record, ["operator", "operands"], path ++ ["$condition"]),
         {:ok, operator_name} <- string_field(record, "operator", path ++ ["$condition"]),
         {:ok, operator} <-
           closed_value(
             @operators,
             operator_name,
             "condition operator",
             path ++ ["$condition", "operator"]
           ),
         {:ok, operands} <-
           decode_condition_operands(
             operator,
             Map.fetch!(record, "operands"),
             registry,
             depth + 1,
             path ++ ["$condition", "operands"]
           ) do
      {:ok, %Condition{operator: operator, operands: operands}}
    end
  end

  defp decode_condition(_value, _registry, _depth, path) do
    {:error,
     Error.validation_error("stored Flow condition must be a tagged condition", %{path: path})}
  end

  defp decode_condition_operands(operator, values, registry, depth, path)
       when operator in [:all, :any, :not] do
    decode_list(values, registry, depth, path, &decode_condition/4)
  end

  defp decode_condition_operands(_operator, values, registry, depth, path) do
    decode_list(values, registry, depth, path, &decode_expression/4)
  end

  defp decode_data(value, _registry, depth, _path)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    with :ok <- depth(depth), do: {:ok, value}
  end

  defp decode_data(%{"$type" => "atom", "id" => identifier} = record, registry, depth, path) do
    with :ok <- exact_keys(record, ["$type", "id"], path),
         :ok <- depth(depth),
         true <- is_binary(identifier),
         {:ok, atom} <- Registry.resolve(registry, identifier, :atom) do
      {:ok, atom}
    else
      false ->
        {:error,
         Error.validation_error("stored atom identifier must be a string", %{path: path ++ ["id"]})}

      {:error, error} ->
        {:error, prefix(error, path)}
    end
  end

  defp decode_data(%{"$type" => "map"} = record, registry, depth, path) do
    decode_map(record, registry, depth, path, &decode_data/4)
  end

  defp decode_data(value, registry, depth, path) when is_list(value) do
    decode_list(value, registry, depth, path, &decode_data/4)
  end

  defp decode_data(_value, _registry, _depth, path) do
    {:error,
     Error.validation_error("stored Flow data has an invalid tagged value", %{path: path})}
  end

  defp decode_list(values, registry, depth, path, decoder) when is_list(values) do
    with :ok <- depth(depth),
         :ok <- collection_size(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, decoded} ->
        case decoder.(value, registry, depth + 1, path ++ [index]) do
          {:ok, value} -> {:cont, {:ok, [value | decoded]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> reverse_ok()
    else
      {:error, error} -> {:error, prefix(error, path)}
    end
  end

  defp decode_list(_values, _registry, _depth, path, _decoder) do
    {:error, Error.validation_error("stored Flow data must be a list", %{path: path})}
  end

  defp decode_map(record, registry, depth, path, value_decoder) do
    with :ok <- depth(depth),
         :ok <- exact_keys(record, ["$type", "entries"], path),
         :ok <- exact_value(record, "$type", "map", path),
         {:ok, entries} <- list_field(record, "entries", path),
         :ok <- collection_size(entries) do
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {entry, index}, {:ok, decoded} ->
        entry_path = path ++ ["entries", index]

        result =
          with :ok <- plain_map(entry, "stored map entry", entry_path),
               :ok <- exact_keys(entry, ["key", "value"], entry_path),
               {:ok, key} <-
                 decode_data(Map.fetch!(entry, "key"), registry, depth + 1, entry_path ++ ["key"]),
               :ok <- Data.validate_key(key),
               false <- Map.has_key?(decoded, key),
               {:ok, value} <-
                 value_decoder.(
                   Map.fetch!(entry, "value"),
                   registry,
                   depth + 1,
                   entry_path ++ ["value"]
                 ) do
            {:ok, Map.put(decoded, key, value)}
          else
            true ->
              {:error,
               Error.validation_error("stored map contains a duplicate key", %{
                 path: entry_path ++ ["key"]
               })}

            {:error, error} ->
              {:error, prefix(error, entry_path)}
          end

        case result do
          {:ok, decoded} -> {:cont, {:ok, decoded}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp resolve_field(record, field, kind, registry, path) do
    case Map.fetch(record, field) do
      {:ok, identifier} when is_binary(identifier) ->
        case Registry.resolve(registry, identifier, kind) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, prefix(error, path ++ [field])}
        end

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored registry identifier must be a string", %{
           path: path ++ [field]
         })}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp exact_keys(record, keys, path) when is_map(record) do
    expected = MapSet.new(keys)
    actual = MapSet.new(Map.keys(record))

    cond do
      actual == expected ->
        :ok

      MapSet.size(MapSet.difference(actual, expected)) > 0 ->
        [key | _] = actual |> MapSet.difference(expected) |> Enum.sort()

        {:error,
         Error.validation_error("stored Flow contains an unknown field", %{
           path: path ++ [key],
           field: key
         })}

      true ->
        [key | _] = expected |> MapSet.difference(actual) |> Enum.sort()

        {:error,
         Error.validation_error("stored Flow field is required", %{
           path: path ++ [key],
           field: key
         })}
    end
  end

  defp exact_value(record, field, expected, path) do
    case Map.fetch(record, field) do
      {:ok, ^expected} ->
        :ok

      {:ok, actual} ->
        {:error,
         Error.validation_error("stored Flow field has an unsupported value", %{
           path: path ++ [field],
           expected: expected,
           actual: actual
         })}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp string_field(record, field, path) do
    case Map.fetch(record, field) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored Flow field must be a string", %{path: path ++ [field]})}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp optional_string_field(record, field, path) do
    case Map.fetch(record, field) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored Flow field must be a string or null", %{
           path: path ++ [field]
         })}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp string_list_field(record, field, path) do
    case Map.fetch(record, field) do
      {:ok, values} when is_list(values) ->
        case collection_size(values) do
          :ok ->
            if Enum.all?(values, &is_binary/1) do
              {:ok, values}
            else
              {:error,
               Error.validation_error("stored Flow field must contain only strings", %{
                 path: path ++ [field]
               })}
            end

          {:error, error} ->
            {:error, prefix(error, path ++ [field])}
        end

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored Flow field must be a list", %{path: path ++ [field]})}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp list_field(record, field, path) do
    case Map.fetch(record, field) do
      {:ok, values} when is_list(values) ->
        {:ok, values}

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored Flow field must be a list", %{path: path ++ [field]})}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp positive_integer_field(record, field, path) do
    case Map.fetch(record, field) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Error.validation_error("stored Flow field must be a positive integer", %{
           path: path ++ [field]
         })}

      :error ->
        {:error,
         Error.validation_error("stored Flow field is required", %{path: path ++ [field]})}
    end
  end

  defp plain_map(value, _label, _path) when is_map(value) and not is_struct(value), do: :ok

  defp plain_map(_value, label, path),
    do: {:error, Error.validation_error("#{label} must be a map", %{path: path})}

  defp closed_value(table, value, label, path) do
    case Map.fetch(table, value) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {:error, Error.validation_error("unsupported #{label}", %{path: path, value: value})}
    end
  end

  defp depth(value) when value <= @maximum_depth, do: :ok

  defp depth(_value),
    do:
      {:error,
       Error.validation_error("stored Flow exceeds its nesting limit", %{
         maximum_depth: @maximum_depth
       })}

  defp collection_size(values) when length(values) <= @maximum_collection_size, do: :ok

  defp collection_size(_values),
    do:
      {:error,
       Error.validation_error("stored Flow collection exceeds its size limit", %{
         maximum_size: @maximum_collection_size
       })}

  defp prefix(%{details: details} = error, path) when is_map(details) do
    %{error | details: Map.put(details, :path, path ++ Map.get(details, :path, []))}
  end

  defp prefix(error, _path), do: error

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
end
