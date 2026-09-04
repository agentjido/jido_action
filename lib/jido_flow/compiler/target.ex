defmodule Jido.Flow.Compiler.Target do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.Transition

  @type kind :: :node | :choice | :map | :reduce | :iterate | :dispatch
  @type t :: %__MODULE__{kind: kind(), details: map()}

  @enforce_keys [:kind, :details]
  defstruct [:kind, :details]

  @doc false
  @spec at(t(), [String.t()]) :: t()
  def at(%__MODULE__{} = owner, namespace) do
    %{owner | details: Map.put(owner.details, :node_path, namespace ++ [owner.details.node])}
  end

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
    },
    dispatch: %{
      input: :dispatch_target_input,
      execution: :dispatch_target_execution,
      output: :dispatch_target_output
    }
  }

  @doc false
  @spec node(Jido.Flow.Step.t()) :: t()
  def node(%Jido.Flow.Step{} = node) do
    %__MODULE__{kind: :node, details: %{node: node.name, action: node.action}}
  end

  @doc false
  @spec choice(
          Jido.Flow.Choice.t(),
          Jido.Flow.Choice.Option.t() | Jido.Flow.Choice.Fallback.t()
        ) :: t()
  def choice(choice, target) do
    %__MODULE__{
      kind: :choice,
      details: %{node: choice.name, option: choice_target_name(target), target: target.action}
    }
  end

  @doc false
  @spec map(Jido.Flow.Map.t(), map()) :: t()
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
  @spec reduce(Jido.Flow.Reduce.t(), map()) :: t()
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
  @spec iterator(Jido.Flow.Iterate.t(), non_neg_integer(), String.t(), non_neg_integer()) :: t()
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
  @spec dispatch(Jido.Flow.Dispatch.t(), :decision | :expander) :: t()
  def dispatch(dispatch, phase) when phase in [:decision, :expander] do
    target = if phase == :decision, do: dispatch.decision, else: dispatch.expander

    %__MODULE__{
      kind: :dispatch,
      details: %{node: dispatch.name, target: target, dispatch_phase: phase}
    }
  end

  @doc false
  @spec run(module(), term(), map(), t(), String.t(), Jido.Flow.Compiler.target_runner()) ::
          {:ok, term()} | {:continue, Transition.t()} | {:error, Exception.t()}
  def run(action, params, context, %__MODULE__{} = owner, execution_id, target_runner) do
    case target_runner.(action, params, context, execution_id, owner) do
      {:ok, output} ->
        {:ok, output}

      {:continue, %Transition{} = transition} ->
        {:continue, transition}

      {:error, :input, error} ->
        tag_validation({:error, error}, owner)

      {:error, phase, error} when phase in [:execution, :output] ->
        tag({:error, error}, phase, owner, :target)
    end
  end

  @doc false
  @spec tag_validation({:ok, term()} | {:error, Exception.t()}, t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def tag_validation(result, %__MODULE__{} = owner) do
    tag(result, :input, owner, :validation)
  end

  @doc false
  @spec telemetry_metadata(t(), module()) ::
          {:ok, %{node: String.t(), kind: :step | :choice, target: module(), option: term()}}
          | :none
  def telemetry_metadata(%__MODULE__{kind: :node, details: details}, action) do
    {:ok, %{node: details.node, kind: :step, target: action, option: nil}}
  end

  def telemetry_metadata(%__MODULE__{kind: :choice, details: details}, action) do
    {:ok,
     %{node: details.node, kind: :choice, target: action, option: Map.fetch!(details, :option)}}
  end

  def telemetry_metadata(%__MODULE__{}, _action), do: :none

  defp tag({:ok, value}, _phase, _context, _mode), do: {:ok, value}

  defp tag({:error, error}, phase, context, mode) when is_exception(error) do
    tagged_phase = phase(context, phase)

    case exception_strategy(context, tagged_phase, error, mode) do
      {:validation, details} ->
        tagged_error = Error.validation_error(Exception.message(error), details)
        {:error, preserve_stacktrace(tagged_error, error)}

      {:merge, details} ->
        {:error, %{error | details: details}}

      {:replace, details} ->
        {:error, replace_details(error, details)}
    end
  end

  defp phase(%__MODULE__{kind: kind}, phase) do
    @phases |> Map.fetch!(kind) |> Map.fetch!(phase)
  end

  defp exception_strategy(%__MODULE__{kind: :node} = context, phase, error, :validation) do
    {:validation, merge_error_details(error, details(context, phase))}
  end

  defp exception_strategy(%__MODULE__{kind: :iterate} = context, phase, error, _mode) do
    tagged_details =
      context
      |> details(phase)
      |> preserve_error_path(error)
      |> Map.put(:retry, iterator_retry_policy(error))

    {:replace, tagged_details}
  end

  defp exception_strategy(%__MODULE__{} = context, phase, %{details: existing}, _mode)
       when is_map(existing) do
    {:merge, Map.merge(existing, details(context, phase))}
  end

  defp exception_strategy(%__MODULE__{} = context, phase, _error, _mode) do
    {:replace, details(context, phase)}
  end

  defp details(%__MODULE__{details: details}, phase), do: Map.put(details, :phase, phase)

  defp choice_target_name(%Jido.Flow.Choice.Option{name: name}), do: name
  defp choice_target_name(%Jido.Flow.Choice.Fallback{}), do: :fallback

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

  defp replace_details(error, details) do
    if Map.has_key?(error, :details) do
      %{error | details: details}
    else
      details =
        details
        |> Map.put(:exception, error.__struct__)
        |> Map.put_new(:retry, Error.retryable?(error))

      error
      |> Exception.message()
      |> Error.execution_error(details)
      |> preserve_stacktrace(error)
    end
  end

  defp preserve_stacktrace(tagged_error, %{stacktrace: stacktrace})
       when not is_nil(stacktrace) do
    %{tagged_error | stacktrace: stacktrace}
  end

  defp preserve_stacktrace(tagged_error, _error), do: tagged_error
end
