defmodule Jido.Flow.DSL.Lowerer do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Constructor, Ref}
  alias Jido.Flow.Iterator.Termination

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
        nodes: node_specs,
        return: return
      })
    end
  end

  defp lower_entities(entities) do
    entities
    |> Enum.reduce_while({:ok, [], nil}, fn entity, {:ok, specs, return} ->
      case lower_entity(entity) do
        {:ok, {:node, spec}} -> {:cont, {:ok, [spec | specs], return}}
        {:ok, {:return, expression}} -> {:cont, {:ok, specs, expression}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_lowered_entities()
  end

  defp lower_entity(%Step{} = step) do
    with {:ok, input} <- Expression.parse(step.params),
         {:ok, deps} <- normalize_after(step.after) do
      {:ok,
       {:node,
        %{
          kind: :step,
          name: step.name,
          action: step.action,
          input: input,
          deps: deps,
          provenance: provenance(step)
        }}}
    end
  end

  defp lower_entity(%Choice{} = choice) do
    with {:ok, options} <- lower_choice_options(choice.options),
         {:ok, fallback} <- lower_fallback(choice.fallback),
         {:ok, deps} <- normalize_after(choice.after) do
      {:ok,
       {:node,
        %{
          kind: :choice,
          name: choice.name,
          options: options,
          fallback: fallback,
          deps: deps,
          provenance: provenance(choice)
        }}}
    end
  end

  defp lower_entity(%MapNode{} = map) do
    with {:ok, collection} <- Expression.parse(map.collection),
         {:ok, input} <- Expression.parse(map.params),
         {:ok, deps} <- normalize_after(map.after) do
      {:ok,
       {:node,
        %{
          kind: :map,
          name: map.name,
          collection: collection,
          action: map.action,
          input: input,
          on_error: map.on_error,
          deps: deps,
          provenance: provenance(map)
        }}}
    end
  end

  defp lower_entity(%Reduce{} = reduce) do
    with {:ok, collection} <- Expression.parse(reduce.collection),
         {:ok, initial} <- Expression.parse(reduce.initial),
         {:ok, input} <- Expression.parse(reduce.params),
         {:ok, deps} <- normalize_after(reduce.after) do
      {:ok,
       {:node,
        %{
          kind: :reduce,
          name: reduce.name,
          collection: collection,
          initial: initial,
          action: reduce.action,
          input: input,
          deps: deps,
          provenance: provenance(reduce)
        }}}
    end
  end

  defp lower_entity(%Iterate{} = iterate) do
    with {:ok, state} <- lower_iterate_state(iterate.state),
         {:ok, input} <- Expression.parse(iterate.params),
         {:ok, update} <- optional_expression(iterate.update, Ref.body_result()),
         {:ok, while_condition} <- optional_condition(iterate.while),
         {:ok, deps} <- normalize_after(iterate.after),
         {:ok, completion, max_iterations} <-
           normalize_termination(iterate, while_condition) do
      {:ok,
       {:node,
        %{
          kind: :iterate,
          name: iterate.name,
          action: iterate.action,
          input: input,
          state: Map.put(state, :update, update),
          completion: completion,
          max_iterations: max_iterations,
          deps: deps,
          provenance: provenance(iterate)
        }}}
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

  defp normalize_termination(iterate, while_condition) do
    spec =
      [
        while: while_condition,
        repeat: iterate.repeat,
        max_iterations: iterate.max_iterations
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()

    Termination.normalize(spec, [:while, :repeat])
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

  defp reverse_lowered_entities({:ok, specs, return}), do: {:ok, Enum.reverse(specs), return}
  defp reverse_lowered_entities({:error, error}), do: {:error, error}
end
