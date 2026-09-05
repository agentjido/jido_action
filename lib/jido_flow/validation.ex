defmodule Jido.Flow.Validation do
  @moduledoc false

  alias Jido.Action
  alias Jido.Executable
  alias Jido.Flow.Component
  alias Jido.Flow.Choice
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Expression
  alias Jido.Flow.Error
  alias Jido.Flow.Graph
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias Jido.Flow.Ref

  @module_config_keys [:name, :description, :schema, :output_schema]
  @artifact_config_keys @module_config_keys ++ [:components, :output]

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
  @spec validate(map() | keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def validate(attrs) do
    case diagnose(attrs) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, [issue | _rest]} -> {:error, issue.error}
    end
  end

  @doc false
  @spec diagnose(map() | keyword()) :: {:ok, map()} | {:error, [issue()]}
  def diagnose(attrs) do
    case normalize_attrs(attrs) do
      {:ok, attrs} ->
        issues = output_issues(attrs.output) ++ graph_issues(attrs.components, attrs.output)
        if issues == [], do: {:ok, attrs}, else: {:error, issues}

      {:error, error} ->
        {:error, [issue(:definition, error, Map.get(error.details, :path, []))]}
    end
  end

  @doc false
  @spec validate_executable(map() | keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_executable(attrs) do
    with {:ok, flow, _subflows} <- prepare_executable(attrs) do
      {:ok, flow}
    end
  end

  @doc false
  @spec prepare_executable(map() | keyword(), [module()]) ::
          {:ok, map(), %{optional(module()) => Jido.Flow.t()}} | {:error, Exception.t()}
  def prepare_executable(attrs, module_stack \\ []) do
    with {:ok, flow} <- validate(attrs),
         {:ok, subflows} <- validate_component_targets(flow.components, module_stack, %{}) do
      {:ok, flow, subflows}
    end
  end

  @doc false
  @spec validate_config(term()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_config(%{} = attrs) do
    with :ok <- known_keys(attrs, @module_config_keys),
         {:ok, name} <- name(Map.get(attrs, :name)),
         {:ok, description} <- description(Map.get(attrs, :description)),
         {:ok, schema} <- schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <- schema(Map.get(attrs, :output_schema, []), "output_schema") do
      {:ok, %{name: name, description: description, schema: schema, output_schema: output_schema}}
    end
  end

  def validate_config(_attrs),
    do: {:error, Error.validation_error("flow configuration must be a map")}

  @doc false
  @spec invalid_subject(term()) :: {:error, Exception.t()}
  def invalid_subject(value),
    do: {:error, Error.validation_error("expected a Jido.Flow artifact", %{value: value})}

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> normalize_attrs(),
      else: {:error, Error.validation_error("flow configuration must be a map")}
  end

  defp normalize_attrs(%{} = attrs) do
    with :ok <- known_keys(attrs, @artifact_config_keys),
         {:ok, name} <- name(Map.get(attrs, :name)),
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
       }}
    end
  end

  defp normalize_attrs(_attrs),
    do: {:error, Error.validation_error("flow configuration must be a map")}

  defp known_keys(attrs, allowed) do
    case Enum.find(Map.keys(attrs), &(&1 not in allowed)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown Flow configuration key: #{inspect(key)}", %{key: key})}
    end
  end

  defp name(value) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp name(_value), do: {:error, Error.validation_error("flow name must be a string")}

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
         :ok <- Action.validate_action_schema(value) do
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

  defp components([]),
    do: {:error, Error.validation_error("Flow must declare at least one component")}

  defp components(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("flow components must be a proper list")}
    else
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
        case Component.new(value) do
          {:ok, component} -> {:cont, {:ok, [component | acc]}}
          {:error, error} -> {:halt, {:error, prefix(error, [:components, index])}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp components(_values), do: {:error, Error.validation_error("flow components must be a list")}

  defp output(nil), do: {:ok, nil}

  defp output(value) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value) do
      {:ok, value}
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

  defp graph_issues(components, output) do
    {known, duplicates} = duplicate_name_issues(components)
    references = unknown_dependency_issues(components, output, known)

    case duplicates ++ references do
      [] ->
        case Graph.analyze(components) do
          %{remaining: []} ->
            dispatch_issues(components, output)

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

  defp duplicate_name_issues(components) do
    {known, issues} =
      components
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {component, index}, {known, issues} ->
        name = Component.name_of(component)

        if MapSet.member?(known, name) do
          error = Error.validation_error("duplicate component name", %{name: name})
          {known, [issue(:duplicate_name, error, [:components, index, :name]) | issues]}
        else
          {MapSet.put(known, name), issues}
        end
      end)

    {known, Enum.reverse(issues)}
  end

  defp unknown_dependency_issues(components, output, known) do
    output_issues = unknown_refs(Expression.result_refs(output), known, :output, [:output])

    component_issues =
      components
      |> Enum.with_index()
      |> Enum.flat_map(fn {component, index} ->
        # Preserve the canonical first-error order. Codec sorts each component's
        # missing dependencies when it presents the same issues as JSON errors.
        names = Component.after_of(component) ++ Component.reference_dependencies(component)
        unknown_refs(names, known, Component.name_of(component), [:components, index])
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

  defp issue(kind, error, location), do: %{kind: kind, error: error, location: location}

  defp dispatch_issues(components, output) do
    components
    |> dispatch_errors(output)
    |> Enum.map(&issue(:dispatch, &1, &1.details.path))
  end

  defp dispatch_errors(components, output) do
    dispatches =
      components
      |> Enum.with_index()
      |> Enum.filter(fn {component, _index} -> match?(%Dispatch{}, component) end)

    case dispatches do
      [] ->
        []

      [{%Dispatch{name: name}, index}] ->
        dispatch_sink_errors(components, name, index) ++ dispatch_output_errors(output, name)

      [_first, {%Dispatch{} = second, index} | _rest] ->
        [
          Error.validation_error("Flow can contain only one Dispatch component", %{
            component: second.name,
            components: Enum.map(dispatches, fn {%Dispatch{name: name}, _index} -> name end),
            path: [:components, index]
          })
        ]
    end
  end

  defp dispatch_sink_errors(components, dispatch_name, dispatch_index) do
    dependencies =
      components
      |> Enum.flat_map(&Component.effective_dependencies/1)
      |> MapSet.new()

    sinks =
      components
      |> Enum.map(&Component.name_of/1)
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

  defp dispatch_output_errors(
         %Ref{source: :result, component: dispatch_name, path: []},
         dispatch_name
       ),
       do: []

  defp dispatch_output_errors(_output, dispatch_name) do
    [
      Error.validation_error("Flow output must be the complete Dispatch result", %{
        dispatch: dispatch_name,
        path: [:output]
      })
    ]
  end

  defp validate_component_targets(components, module_stack, subflows) do
    Enum.reduce_while(components, {:ok, subflows}, fn component, {:ok, subflows} ->
      case validate_target(component, module_stack, subflows) do
        {:ok, subflows} -> {:cont, {:ok, subflows}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_target(%Step{name: name, action: action}, _module_stack, subflows) do
    with {:ok, executable} <- Executable.resolve(action),
         :ok <- require_kind(executable, :action, name),
         :ok <- Executable.validate(executable) do
      {:ok, subflows}
    else
      {:error, error} -> {:error, target_error(error, name, :action)}
    end
  end

  defp validate_target(%Subflow{name: name, flow: flow}, module_stack, subflows) do
    with {:ok, executable} <- Executable.resolve(flow),
         :ok <- require_kind(executable, :flow, name),
         :ok <- Executable.validate(executable),
         :ok <- reject_recursive_subflow(flow, module_stack),
         {:ok, subflows} <- materialize_subflow(flow, module_stack, subflows) do
      {:ok, subflows}
    else
      {:error, error} -> {:error, target_error(error, name, :flow)}
    end
  end

  defp validate_target(%Choice{} = choice, _module_stack, subflows) do
    targets =
      Enum.map(choice.options, &{&1.name, &1.action}) ++ [{:fallback, choice.fallback.action}]

    validate_action_targets(targets, choice.name, subflows)
  end

  defp validate_target(%FlowMap{name: name, action: action}, _module_stack, subflows),
    do: validate_action_targets([{:action, action}], name, subflows)

  defp validate_target(%Reduce{name: name, action: action}, _module_stack, subflows),
    do: validate_action_targets([{:action, action}], name, subflows)

  defp validate_target(%Iterate{name: name, action: action}, _module_stack, subflows),
    do: validate_action_targets([{:action, action}], name, subflows)

  defp validate_target(
         %Dispatch{name: name, decision: decision, expander: expander},
         _module_stack,
         subflows
       ) do
    validate_action_targets([{:decision, decision}, {:expander, expander}], name, subflows)
  end

  defp validate_action_targets(targets, component, subflows) do
    Enum.reduce_while(targets, {:ok, subflows}, fn {field, target}, {:ok, subflows} ->
      with {:ok, executable} <- Executable.resolve(target),
           :ok <- require_kind(executable, :action, component),
           :ok <- Executable.validate(executable) do
        {:cont, {:ok, subflows}}
      else
        {:error, error} ->
          {:halt, {:error, target_error(error, component, field)}}
      end
    end)
  end

  defp materialize_subflow(module, module_stack, subflows) do
    case Map.fetch(subflows, module) do
      {:ok, _flow} ->
        {:ok, subflows}

      :error ->
        with {:ok, child} <- load_child_flow(module),
             {:ok, child} <- validate(Map.from_struct(child)),
             :ok <- reject_dispatch_subflow(child, module),
             {:ok, subflows} <-
               validate_component_targets(child.components, [module | module_stack], subflows) do
          {:ok, Map.put(subflows, module, struct!(Jido.Flow, child))}
        end
    end
  end

  defp reject_dispatch_subflow(%{components: components}, module) do
    if Enum.any?(components, &match?(%Dispatch{}, &1)) do
      {:error,
       Error.validation_error("a Flow with Dispatch cannot be used as a Subflow", %{flow: module})}
    else
      :ok
    end
  end

  defp reject_recursive_subflow(flow, module_stack) do
    if flow in module_stack do
      {:error,
       Error.validation_error("recursive Subflow module cycle", %{
         flow: flow,
         module_stack: Enum.reverse([flow | module_stack])
       })}
    else
      :ok
    end
  end

  defp load_child_flow(module) do
    case module.flow() do
      %Jido.Flow{} = flow ->
        {:ok, flow}

      value ->
        {:error,
         Error.validation_error("Subflow flow/0 must return a Jido.Flow", %{value: value})}
    end
  rescue
    error -> {:error, Error.validation_error("Subflow flow/0 failed", %{error: error})}
  catch
    kind, reason ->
      {:error, Error.validation_error("Subflow flow/0 failed", %{kind: kind, reason: reason})}
  end

  defp target_error(error, component, field) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{component: component, field: field, cause: error.__struct__})

    Error.validation_error(Exception.message(error), details)
  end

  defp require_kind(%Executable{kind: kind}, kind, _name), do: :ok

  defp require_kind(%Executable{kind: actual}, expected, name) do
    {:error,
     Error.validation_error("Flow component has the wrong executable kind", %{
       component: name,
       expected: expected,
       actual: actual
     })}
  end

  defp prefix(%{details: details} = error, path) when is_map(details),
    do: %{error | details: Map.put(details, :path, path ++ Map.get(details, :path, []))}

  defp prefix(error, _path), do: error

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
end
