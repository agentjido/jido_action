defmodule Jido.Flow.Codec do
  @moduledoc """
  Encodes and decodes the stored Flow document.

  The document contains JSON-compatible data. A trusted `Jido.Flow.Registry`
  resolves all Action, Flow, schema, and user-data atom identifiers.

  The decoder rejects invalid UTF-8, data deeper than 100 levels, one
  collection with more than 10,000 items, and one document with more than
  100,000 data nodes. These limits apply before module or schema resolution.

      registry =
        Jido.Flow.Registry.new!(%{
          "actions/send" => {:action, MyApp.SendNotice},
          "schemas/none" => {:schema, []}
        })

      {:ok, document} = Jido.Flow.Codec.encode(flow, registry)
      {:ok, decoded_flow} = Jido.Flow.Codec.decode(document, registry)

      {:ok, temporary_document, temporary_registry} =
        Jido.Flow.Codec.encode(flow)

      case Jido.Flow.Codec.diagnose(editor_document, registry) do
        {:ok, flow} -> {:ok, flow}
        {:error, errors} -> {:error, Jido.Flow.Error.to_map(errors)}
      end
  """

  alias Jido.Action
  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Data
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Error
  alias Jido.Flow.Expression
  alias Jido.Flow.Graph
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Registry
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias Jido.Flow.Validation

  @type document :: %{required(String.t()) => term()}

  @version 1
  @expression_version 2
  @expression_operators Map.new(Expr.operators(), &{Atom.to_string(&1), &1})
  @maximum_depth 100
  @maximum_collection_size 10_000
  @maximum_document_nodes 100_000

  @component_kinds %{
    "step" => :step,
    "subflow" => :subflow,
    "choice" => :choice,
    "map" => :map,
    "reduce" => :reduce,
    "iterate" => :iterate,
    "dispatch" => :dispatch
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

  @doc """
  Encodes one executable Flow with a generated convenience Registry.

  The generated identifiers are for temporary storage, tests, or transport
  within one application version. They can change when the Flow changes. Use
  `encode/2` with an application-owned Registry for durable storage.
  """
  @spec encode(Flow.t()) ::
          {:ok, document(), Registry.t()} | {:error, Exception.t()}
  def encode(flow) do
    with {:ok, registry} <- Registry.from_flow(flow),
         {:ok, document} <- encode(flow, registry) do
      {:ok, document, registry}
    end
  end

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
         "version" =>
           if(expression_document?([components, output]), do: @expression_version, else: @version),
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
  def decode(document, registry) do
    case diagnose(document, registry) do
      {:ok, flow} -> {:ok, flow}
      {:error, %Error.Invalid{errors: [error | _rest]}} -> {:error, error}
    end
  end

  @doc """
  Diagnoses one stored Flow document without producing a partial Flow.

  The function returns the same canonical value as `decode/2` when the complete
  document is valid. Otherwise, it returns one ordered
  `Jido.Flow.Error.Invalid` group. Each independent leaf error has a JSON path
  when a path is applicable.

  Document size, collection size, nesting, root type, and document version
  errors are terminal. The function does not traverse an unsafe document or a
  document for another format version.
  """
  @spec diagnose(document(), Registry.t()) ::
          {:ok, Flow.t()} | {:error, Error.Invalid.t()}
  def diagnose(document, %Registry{} = registry)
      when is_map(document) and not is_struct(document) do
    with :ok <- validate_document_limits(document) do
      case diagnose_envelope(document) do
        [] -> diagnose_document(document, registry)
        errors -> diagnostic_failure(errors)
      end
    else
      {:error, error} -> diagnostic_failure([error])
    end
  end

  def diagnose(document, %Registry{}) do
    diagnostic_failure([
      Error.validation_error("stored Flow document must be a map", %{value: document})
    ])
  end

  def diagnose(_document, registry) do
    diagnostic_failure([
      Error.validation_error("flow codec registry must be a Jido.Flow.Registry", %{
        value: registry
      })
    ])
  end

  defp diagnose_envelope(document) do
    unknown_field_errors(document, root_keys(), []) ++
      result_errors(exact_value(document, "type", "jido.flow", [])) ++
      version_errors(document)
  end

  defp version_errors(%{"version" => @version} = document) do
    if expression_document?(document) do
      [
        Error.validation_error("stored expressions require Flow document version 2", %{
          path: ["version"]
        })
      ]
    else
      []
    end
  end

  defp version_errors(%{"version" => @expression_version}), do: []
  defp version_errors(document), do: result_errors(exact_value(document, "version", @version, []))

  defp expression_document?(%{"$expr" => _}), do: true
  defp expression_document?(%{} = map), do: Enum.any?(Map.values(map), &expression_document?/1)
  defp expression_document?(list) when is_list(list), do: Enum.any?(list, &expression_document?/1)
  defp expression_document?(_), do: false

  defp diagnose_document(document, registry) do
    fields = [
      name: fn -> diagnose_flow_name(document) end,
      description: fn -> diagnose_flow_description(document) end,
      schema: fn -> diagnose_schema_field(document, "schema", registry) end,
      output_schema: fn -> diagnose_schema_field(document, "output_schema", registry) end,
      components: fn -> diagnose_components_field(document, registry) end,
      output: fn -> diagnose_output_field(document, registry) end
    ]

    case collect_values(fields) do
      {:ok, attrs} -> diagnose_canonical_document(attrs)
      {:error, errors} -> diagnostic_failure(errors)
    end
  end

  defp diagnose_flow_name(document) do
    with {:ok, name} <- string_field(document, "name", []),
         :ok <- Action.validate_name(name) do
      {:ok, name}
    else
      {:error, message} when is_binary(message) ->
        {:error, Error.validation_error(message, %{path: ["name"]})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp diagnose_flow_description(document) do
    with {:ok, description} <- optional_string_field(document, "description", []),
         :ok <- valid_optional_utf8(description) do
      {:ok, description}
    end
  end

  defp valid_optional_utf8(nil), do: :ok

  defp valid_optional_utf8(value) when is_binary(value) do
    if String.valid?(value),
      do: :ok,
      else:
        {:error,
         Error.validation_error("flow description must be valid UTF-8", %{
           path: ["description"]
         })}
  end

  defp diagnose_schema_field(document, field, registry) do
    with {:ok, schema} <- resolve_field(document, field, :schema, registry, []),
         :ok <- Action.validate_static_data(schema),
         :ok <- Action.validate_action_schema(schema) do
      {:ok, schema}
    else
      {:error, message} when is_binary(message) ->
        {:error, Error.validation_error("#{field} #{message}", %{path: [field]})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp diagnose_components_field(document, registry) do
    case Map.fetch(document, "components") do
      {:ok, components} -> diagnose_components(components, registry)
      :error -> required_field(["components"], "components")
    end
  end

  defp diagnose_output_field(document, registry) do
    case Map.fetch(document, "output") do
      {:ok, value} ->
        with {:ok, output} <- diagnose_expression(value, registry, 0, ["output"]),
             :ok <- Expression.validate(output) do
          {:ok, output}
        else
          {:error, error} -> {:error, ensure_json_path(error, ["output"])}
        end

      :error ->
        required_field(["output"], "output")
    end
  end

  defp diagnose_canonical_document(attrs) do
    graph_errors = graph_diagnostics(attrs.components, attrs.output)

    cond do
      graph_errors != [] ->
        diagnostic_failure(graph_errors)

      true ->
        case Flow.new(attrs) do
          {:ok, flow} -> {:ok, flow}
          {:error, error} -> diagnostic_failure([ensure_json_path(error, [])])
        end
    end
  end

  defp diagnose_components(values, registry) when is_list(values) do
    cond do
      values == [] ->
        {:error,
         Error.validation_error("stored Flow must contain at least one component", %{
           path: ["components"]
         })}

      true ->
        case collection_size(values) do
          :ok ->
            values
            |> Enum.with_index()
            |> collect_sequence(fn {value, index} ->
              diagnose_component(value, registry, ["components", index])
            end)

          {:error, error} ->
            {:error, ensure_json_path(error, ["components"])}
        end
    end
  end

  defp diagnose_components(_values, _registry) do
    {:error,
     Error.validation_error("stored Flow components must be a list", %{path: ["components"]})}
  end

  defp diagnose_component(%{} = record, registry, path) when not is_struct(record) do
    with {:ok, kind_name} <- string_field(record, "kind", path),
         {:ok, kind} <-
           closed_value(@component_kinds, kind_name, "component kind", path ++ ["kind"]) do
      diagnose_component_kind(kind, record, registry, path)
    end
  end

  defp diagnose_component(_record, _registry, path) do
    {:error, Error.validation_error("stored Flow component must be a map", %{path: path})}
  end

  defp diagnose_component_kind(:step, record, registry, path) do
    allowed = ["kind", "name", "action", "params", "after", "meta"]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        action: fn -> resolve_field(record, "action", :action, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end
      ],
      &Step.new/1
    )
  end

  defp diagnose_component_kind(:subflow, record, registry, path) do
    allowed = ["kind", "name", "flow", "params", "after", "meta"]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        flow: fn -> resolve_field(record, "flow", :flow, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end
      ],
      &Subflow.new/1
    )
  end

  defp diagnose_component_kind(:choice, record, registry, path) do
    allowed = ["kind", "name", "options", "fallback", "after", "meta"]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        options: fn -> diagnose_choice_options_field(record, registry, path) end,
        fallback: fn -> diagnose_fallback_field(record, registry, path) end
      ],
      &Choice.new/1
    )
  end

  defp diagnose_component_kind(:map, record, registry, path) do
    allowed = ["kind", "name", "collection", "action", "params", "on_error", "after", "meta"]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        collection: fn -> diagnose_expression_field(record, "collection", registry, path) end,
        action: fn -> resolve_field(record, "action", :action, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end,
        on_error: fn -> diagnose_on_error_field(record, path) end
      ],
      &FlowMap.new/1
    )
  end

  defp diagnose_component_kind(:reduce, record, registry, path) do
    allowed = ["kind", "name", "collection", "initial", "action", "params", "after", "meta"]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        collection: fn -> diagnose_expression_field(record, "collection", registry, path) end,
        initial: fn -> diagnose_expression_field(record, "initial", registry, path) end,
        action: fn -> resolve_field(record, "action", :action, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end
      ],
      &Reduce.new/1
    )
  end

  defp diagnose_component_kind(:iterate, record, registry, path) do
    allowed = [
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

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        action: fn -> resolve_field(record, "action", :action, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end,
        state: fn -> diagnose_iterate_state_field(record, registry, path) end,
        completion: fn -> diagnose_completion_field(record, registry, path) end,
        max_iterations: fn -> positive_integer_field(record, "max_iterations", path) end
      ],
      &Iterate.new/1
    )
  end

  defp diagnose_component_kind(:dispatch, record, registry, path) do
    allowed = [
      "kind",
      "name",
      "decision",
      "expander",
      "params",
      "after",
      "meta"
    ]

    diagnose_component_fields(
      record,
      registry,
      path,
      allowed,
      [
        decision: fn -> resolve_field(record, "decision", :action, registry, path) end,
        expander: fn -> resolve_field(record, "expander", :action, registry, path) end,
        params: fn -> diagnose_expression_field(record, "params", registry, path) end
      ],
      &Dispatch.new/1
    )
  end

  defp diagnose_component_fields(
         record,
         registry,
         path,
         allowed,
         specific_fields,
         constructor
       ) do
    fields = [common: fn -> diagnose_common(record, registry, path) end] ++ specific_fields
    initial_errors = unknown_field_errors(record, allowed, path)

    case collect_values(fields, initial_errors) do
      {:ok, %{common: common} = values} ->
        attrs = values |> Map.delete(:common) |> Map.merge(common)
        diagnose_constructor(constructor.(attrs), path)

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp diagnose_common(record, registry, path) do
    fields = [
      name: fn -> string_field(record, "name", path) end,
      after: fn -> string_list_field(record, "after", path) end,
      meta: fn -> diagnose_meta_field(record, registry, path) end
    ]

    collect_values(fields)
  end

  defp diagnose_meta_field(record, registry, path) do
    case Map.fetch(record, "meta") do
      {:ok, value} ->
        with {:ok, meta} <- diagnose_data(value, registry, 0, path ++ ["meta"]),
             :ok <- Data.validate_object(meta) do
          {:ok, meta}
        else
          {:error, error} -> {:error, ensure_json_path(error, path ++ ["meta"])}
        end

      :error ->
        required_field(path ++ ["meta"], "meta")
    end
  end

  defp diagnose_expression_field(record, field, registry, path) do
    case Map.fetch(record, field) do
      {:ok, value} -> diagnose_expression(value, registry, 0, path ++ [field])
      :error -> required_field(path ++ [field], field)
    end
  end

  defp diagnose_on_error_field(record, path) do
    with {:ok, name} <- string_field(record, "on_error", path) do
      closed_value(@on_error, name, "Map on_error", path ++ ["on_error"])
    end
  end

  defp diagnose_choice_options_field(record, registry, path) do
    case Map.fetch(record, "options") do
      {:ok, values} -> diagnose_choice_options(values, registry, path ++ ["options"])
      :error -> required_field(path ++ ["options"], "options")
    end
  end

  defp diagnose_choice_options(values, registry, path) when is_list(values) do
    cond do
      values == [] ->
        {:error, Error.validation_error("choice options must not be empty", %{path: path})}

      true ->
        case collection_size(values) do
          :ok ->
            values
            |> Enum.with_index()
            |> collect_sequence(fn {record, index} ->
              diagnose_choice_option(record, registry, path ++ [index])
            end)

          {:error, error} ->
            {:error, ensure_json_path(error, path)}
        end
    end
  end

  defp diagnose_choice_options(_values, _registry, path) do
    {:error, Error.validation_error("choice options must be a list", %{path: path})}
  end

  defp diagnose_choice_option(%{} = record, registry, path) when not is_struct(record) do
    fields = [
      name: fn -> string_field(record, "name", path) end,
      condition: fn -> diagnose_condition_field(record, "condition", registry, path) end,
      action: fn -> resolve_field(record, "action", :action, registry, path) end,
      params: fn -> diagnose_expression_field(record, "params", registry, path) end
    ]

    initial_errors = unknown_field_errors(record, ["name", "condition", "action", "params"], path)

    case collect_values(fields, initial_errors) do
      {:ok, attrs} -> diagnose_constructor(Choice.Option.new(attrs), path)
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_choice_option(_record, _registry, path) do
    {:error, Error.validation_error("choice option must be a map", %{path: path})}
  end

  defp diagnose_condition_field(record, field, registry, path) do
    case Map.fetch(record, field) do
      {:ok, value} -> diagnose_condition(value, registry, 0, path ++ [field])
      :error -> required_field(path ++ [field], field)
    end
  end

  defp diagnose_fallback_field(record, registry, path) do
    case Map.fetch(record, "fallback") do
      {:ok, value} -> diagnose_fallback(value, registry, path ++ ["fallback"])
      :error -> required_field(path ++ ["fallback"], "fallback")
    end
  end

  defp diagnose_fallback(%{} = record, registry, path) when not is_struct(record) do
    fields = [
      action: fn -> resolve_field(record, "action", :action, registry, path) end,
      params: fn -> diagnose_expression_field(record, "params", registry, path) end
    ]

    initial_errors = unknown_field_errors(record, ["action", "params"], path)

    case collect_values(fields, initial_errors) do
      {:ok, attrs} -> diagnose_constructor(Choice.Fallback.new(attrs), path)
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_fallback(_record, _registry, path) do
    {:error, Error.validation_error("choice fallback must be a map", %{path: path})}
  end

  defp diagnose_iterate_state_field(record, registry, path) do
    case Map.fetch(record, "state") do
      {:ok, value} -> diagnose_iterate_state(value, registry, path ++ ["state"])
      :error -> required_field(path ++ ["state"], "state")
    end
  end

  defp diagnose_iterate_state(%{} = record, registry, path) when not is_struct(record) do
    fields = [
      schema: fn -> diagnose_nested_schema_field(record, registry, path) end,
      initial: fn -> diagnose_expression_field(record, "initial", registry, path) end,
      update: fn -> diagnose_expression_field(record, "update", registry, path) end
    ]

    initial_errors = unknown_field_errors(record, ["schema", "initial", "update"], path)

    case collect_values(fields, initial_errors) do
      {:ok, attrs} -> diagnose_constructor(Iterate.State.new(attrs), path)
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_iterate_state(_record, _registry, path) do
    {:error, Error.validation_error("iterate state must be a map", %{path: path})}
  end

  defp diagnose_nested_schema_field(record, registry, path) do
    with {:ok, schema} <- resolve_field(record, "schema", :schema, registry, path),
         :ok <- Action.validate_static_data(schema),
         :ok <- Action.validate_action_schema(schema) do
      {:ok, schema}
    else
      {:error, message} when is_binary(message) ->
        {:error,
         Error.validation_error("iterate state schema #{message}", %{
           path: path ++ ["schema"]
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp diagnose_completion_field(record, registry, path) do
    case Map.fetch(record, "completion") do
      {:ok, value} -> diagnose_condition(value, registry, 0, path ++ ["completion"])
      :error -> required_field(path ++ ["completion"], "completion")
    end
  end

  defp diagnose_expression(value, registry, depth, path) when is_list(value) do
    diagnose_list(value, registry, depth, path, &diagnose_expression/4)
  end

  defp diagnose_expression(%{"$expr" => record} = value, registry, depth, path) do
    tag_path = path ++ ["$expr"]

    initial_errors =
      unknown_field_errors(value, ["$expr"], path) ++ result_errors(ensure_depth(depth, path))

    case plain_map(record, "expression", tag_path) do
      :ok ->
        fields = [
          operator: fn ->
            with {:ok, name} <- string_field(record, "operator", tag_path) do
              closed_value(
                @expression_operators,
                name,
                "expression operator",
                tag_path ++ ["operator"]
              )
            end
          end,
          operands: fn ->
            case Map.fetch(record, "operands") do
              {:ok, values} ->
                diagnose_list(
                  values,
                  registry,
                  depth + 1,
                  tag_path ++ ["operands"],
                  &diagnose_expression/4
                )

              :error ->
                required_field(tag_path ++ ["operands"], "operands")
            end
          end
        ]

        errors =
          initial_errors ++ unknown_field_errors(record, ["operator", "operands"], tag_path)

        case collect_values(fields, errors) do
          {:ok, attrs} ->
            case Expr.new(attrs.operator, attrs.operands) do
              {:ok, expression} ->
                {:ok, expression}

              {:error, error} ->
                {:error,
                 Error.validation_error("invalid stored expression", %{
                   path: tag_path,
                   reason: error.reason,
                   operator: error.operator
                 })}
            end

          error ->
            error
        end

      {:error, error} ->
        {:error, initial_errors ++ [error]}
    end
  end

  defp diagnose_expression(%{"$ref" => record} = value, registry, depth, path) do
    initial_errors =
      unknown_field_errors(value, ["$ref"], path) ++
        result_errors(ensure_depth(depth, path))

    case plain_map(record, "Flow reference", path ++ ["$ref"]) do
      :ok ->
        fields = [
          source: fn -> diagnose_ref_source(record, path) end,
          component: fn -> optional_string_field(record, "component", path ++ ["$ref"]) end,
          path: fn -> diagnose_ref_path(record, registry, depth, path) end
        ]

        errors =
          initial_errors ++
            unknown_field_errors(record, ["source", "component", "path"], path ++ ["$ref"])

        case collect_values(fields, errors) do
          {:ok, attrs} -> {:ok, struct!(Ref, attrs)}
          {:error, errors} -> {:error, errors}
        end

      {:error, error} ->
        {:error, initial_errors ++ [error]}
    end
  end

  defp diagnose_expression(%{"$type" => "map"} = value, registry, depth, path) do
    diagnose_map(value, registry, depth, path, &diagnose_expression/4)
  end

  defp diagnose_expression(value, registry, depth, path) when is_map(value) do
    diagnose_data(value, registry, depth, path)
  end

  defp diagnose_expression(value, registry, depth, path) do
    diagnose_data(value, registry, depth, path)
  end

  defp diagnose_ref_source(record, path) do
    with {:ok, source_name} <- string_field(record, "source", path ++ ["$ref"]) do
      closed_value(
        @sources,
        source_name,
        "reference source",
        path ++ ["$ref", "source"]
      )
    end
  end

  defp diagnose_ref_path(record, registry, depth, path) do
    case Map.fetch(record, "path") do
      {:ok, value} ->
        diagnose_list(
          value,
          registry,
          depth + 1,
          path ++ ["$ref", "path"],
          &diagnose_data/4
        )

      :error ->
        required_field(path ++ ["$ref", "path"], "path")
    end
  end

  defp diagnose_condition(%{"$expr" => _} = value, registry, depth, path),
    do: diagnose_expression(value, registry, depth, path)

  defp diagnose_condition(%{"$condition" => record} = value, registry, depth, path) do
    initial_errors =
      unknown_field_errors(value, ["$condition"], path) ++
        result_errors(ensure_depth(depth, path))

    case plain_map(record, "Flow condition", path ++ ["$condition"]) do
      :ok ->
        operator_result = diagnose_condition_operator(record, path)

        fields = [
          operator: fn -> operator_result end,
          operands: fn ->
            diagnose_condition_operands_field(record, operator_result, registry, depth, path)
          end
        ]

        errors =
          initial_errors ++
            unknown_field_errors(record, ["operator", "operands"], path ++ ["$condition"])

        case collect_values(fields, errors) do
          {:ok, attrs} -> {:ok, struct!(Condition, attrs)}
          {:error, errors} -> {:error, errors}
        end

      {:error, error} ->
        {:error, initial_errors ++ [error]}
    end
  end

  defp diagnose_condition(_value, _registry, _depth, path) do
    {:error,
     Error.validation_error("stored Flow condition must be a tagged condition", %{path: path})}
  end

  defp diagnose_condition_operator(record, path) do
    with {:ok, operator_name} <- string_field(record, "operator", path ++ ["$condition"]) do
      closed_value(
        @operators,
        operator_name,
        "condition operator",
        path ++ ["$condition", "operator"]
      )
    end
  end

  defp diagnose_condition_operands_field(record, {:ok, operator}, registry, depth, path) do
    case Map.fetch(record, "operands") do
      {:ok, values} when operator in [:all, :any, :not] ->
        diagnose_list(
          values,
          registry,
          depth + 1,
          path ++ ["$condition", "operands"],
          &diagnose_condition/4
        )

      {:ok, values} ->
        diagnose_list(
          values,
          registry,
          depth + 1,
          path ++ ["$condition", "operands"],
          &diagnose_expression/4
        )

      :error ->
        required_field(path ++ ["$condition", "operands"], "operands")
    end
  end

  defp diagnose_condition_operands_field(_record, {:error, _error}, _registry, _depth, _path) do
    {:ok, []}
  end

  defp diagnose_data(value, _registry, depth, path)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    with :ok <- ensure_depth(depth, path), do: {:ok, value}
  end

  defp diagnose_data(%{"$type" => "atom"} = record, registry, depth, path) do
    fields = [
      type: fn -> exact_value_as_value(record, "$type", "atom", path) end,
      value: fn -> diagnose_atom_identifier(record, registry, path) end
    ]

    initial_errors =
      unknown_field_errors(record, ["$type", "id"], path) ++
        result_errors(ensure_depth(depth, path))

    case collect_values(fields, initial_errors) do
      {:ok, %{value: atom}} -> {:ok, atom}
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_data(%{"$type" => "map"} = record, registry, depth, path) do
    diagnose_map(record, registry, depth, path, &diagnose_data/4)
  end

  defp diagnose_data(value, registry, depth, path) when is_list(value) do
    diagnose_list(value, registry, depth, path, &diagnose_data/4)
  end

  defp diagnose_data(_value, _registry, _depth, path) do
    {:error,
     Error.validation_error("stored Flow data has an invalid tagged value", %{path: path})}
  end

  defp diagnose_atom_identifier(record, registry, path) do
    case Map.fetch(record, "id") do
      {:ok, identifier} when is_binary(identifier) ->
        case Registry.resolve(registry, identifier, :atom) do
          {:ok, atom} -> {:ok, atom}
          {:error, error} -> {:error, ensure_json_path(error, path ++ ["id"])}
        end

      {:ok, _identifier} ->
        {:error,
         Error.validation_error("stored atom identifier must be a string", %{
           path: path ++ ["id"]
         })}

      :error ->
        required_field(path ++ ["id"], "id")
    end
  end

  defp diagnose_list(values, registry, depth, path, decoder) when is_list(values) do
    with :ok <- ensure_depth(depth, path),
         :ok <- ensure_collection_size(values, path) do
      values
      |> Enum.with_index()
      |> collect_sequence(fn {value, index} ->
        decoder.(value, registry, depth + 1, path ++ [index])
      end)
    end
  end

  defp diagnose_list(_values, _registry, _depth, path, _decoder) do
    {:error, Error.validation_error("stored Flow data must be a list", %{path: path})}
  end

  defp diagnose_map(record, registry, depth, path, value_decoder) do
    initial_errors =
      unknown_field_errors(record, ["$type", "entries"], path) ++
        result_errors(ensure_depth(depth, path)) ++
        result_errors(exact_value(record, "$type", "map", path))

    entries_result =
      case Map.fetch(record, "entries") do
        {:ok, entries} when is_list(entries) ->
          with :ok <- ensure_collection_size(entries, path ++ ["entries"]) do
            entries
            |> Enum.with_index()
            |> collect_sequence(fn {entry, index} ->
              diagnose_map_entry(
                entry,
                registry,
                depth,
                path ++ ["entries", index],
                value_decoder,
                index
              )
            end)
          end

        {:ok, _entries} ->
          {:error,
           Error.validation_error("stored Flow field must be a list", %{
             path: path ++ ["entries"]
           })}

        :error ->
          required_field(path ++ ["entries"], "entries")
      end

    case collect_values([entries: fn -> entries_result end], initial_errors) do
      {:ok, %{entries: entries}} -> diagnose_map_entries(entries, path)
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_map_entry(%{} = entry, registry, depth, path, value_decoder, index)
       when not is_struct(entry) do
    fields = [
      key: fn -> diagnose_map_entry_key(entry, registry, depth, path) end,
      value: fn -> diagnose_map_entry_value(entry, registry, depth, path, value_decoder) end
    ]

    initial_errors = unknown_field_errors(entry, ["key", "value"], path)

    case collect_values(fields, initial_errors) do
      {:ok, decoded} -> {:ok, Map.put(decoded, :index, index)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp diagnose_map_entry(_entry, _registry, _depth, path, _value_decoder, _index) do
    {:error, Error.validation_error("stored map entry must be a map", %{path: path})}
  end

  defp diagnose_map_entry_key(entry, registry, depth, path) do
    case Map.fetch(entry, "key") do
      {:ok, value} ->
        with {:ok, key} <- diagnose_data(value, registry, depth + 1, path ++ ["key"]),
             :ok <- Data.validate_key(key) do
          {:ok, key}
        else
          {:error, error} -> {:error, ensure_json_path(error, path ++ ["key"])}
        end

      :error ->
        required_field(path ++ ["key"], "key")
    end
  end

  defp diagnose_map_entry_value(entry, registry, depth, path, value_decoder) do
    case Map.fetch(entry, "value") do
      {:ok, value} -> value_decoder.(value, registry, depth + 1, path ++ ["value"])
      :error -> required_field(path ++ ["value"], "value")
    end
  end

  defp diagnose_map_entries(entries, path) do
    {map, errors} =
      Enum.reduce(entries, {%{}, []}, fn %{index: index, key: key, value: value}, {map, errors} ->
        if Map.has_key?(map, key) do
          error =
            Error.validation_error("stored map contains a duplicate key", %{
              path: path ++ ["entries", index, "key"]
            })

          {map, errors ++ [error]}
        else
          {Map.put(map, key, value), errors}
        end
      end)

    if errors == [], do: {:ok, map}, else: {:error, errors}
  end

  defp exact_value_as_value(record, field, expected, path) do
    case exact_value(record, field, expected, path) do
      :ok -> {:ok, expected}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_depth(depth, path) do
    case depth(depth) do
      :ok -> :ok
      {:error, error} -> {:error, ensure_json_path(error, path)}
    end
  end

  defp ensure_collection_size(values, path) do
    case collection_size(values) do
      :ok -> :ok
      {:error, error} -> {:error, ensure_json_path(error, path)}
    end
  end

  defp diagnose_constructor({:ok, value}, _path), do: {:ok, value}

  defp diagnose_constructor({:error, error}, path) do
    {:error, ensure_json_path(error, path)}
  end

  defp graph_diagnostics(components, output) do
    duplicate_errors = duplicate_component_errors(components)
    reference_errors = unknown_reference_errors(components, output)

    cycle_errors =
      if duplicate_errors == [] and reference_errors == [] do
        case Graph.analyze(components) do
          %{remaining: []} ->
            []

          %{remaining: names} ->
            [
              Error.validation_error("flow dependency graph contains a cycle", %{
                components: names,
                path: ["components"]
              })
            ]
        end
      else
        []
      end

    dispatch_errors =
      if duplicate_errors == [] and reference_errors == [] and cycle_errors == [] do
        components
        |> Validation.dispatch_diagnostics(output)
        |> Enum.map(&ensure_json_path(&1, []))
      else
        []
      end

    duplicate_errors ++ reference_errors ++ cycle_errors ++ dispatch_errors
  end

  defp duplicate_component_errors(components) do
    components
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {component, index}, {seen, errors} ->
      name = Jido.Flow.Component.name_of(component)

      if MapSet.member?(seen, name) do
        error =
          Error.validation_error("duplicate component name", %{
            name: name,
            path: ["components", index, "name"]
          })

        {seen, errors ++ [error]}
      else
        {MapSet.put(seen, name), errors}
      end
    end)
    |> elem(1)
  end

  defp unknown_reference_errors(components, output) do
    known = components |> Enum.map(&Jido.Flow.Component.name_of/1) |> MapSet.new()

    output_errors =
      output
      |> Expression.result_refs()
      |> Enum.uniq()
      |> unknown_reference_errors_for(known, :output, ["output"])

    component_errors =
      components
      |> Enum.with_index()
      |> Enum.flat_map(fn {component, index} ->
        component
        |> Jido.Flow.Component.effective_dependencies()
        |> unknown_reference_errors_for(
          known,
          Jido.Flow.Component.name_of(component),
          ["components", index]
        )
      end)

    output_errors ++ component_errors
  end

  defp unknown_reference_errors_for(names, known, owner, path) do
    names
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.uniq()
    |> Enum.map(fn name ->
      Error.validation_error("Flow reference points to an unknown component", %{
        owner: owner,
        component: name,
        path: path
      })
    end)
  end

  defp collect_values(fields, initial_errors \\ []) do
    {values, errors} =
      Enum.reduce(fields, {%{}, initial_errors}, fn {key, validator}, {values, errors} ->
        case validator.() do
          {:ok, value} -> {Map.put(values, key, value), errors}
          {:error, nested} when is_list(nested) -> {values, errors ++ nested}
          {:error, error} -> {values, errors ++ [error]}
        end
      end)

    if errors == [], do: {:ok, values}, else: {:error, errors}
  end

  defp collect_sequence(values, validator) do
    {decoded, errors} =
      Enum.reduce(values, {[], []}, fn value, {decoded, errors} ->
        case validator.(value) do
          {:ok, item} -> {decoded ++ [item], errors}
          {:error, nested} when is_list(nested) -> {decoded, errors ++ nested}
          {:error, error} -> {decoded, errors ++ [error]}
        end
      end)

    if errors == [], do: {:ok, decoded}, else: {:error, errors}
  end

  defp unknown_field_errors(record, allowed, path) do
    record
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(fn field ->
      Error.validation_error("stored Flow contains an unknown field", %{
        path: path ++ [json_path_segment(field)],
        field: field
      })
    end)
  end

  defp result_errors(:ok), do: []
  defp result_errors({:error, error}), do: [error]

  defp required_field(path, field) do
    {:error, Error.validation_error("stored Flow field is required", %{path: path, field: field})}
  end

  defp ensure_json_path(%{details: details} = error, base_path) when is_map(details) do
    local_path = details |> Map.get(:path, []) |> Enum.map(&json_path_segment/1)

    path =
      if path_starts_with?(local_path, base_path), do: local_path, else: base_path ++ local_path

    %{error | details: Map.put(details, :path, path)}
  end

  defp ensure_json_path(error, _base_path), do: error

  defp path_starts_with?(path, prefix), do: Enum.take(path, length(prefix)) == prefix

  defp json_path_segment(segment) when is_binary(segment) or is_integer(segment), do: segment
  defp json_path_segment(segment) when is_atom(segment), do: Atom.to_string(segment)
  defp json_path_segment(segment), do: inspect(segment)

  defp diagnostic_failure(errors) do
    {:error, Error.to_class(errors)}
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

  defp encode_component(%Dispatch{} = dispatch, registry) do
    with {:ok, decision} <- Registry.identifier(registry, :action, dispatch.decision),
         {:ok, expander} <- Registry.identifier(registry, :action, dispatch.expander),
         {:ok, params} <- encode_expression(dispatch.params, registry, 0),
         {:ok, meta} <- encode_data(dispatch.meta, registry, 0) do
      {:ok,
       %{
         "kind" => "dispatch",
         "name" => dispatch.name,
         "decision" => decision,
         "expander" => expander,
         "params" => params,
         "after" => dispatch.after,
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

  defp encode_expression(%Expr{} = expression, registry, depth) do
    with :ok <- depth(depth),
         {:ok, operands} <-
           encode_list(expression.operands, registry, depth + 1, &encode_expression/3) do
      {:ok,
       %{"$expr" => %{"operator" => Atom.to_string(expression.operator), "operands" => operands}}}
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

  defp encode_condition(%Expr{} = expression, registry, depth),
    do: encode_expression(expression, registry, depth)

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

  defp validate_document_limits(document) do
    case count_document_nodes(document, 0, @maximum_document_nodes) do
      {:ok, _remaining} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp count_document_nodes(_value, _depth, remaining) when remaining <= 0 do
    {:error,
     Error.validation_error("stored Flow exceeds its total node limit", %{
       maximum_nodes: @maximum_document_nodes
     })}
  end

  defp count_document_nodes(value, depth, remaining) when is_list(value) do
    with :ok <- depth(depth),
         false <- List.improper?(value),
         :ok <- collection_size(value) do
      Enum.reduce_while(value, {:ok, remaining - 1}, fn item, {:ok, remaining} ->
        case count_document_nodes(item, depth + 1, remaining) do
          {:ok, remaining} -> {:cont, {:ok, remaining}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    else
      true ->
        {:error, Error.validation_error("stored Flow data must contain proper lists")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp count_document_nodes(value, depth, remaining)
       when is_map(value) and not is_struct(value) do
    with :ok <- depth(depth),
         :ok <- document_map_size(value) do
      Enum.reduce_while(value, {:ok, remaining - 1}, fn {key, item}, {:ok, remaining} ->
        with {:ok, remaining} <- count_document_nodes(key, depth + 1, remaining),
             {:ok, remaining} <- count_document_nodes(item, depth + 1, remaining) do
          {:cont, {:ok, remaining}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp count_document_nodes(_value, depth, remaining) do
    with :ok <- depth(depth), do: {:ok, remaining - 1}
  end

  defp document_map_size(value) when map_size(value) <= @maximum_collection_size, do: :ok

  defp document_map_size(_value) do
    {:error,
     Error.validation_error("stored Flow collection exceeds its size limit", %{
       maximum_size: @maximum_collection_size
     })}
  end

  defp prefix(%{details: details} = error, path) when is_map(details) do
    %{error | details: Map.put(details, :path, path ++ Map.get(details, :path, []))}
  end

  defp prefix(error, _path), do: error

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
end
