defmodule Jido.Flow.Compiler.Target do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.Transition
  alias Jido.Instruction

  @type kind :: :step | :choice | :map | :reduce | :iterate | :dispatch
  @type t :: Instruction.t()

  @metadata_key :jido_flow

  @doc false
  @spec at(t(), [String.t()]) :: t()
  def at(%Instruction{} = instruction, namespace) do
    update_details(instruction, fn details ->
      Map.put(details, :node_path, namespace ++ [details.node])
    end)
  end

  @phases %{
    step: %{input: :step_input, execution: :step_execution, output: :step_output},
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
  @spec step(Jido.Flow.Step.t()) :: t()
  def step(%Jido.Flow.Step{} = step) do
    new(:step, step.action, %{node: step.name})
  end

  @doc false
  @spec choice(
          Jido.Flow.Choice.t(),
          Jido.Flow.Choice.Option.t() | Jido.Flow.Choice.Fallback.t()
        ) :: t()
  def choice(choice, target) do
    new(:choice, target.action, %{
      node: choice.name,
      option: choice_target_name(target)
    })
  end

  @doc false
  @spec map(Jido.Flow.Map.t(), map()) :: t()
  def map(map, item) do
    new(:map, map.action, %{
      node: map.name,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  @doc false
  @spec reduce(Jido.Flow.Reduce.t(), map()) :: t()
  def reduce(reduce, item) do
    new(:reduce, reduce.action, %{
      node: reduce.name,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  @doc false
  @spec iterator(Jido.Flow.Iterate.t(), non_neg_integer(), String.t(), non_neg_integer()) :: t()
  def iterator(iterator, iteration_index, iteration_id, state_revision) do
    new(:iterate, iterator.action, %{
      node: iterator.name,
      iteration_index: iteration_index,
      iteration_id: iteration_id,
      state_revision: state_revision
    })
  end

  @doc false
  @spec dispatch(Jido.Flow.Dispatch.t(), :decision | :expander) :: t()
  def dispatch(dispatch, phase) when phase in [:decision, :expander] do
    target = if phase == :decision, do: dispatch.decision, else: dispatch.expander

    new(:dispatch, target, %{node: dispatch.name, dispatch_phase: phase})
  end

  @doc false
  @spec new(kind(), module(), map()) :: t()
  def new(kind, target, details)
      when kind in [:step, :choice, :map, :reduce, :iterate, :dispatch] and is_map(details) do
    %Instruction{
      kind: :action,
      target: target,
      params: %{},
      context: %{},
      metadata: %{@metadata_key => %{kind: kind, details: details}}
    }
  end

  @doc false
  @spec run(t(), term(), map(), String.t(), Jido.Flow.Compiler.target_runner()) ::
          {:ok, term(), [term()]} | {:continue, Transition.t()} | {:error, Exception.t()}
  def run(%Instruction{} = instruction, params, context, execution_id, target_runner) do
    instruction = %{instruction | params: params, context: context}

    case target_runner.(instruction, execution_id) do
      {:ok, output} ->
        {:ok, output, []}

      {:ok, output, items} ->
        {:ok, output, items}

      {:continue, %Transition{} = transition} ->
        {:continue, transition}

      {:error, :input, error} ->
        tag_validation({:error, error}, instruction)

      {:error, phase, error} when phase in [:execution, :output] ->
        tag({:error, error}, phase, instruction, :target)
    end
  end

  @doc false
  @spec tag_validation({:ok, term()} | {:error, Exception.t()}, t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def tag_validation(result, %Instruction{} = instruction) do
    tag(result, :input, instruction, :validation)
  end

  @doc false
  @spec tag_execution(Exception.t(), t()) :: {:error, Exception.t()}
  def tag_execution(error, instruction),
    do: tag({:error, error}, :execution, instruction, :target)

  @doc false
  @spec kind(t()) :: kind()
  def kind(%Instruction{metadata: %{@metadata_key => %{kind: kind}}}), do: kind

  @doc false
  @spec details(t()) :: map()
  def details(%Instruction{target: target, metadata: %{@metadata_key => target_data}}) do
    key = if target_data.kind == :step, do: :action, else: :target
    Map.put(target_data.details, key, target)
  end

  @doc false
  @spec telemetry_metadata(t(), module()) :: map()
  def telemetry_metadata(%Instruction{} = instruction, action) do
    telemetry_metadata(kind(instruction), details(instruction), action)
  end

  defp telemetry_metadata(:step, details, action) do
    %{
      node: details.node,
      node_path: Map.get(details, :node_path, [details.node]),
      kind: :step,
      target: action,
      option: nil
    }
  end

  defp telemetry_metadata(:choice, details, action) do
    %{
      node: details.node,
      node_path: Map.get(details, :node_path, [details.node]),
      kind: :choice,
      target: action,
      option: Map.fetch!(details, :option)
    }
  end

  defp telemetry_metadata(kind, details, action) do
    Map.merge(details, %{
      kind: kind,
      target: action,
      node_path: Map.get(details, :node_path, [details.node])
    })
  end

  defp tag({:ok, value}, _phase, _context, _mode), do: {:ok, value}

  defp tag({:error, error}, phase, instruction, mode) when is_exception(error) do
    tagged_phase = phase(instruction, phase)

    case exception_strategy(instruction, tagged_phase, error, mode) do
      {:validation, details} ->
        tagged_error = Error.validation_error(Exception.message(error), details)
        {:error, preserve_stacktrace(tagged_error, error)}

      {:merge, details} ->
        {:error, %{error | details: details}}

      {:replace, details} ->
        {:error, replace_details(error, details)}
    end
  end

  defp phase(%Instruction{} = instruction, phase) do
    @phases |> Map.fetch!(kind(instruction)) |> Map.fetch!(phase)
  end

  defp exception_strategy(%Instruction{} = instruction, phase, error, :validation) do
    if kind(instruction) == :step do
      {:validation, merge_error_details(error, error_details(instruction, phase))}
    else
      exception_strategy(instruction, phase, error, :target)
    end
  end

  defp exception_strategy(
         %Instruction{metadata: %{@metadata_key => %{kind: :iterate}}} = instruction,
         phase,
         error,
         _mode
       ) do
    tagged_details =
      instruction
      |> error_details(phase)
      |> preserve_error_path(error)
      |> Map.put(:retry, iterator_retry_policy(error))

    {:replace, tagged_details}
  end

  defp exception_strategy(%Instruction{} = instruction, phase, %{details: existing}, _mode)
       when is_map(existing) do
    {:merge, Map.merge(existing, error_details(instruction, phase))}
  end

  defp exception_strategy(%Instruction{} = instruction, phase, _error, _mode) do
    {:replace, error_details(instruction, phase)}
  end

  defp error_details(instruction, phase), do: instruction |> details() |> Map.put(:phase, phase)

  defp choice_target_name(%Jido.Flow.Choice.Option{name: name}), do: name
  defp choice_target_name(%Jido.Flow.Choice.Fallback{}), do: :fallback

  defp preserve_error_path(details, %{details: %{path: path}}) when is_list(path) do
    Map.put(details, :path, path)
  end

  defp preserve_error_path(details, _error), do: details

  defp merge_error_details(%{details: existing}, target_details) when is_map(existing),
    do: Map.merge(existing, target_details)

  defp merge_error_details(_error, target_details), do: target_details

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

  defp update_details(%Instruction{} = instruction, fun) do
    update_in(instruction.metadata[@metadata_key].details, fun)
  end
end
