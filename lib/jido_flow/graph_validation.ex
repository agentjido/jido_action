defmodule Jido.Flow.GraphValidation do
  @moduledoc false

  alias Jido.Flow.{Definition, Error, Graph, Ref, Value}

  @doc false
  @spec diagnose([Definition.named_component()], Value.t()) :: [Definition.issue()]
  def diagnose(components, output), do: output_issues(output) ++ graph_issues(components, output)

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
        unknown_refs(
          Definition.needs(node) ++ Definition.reference_dependencies(node),
          known,
          name,
          [
            :components,
            index
          ]
        )
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
      |> Enum.flat_map(fn {_name, node} -> Definition.effective_dependencies(node) end)
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

  defp issue(kind, error, location), do: %{kind: kind, error: error, location: location}
end
