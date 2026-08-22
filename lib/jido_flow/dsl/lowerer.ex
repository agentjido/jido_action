defmodule Jido.Flow.DSL.Lowerer do
  @moduledoc false

  alias Jido.Action.Error

  alias Jido.Flow.DSL.{
    Choice,
    ChoiceOption,
    Expression,
    Iterate,
    MapNode,
    Otherwise,
    Output,
    Reduce,
    Step
  }

  alias Jido.Flow.Syntax

  @spec lower(module(), keyword()) :: {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def lower(module, opts) do
    entities = Spark.Dsl.Extension.get_entities(module, [:flow])

    with :ok <- validate_output_position(entities),
         {:ok, operations} <- lower_entities(entities),
         {:ok, operations} <- ensure_output(operations) do
      syntax =
        Syntax.new(
          name: Keyword.fetch!(opts, :name),
          description: Keyword.get(opts, :description),
          schema: Keyword.get(opts, :schema, []),
          output_schema: Keyword.get(opts, :output_schema, [])
        )

      syntax
      |> Map.put(:operations, operations)
      |> Syntax.Lowerer.lower()
    end
  end

  defp lower_entities(entities) do
    Enum.reduce_while(entities, {:ok, []}, fn entity, {:ok, operations} ->
      case lower_entity(entity) do
        {:ok, operation} -> {:cont, {:ok, operations ++ [operation]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lower_entity(%Step{} = step) do
    with {:ok, params} <- Expression.parse(step.params) do
      attrs = %{
        name: step.name,
        action: step.action,
        input: params,
        after: step.after
      }

      {:ok, Syntax.operation(:step, attrs, provenance: provenance(step))}
    end
  end

  defp lower_entity(%Choice{} = choice) do
    with {:ok, options} <- lower_choice_options(choice.options),
         {:ok, fallback} <- lower_fallback(choice.fallback) do
      attrs = %{
        name: choice.name,
        options: options,
        fallback: fallback,
        after: choice.after
      }

      {:ok, Syntax.operation(:choice, attrs, provenance: provenance(choice))}
    end
  end

  defp lower_entity(%MapNode{} = map) do
    with {:ok, collection} <- Expression.parse(map.collection),
         {:ok, params} <- Expression.parse(map.params) do
      attrs = %{
        name: map.name,
        collection: collection,
        action: map.action,
        input: params,
        on_error: map.on_error,
        after: map.after
      }

      {:ok, Syntax.operation(:map, attrs, provenance: provenance(map))}
    end
  end

  defp lower_entity(%Reduce{} = reduce) do
    with {:ok, collection} <- Expression.parse(reduce.collection),
         {:ok, initial} <- Expression.parse(reduce.initial),
         {:ok, params} <- Expression.parse(reduce.params) do
      attrs = %{
        name: reduce.name,
        collection: collection,
        initial: initial,
        action: reduce.action,
        input: params,
        after: reduce.after
      }

      {:ok, Syntax.operation(:reduce, attrs, provenance: provenance(reduce))}
    end
  end

  defp lower_entity(%Iterate{} = iterate) do
    with {:ok, state} <- lower_iterate_state(iterate.state),
         {:ok, params} <- Expression.parse(iterate.params),
         {:ok, attrs} <- iterate_attrs(iterate, state, params) do
      {:ok, Syntax.operation(:iterate, attrs, provenance: provenance(iterate))}
    end
  end

  defp lower_entity(%Output{} = output) do
    with {:ok, expression} <- Expression.parse(output.value) do
      {:ok, Syntax.operation(:return, %{expr: expression})}
    end
  end

  defp validate_output_position(entities) do
    case Enum.find_index(entities, &match?(%Output{}, &1)) do
      nil ->
        :ok

      index when index == length(entities) - 1 ->
        :ok

      _index ->
        {:error, Error.validation_error("output must be the final Flow declaration")}
    end
  end

  defp lower_choice_options([]) do
    {:error, Error.validation_error("choice must declare at least one option")}
  end

  defp lower_choice_options(options) do
    Enum.reduce_while(options, {:ok, []}, fn %ChoiceOption{} = option, {:ok, lowered} ->
      with {:ok, condition} <- Expression.parse_condition(option.condition),
           {:ok, params} <- Expression.parse(option.params) do
        value = Syntax.option(option.name, condition, option.action, params)
        {:cont, {:ok, lowered ++ [value]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lower_fallback(%Otherwise{} = fallback) do
    with {:ok, params} <- Expression.parse(fallback.params) do
      {:ok, Syntax.fallback(fallback.action, params)}
    end
  end

  defp lower_fallback(nil), do: {:error, Error.validation_error("choice must declare otherwise")}

  defp lower_iterate_state(nil) do
    {:error, Error.validation_error("iterate must declare one state")}
  end

  defp lower_iterate_state(state) do
    with {:ok, initial} <- Expression.parse(state.initial) do
      {:ok,
       %{
         schema: state.schema,
         initial: initial,
         update: Syntax.body_result()
       }}
    end
  end

  defp iterate_attrs(iterate, state, params) do
    with {:ok, update} <- optional_expression(iterate.update, state.update),
         {:ok, while_condition} <- optional_condition(iterate.while) do
      state = Map.put(state, :update, update)

      attrs = %{
        name: iterate.name,
        action: iterate.action,
        input: params,
        state: state,
        after: iterate.after
      }

      attrs = if iterate.repeat, do: Map.put(attrs, :repeat, iterate.repeat), else: attrs
      attrs = if while_condition, do: Map.put(attrs, :while, while_condition), else: attrs

      attrs =
        if iterate.max_iterations,
          do: Map.put(attrs, :max_iterations, iterate.max_iterations),
          else: attrs

      {:ok, attrs}
    end
  end

  defp optional_expression(nil, default), do: {:ok, default}
  defp optional_expression(expression, _default), do: Expression.parse(expression)

  defp optional_condition(nil), do: {:ok, nil}
  defp optional_condition(condition), do: Expression.parse_condition(condition)

  defp ensure_output([]),
    do: {:error, Error.validation_error("Flow must declare at least one node")}

  defp ensure_output(operations) do
    case List.last(operations) do
      %Syntax.Operation{kind: :return} ->
        {:ok, operations}

      %Syntax.Operation{attrs: %{name: name}} ->
        {:ok, operations ++ [Syntax.operation(:return, %{expr: Syntax.result(name)})]}

      _operation ->
        {:error, Error.validation_error("Flow cannot infer output from its final declaration")}
    end
  end

  defp provenance(%{meta: meta, __spark_metadata__: spark_metadata}) do
    source =
      case spark_metadata do
        %Spark.Dsl.Entity.Meta{anno: anno} -> annotation_map(anno)
        _other -> %{}
      end

    Map.merge(source, meta)
  end

  defp annotation_map(nil), do: %{}

  defp annotation_map(anno) do
    %{}
    |> maybe_put(:line, :erl_anno.line(anno))
    |> maybe_put(:column, :erl_anno.column(anno))
  end

  defp maybe_put(map, _key, :undefined), do: map
  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
