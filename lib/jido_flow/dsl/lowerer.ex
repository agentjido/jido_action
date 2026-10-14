defmodule Jido.Flow.DSL.Lowerer do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Definition
  alias Jido.Expr
  alias Jido.Flow.Error
  alias Jido.Flow.Ref

  @maximum_iterations Jido.Flow.Component.maximum_iterations()

  alias Jido.Flow.DSL.{
    Choice,
    ChoiceOption,
    Dispatch,
    ValueParser,
    Iterate,
    MapNode,
    Otherwise,
    Output,
    Reduce,
    Step
  }

  @doc "Lowers the Spark entities for one module into a canonical Flow."
  @spec lower(module(), map()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def lower(module, config) do
    entities = Spark.Dsl.Extension.get_entities(module, [:flow])

    with :ok <- validate_output_position(entities),
         {:ok, components, output} <- lower_entities(entities) do
      case Definition.diagnose_body(config, components, output) do
        {:ok, attrs} ->
          {:ok, struct!(Flow, attrs)}

        {:error, [issue | _rest]} ->
          {:error, Jido.Flow.DSL.SourceMap.attach_issue(issue, entities)}
      end
    end
  end

  @doc false
  @spec source_map(module(), String.t() | nil) :: map()
  def source_map(module, default_file \\ nil),
    do: Jido.Flow.DSL.SourceMap.from_module(module, default_file)

  defp lower_entities(entities) do
    entities
    |> Enum.reduce_while({:ok, [], :missing}, fn entity, {:ok, specs, output} ->
      case lower_entity(entity) do
        {:ok, {:component, component}} -> {:cont, {:ok, [component | specs], output}}
        {:ok, {:output, expression}} -> {:cont, {:ok, specs, {:present, expression}}}
        {:error, error} -> {:halt, {:error, Jido.Flow.DSL.SourceMap.attach_entity(error, entity)}}
      end
    end)
    |> reverse_lowered_entities()
  end

  defp lower_entity(%Step{} = step) do
    with {:ok, params} <- ValueParser.parse(step.params),
         {:ok, component} <- step_component(step, params) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%Choice{} = choice) do
    with {:ok, options} <- lower_choice_options(choice.options),
         {:ok, fallback} <- lower_fallback(choice.fallback) do
      {:ok,
       {:component,
        %{
          kind: :choice,
          name: choice.name,
          options: options,
          fallback: fallback,
          needs: choice.needs,
          meta: choice.meta
        }}}
    end
  end

  defp lower_entity(%MapNode{} = map) do
    with {:ok, collection} <- ValueParser.parse(map.collection),
         {:ok, params} <- ValueParser.parse(map.params) do
      {:ok,
       {:component,
        %{
          kind: :map,
          name: map.name,
          collection: collection,
          call: %{kind: :action, target: map.action, params: params},
          on_error: map.on_error,
          needs: map.needs,
          meta: map.meta
        }}}
    end
  end

  defp lower_entity(%Reduce{} = reduce) do
    with {:ok, collection} <- ValueParser.parse(reduce.collection),
         {:ok, initial} <- ValueParser.parse(reduce.initial),
         {:ok, params} <- ValueParser.parse(reduce.params) do
      {:ok,
       {:component,
        %{
          kind: :reduce,
          name: reduce.name,
          collection: collection,
          initial: initial,
          call: %{kind: :action, target: reduce.action, params: params},
          needs: reduce.needs,
          meta: reduce.meta
        }}}
    end
  end

  defp lower_entity(%Iterate{} = iterate) do
    with {:ok, state} <- lower_iterate_state(iterate.state),
         {:ok, params} <- ValueParser.parse(iterate.params),
         {:ok, update} <- optional_expression(iterate.update, Ref.body_result()),
         {:ok, while_condition} <- optional_condition(iterate.while),
         {:ok, completion, max_iterations} <-
           normalize_termination(iterate, while_condition) do
      {:ok,
       {:component,
        %{
          kind: :iterate,
          name: iterate.name,
          call: %{kind: :action, target: iterate.action, params: params},
          state: Map.put(state, :update, update),
          completion: completion,
          max_iterations: max_iterations,
          needs: iterate.needs,
          meta: iterate.meta
        }}}
    end
  end

  defp lower_entity(%Dispatch{} = dispatch) do
    with {:ok, params} <- ValueParser.parse(dispatch.params) do
      {:ok,
       {:component,
        %{
          kind: :dispatch,
          name: dispatch.name,
          decision: %{kind: :action, target: dispatch.decision, params: params},
          expander: %{kind: :action, target: dispatch.expander},
          needs: dispatch.needs,
          meta: dispatch.meta
        }}}
    end
  end

  defp lower_entity(%Output{} = output) do
    with {:ok, expression} <- ValueParser.parse(output.value) do
      {:ok, {:output, expression}}
    end
  end

  defp step_component(step, params) do
    with {:module, _module} <- Code.ensure_compiled(step.action),
         {:ok, kind} <- Jido.Instruction.target_kind(step.action) do
      {:ok,
       %{
         kind: :call,
         name: step.name,
         call: %{kind: kind, target: step.action, params: params},
         needs: step.needs,
         meta: step.meta
       }}
    else
      {:error, error} when is_exception(error) ->
        details = error |> Map.get(:details, %{}) |> Map.put(:cause, error.__struct__)
        {:error, Error.validation_error(Exception.message(error), details)}

      {:error, reason} ->
        {:error,
         Error.validation_error("step action module could not be compiled", %{
           action: step.action,
           reason: reason
         })}
    end
  end

  defp lower_choice_options([]) do
    {:error, Error.validation_error("choice must declare at least one option")}
  end

  defp lower_choice_options(options) do
    options
    |> Enum.reduce_while({:ok, []}, fn %ChoiceOption{} = option, {:ok, lowered} ->
      with {:ok, condition} <- ValueParser.parse_condition(option.condition),
           {:ok, input} <- ValueParser.parse(option.params) do
        value = %{
          name: option.name,
          condition: condition,
          call: %{kind: :action, target: option.action, params: input}
        }

        {:cont, {:ok, [value | lowered]}}
      else
        {:error, error} -> {:halt, {:error, Jido.Flow.DSL.SourceMap.attach_entity(error, option)}}
      end
    end)
    |> reverse_ok()
  end

  defp lower_fallback(%Otherwise{} = fallback) do
    with {:ok, input} <- ValueParser.parse(fallback.params) do
      {:ok, %{kind: :action, target: fallback.action, params: input}}
    else
      {:error, error} -> {:error, Jido.Flow.DSL.SourceMap.attach_entity(error, fallback)}
    end
  end

  defp lower_fallback(nil), do: {:error, Error.validation_error("choice must declare otherwise")}

  defp lower_iterate_state(nil) do
    {:error, Error.validation_error("iterate must declare one state")}
  end

  defp lower_iterate_state(state) do
    with {:ok, initial} <- ValueParser.parse(state.initial) do
      {:ok, %{schema: state.schema, initial: initial}}
    else
      {:error, error} -> {:error, Jido.Flow.DSL.SourceMap.attach_entity(error, state)}
    end
  end

  defp optional_expression(nil, default), do: {:ok, default}
  defp optional_expression(expression, _default), do: ValueParser.parse(expression)

  defp optional_condition(nil), do: {:ok, nil}
  defp optional_condition(condition), do: ValueParser.parse_condition(condition)

  defp normalize_termination(iterate, while_condition) do
    case {while_condition, iterate.repeat, iterate.max_iterations} do
      {condition, nil, maximum}
      when not is_nil(condition) and is_integer(maximum) and maximum in 1..@maximum_iterations ->
        {:ok, Expr.new!(:not, [condition]), maximum}

      {nil, count, nil} when is_integer(count) and count in 1..@maximum_iterations ->
        {:ok, Expr.new!(:>=, [Ref.iteration_index(), count]), count}

      {condition, nil, _maximum} when not is_nil(condition) ->
        {:error,
         Error.validation_error("iterate max_iterations must be an integer from 1 to 10000")}

      {nil, count, nil} when not is_nil(count) ->
        {:error, Error.validation_error("iterate repeat must be an integer from 1 to 10000")}

      {nil, _count, maximum} when not is_nil(maximum) ->
        {:error, Error.validation_error("iterate repeat must not set max_iterations")}

      _other ->
        {:error, Error.validation_error("iterate requires exactly one of while or repeat")}
    end
  end

  defp validate_output_position(entities) do
    case Enum.find_index(entities, &match?(%Output{}, &1)) do
      nil ->
        :ok

      index when index == length(entities) - 1 ->
        :ok

      index ->
        error = Error.validation_error("output must be the final Flow declaration")
        {:error, Jido.Flow.DSL.SourceMap.attach_entity(error, Enum.at(entities, index))}
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}

  defp reverse_lowered_entities({:ok, _specs, :missing}),
    do: {:error, Error.validation_error("Flow output is required")}

  defp reverse_lowered_entities({:ok, specs, {:present, output}}),
    do: {:ok, Enum.reverse(specs), output}

  defp reverse_lowered_entities({:error, error}), do: {:error, error}
end
