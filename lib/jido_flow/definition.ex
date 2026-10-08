defmodule Jido.Flow.Definition do
  @moduledoc false

  alias Jido.Action
  alias Jido.Flow.Error
  alias Jido.Flow.Graph
  alias Jido.Flow.Ref
  alias Jido.Flow.Value
  alias Jido.Instruction

  @maximum_iterations 10_000
  @module_config_keys [:name, :description, :schema, :output_schema]
  @artifact_config_keys @module_config_keys ++ [:components, :output]
  @common_keys [:kind, :name, :needs, :meta]
  @canonical_node_keys %{
    call: [:kind, :needs, :meta, :call],
    choice: [:kind, :needs, :meta, :options, :fallback],
    map: [:kind, :needs, :meta, :collection, :call, :on_error],
    reduce: [:kind, :needs, :meta, :collection, :initial, :call],
    iterate: [:kind, :needs, :meta, :call, :state, :completion, :max_iterations],
    dispatch: [:kind, :needs, :meta, :decision, :expander]
  }
  @canonical_option_keys [:name, :condition, :call]
  @canonical_state_keys [:schema, :initial, :update]

  @type call :: {Instruction.template_t(), Value.t()}
  @type condition :: boolean() | Ref.t() | Jido.Expr.t()
  @type choice_option :: %{
          required(:name) => String.t(),
          required(:condition) => condition(),
          required(:call) => call()
        }
  @type component_node :: map()
  @type components :: %{optional(String.t()) => component_node()}
  @type named_component :: {String.t(), component_node()}

  @typedoc false
  @type issue :: %{
          kind:
            :definition
            | :output_required
            | :duplicate_name
            | :unknown_dependency
            | :cycle
            | :dispatch,
          error: Exception.t(),
          location: [atom() | String.t() | non_neg_integer()]
        }

  @doc false
  @spec validate(map()) :: {:ok, map()} | {:error, Exception.t()}
  def validate(attrs) do
    case diagnose(attrs) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, [issue | _rest]} -> {:error, put_location(issue.error, issue.location)}
    end
  end

  # Graph issues carry their location separately; expose it as the error path.
  defp put_location(%{details: details} = error, [_ | _] = location) when is_map(details) do
    if Map.has_key?(details, :path),
      do: error,
      else: %{error | details: Map.put(details, :path, location)}
  end

  defp put_location(error, _location), do: error

  @doc false
  @spec validate_canonical(map()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_canonical(%{} = attrs) when not is_struct(attrs) do
    components = Map.get(attrs, :components)

    with :ok <- canonical_components(components),
         definitions <- canonical_definitions(components),
         {:ok, normalized} <- validate_canonical_definitions(attrs, definitions, components),
         :ok <- unchanged_canonical(attrs, normalized) do
      {:ok, normalized}
    end
  end

  def validate_canonical(_attrs),
    do: {:error, Error.validation_error("canonical Flow must be a map")}

  @doc false
  @spec diagnose(map()) :: {:ok, map()} | {:error, [issue()]}
  def diagnose(attrs) do
    case normalize_attrs(attrs) do
      {:ok, attrs, named_components} ->
        diagnose_normalized(attrs, named_components)

      {:error, error} ->
        {:error, [issue(:definition, error, Map.get(error.details, :path, []))]}
    end
  end

  @doc false
  @spec diagnose_normalized(map(), [named_component()]) ::
          {:ok, map()} | {:error, [issue()]}
  def diagnose_normalized(attrs, named_components) do
    issues = output_issues(attrs.output) ++ graph_issues(named_components, attrs.output)

    if issues == [] do
      {:ok, %{attrs | components: Map.new(named_components)}}
    else
      {:error, issues}
    end
  end

  @doc false
  @spec validate_config(term()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_config(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs, @module_config_keys, "Flow configuration"),
         {:ok, name} <- flow_name(Map.get(attrs, :name)),
         {:ok, description} <- description(Map.get(attrs, :description)),
         {:ok, schema} <- schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <- schema(Map.get(attrs, :output_schema, []), "output_schema") do
      {:ok, %{name: name, description: description, schema: schema, output_schema: output_schema}}
    end
  end

  def validate_config(_attrs),
    do: {:error, Error.validation_error("flow configuration must be a map")}

  @doc false
  @spec component(term()) :: {:ok, named_component()} | {:error, Exception.t()}
  def component(%{kind: kind} = attrs) when not is_struct(attrs) do
    normalize_component(kind, attrs)
  end

  def component(value) do
    {:error, Error.validation_error("expected a Flow component map", %{value: value})}
  end

  @doc false
  @spec name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def name(value), do: name(value, "component")

  @doc false
  @spec invalid_subject(term()) :: {:error, Exception.t()}
  def invalid_subject(value),
    do: {:error, Error.validation_error("expected a Jido.Flow artifact", %{value: value})}

  @doc false
  @spec needs(component_node()) :: [String.t()]
  def needs(%{needs: needs}), do: needs

  @doc false
  @spec calls(component_node()) ::
          [{atom() | String.t(), Instruction.template_t(), Value.t()}]
  def calls(%{kind: :call, call: {instruction, params}}),
    do: [{:call, instruction, params}]

  def calls(%{kind: :choice, options: options, fallback: fallback}) do
    Enum.map(options, fn %{name: name, call: {instruction, params}} ->
      {name, instruction, params}
    end) ++ [fallback_call(fallback)]
  end

  def calls(%{kind: kind, call: {instruction, params}})
      when kind in [:map, :reduce, :iterate],
      do: [{kind, instruction, params}]

  def calls(%{
        kind: :dispatch,
        decision: {decision, params},
        expander: {expander, expander_params}
      }),
      do: [{:decision, decision, params}, {:expander, expander, expander_params}]

  @doc false
  @spec reference_dependencies(component_node()) :: [String.t()]
  def reference_dependencies(node) do
    node
    |> values()
    |> Enum.flat_map(&Value.result_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec effective_dependencies(component_node()) :: [String.t()]
  def effective_dependencies(node) do
    (needs(node) ++ reference_dependencies(node)) |> Enum.uniq() |> Enum.sort()
  end

  @doc false
  @spec values(component_node()) :: [Value.t()]
  def values(%{kind: :call, call: {_instruction, params}}), do: [params]

  def values(%{kind: :choice, options: options, fallback: {_instruction, params}}) do
    Enum.flat_map(options, fn %{condition: condition, call: {_instruction, option_params}} ->
      [condition, option_params]
    end) ++ [params]
  end

  def values(%{kind: :map, collection: collection, call: {_instruction, params}}),
    do: [collection, params]

  def values(%{
        kind: :reduce,
        collection: collection,
        initial: initial,
        call: {_instruction, params}
      }),
      do: [collection, initial, params]

  def values(%{
        kind: :iterate,
        call: {_instruction, params},
        state: state,
        completion: completion
      }),
      do: [params, state.initial, state.update, completion]

  def values(%{
        kind: :dispatch,
        decision: {_decision, params},
        expander: {_expander, expander_params}
      }),
      do: [params, expander_params]

  @doc false
  @spec to_definition(components()) :: [map()]
  def to_definition(components) when is_map(components) do
    components
    |> Graph.canonical_components()
    |> Enum.map(&component_to_definition/1)
  end

  @doc false
  @spec to_map(components()) :: [map()]
  def to_map(components) when is_map(components) do
    components
    |> to_definition()
    |> Enum.map(&Value.to_map/1)
  end

  @doc false
  @spec component_to_definition(named_component()) :: map()
  def component_to_definition({name, %{kind: :call, call: {instruction, params}} = node}) do
    common = common_definition(name, node)

    case instruction.kind do
      :action ->
        Map.merge(common, %{kind: :step, action: instruction.target, params: params})

      :flow ->
        Map.merge(common, %{
          kind: :subflow,
          flow: instruction.target,
          params: params
        })
    end
  end

  def component_to_definition({name, %{kind: :choice} = node}) do
    options =
      Enum.map(node.options, fn %{
                                  name: option_name,
                                  condition: condition,
                                  call: {instruction, params}
                                } ->
        %{
          name: option_name,
          condition: condition,
          action: instruction.target,
          params: params
        }
      end)

    {fallback_instruction, fallback_params} = node.fallback

    common_definition(name, node)
    |> Map.merge(%{
      kind: :choice,
      options: options,
      fallback: %{action: fallback_instruction.target, params: fallback_params}
    })
  end

  def component_to_definition({name, %{kind: :map, call: {instruction, params}} = node}) do
    common_definition(name, node)
    |> Map.merge(%{
      kind: :map,
      collection: node.collection,
      action: instruction.target,
      params: params,
      on_error: node.on_error
    })
  end

  def component_to_definition({name, %{kind: :reduce, call: {instruction, params}} = node}) do
    common_definition(name, node)
    |> Map.merge(%{
      kind: :reduce,
      collection: node.collection,
      initial: node.initial,
      action: instruction.target,
      params: params
    })
  end

  def component_to_definition({name, %{kind: :iterate, call: {instruction, params}} = node}) do
    common_definition(name, node)
    |> Map.merge(%{
      kind: :iterate,
      action: instruction.target,
      params: params,
      state: %{
        schema: node.state.schema,
        initial: node.state.initial,
        update: node.state.update
      },
      completion: node.completion,
      max_iterations: node.max_iterations
    })
  end

  def component_to_definition(
        {name,
         %{
           kind: :dispatch,
           decision: {decision, params},
           expander: {expander, _expander_params}
         } = node}
      ) do
    common_definition(name, node)
    |> Map.merge(%{
      kind: :dispatch,
      decision: decision.target,
      expander: expander.target,
      params: params
    })
  end

  defp canonical_components(%{} = components) when not is_struct(components) do
    components
    |> canonical_entries()
    |> Enum.reduce_while(:ok, fn {name, node}, :ok ->
      case canonical_component(name, node) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, Error.prefix_path(error, [:components, name])}}
      end
    end)
  end

  defp canonical_components(_components) do
    {:error, Error.validation_error("Flow components must be a canonical component map")}
  end

  defp canonical_component(name, %{} = node) when is_binary(name) and not is_struct(node) do
    with {:ok, kind} <- canonical_kind(node),
         :ok <- exact_canonical_keys(node, Map.fetch!(@canonical_node_keys, kind), "component"),
         :ok <- canonical_common(node) do
      canonical_fields(kind, node)
    end
  end

  defp canonical_component(name, _node) when not is_binary(name) do
    {:error,
     Error.validation_error("canonical component names must be strings", %{
       reason: :invalid_component_name
     })}
  end

  defp canonical_component(_name, _node) do
    {:error,
     Error.validation_error("canonical Flow components must be maps", %{
       reason: :invalid_component_node
     })}
  end

  defp canonical_kind(%{kind: kind}) when is_map_key(@canonical_node_keys, kind), do: {:ok, kind}

  defp canonical_kind(%{kind: kind}) do
    {:error,
     Error.validation_error("canonical Flow component has an invalid kind", %{
       path: [:kind],
       kind: kind
     })}
  end

  defp canonical_kind(_node) do
    {:error,
     Error.validation_error("canonical Flow component kind is required", %{
       path: [:kind]
     })}
  end

  defp canonical_common(%{needs: needs, meta: meta}) do
    with :ok <- canonical_needs(needs),
         true <- is_map(meta) and not is_struct(meta) do
      :ok
    else
      false ->
        {:error,
         Error.validation_error("canonical component metadata must be a map", %{
           path: [:meta],
           reason: :invalid_metadata
         })}

      {:error, _error} = error ->
        error
    end
  end

  defp canonical_needs(needs) when is_list(needs) do
    cond do
      List.improper?(needs) ->
        {:error,
         Error.validation_error("canonical component needs must be a proper list", %{
           path: [:needs],
           reason: :improper_list
         })}

      Enum.all?(needs, &is_binary/1) ->
        :ok

      true ->
        {:error,
         Error.validation_error("canonical component needs must contain string names", %{
           path: [:needs],
           reason: :invalid_dependency_name
         })}
    end
  end

  defp canonical_needs(_needs) do
    {:error,
     Error.validation_error("canonical component needs must be a list", %{
       path: [:needs],
       reason: :invalid_dependencies
     })}
  end

  defp canonical_fields(:call, %{call: call}),
    do: canonical_call(call, [:action, :flow], [:call])

  defp canonical_fields(:choice, %{options: options, fallback: fallback}) do
    with :ok <- canonical_options(options) do
      canonical_call(fallback, [:action], [:fallback])
    end
  end

  defp canonical_fields(:map, %{call: call}),
    do: canonical_call(call, [:action], [:call])

  defp canonical_fields(:reduce, %{call: call}),
    do: canonical_call(call, [:action], [:call])

  defp canonical_fields(:iterate, %{call: call, state: state}) do
    with :ok <- canonical_call(call, [:action], [:call]) do
      canonical_state(state)
    end
  end

  defp canonical_fields(:dispatch, %{decision: decision, expander: expander}) do
    with :ok <- canonical_call(decision, [:action], [:decision]),
         :ok <- canonical_call(expander, [:action], [:expander]),
         {_template, nil} <- expander do
      :ok
    else
      {:error, _error} = error ->
        error

      {_template, _params} ->
        {:error,
         Error.validation_error("canonical Dispatch expander parameters must be nil", %{
           path: [:expander, 1],
           reason: :bound_expander_params
         })}
    end
  end

  defp canonical_options(options) when is_list(options) do
    if List.improper?(options) do
      {:error,
       Error.validation_error("canonical Choice options must be a proper list", %{
         path: [:options],
         reason: :improper_list
       })}
    else
      options
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {option, index}, :ok ->
        case canonical_option(option) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, Error.prefix_path(error, [:options, index])}}
        end
      end)
    end
  end

  defp canonical_options(_options) do
    {:error,
     Error.validation_error("canonical Choice options must be a list", %{
       path: [:options],
       reason: :invalid_options
     })}
  end

  defp canonical_option(%{} = option) when not is_struct(option) do
    with :ok <- exact_canonical_keys(option, @canonical_option_keys, "Choice option"),
         true <- is_binary(option.name),
         :ok <- canonical_call(option.call, [:action], [:call]) do
      :ok
    else
      false ->
        {:error,
         Error.validation_error("canonical Choice option name must be a string", %{
           path: [:name],
           reason: :invalid_option_name
         })}

      {:error, _error} = error ->
        error
    end
  end

  defp canonical_option(_option) do
    {:error,
     Error.validation_error("canonical Choice option must be a map", %{
       reason: :invalid_option
     })}
  end

  defp canonical_state(%{} = state) when not is_struct(state) do
    case exact_canonical_keys(state, @canonical_state_keys, "Iterate state") do
      :ok -> :ok
      {:error, error} -> {:error, Error.prefix_path(error, [:state])}
    end
  end

  defp canonical_state(_state) do
    {:error,
     Error.validation_error("canonical Iterate state must be a map", %{
       path: [:state],
       reason: :invalid_state
     })}
  end

  defp canonical_call({%Instruction{} = template, _params}, expected_kinds, path) do
    with :ok <- canonical_template(template, expected_kinds) do
      :ok
    else
      {:error, error} -> {:error, Error.prefix_path(error, path)}
    end
  end

  defp canonical_call(_call, _expected_kinds, path) do
    {:error,
     Error.validation_error("canonical Flow call must be an Instruction and value tuple", %{
       path: path,
       reason: :invalid_call
     })}
  end

  defp canonical_template(%Instruction{} = template, expected_kinds) do
    with :ok <- instruction_template(template) do
      cond do
        template.kind not in expected_kinds ->
          {:error,
           Error.validation_error("canonical Flow call has the wrong Instruction kind", %{
             expected: expected_kinds,
             actual: template.kind,
             reason: :invalid_instruction_kind
           })}

        template.metadata != %{} ->
          {:error,
           Error.validation_error("canonical Flow Instruction metadata must be empty", %{
             reason: :bound_metadata
           })}

        true ->
          :ok
      end
    end
  end

  defp instruction_template(template) do
    case Instruction.validate_template(template) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Error.validation_error("invalid canonical Flow Instruction template", %{
           reason: Map.get(Map.get(error, :details, %{}), :reason, :invalid_template),
           cause: error.__struct__
         })}
    end
  end

  defp exact_canonical_keys(map, allowed, label) do
    actual = Map.keys(map)
    missing = allowed -- actual
    unknown = actual -- allowed

    cond do
      unknown != [] ->
        key = Enum.min_by(unknown, &:erlang.term_to_binary/1)

        {:error,
         Error.validation_error("canonical #{label} contains an unknown field", %{
           path: [key],
           field: key,
           reason: :unknown_field
         })}

      missing != [] ->
        key = hd(missing)

        {:error,
         Error.validation_error("canonical #{label} field is required", %{
           path: [key],
           field: key,
           reason: :missing_field
         })}

      true ->
        :ok
    end
  end

  defp canonical_definitions(components) do
    components
    |> canonical_entries()
    |> Enum.map(&component_to_definition/1)
  end

  defp validate_canonical_definitions(attrs, definitions, components) do
    attrs
    |> Map.put(:components, definitions)
    |> validate()
    |> canonical_component_error_path(canonical_entries(components))
  end

  # Canonical entries are sorted for validation. Report the component name, not
  # that internal position.
  defp canonical_component_error_path(
         {:error, %{details: %{path: [:components, index | rest]} = details} = error},
         entries
       )
       when is_integer(index) do
    case Enum.fetch(entries, index) do
      {:ok, {name, _node}} ->
        {:error, %{error | details: %{details | path: [:components, name | rest]}}}

      :error ->
        {:error, error}
    end
  end

  defp canonical_component_error_path(result, _entries), do: result

  defp canonical_entries(components) do
    components
    |> Map.to_list()
    |> Enum.sort_by(fn {name, _node} -> :erlang.term_to_binary(name) end)
  end

  defp unchanged_canonical(attrs, attrs), do: :ok

  defp unchanged_canonical(attrs, normalized) do
    field =
      Enum.find(@artifact_config_keys, fn field ->
        Map.get(attrs, field, :__missing__) != Map.get(normalized, field, :__missing__)
      end)

    {:error,
     Error.validation_error("Flow artifact contains non-canonical data", %{
       path: if(field, do: [field], else: []),
       field: field,
       reason: :non_canonical
     })}
  end

  defp normalize_attrs(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs, @artifact_config_keys, "Flow configuration"),
         {:ok, name} <- flow_name(Map.get(attrs, :name)),
         {:ok, description} <- description(Map.get(attrs, :description)),
         {:ok, schema} <- schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <- schema(Map.get(attrs, :output_schema, []), "output_schema"),
         {:ok, components} <- components(Map.get(attrs, :components, [])),
         {:ok, output} <- output(Map.get(attrs, :output)) do
      {:ok,
       %{
         name: name,
         description: description,
         schema: schema,
         output_schema: output_schema,
         components: components,
         output: output
       }, components}
    end
  end

  defp normalize_attrs(_attrs),
    do: {:error, Error.validation_error("flow configuration must be a map")}

  defp components([]),
    do: {:error, Error.validation_error("Flow must declare at least one component")}

  defp components(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("flow components must be a proper list")}
    else
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
        case component(value) do
          {:ok, named} -> {:cont, {:ok, [named | acc]}}
          {:error, error} -> {:halt, {:error, Error.prefix_path(error, [:components, index])}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp components(_values), do: {:error, Error.validation_error("flow components must be a list")}

  defp normalize_component(:step, attrs) do
    with :ok <- known_component_keys(attrs, [:action, :params], "step"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "step action"),
         {:ok, params} <- params(attrs, :flow) do
      {:ok, {name, %{kind: :call, needs: needs, meta: meta, call: call(:action, action, params)}}}
    end
  end

  defp normalize_component(:subflow, attrs) do
    with :ok <- known_component_keys(attrs, [:flow, :params], "subflow"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, flow} <- module_atom(Map.get(attrs, :flow), "subflow module"),
         {:ok, params} <- params(attrs, :flow) do
      {:ok, {name, %{kind: :call, needs: needs, meta: meta, call: call(:flow, flow, params)}}}
    end
  end

  defp normalize_component(:choice, attrs) do
    with :ok <- known_component_keys(attrs, [:options, :fallback], "choice"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, options} <- choice_options(Map.get(attrs, :options)),
         {:ok, fallback} <- nested_field(choice_fallback(Map.get(attrs, :fallback)), :fallback) do
      {:ok,
       {name, %{kind: :choice, needs: needs, meta: meta, options: options, fallback: fallback}}}
    end
  end

  defp normalize_component(:map, attrs) do
    with :ok <- known_component_keys(attrs, [:collection, :action, :params, :on_error], "map"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, collection} <- required_value(attrs, :collection, :map_collection, "map"),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "map action"),
         {:ok, params} <- params(attrs, :map_params),
         {:ok, on_error} <- on_error(Map.get(attrs, :on_error, :fail_fast)) do
      {:ok,
       {name,
        %{
          kind: :map,
          needs: needs,
          meta: meta,
          collection: collection,
          call: call(:action, action, params),
          on_error: on_error
        }}}
    end
  end

  defp normalize_component(:reduce, attrs) do
    with :ok <- known_component_keys(attrs, [:collection, :initial, :action, :params], "reduce"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, collection} <- required_value(attrs, :collection, :reduce_collection, "reduce"),
         {:ok, initial} <- required_value(attrs, :initial, :reduce_initial, "reduce"),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "reduce action"),
         {:ok, params} <- params(attrs, :reduce_params) do
      {:ok,
       {name,
        %{
          kind: :reduce,
          needs: needs,
          meta: meta,
          collection: collection,
          initial: initial,
          call: call(:action, action, params)
        }}}
    end
  end

  defp normalize_component(:iterate, attrs) do
    with :ok <-
           known_component_keys(
             attrs,
             [:action, :params, :state, :completion, :max_iterations],
             "iterate"
           ),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "iterate action"),
         {:ok, params} <- params(attrs, :iterate_params),
         {:ok, state} <- nested_field(iterate_state(Map.get(attrs, :state)), :state),
         {:ok, completion} <-
           condition(Map.get(attrs, :completion), :completion, :iterate_completion),
         {:ok, maximum} <- maximum_iterations(Map.get(attrs, :max_iterations)) do
      {:ok,
       {name,
        %{
          kind: :iterate,
          needs: needs,
          meta: meta,
          call: call(:action, action, params),
          state: state,
          completion: completion,
          max_iterations: maximum
        }}}
    end
  end

  defp normalize_component(:dispatch, attrs) do
    with :ok <- known_component_keys(attrs, [:decision, :expander, :params], "dispatch"),
         {:ok, name, needs, meta} <- common(attrs),
         {:ok, decision} <- module_atom(Map.get(attrs, :decision), "dispatch decision"),
         {:ok, expander} <- module_atom(Map.get(attrs, :expander), "dispatch expander"),
         {:ok, params} <- params(attrs, :flow) do
      {:ok,
       {name,
        %{
          kind: :dispatch,
          needs: needs,
          meta: meta,
          decision: call(:action, decision, params),
          expander: call(:action, expander, nil)
        }}}
    end
  end

  defp normalize_component(_kind, attrs) do
    {:error, Error.validation_error("expected a supported Flow component kind", %{value: attrs})}
  end

  defp common(attrs) do
    with {:ok, name} <- component_name(Map.get(attrs, :name)),
         {:ok, needs} <- needs_names(Map.get(attrs, :needs, [])),
         {:ok, meta} <- meta(Map.get(attrs, :meta, %{})) do
      {:ok, name, needs, meta}
    end
  end

  defp choice_options([]),
    do: {:error, Error.validation_error("choice must contain at least one option")}

  defp choice_options(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("choice options must be a proper list")}
    else
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
        case choice_option(value) do
          {:ok, option} -> {:cont, {:ok, [option | acc]}}
          {:error, error} -> {:halt, {:error, Error.prefix_path(error, [:options, index])}}
        end
      end)
      |> reverse_choice_options()
    end
  end

  defp choice_options(_values),
    do: {:error, Error.validation_error("choice options must be a list")}

  @doc false
  @spec choice_option(term()) :: {:ok, choice_option()} | {:error, Exception.t()}
  def choice_option(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs, [:name, :condition, :action, :params], "choice option"),
         {:ok, name} <- name(Map.get(attrs, :name), "choice option"),
         {:ok, condition} <- condition(Map.get(attrs, :condition), :condition, :flow),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "choice option action"),
         {:ok, params} <- params(attrs, :flow) do
      {:ok, %{name: name, condition: condition, call: call(:action, action, params)}}
    end
  end

  def choice_option(_value), do: {:error, Error.validation_error("choice option must be a map")}

  @doc false
  @spec choice_fallback(term()) :: {:ok, call()} | {:error, Exception.t()}
  def choice_fallback(nil),
    do: {:error, Error.validation_error("choice fallback is required")}

  def choice_fallback(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs, [:action, :params], "choice fallback"),
         {:ok, action} <- module_atom(Map.get(attrs, :action), "choice fallback action"),
         {:ok, params} <- params(attrs, :flow) do
      {:ok, call(:action, action, params)}
    end
  end

  def choice_fallback(_value),
    do: {:error, Error.validation_error("choice fallback must be a map")}

  defp nested_field({:ok, value}, _field), do: {:ok, value}
  defp nested_field({:error, error}, field), do: {:error, Error.prefix_path(error, [field])}

  @doc false
  @spec iterate_state(term()) :: {:ok, map()} | {:error, Exception.t()}
  def iterate_state(nil), do: {:error, Error.validation_error("iterate state is required")}

  def iterate_state(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs, [:schema, :initial, :update], "iterate state"),
         {:ok, schema} <-
           nested_field(schema(Map.get(attrs, :schema, []), "iterate state schema"), :schema),
         {:ok, initial} <- required_value(attrs, :initial, :iterate_initial, "iterate state"),
         {:ok, update} <- required_value(attrs, :update, :iterate_update, "iterate state") do
      {:ok, %{schema: schema, initial: initial, update: update}}
    end
  end

  def iterate_state(_value),
    do: {:error, Error.validation_error("iterate state must be a map")}

  defp reverse_choice_options({:ok, reversed}) do
    options = Enum.reverse(reversed)
    names = Enum.map(options, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        {:ok, options}

      [name | _rest] ->
        {:error,
         Error.validation_error("choice option names must be unique", %{
           name: name,
           path: [:options]
         })}
    end
  end

  defp reverse_choice_options(error), do: error

  defp call(kind, target, params),
    do: {Instruction.template(kind, target), params}

  defp fallback_call({instruction, params}), do: {:fallback, instruction, params}

  defp params(attrs, scope) do
    case Map.get(attrs, :params) do
      nil -> {:ok, %{}}
      value -> prepare_value(value, :params, scope)
    end
  end

  defp required_value(attrs, field, scope, owner) do
    if Map.has_key?(attrs, field) do
      prepare_value(Map.fetch!(attrs, field), field, scope)
    else
      {:error, Error.validation_error("#{owner} #{field} is required", %{path: [field]})}
    end
  end

  defp prepare_value(value, field, scope) do
    case Value.prepare(value, scope) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Error.prefix_path(error, [field])}
    end
  end

  defp condition(value, field, scope) do
    case Value.condition(value, scope) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Error.prefix_path(error, [field])}
    end
  end

  defp maximum_iterations(value)
       when is_integer(value) and value >= 1 and value <= @maximum_iterations,
       do: {:ok, value}

  defp maximum_iterations(_value),
    do:
      {:error,
       Error.validation_error("iterate max_iterations must be from 1 to 10000", %{
         path: [:max_iterations]
       })}

  defp on_error(value) when value in [:fail_fast, :collect_errors], do: {:ok, value}

  defp on_error(value) do
    {:error,
     Error.validation_error("map on_error must be :fail_fast or :collect_errors", %{
       path: [:on_error],
       on_error: value
     })}
  end

  defp component_name(value) do
    with {:error, error} <- name(value, "component"),
         do: {:error, Error.prefix_path(error, [:name])}
  end

  defp name(value, _owner) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> name("component")

  defp name(value, owner) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message, %{owner: owner})}
    end
  end

  defp name(_value, owner),
    do: {:error, Error.validation_error("#{owner} name must be a non-empty string")}

  defp flow_name(value) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp flow_name(_value), do: {:error, Error.validation_error("flow name must be a string")}

  defp needs_names(nil), do: {:ok, []}

  defp needs_names(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("component needs must be a proper list")}
    else
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, names} ->
        case name(value, "component") do
          {:ok, name} ->
            {:cont, {:ok, [name | names]}}

          {:error, _error} ->
            {:halt,
             {:error, Error.validation_error("component needs must contain component names")}}
        end
      end)
      |> reject_duplicate_needs()
    end
  end

  defp needs_names(_values),
    do: {:error, Error.validation_error("component needs must be a list")}

  defp reject_duplicate_needs({:ok, reversed}) do
    names = Enum.reverse(reversed)

    case names -- Enum.uniq(names) do
      [] ->
        {:ok, names}

      [name | _rest] ->
        {:error,
         Error.validation_error("component needs contains a duplicate", %{
           name: name,
           path: [:needs]
         })}
    end
  end

  defp reject_duplicate_needs(error), do: error

  defp meta(nil), do: {:ok, %{}}

  defp meta(value) do
    case Value.validate_object(value) do
      :ok -> {:ok, value}
      {:error, error} -> {:error, error}
    end
  end

  defp module_atom(value, _label) when is_atom(value) and not is_nil(value), do: {:ok, value}

  defp module_atom(_value, label),
    do: {:error, Error.validation_error("#{label} must be a module atom")}

  defp description(nil), do: {:ok, nil}

  defp description(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, Error.validation_error("flow description must be valid UTF-8")}
  end

  defp description(_value),
    do: {:error, Error.validation_error("flow description must be a string")}

  defp schema(nil, _field), do: {:ok, []}

  defp schema(value, field) do
    with :ok <- static_schema(value),
         :ok <- Action.validate_map_schema(value) do
      {:ok, value}
    else
      {:error, message} ->
        {:error, Error.validation_error("#{field} #{message}", %{field: field})}
    end
  end

  defp static_schema(value) do
    case Action.validate_static_data(value) do
      :ok -> :ok
      {:error, message} -> {:error, "must be static module data; #{message}"}
    end
  end

  defp output(nil), do: {:ok, nil}
  defp output(value), do: Value.prepare(value)

  defp known_component_keys(attrs, specific, label),
    do: known_keys(attrs, @common_keys ++ specific, label)

  defp known_keys(attrs, allowed, label) do
    case Enum.reject(Map.keys(attrs), &(&1 in allowed)) do
      [] ->
        :ok

      [key | _rest] ->
        {:error, Error.validation_error("unknown #{label} key: #{inspect(key)}", %{key: key})}
    end
  end

  defp output_issues(nil) do
    [
      issue(
        :output_required,
        Error.validation_error("Flow output is required", %{path: [:output]}),
        [:output]
      )
    ]
  end

  defp output_issues(_output), do: []

  defp graph_issues(named_components, output) do
    {known, duplicates} = duplicate_name_issues(named_components)
    references = unknown_dependency_issues(named_components, output, known)

    case duplicates ++ references do
      [] ->
        components = Map.new(named_components)

        case Graph.analyze(components) do
          %{remaining: []} ->
            dispatch_issues(named_components, output)

          %{remaining: names} ->
            [
              issue(
                :cycle,
                Error.validation_error("flow dependency graph contains a cycle", %{
                  components: names
                }),
                [:components]
              )
            ]
        end

      issues ->
        issues
    end
  end

  defp duplicate_name_issues(named_components) do
    {known, issues} =
      named_components
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {{name, _node}, index}, {known, issues} ->
        if MapSet.member?(known, name) do
          error = Error.validation_error("duplicate component name", %{name: name})
          {known, [issue(:duplicate_name, error, [:components, index, :name]) | issues]}
        else
          {MapSet.put(known, name), issues}
        end
      end)

    {known, Enum.reverse(issues)}
  end

  defp unknown_dependency_issues(named_components, output, known) do
    output_issues = unknown_refs(Value.result_refs(output), known, :output, [:output])

    component_issues =
      named_components
      |> Enum.with_index()
      |> Enum.flat_map(fn {{name, node}, index} ->
        unknown_refs(needs(node) ++ reference_dependencies(node), known, name, [
          :components,
          index
        ])
      end)

    output_issues ++ component_issues
  end

  defp unknown_refs(names, known, owner, location) do
    names
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.map(fn name ->
      error =
        Error.validation_error("Flow reference points to an unknown component", %{
          owner: owner,
          component: name
        })

      issue(:unknown_dependency, error, location)
    end)
  end

  defp dispatch_issues(named_components, output) do
    dispatches =
      named_components
      |> Enum.with_index()
      |> Enum.filter(fn {{_name, node}, _index} -> node.kind == :dispatch end)

    errors =
      case dispatches do
        [] ->
          []

        [{{name, _node}, index}] ->
          dispatch_sink_errors(named_components, name, index) ++
            dispatch_output_errors(output, name)

        [_first, {{name, _node}, index} | _rest] ->
          [
            Error.validation_error("Flow can contain only one Dispatch component", %{
              component: name,
              components:
                Enum.map(dispatches, fn {{dispatch_name, _node}, _index} -> dispatch_name end),
              path: [:components, index]
            })
          ]
      end

    Enum.map(errors, &issue(:dispatch, &1, &1.details.path))
  end

  defp dispatch_sink_errors(named_components, dispatch_name, dispatch_index) do
    dependencies =
      named_components
      |> Enum.flat_map(fn {_name, node} -> effective_dependencies(node) end)
      |> MapSet.new()

    sinks =
      named_components
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&MapSet.member?(dependencies, &1))
      |> Enum.sort()

    if sinks == [dispatch_name] do
      []
    else
      [
        Error.validation_error("Dispatch must be the final component in the Flow", %{
          component: dispatch_name,
          dispatch: dispatch_name,
          terminal_components: sinks,
          path: [:components, dispatch_index]
        })
      ]
    end
  end

  defp dispatch_output_errors(%Ref{source: :result, component: name, path: []}, name), do: []

  defp dispatch_output_errors(_output, name) do
    [
      Error.validation_error("Flow output must be the complete Dispatch result", %{
        dispatch: name,
        path: [:output]
      })
    ]
  end

  defp common_definition(name, node),
    do: %{name: name, needs: node.needs, meta: node.meta}

  defp issue(kind, error, location), do: %{kind: kind, error: error, location: location}

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
end
