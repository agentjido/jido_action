defmodule Jido.Flow.DSL.Lowerer do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Condition
  alias Jido.Flow.Error
  alias Jido.Flow.Ref
  alias Jido.Flow.Step, as: FlowStep
  alias Jido.Flow.Subflow
  alias Jido.Flow.Choice, as: FlowChoice
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce, as: FlowReduce
  alias Jido.Flow.Iterate, as: FlowIterate
  alias Jido.Flow.Dispatch, as: FlowDispatch

  @maximum_iterations 10_000

  alias Jido.Flow.DSL.{
    Choice,
    ChoiceOption,
    Dispatch,
    Expression,
    Iterate,
    MapNode,
    Otherwise,
    Output,
    Reduce,
    Step
  }

  @doc "Lowers the Spark entities for one module into a canonical Flow."
  @spec lower(module(), keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def lower(module, opts) do
    entities = Spark.Dsl.Extension.get_entities(module, [:flow])

    with :ok <- validate_output_position(entities),
         {:ok, components, output} <- lower_entities(entities) do
      Flow.new(%{
        name: Keyword.fetch!(opts, :name),
        description: Keyword.get(opts, :description),
        schema: Keyword.get(opts, :schema, []),
        output_schema: Keyword.get(opts, :output_schema, []),
        components: components,
        output: output
      })
    end
  end

  @doc false
  @spec source_map(module(), String.t() | nil) :: map()
  def source_map(module, default_file \\ nil) do
    module
    |> Spark.Dsl.Extension.get_entities([:flow])
    |> Enum.reduce(%{}, &put_source/2)
    |> Map.new(fn {path, location} ->
      location =
        if is_binary(default_file), do: Map.put_new(location, :file, default_file), else: location

      {path, location}
    end)
  end

  defp lower_entities(entities) do
    entities
    |> Enum.reduce_while({:ok, [], nil}, fn entity, {:ok, specs, return} ->
      case lower_entity(entity) do
        {:ok, {:component, component}} -> {:cont, {:ok, [component | specs], return}}
        {:ok, {:output, expression}} -> {:cont, {:ok, specs, expression}}
        {:error, error} -> {:halt, {:error, attach_entity_location(error, entity)}}
      end
    end)
    |> reverse_lowered_entities()
  end

  defp lower_entity(%Step{} = step) do
    with {:ok, params} <- Expression.parse(step.params),
         {:ok, after_names} <- normalize_after(step.after),
         {:ok, component} <- step_component(step, params, after_names) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%Choice{} = choice) do
    with {:ok, options} <- lower_choice_options(choice.options),
         {:ok, fallback} <- lower_fallback(choice.fallback),
         {:ok, after_names} <- normalize_after(choice.after),
         {:ok, component} <-
           FlowChoice.new(
             name: choice.name,
             options: options,
             fallback: fallback,
             after: after_names,
             meta: choice.meta
           ) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%MapNode{} = map) do
    with {:ok, collection} <- Expression.parse(map.collection),
         {:ok, params} <- Expression.parse(map.params),
         {:ok, after_names} <- normalize_after(map.after),
         {:ok, component} <-
           FlowMap.new(
             name: map.name,
             collection: collection,
             action: map.action,
             params: params,
             on_error: map.on_error,
             after: after_names,
             meta: map.meta
           ) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%Reduce{} = reduce) do
    with {:ok, collection} <- Expression.parse(reduce.collection),
         {:ok, initial} <- Expression.parse(reduce.initial),
         {:ok, params} <- Expression.parse(reduce.params),
         {:ok, after_names} <- normalize_after(reduce.after),
         {:ok, component} <-
           FlowReduce.new(
             name: reduce.name,
             collection: collection,
             initial: initial,
             action: reduce.action,
             params: params,
             after: after_names,
             meta: reduce.meta
           ) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%Iterate{} = iterate) do
    with {:ok, state} <- lower_iterate_state(iterate.state),
         {:ok, params} <- Expression.parse(iterate.params),
         {:ok, update} <- optional_expression(iterate.update, Ref.body_result()),
         {:ok, while_condition} <- optional_condition(iterate.while),
         {:ok, after_names} <- normalize_after(iterate.after),
         {:ok, completion, max_iterations} <-
           normalize_termination(iterate, while_condition) do
      with {:ok, state} <- FlowIterate.State.new(Map.put(state, :update, update)),
           {:ok, component} <-
             FlowIterate.new(
               name: iterate.name,
               action: iterate.action,
               params: params,
               state: state,
               completion: completion,
               max_iterations: max_iterations,
               after: after_names,
               meta: iterate.meta
             ) do
        {:ok, {:component, component}}
      end
    end
  end

  defp lower_entity(%Dispatch{} = dispatch) do
    with {:ok, params} <- Expression.parse(dispatch.params),
         {:ok, after_names} <- normalize_after(dispatch.after),
         {:ok, component} <-
           FlowDispatch.new(
             name: dispatch.name,
             decision: dispatch.decision,
             expander: dispatch.expander,
             params: params,
             after: after_names,
             meta: dispatch.meta
           ) do
      {:ok, {:component, component}}
    end
  end

  defp lower_entity(%Output{} = output) do
    with {:ok, expression} <- Expression.parse(output.value) do
      {:ok, {:output, expression}}
    end
  end

  defp step_component(step, params, after_names) do
    with {:module, _module} <- Code.ensure_compiled(step.action),
         {:ok, executable} <- Jido.Executable.resolve(step.action) do
      case executable.kind do
        :action ->
          FlowStep.new(
            name: step.name,
            action: step.action,
            params: params,
            after: after_names,
            meta: step.meta
          )

        :flow ->
          Subflow.new(
            name: step.name,
            flow: step.action,
            params: params,
            after: after_names,
            meta: step.meta
          )
      end
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
      with {:ok, condition} <- Expression.parse_condition(option.condition),
           {:ok, input} <- Expression.parse(option.params) do
        value = %{
          name: option.name,
          condition: condition,
          action: option.action,
          params: input
        }

        {:cont, {:ok, [value | lowered]}}
      else
        {:error, error} -> {:halt, {:error, attach_entity_location(error, option)}}
      end
    end)
    |> reverse_ok()
  end

  defp lower_fallback(%Otherwise{} = fallback) do
    with {:ok, input} <- Expression.parse(fallback.params) do
      {:ok, %{action: fallback.action, params: input}}
    end
  end

  defp lower_fallback(nil), do: {:error, Error.validation_error("choice must declare otherwise")}

  defp lower_iterate_state(nil) do
    {:error, Error.validation_error("iterate must declare one state")}
  end

  defp lower_iterate_state(state) do
    with {:ok, initial} <- Expression.parse(state.initial) do
      {:ok, %{schema: state.schema, initial: initial}}
    end
  end

  defp optional_expression(nil, default), do: {:ok, default}
  defp optional_expression(expression, _default), do: Expression.parse(expression)

  defp optional_condition(nil), do: {:ok, nil}
  defp optional_condition(condition), do: Expression.parse_condition(condition)

  defp normalize_termination(iterate, while_condition) do
    case {while_condition, iterate.repeat, iterate.max_iterations} do
      {condition, nil, maximum}
      when not is_nil(condition) and is_integer(maximum) and maximum in 1..@maximum_iterations ->
        {:ok, Condition.not(condition), maximum}

      {nil, count, nil} when is_integer(count) and count in 1..@maximum_iterations ->
        {:ok, Condition.gte(Ref.iteration_index(), count), count}

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

  defp normalize_after(nil), do: {:ok, []}

  defp normalize_after(after_targets) when is_list(after_targets) do
    if List.improper?(after_targets) do
      {:error, Error.validation_error("flow node dependencies must be a proper list")}
    else
      {:ok, after_targets}
    end
  end

  defp normalize_after(after_target), do: {:ok, [after_target]}

  defp validate_output_position(entities) do
    case Enum.find_index(entities, &match?(%Output{}, &1)) do
      nil ->
        {:error, Error.validation_error("Flow output is required")}

      index when index == length(entities) - 1 ->
        :ok

      index ->
        error = Error.validation_error("output must be the final Flow declaration")
        {:error, attach_entity_location(error, Enum.at(entities, index))}
    end
  end

  defp attach_entity_location(%{details: details} = error, entity) when is_map(details) do
    source =
      entity
      |> Spark.Dsl.Entity.anno()
      |> annotation_map()
      |> Map.merge(Map.get(entity, :__source__, %{}))

    %{error | details: Map.merge(source, details)}
  end

  defp attach_entity_location(error, _entity), do: error

  defp annotation_map(nil), do: %{}

  defp annotation_map(anno) do
    %{}
    |> maybe_put(:line, :erl_anno.line(anno))
    |> maybe_put(:column, :erl_anno.column(anno))
  end

  defp maybe_put(map, _key, :undefined), do: map
  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_source(%Output{} = output, source_map) do
    Map.put(source_map, [:output], entity_source(output))
  end

  defp put_source(%Choice{} = choice, source_map) do
    source_map
    |> Map.put([:components, choice.name], entity_source(choice))
    |> put_choice_sources(choice)
  end

  defp put_source(%Iterate{} = iterate, source_map) do
    source_map
    |> Map.put([:components, iterate.name], entity_source(iterate))
    |> maybe_put_source([:components, iterate.name, :state], iterate.state)
  end

  defp put_source(entity, source_map) do
    Map.put(source_map, [:components, Map.fetch!(entity, :name)], entity_source(entity))
  end

  defp put_choice_sources(source_map, choice) do
    source_map =
      Enum.reduce(choice.options, source_map, fn option, current ->
        Map.put(
          current,
          [:components, choice.name, :options, option.name],
          entity_source(option)
        )
      end)

    maybe_put_source(
      source_map,
      [:components, choice.name, :fallback],
      choice.fallback
    )
  end

  defp maybe_put_source(source_map, _path, nil), do: source_map

  defp maybe_put_source(source_map, path, entity),
    do: Map.put(source_map, path, entity_source(entity))

  defp entity_source(entity) do
    annotation =
      case Map.get(entity, :__spark_metadata__) do
        %Spark.Dsl.Entity.Meta{anno: anno} -> annotation_map(anno)
        _other -> %{}
      end

    annotation |> Map.merge(Map.get(entity, :__source__, %{}))
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}

  defp reverse_lowered_entities({:ok, specs, return}), do: {:ok, Enum.reverse(specs), return}
  defp reverse_lowered_entities({:error, error}), do: {:error, error}
end
