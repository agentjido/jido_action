defmodule Jido.Flow.Compiler.TargetContext do
  @moduledoc false

  alias Jido.Action.Error

  @enforce_keys [:kind, :details]
  defstruct [:kind, :details]

  @phases %{
    node: %{input: :step_input, execution: :step_execution, output: :step_output},
    choice: %{
      input: :choice_target_input,
      execution: :choice_target_execution,
      output: :choice_target_output
    },
    map: %{
      input: :map_target_input,
      execution: :map_target_execution,
      output: :map_target_output
    },
    reduce: %{
      input: :reduce_target_input,
      execution: :reduce_target_execution,
      output: :reduce_target_output
    },
    iterate: %{
      input: :iterate_body_input,
      execution: :iterate_body_execution,
      output: :iterate_body_output
    }
  }

  @doc false
  def node(node) do
    %__MODULE__{kind: :node, details: %{node: node.name, action: node.action}}
  end

  @doc false
  def choice(choice, target) do
    %__MODULE__{
      kind: :choice,
      details: %{node: choice.name, option: target.name, target: target.action}
    }
  end

  @doc false
  def map(map, item) do
    %__MODULE__{
      kind: :map,
      details: %{
        node: map.name,
        target: map.action,
        item_index: item.item_index,
        item_id: item.item_id
      }
    }
  end

  @doc false
  def reduce(reduce, item) do
    %__MODULE__{
      kind: :reduce,
      details: %{
        node: reduce.name,
        target: reduce.action,
        item_index: item.item_index,
        item_id: item.item_id
      }
    }
  end

  @doc false
  def iterator(iterator, iteration_index, iteration_id, state_revision) do
    %__MODULE__{
      kind: :iterate,
      details: %{
        node: iterator.name,
        target: iterator.action,
        iteration_index: iteration_index,
        iteration_id: iteration_id,
        state_revision: state_revision
      }
    }
  end

  @doc false
  def phase(%__MODULE__{kind: kind}, phase) do
    @phases |> Map.fetch!(kind) |> Map.fetch!(phase)
  end

  @doc false
  def validation_details(%__MODULE__{kind: :iterate} = context, phase, _reason) do
    context
    |> details(phase)
    |> Map.put(:retry, false)
  end

  def validation_details(%__MODULE__{} = context, phase, reason) do
    context
    |> details(phase)
    |> Map.put(:reason, reason)
  end

  @doc false
  def exception_strategy(
        %__MODULE__{kind: :node} = context,
        phase,
        error,
        :validation
      ) do
    {:validation, merge_error_details(error, details(context, phase))}
  end

  def exception_strategy(%__MODULE__{kind: :iterate} = context, phase, error, _mode) do
    tagged_details =
      context
      |> details(phase)
      |> preserve_error_path(error)
      |> Map.put(:retry, iterator_retry_policy(error))

    {:replace, tagged_details}
  end

  def exception_strategy(%__MODULE__{} = context, phase, %{details: existing_details}, _mode)
      when is_map(existing_details) do
    {:merge, Map.merge(existing_details, details(context, phase))}
  end

  def exception_strategy(%__MODULE__{} = context, phase, _error, _mode) do
    {:replace, details(context, phase)}
  end

  defp details(%__MODULE__{details: details}, phase), do: Map.put(details, :phase, phase)

  defp preserve_error_path(details, %{details: %{path: path}}) when is_list(path) do
    Map.put(details, :path, path)
  end

  defp preserve_error_path(details, _error), do: details

  defp merge_error_details(error, target_details) do
    error
    |> Map.get(:details, %{})
    |> Map.merge(target_details)
  end

  defp iterator_retry_policy(%Error.ExecutionFailureError{details: %{retry: retry}})
       when is_boolean(retry),
       do: retry

  defp iterator_retry_policy(%Error.ExecutionFailureError{}), do: false
  defp iterator_retry_policy(error), do: Error.retryable?(error)
end
