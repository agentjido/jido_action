defmodule Jido.Flow.Compiler.Collection do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Frame
  alias Jido.Flow.Compiler.Payload
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Error
  alias Jido.Flow.Identity

  @doc false
  @spec map_input(Jido.Flow.Map.t(), map()) :: [map()]
  def map_input(map, local) do
    case Expression.resolve(map.collection, local) do
      {:ok, collection} -> map_tokens(map, collection, local)
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec reduce_input(Jido.Flow.Reduce.t(), map()) :: [map()]
  def reduce_input(reduce, local) do
    with {:ok, collection} <- Expression.resolve(reduce.collection, local),
         {:ok, initial} <- Expression.resolve(reduce.initial, local) do
      reduce_tokens(reduce, collection, initial, local)
    else
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec map_item(Jido.Flow.Map.t(), [String.t()], map(), map()) :: map()
  def map_item(_map, _namespace, %{kind: :empty} = token, _runtime), do: token

  def map_item(map, namespace, %{kind: :item} = token, runtime) do
    local =
      Frame.base_runtime_state(runtime, token.input, token.results)
      |> Map.merge(%{
        item: token.item,
        item_index: token.index,
        item_id: token.id
      })

    owner =
      Target.map(map, %{
        item_index: token.index,
        item_id: token.id
      })
      |> Target.at(namespace)

    span =
      runtime.observer.({
        :start,
        :map_item,
        %{node: map.name, target: map.action, item_index: token.index, item_id: token.id}
      })

    outcome =
      with {:ok, params} <- Expression.resolve(map.params, local) do
        Target.run(
          map.action,
          params,
          runtime.context,
          owner,
          runtime.execution_id,
          runtime.target_runner
        )
      end

    case {map.on_error, outcome} do
      {_, {:ok, output}} ->
        runtime.observer.({:stop, span})

        output =
          if map.on_error == :collect_errors,
            do: %{status: :ok, value: output},
            else: output

        token
        |> Map.put(:kind, :result)
        |> Map.put(:output, output)
        |> Map.drop([:item, :results])

      {:collect_errors, {:error, error}} ->
        runtime.observer.({:error, span, error})

        token
        |> Map.put(:kind, :result)
        |> Map.put(:output, %{
          status: :error,
          error: Error.to_map(error)
        })
        |> Map.drop([:item, :results])

      {:fail_fast, {:error, error}} ->
        runtime.observer.({:error, span, error})
        raise error
    end
  end

  defp map_tokens(map, collection, local) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:map, map.name, collection)
    else
      case collection do
        [] ->
          [
            %{
              kind: :empty,
              input: local.input_frame,
              results: local.results
            }
          ]

        items ->
          items
          |> Enum.with_index()
          |> Enum.map(fn {item, index} ->
            %{
              kind: :item,
              item: item,
              index: index,
              id: Identity.item_uuid(local.flow_digest, map.name, index),
              input: local.input_frame,
              results: local.results
            }
          end)
      end
    end
  end

  defp map_tokens(map, collection, _local),
    do: invalid_collection!(:map, map.name, collection)

  @doc false
  @spec collect_map_tokens(Jido.Flow.Map.t(), term()) :: term()
  def collect_map_tokens(map, tokens) do
    tokens = if is_list(tokens), do: tokens, else: [tokens]

    input =
      tokens
      |> Enum.find_value(fn token -> if is_map(token), do: Map.get(token, :input) end)

    values =
      tokens
      |> Enum.filter(&match?(%{kind: :result}, &1))
      |> Enum.sort_by(& &1.index)
      |> Enum.map(& &1.output)

    if is_nil(input) do
      raise Error.execution_error("Map collector did not receive Flow input", %{
              phase: :map_collection,
              node: map.name
            })
    end

    Frame.value(input, values)
  end

  @doc false
  @spec reduce_fun(Jido.Flow.Reduce.t(), [String.t()]) :: function()
  def reduce_fun(reduce, namespace) do
    # Reduce uses Runic's simple FanIn mode. Its context is separate from facts.
    # Keep target failures in the aggregate for the output Step to report.
    fn payload, accumulator, effective_context ->
      token = Payload.unwrap(payload)
      aggregate = Payload.unwrap(accumulator)
      runtime = runtime_from_context(effective_context)

      result =
        try do
          reduce_token(reduce, token, aggregate, namespace, runtime)
        rescue
          error -> {:halt, %{aggregate | input: token.input, error: error}}
        catch
          kind, reason ->
            error =
              Error.execution_error("flow Reduce #{kind}", %{
                node: reduce.name,
                reason: reason
              })

            {:halt, %{aggregate | input: token.input, error: error}}
        end

      case result do
        {:halt, aggregate} -> {:halt, Payload.new(aggregate)}
        aggregate -> Payload.new(aggregate)
      end
    end
  end

  defp reduce_token(reduce, token, aggregate, namespace, runtime) do
    aggregate =
      if aggregate.initialized do
        aggregate
      else
        %{aggregate | initialized: true, accumulator: token.initial, input: token.input}
      end

    case token.kind do
      :init ->
        aggregate

      :item ->
        local =
          Frame.base_runtime_state(runtime, token.input, Map.get(token, :results, %{}))
          |> Map.merge(%{
            item: token.item,
            item_index: token.index,
            item_id: token.id,
            accumulator: aggregate.accumulator
          })

        owner =
          Target.reduce(reduce, %{
            item_index: token.index,
            item_id: token.id
          })
          |> Target.at(namespace)

        span =
          runtime.observer.({
            :start,
            :reduce_item,
            %{
              node: reduce.name,
              target: reduce.action,
              item_index: token.index,
              item_id: token.id
            }
          })

        result =
          with {:ok, params} <- Expression.resolve(reduce.params, local) do
            Target.run(
              reduce.action,
              params,
              runtime.context,
              owner,
              runtime.execution_id,
              runtime.target_runner
            )
          end

        case result do
          {:ok, output} ->
            runtime.observer.({:stop, span})
            %{aggregate | accumulator: output}

          {:error, error} ->
            runtime.observer.({:error, span, error})
            {:halt, %{aggregate | error: error}}
        end
    end
  end

  defp reduce_tokens(reduce, collection, initial, local) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:reduce, reduce.name, collection)
    else
      validate_reduce_initial!(reduce, initial)

      init = %{
        kind: :init,
        initial: initial,
        input: local.input_frame,
        results: local.results
      }

      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            kind: :item,
            item: item,
            index: index,
            id: Identity.item_uuid(local.flow_digest, reduce.name, index),
            input: local.input_frame,
            results: local.results,
            initial: initial
          }
        end)

      [init | items]
    end
  end

  defp reduce_tokens(reduce, collection, _initial, _local),
    do: invalid_collection!(:reduce, reduce.name, collection)

  defp validate_reduce_initial!(reduce, initial) do
    valid? =
      case initial do
        %Output{} = output -> match?({:ok, _}, Output.validate(output))
        value -> is_map(value)
      end

    unless valid? do
      raise Error.execution_error("reduce initial value must be a map or Jido.Action.Output", %{
              phase: :reduce_initial,
              node: reduce.name,
              reason: :output_envelope_required,
              value_type: Expression.value_type(initial),
              retry: false
            })
    end
  end

  defp invalid_collection!(kind, name, collection) do
    raise Error.execution_error("#{kind} collection must resolve to a proper list", %{
            phase: String.to_atom("#{kind}_collection"),
            node: name,
            reason: :not_a_proper_list,
            value_type: Expression.value_type(collection),
            retry: false
          })
  end

  defp runtime_from_context(%{jido: runtime}), do: runtime
end
