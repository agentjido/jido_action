defmodule Jido.Flow.DSL.Lowerer do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Constructor, Ref}

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

  @spec lower(module(), keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def lower(module, opts) do
    entities = Spark.Dsl.Extension.get_entities(module, [:flow])

    with :ok <- validate_output_position(entities),
         {:ok, node_specs, return} <- lower_entities(entities) do
      Constructor.build(%{
        name: Keyword.fetch!(opts, :name),
        description: Keyword.get(opts, :description),
        schema: Keyword.get(opts, :schema, []),
        output_schema: Keyword.get(opts, :output_schema, []),
        node_specs: node_specs,
        return: return
      })
    end
  end

  defp lower_entities(entities) do
    Enum.reduce_while(entities, {:ok, [], nil}, fn entity, {:ok, specs, return} ->
      case lower_entity(entity) do
        {:ok, {:node, spec}} -> {:cont, {:ok, specs ++ [spec], return}}
        {:ok, {:return, expression}} -> {:cont, {:ok, specs, expression}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lower_entity(%Step{} = step) do
    with {:ok, input} <- Expression.parse(step.params) do
      {:ok,
       {:node,
        %{
          kind: :step,
          name: step.name,
          action: step.action,
          input: input,
          after: step.after,
          provenance: provenance(step)
        }}}
    end
  end

  defp lower_entity(%Choice{} = choice) do
    with {:ok, options} <- lower_choice_options(choice.options),
         {:ok, fallback} <- lower_fallback(choice.fallback) do
      {:ok,
       {:node,
        %{
          kind: :choice,
          name: choice.name,
          options: options,
          fallback: fallback,
          after: choice.after,
          provenance: provenance(choice)
        }}}
    end
  end

  defp lower_entity(%MapNode{} = map) do
    with {:ok, collection} <- Expression.parse(map.collection),
         {:ok, input} <- Expression.parse(map.params) do
      {:ok,
       {:node,
        %{
          kind: :map,
          name: map.name,
          collection: collection,
          action: map.action,
          input: input,
          on_error: map.on_error,
          after: map.after,
          provenance: provenance(map)
        }}}
    end
  end

  defp lower_entity(%Reduce{} = reduce) do
    with {:ok, collection} <- Expression.parse(reduce.collection),
         {:ok, initial} <- Expression.parse(reduce.initial),
         {:ok, input} <- Expression.parse(reduce.params) do
      {:ok,
       {:node,
        %{
          kind: :reduce,
          name: reduce.name,
          collection: collection,
          initial: initial,
          action: reduce.action,
          input: input,
          after: reduce.after,
          provenance: provenance(reduce)
        }}}
    end
  end

  defp lower_entity(%Iterate{} = iterate) do
    with {:ok, state} <- lower_iterate_state(iterate.state),
         {:ok, input} <- Expression.parse(iterate.params),
         {:ok, update} <- optional_expression(iterate.update, Ref.body_result()),
         {:ok, while_condition} <- optional_condition(iterate.while) do
      spec = %{
        kind: :iterate,
        name: iterate.name,
        action: iterate.action,
        input: input,
        state: Map.put(state, :update, update),
        after: iterate.after,
        provenance: provenance(iterate)
      }

      spec = if iterate.repeat, do: Map.put(spec, :repeat, iterate.repeat), else: spec
      spec = if while_condition, do: Map.put(spec, :while, while_condition), else: spec

      spec =
        if iterate.max_iterations,
          do: Map.put(spec, :max_iterations, iterate.max_iterations),
          else: spec

      {:ok, {:node, spec}}
    end
  end

  defp lower_entity(%Output{} = output) do
    with {:ok, expression} <- Expression.parse(output.value) do
      {:ok, {:return, expression}}
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
          input: input
        }

        {:cont, {:ok, [value | lowered]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_ok()
  end

  defp lower_fallback(%Otherwise{} = fallback) do
    with {:ok, input} <- Expression.parse(fallback.params) do
      {:ok, %{action: fallback.action, input: input}}
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

  defp validate_output_position(entities) do
    case Enum.find_index(entities, &match?(%Output{}, &1)) do
      nil -> :ok
      index when index == length(entities) - 1 -> :ok
      _index -> {:error, Error.validation_error("output must be the final Flow declaration")}
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

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}
end
