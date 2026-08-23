defmodule Jido.Flow.Compiler.ErrorTagger do
  @moduledoc false

  alias Jido.Action.Error

  @doc false
  def node_target_owner(node), do: %{kind: :node, node: node}

  def choice_target_owner(choice, target), do: %{kind: :choice, choice: choice, target: target}

  def map_target_owner(map, item_state), do: %{kind: :map, map: map, item: item_state}

  def reduce_target_owner(reduce, item_state),
    do: %{kind: :reduce, reduce: reduce, item: item_state}

  def iterator_target_owner(iterator, iteration_index, iteration_id, state_revision) do
    %{
      kind: :iterate,
      iterator: iterator,
      iteration_index: iteration_index,
      iteration_id: iteration_id,
      state_revision: state_revision
    }
  end

  def tag_target_error(result, phase, %{kind: :node, node: node}) do
    tag_step_error(result, node_target_phase(phase), node)
  end

  def tag_target_error(result, phase, %{kind: :choice, choice: choice, target: target}) do
    tag_choice_target_error(result, choice, target, choice_target_phase(phase))
  end

  def tag_target_error(result, phase, %{kind: :map, map: map, item: item}) do
    tag_map_target_error(result, map, item, map_target_phase(phase))
  end

  def tag_target_error(result, phase, %{kind: :reduce, reduce: reduce, item: item}) do
    tag_reduce_target_error(result, reduce, item, reduce_target_phase(phase))
  end

  def tag_target_error(result, phase, %{kind: :iterate} = owner) do
    tag_iterator_target_error(result, owner, iterator_target_phase(phase))
  end

  def tag_target_validation_error(result, :input, %{kind: :node, node: node}) do
    tag_step_validation_error(result, :step_input, node)
  end

  def tag_target_validation_error(result, :input, %{
        kind: :choice,
        choice: choice,
        target: target
      }) do
    tag_choice_target_validation_error(result, choice, target, :choice_target_input)
  end

  def tag_target_validation_error(result, :input, %{kind: :map, map: map, item: item}) do
    tag_map_target_validation_error(result, map, item, :map_target_input)
  end

  def tag_target_validation_error(result, :input, %{
        kind: :reduce,
        reduce: reduce,
        item: item
      }) do
    tag_reduce_target_validation_error(result, reduce, item, :reduce_target_input)
  end

  def tag_target_validation_error(result, :input, %{kind: :iterate} = owner) do
    tag_iterator_target_validation_error(result, owner, :iterate_body_input)
  end

  defp node_target_phase(:execution), do: :step_execution
  defp node_target_phase(:output), do: :step_output

  defp choice_target_phase(:execution), do: :choice_target_execution
  defp choice_target_phase(:output), do: :choice_target_output

  defp map_target_phase(:execution), do: :map_target_execution
  defp map_target_phase(:output), do: :map_target_output

  defp reduce_target_phase(:execution), do: :reduce_target_execution
  defp reduce_target_phase(:output), do: :reduce_target_output

  defp iterator_target_phase(:execution), do: :iterate_body_execution
  defp iterator_target_phase(:output), do: :iterate_body_output

  defp tag_step_error({:ok, output}, _phase, _node), do: {:ok, output}

  defp tag_step_error({:error, error}, phase, node) when is_exception(error) do
    {:error, put_step_details(error, phase, node)}
  end

  defp tag_step_error({:error, error}, _phase, _node), do: {:error, error}

  defp put_step_details(%{details: details} = error, phase, node) when is_map(details) do
    %{
      error
      | details: Map.merge(details, %{phase: phase, node: node.name, action: node.action})
    }
  end

  defp put_step_details(error, _phase, _node), do: error

  defp tag_choice_target_error({:ok, output}, _choice, _target, _phase), do: {:ok, output}

  defp tag_choice_target_error({:error, error}, choice, target, phase) when is_exception(error) do
    {:error, put_choice_target_details(error, choice, target, phase)}
  end

  defp tag_choice_target_error({:error, error}, _choice, _target, _phase), do: {:error, error}

  defp tag_choice_target_validation_error({:ok, value}, _choice, _target, _phase),
    do: {:ok, value}

  defp tag_choice_target_validation_error({:error, error}, choice, target, phase)
       when is_exception(error) do
    {:error, put_choice_target_details(error, choice, target, phase)}
  end

  defp tag_choice_target_validation_error({:error, reason}, choice, target, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       choice_target_details(%{reason: reason}, choice, target, phase)
     )}
  end

  defp tag_map_target_error({:ok, output}, _map, _item, _phase), do: {:ok, output}

  defp tag_map_target_error({:error, error}, map, item, phase) when is_exception(error) do
    {:error, put_map_target_details(error, map, item, phase)}
  end

  defp tag_map_target_error({:error, error}, _map, _item, _phase), do: {:error, error}

  defp tag_map_target_validation_error({:ok, value}, _map, _item, _phase), do: {:ok, value}

  defp tag_map_target_validation_error({:error, error}, map, item, phase)
       when is_exception(error) do
    {:error, put_map_target_details(error, map, item, phase)}
  end

  defp tag_map_target_validation_error({:error, reason}, map, item, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       map_target_details(%{reason: reason}, map, item, phase)
     )}
  end

  defp tag_reduce_target_error({:ok, output}, _reduce, _item, _phase), do: {:ok, output}

  defp tag_reduce_target_error({:error, error}, reduce, item, phase)
       when is_exception(error) do
    {:error, put_reduce_target_details(error, reduce, item, phase)}
  end

  defp tag_reduce_target_error({:error, error}, _reduce, _item, _phase),
    do: {:error, error}

  defp tag_reduce_target_validation_error({:ok, value}, _reduce, _item, _phase),
    do: {:ok, value}

  defp tag_reduce_target_validation_error({:error, error}, reduce, item, phase)
       when is_exception(error) do
    {:error, put_reduce_target_details(error, reduce, item, phase)}
  end

  defp tag_reduce_target_validation_error({:error, reason}, reduce, item, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       reduce_target_details(%{reason: reason}, reduce, item, phase)
     )}
  end

  defp tag_iterator_target_error({:ok, output}, _owner, _phase), do: {:ok, output}

  defp tag_iterator_target_error({:error, error}, owner, phase) when is_exception(error) do
    {:error, put_iterator_target_details(error, owner, phase)}
  end

  defp tag_iterator_target_error({:error, error}, _owner, _phase), do: {:error, error}

  defp tag_iterator_target_validation_error({:ok, value}, _owner, _phase), do: {:ok, value}

  defp tag_iterator_target_validation_error({:error, error}, owner, phase)
       when is_exception(error) do
    {:error, put_iterator_target_details(error, owner, phase)}
  end

  defp tag_iterator_target_validation_error({:error, reason}, owner, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       iterator_target_details(owner, phase, false)
     )}
  end

  defp put_iterator_target_details(error, owner, phase) do
    details = iterator_target_details(owner, phase, iterator_target_retry_policy(error))

    if Map.has_key?(error, :details) do
      %{error | details: details}
    else
      Map.put(error, :details, details)
    end
  end

  defp iterator_target_details(owner, phase, retry) do
    %{
      phase: phase,
      node: owner.iterator.name,
      target: owner.iterator.action,
      iteration_index: owner.iteration_index,
      iteration_id: owner.iteration_id,
      state_revision: owner.state_revision,
      retry: retry
    }
  end

  defp iterator_target_retry_policy(%Error.ExecutionFailureError{details: %{retry: retry}})
       when is_boolean(retry),
       do: retry

  defp iterator_target_retry_policy(%Error.ExecutionFailureError{}), do: false
  defp iterator_target_retry_policy(error), do: Error.retryable?(error)

  defp put_map_target_details(%{details: details} = error, map, item, phase)
       when is_map(details) do
    %{error | details: map_target_details(details, map, item, phase)}
  end

  defp put_map_target_details(error, _map, _item, _phase), do: error

  defp map_target_details(details, map, item, phase) do
    Map.merge(details, %{
      phase: phase,
      node: map.name,
      target: map.action,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  defp put_reduce_target_details(%{details: details} = error, reduce, item, phase)
       when is_map(details) do
    %{error | details: reduce_target_details(details, reduce, item, phase)}
  end

  defp put_reduce_target_details(error, _reduce, _item, _phase), do: error

  defp reduce_target_details(details, reduce, item, phase) do
    Map.merge(details, %{
      phase: phase,
      node: reduce.name,
      target: reduce.action,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  defp put_choice_target_details(%{details: details} = error, choice, target, phase)
       when is_map(details) do
    %{error | details: choice_target_details(details, choice, target, phase)}
  end

  defp put_choice_target_details(error, _choice, _target, _phase), do: error

  defp choice_target_details(details, choice, target, phase) do
    Map.merge(details, %{
      phase: phase,
      node: choice.name,
      option: target.name,
      target: target.action
    })
  end

  defp tag_step_validation_error({:ok, value}, _phase, _node), do: {:ok, value}

  defp tag_step_validation_error({:error, error}, phase, node) when is_exception(error) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.put(:phase, phase)
      |> Map.put(:node, node.name)
      |> Map.put(:action, node.action)

    {:error, Error.validation_error(Exception.message(error), details)}
  end

  defp tag_step_validation_error({:error, reason}, phase, node) do
    {:error,
     Error.validation_error(to_error_message(reason), %{
       phase: phase,
       node: node.name,
       action: node.action,
       reason: reason
     })}
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
