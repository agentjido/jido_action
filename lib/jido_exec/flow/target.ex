defmodule Jido.Exec.Flow.Target do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Invocation.Runtime, as: InvocationRuntime
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Transition
  alias Jido.Instruction

  @type kind :: :step | :choice | :map | :reduce | :iterate | :dispatch
  @type phase :: :input | :execution | :output
  @type t :: Instruction.t()
  @type runner ::
          (t(), String.t() ->
             {:ok, term()}
             | {:ok, term(), Jido.Action.effects()}
             | {:continue, Transition.t()}
             | {:error, phase(), Exception.t()})

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
  @spec step(map()) :: t()
  def step(%{name: name, call: {template, _params}}) do
    new(:step, template, %{node: name})
  end

  @doc false
  @spec choice(map(), map()) :: t()
  def choice(choice, %{name: option, call: {template, _params}}) do
    new(:choice, template, %{
      node: choice.name,
      option: option
    })
  end

  @doc false
  @spec map(map(), map()) :: t()
  def map(map, item) do
    {template, _params} = map.call

    new(:map, template, %{
      node: map.name,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  @doc false
  @spec reduce(map(), map()) :: t()
  def reduce(reduce, item) do
    {template, _params} = reduce.call

    new(:reduce, template, %{
      node: reduce.name,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  @doc false
  @spec iterator(map(), non_neg_integer(), String.t(), non_neg_integer()) :: t()
  def iterator(iterator, iteration_index, iteration_id, state_revision) do
    {template, _params} = iterator.call

    new(:iterate, template, %{
      node: iterator.name,
      iteration_index: iteration_index,
      iteration_id: iteration_id,
      state_revision: state_revision
    })
  end

  @doc false
  @spec dispatch(map(), :decision | :expander) :: t()
  def dispatch(dispatch, phase) when phase in [:decision, :expander] do
    {template, _params} = Map.fetch!(dispatch, phase)

    new(:dispatch, template, %{node: dispatch.name, dispatch_phase: phase})
  end

  @doc false
  @spec new(kind(), Instruction.template_t(), map()) :: t()
  def new(kind, %Instruction{} = template, details)
      when kind in [:step, :choice, :map, :reduce, :iterate, :dispatch] and is_map(details) do
    metadata = Map.put(template.metadata, @metadata_key, %{kind: kind, details: details})
    %{template | metadata: metadata}
  end

  @doc false
  @spec run(t(), term(), map(), String.t(), runner()) ::
          {:ok, term(), [term()]} | {:continue, Transition.t()} | {:error, Exception.t()}
  def run(%Instruction{} = instruction, params, context, execution_id, target_runner) do
    case Instruction.bind(instruction, params, context) do
      {:ok, instruction} ->
        run_bound(instruction, execution_id, target_runner)

      {:error, error} ->
        tag_validation({:error, error}, instruction)
    end
  end

  defp run_bound(instruction, execution_id, target_runner) do
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
  @spec invoke(
          Instruction.t(),
          String.t(),
          String.t(),
          map() | nil,
          (function() -> term())
        ) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Transition.t()}
          | {:error, phase(), Exception.t()}
  def invoke(%Instruction{} = instruction, execution_id, flow_name, invocation, invoke) do
    span = start_span(instruction, execution_id, flow_name)

    result =
      invoke.(fn ->
        Runner.run_target(instruction, bind_invocation(invocation, instruction))
      end)
      |> authorize_transition(instruction)

    finish_span(span, result)
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

  defp bind_invocation(nil, _instruction), do: nil

  defp bind_invocation(%{config: config, chain_index: chain_index} = invocation, instruction) do
    Map.put(invocation, :id, InvocationRuntime.target_id(config, chain_index, instruction))
  end

  defp start_span(%Instruction{target: target} = instruction, execution_id, flow_name) do
    metadata = telemetry_metadata(instruction, target)

    Telemetry.start(
      [:jido, :flow, :target],
      Map.merge(metadata, %{execution_id: execution_id, flow: flow_name})
    )
  end

  defp finish_span(span, {:error, _phase, error} = result) do
    Telemetry.error(span, error)
    result
  end

  defp finish_span(span, result) do
    Telemetry.stop(span)
    result
  end

  defp authorize_transition({:continue, %Transition{} = transition}, instruction) do
    if kind(instruction) == :dispatch and details(instruction).dispatch_phase == :expander do
      {:continue, transition}
    else
      continuation_not_allowed(transition, instruction)
    end
  end

  defp authorize_transition(result, _instruction), do: result

  defp continuation_not_allowed(%Transition{} = transition, instruction) do
    target_details = details(instruction)

    {:error, :execution,
     Error.execution_error(
       "action continuation is not allowed from this Flow position",
       %{
         action: transition.origin,
         component: target_details.node,
         component_kind: kind(instruction),
         retry: false
       }
     )}
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
