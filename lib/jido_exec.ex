defmodule Jido.Exec do
  @moduledoc """
  Runs Actions, Instructions, and Flows through one public execution boundary.

  `run/4` validates the executable and its input, runs the requested work,
  validates normal output, and returns structured errors. Flows also support
  paused, step-wise execution.

  ## Telemetry

  Execution emits these nine stable events:

  - `[:jido, :exec, :start]`, `[:jido, :exec, :stop]`, and
    `[:jido, :exec, :error]` for each public or nested execution.
  - `[:jido, :flow, :start]`, `[:jido, :flow, :stop]`, and
    `[:jido, :flow, :error]` for each Flow execution.
  - `[:jido, :flow, :node, :start]`, `[:jido, :flow, :node, :stop]`, and
    `[:jido, :flow, :node, :error]` for each named Flow node.

  Start measurements are exactly `%{system_time: integer,
  monotonic_time: integer}`. Stop and error measurements are exactly
  `%{duration: integer, monotonic_time: integer}`.

  Exec metadata is exactly `%{execution_id: binary, kind: atom, name: term}`.
  Flow metadata is exactly `%{execution_id: binary, flow: binary}`. Node
  metadata is exactly `%{execution_id: binary, flow: binary, node: binary,
  kind: :step | :choice | :map | :reduce | :iterate}`. Error metadata adds
  exactly `:error` and `:error_type` to the lifecycle metadata.

  One `execution_id` correlates an outer Flow, its nodes, and nested Flows.
  The order for serial run-to-completion is Exec start, Flow start, node spans,
  Flow stop or error, and Exec stop or error. A nested Flow starts inside its
  owning node span. With `async: true`, a wave emits node starts in canonical
  order before dispatch and node stop or error events in canonical order after
  it receives all outcomes. These node spans can overlap.

  `start/4` opens the Exec and Flow lifecycles. Each `step/2` or `wave/1` emits
  spans only for the nodes that it runs. The call that makes the execution
  terminal closes the Flow and Exec lifecycles. An execution that the caller
  abandons has no stop or error event.

  Telemetry observes execution only. It does not select ready nodes, control
  scheduling, create helper processes, send runtime messages, or change a
  result.

  ## Step-wise Flow execution

  Use `start/4` to create a paused Flow execution. Use `ready/1` to inspect
  available nodes, `step/1` or `step/2` to execute one node, and `wave/1` to
  execute the current ready set. Use `continue/1` and `result/1` to finish and
  read the same result that `run/4` returns.

  Always pass the latest returned execution to the next operation. Reusing an
  older execution can run an Action more than once. Execution values are
  in-memory values and are not a persistent checkpoint format.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Action.Validation
  alias Jido.Exec.Execution
  alias Jido.Exec.FlowEngine
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Instruction
  alias Jido.Action.Telemetry

  @flow_run_option_keys [:async, :max_concurrency]

  @doc """
  Runs an executable Jido artifact.

  Flow execution accepts `:async` and `:max_concurrency` options. `:async`
  defaults to `false`. When it is `true`, independent Flow nodes and Map items
  can run concurrently. Action and Instruction execution do not accept run
  options.
  """
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}
  def run(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    execution_id = Telemetry.execution_id()
    run_with_lifecycle(executable, input, context, opts, execution_id)
  end

  @doc false
  @spec run_nested(Flow.t(), map(), map(), String.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_nested(%Flow{} = flow, input, context, execution_id) when is_binary(execution_id) do
    run_with_lifecycle(flow, input, context, [], execution_id)
  end

  @doc """
  Starts a paused Flow execution.

  The function accepts a Flow artifact or a module that uses `Jido.Flow`. It
  validates the Flow, input, context, and run options before it returns. The
  returned execution is paused before the first named Flow node.

  `:async` and `:max_concurrency` are stored on the execution and used by
  `wave/1` and `continue/1`. `step/1` and `step/2` always execute one node.

  The current public API does not accept retry, timeout, deadline,
  persistence, cancellation, or rewind options.
  """
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    execution_id = Telemetry.execution_id()
    exec_span = Telemetry.start([:jido, :exec], exec_metadata(executable, execution_id))

    case do_start(executable, input, context, opts, execution_id, exec_span) do
      {:ok, execution} ->
        {:ok, execution}

      {:error, error} = result ->
        Telemetry.error(exec_span, error)
        result
    end
  end

  @doc """
  Returns the ready Flow node names in canonical order.
  """
  @spec ready(Execution.t()) :: [String.t()]
  def ready(%Execution{} = execution), do: FlowEngine.ready(execution)

  @doc """
  Returns the current Flow execution status.

  The result is `:running`, `:succeeded`, or `:failed`.
  """
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{} = execution), do: FlowEngine.status(execution)

  @doc """
  Executes the first ready Flow node in canonical order.
  """
  @spec step(Execution.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution), do: FlowEngine.step(execution)

  @doc """
  Executes one named Flow node when it is ready.

  A node failure is returned as a `Jido.Exec.NodeResult` with `status: :error`.
  The operation still returns `:ok` because the failure was applied to the Flow
  execution. Selection and state errors return `{:error, exception}`.
  """
  @spec step(Execution.t(), String.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, node), do: FlowEngine.step(execution, node)

  @doc """
  Executes the complete set of nodes that is currently ready.

  Nodes that become ready during the wave wait for the next `step/1`, `wave/1`,
  or `continue/1` call. Stored asynchronous options apply to the wave.
  """
  @spec wave(Execution.t()) ::
          {:ok, [NodeResult.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{} = execution), do: FlowEngine.wave(execution)

  @doc """
  Continues a paused Flow execution until it reaches a terminal status.

  The function returns the updated execution. Use `result/1` to read its cached
  Flow result.
  """
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{} = execution), do: FlowEngine.continue(execution)

  @doc """
  Returns the cached result of a terminal Flow execution.

  The function returns a validation error while the execution is still running.
  It does not repeat Flow output validation.
  """
  @spec result(Execution.t()) :: {:ok, term()} | {:error, Exception.t()}
  def result(%Execution{} = execution), do: FlowEngine.result(execution)

  defp run_with_lifecycle(executable, input, context, opts, execution_id) do
    exec_span = Telemetry.start([:jido, :exec], exec_metadata(executable, execution_id))
    result = do_run(executable, input, context, opts, execution_id)
    Telemetry.finish(exec_span, result)
    result
  end

  defp do_run(%Instruction{} = instruction, input, context, opts, execution_id) do
    with :ok <- reject_run_opts(opts, :instruction),
         {:ok, instruction} <- normalize_instruction(instruction, input, context) do
      run_instruction(instruction, execution_id)
    end
  end

  defp do_run(%Flow{} = flow, input, context, opts, execution_id) do
    with {:ok, execution} <- start_flow(flow, input, context, opts, execution_id, nil),
         {:ok, execution} <- FlowEngine.continue(execution) do
      FlowEngine.result(execution)
    end
  end

  defp do_run(module, input, context, opts, execution_id)
       when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} ->
        run_loaded_module(module, input, context, opts, execution_id)

      {:error, reason} ->
        {:error,
         Error.config_error("unknown executable: #{inspect(module)}", %{
           executable: module,
           reason: reason
         })}
    end
  end

  defp do_run(executable, _input, _context, _opts, _execution_id) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{executable: executable})}
  end

  defp run_loaded_module(module, input, context, opts, execution_id) do
    if function_exported?(module, :__jido_flow__, 0) do
      do_run(module.flow(), input, context, opts, execution_id)
    else
      with :ok <- reject_run_opts(opts, :action),
           {:ok, instruction} <- normalize_instruction(module, input, context) do
        run_instruction(instruction, execution_id)
      end
    end
  end

  defp do_start(%Flow{} = flow, input, context, opts, execution_id, exec_span) do
    start_flow(flow, input, context, opts, execution_id, exec_span)
  end

  defp do_start(%Instruction{}, _input, _context, _opts, _execution_id, _exec_span) do
    stepwise_flow_required(:instruction)
  end

  defp do_start(module, input, context, opts, execution_id, exec_span)
       when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} ->
        if function_exported?(module, :__jido_flow__, 0) do
          start_flow(module.flow(), input, context, opts, execution_id, exec_span)
        else
          stepwise_flow_required(:action)
        end

      {:error, reason} ->
        {:error,
         Error.config_error("unknown executable: #{inspect(module)}", %{
           executable: module,
           reason: reason
         })}
    end
  end

  defp do_start(executable, _input, _context, _opts, _execution_id, _exec_span) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{executable: executable})}
  end

  defp start_flow(flow, input, context, opts, execution_id, exec_span) do
    flow_span =
      Telemetry.start([:jido, :flow], %{execution_id: execution_id, flow: flow.name})

    result =
      with {:ok, run_opts} <- validate_flow_run_opts(opts),
           {:ok, flow} <- Flow.validate_executable(flow),
           {:ok, input} <- normalize_map(input, :input),
           {:ok, context} <- normalize_map(context, :context),
           {:ok, input} <- validate_data(flow.schema, input, "Flow", flow, :flow_input),
           {:ok, input} <- validate_flow_input_shape(flow, input) do
        FlowEngine.start(
          flow,
          input,
          context,
          run_opts,
          fn output -> validate_flow_output(flow, output) end,
          execution_id,
          %{flow: flow_span, exec: exec_span}
        )
      end

    case result do
      {:ok, _execution} ->
        result

      {:error, error} ->
        Telemetry.error(flow_span, error)
        result
    end
  end

  defp stepwise_flow_required(executable_type) do
    {:error,
     Error.validation_error("step-wise execution is only supported for flows", %{
       executable_type: executable_type
     })}
  end

  defp exec_metadata(%Instruction{action: action}, execution_id) do
    %{execution_id: execution_id, kind: :instruction, name: action_name(action)}
  end

  defp exec_metadata(%Flow{} = flow, execution_id) do
    %{execution_id: execution_id, kind: :flow, name: flow.name}
  end

  defp exec_metadata(module, execution_id) when is_atom(module) and not is_nil(module) do
    if flow_module?(module) do
      exec_metadata(module.flow(), execution_id)
    else
      %{execution_id: execution_id, kind: :action, name: action_name(module)}
    end
  end

  defp exec_metadata(_executable, execution_id) do
    %{execution_id: execution_id, kind: :unknown, name: :unknown}
  end

  defp flow_module?(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} -> function_exported?(module, :__jido_flow__, 0)
      {:error, _reason} -> false
    end
  end

  defp action_name(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
      module.name()
    else
      module
    end
  rescue
    _exception -> module
  catch
    _kind, _reason -> module
  end

  defp action_name(action), do: action

  defp validate_flow_run_opts(opts) do
    with :ok <- validate_opts_keyword(opts),
         :ok <- validate_known_flow_run_opts(opts),
         :ok <- validate_async_opt(Keyword.get(opts, :async, false)),
         :ok <- validate_max_concurrency_opt(Keyword.get(opts, :max_concurrency, 1)) do
      {:ok,
       [
         async: Keyword.get(opts, :async, false),
         max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online())
       ]}
    end
  end

  defp reject_run_opts(opts, executable_type) do
    with :ok <- validate_opts_keyword(opts) do
      if opts == [] do
        :ok
      else
        {:error,
         Error.validation_error("run options are only supported for flows", %{
           executable_type: executable_type,
           options: Keyword.keys(opts)
         })}
      end
    end
  end

  defp validate_opts_keyword(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, Error.validation_error("run options must be a keyword list")}
    end
  end

  defp validate_opts_keyword(_opts),
    do: {:error, Error.validation_error("run options must be a keyword list")}

  defp validate_known_flow_run_opts(opts) do
    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in @flow_run_option_keys))
    |> case do
      nil ->
        :ok

      option ->
        {:error,
         Error.validation_error("unknown run option: #{inspect(option)}", %{option: option})}
    end
  end

  defp validate_async_opt(async) when is_boolean(async), do: :ok

  defp validate_async_opt(_async) do
    {:error, Error.validation_error("async option must be a boolean", %{option: :async})}
  end

  defp validate_max_concurrency_opt(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency_opt(_max_concurrency) do
    {:error,
     Error.validation_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end

  defp normalize_instruction(executable, input, context) do
    {:ok, Instruction.normalize!(executable, input, context)}
  rescue
    exception -> {:error, Error.validation_error(Exception.message(exception))}
  end

  defp run_instruction(%Instruction{action: action} = instruction, execution_id) do
    if flow_module?(action) do
      with :ok <- Instruction.validate_action_contract(action) do
        do_run(action.flow(), instruction.params, instruction.context, [], execution_id)
      end
    else
      run_action_instruction(instruction)
    end
  end

  defp run_action_instruction(%Instruction{} = instruction) do
    action = instruction.action

    with :ok <- Instruction.validate_action_contract(action),
         {:ok, params} <- validate_action_params(action, instruction.params) do
      case invoke_action_result(action, params, instruction.context) do
        {:ok, output, extras} ->
          case validate_action_output(action, output) do
            {:ok, output} -> success_result(output, extras)
            {:error, error} -> error_result(error, extras)
          end

        {:error, error, extras} ->
          error_result(error, extras)
      end
    end
  end

  @doc false
  @spec invoke_action(module(), map(), map()) ::
          {:ok, term(), term() | :none} | {:error, Exception.t()}
  def invoke_action(action, params, context) do
    case invoke_action_result(action, params, context) do
      {:ok, output, :no_extras} -> {:ok, output, :none}
      {:ok, output, {:extras, extras}} -> {:ok, output, extras}
      {:error, error, _extras} -> {:error, error}
    end
  end

  defp invoke_action_result(action, params, context) do
    case action.run(params, context) do
      {:ok, output} ->
        {:ok, output, :no_extras}

      {:ok, output, extras} ->
        {:ok, output, {:extras, extras}}

      {:error, reason} ->
        {:error, normalize_action_error(reason), :no_extras}

      {:error, reason, extras} ->
        {:error, normalize_action_error(reason), {:extras, extras}}

      other ->
        {:error,
         Error.execution_error("action returned an unsupported result", %{
           action: action,
           result: other
         }), :no_extras}
    end
  rescue
    exception ->
      {:error,
       Error.execution_error(Exception.message(exception), %{
         action: action,
         exception: exception.__struct__
       }), :no_extras}
  catch
    kind, reason ->
      {:error,
       Error.execution_error("action #{kind}", %{
         action: action,
         reason: reason
       }), :no_extras}
  end

  defp success_result(output, :no_extras), do: {:ok, output}
  defp success_result(output, {:extras, extras}), do: {:ok, output, extras}

  defp error_result(error, :no_extras), do: {:error, error}
  defp error_result(error, {:extras, extras}), do: {:error, error, extras}

  @doc false
  @spec validate_action_params(module(), term()) ::
          {:ok, map()} | {:error, Exception.t()}
  def validate_action_params(action, params) do
    with {:ok, validated} <- invoke_validator(action, :validate_params, params) do
      if is_map(validated) do
        {:ok, validated}
      else
        invalid_validator_value(action, :validate_params, validated, :map)
      end
    end
  end

  defp validate_flow_input_shape(_flow, input) when is_map(input), do: {:ok, input}

  defp validate_flow_input_shape(flow, input) do
    {:error,
     Error.validation_error("Flow input validation must return a map", %{
       context: "Flow",
       subject: flow,
       phase: :flow_input,
       value: input
     })}
  end

  @doc false
  @spec validate_action_output(module(), term()) ::
          {:ok, map() | Output.t()} | {:error, Exception.t()}
  def validate_action_output(_action, %Output{} = output), do: Output.validate(output)

  def validate_action_output(action, output) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      output_envelope_required(action, output, :run)
    else
      with {:ok, validated} <- invoke_validator(action, :validate_output, output) do
        validate_output_shape(action, validated, :validate_output)
      end
    end
  end

  def validate_action_output(action, output) do
    output_envelope_required(action, output, :run)
  end

  defp validate_flow_output(flow, %Output{} = output) do
    flow
    |> validate_output_shape(output, :output_schema)
    |> tag_flow_output_error(flow)
  end

  defp validate_flow_output(flow, output) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      output_envelope_required(flow, output, :run)
    else
      with {:ok, validated} <-
             validate_data(flow.output_schema, output, "Flow output", flow, :flow_output) do
        validate_flow_output_shape(flow, validated)
      end
    end
  end

  defp validate_flow_output(flow, output) do
    output_envelope_required(flow, output, :run)
  end

  defp tag_flow_output_error({:ok, output}, _flow), do: {:ok, output}

  defp tag_flow_output_error({:error, %{details: details} = error}, flow)
       when is_map(details) do
    {:error,
     %{
       error
       | details:
           Map.merge(details, %{
             context: "Flow output",
             subject: flow,
             phase: :flow_output
           })
     }}
  end

  defp validate_flow_output_shape(flow, output) when is_map(output) do
    validate_output_shape(flow, output, :output_schema)
  end

  defp validate_flow_output_shape(flow, output) do
    {:error,
     Error.validation_error("Flow output validation must return a map", %{
       context: "Flow output",
       subject: flow,
       phase: :flow_output,
       value: output
     })}
  end

  defp validate_output_shape(_action, %Output{} = output, _callback), do: Output.validate(output)

  defp validate_output_shape(action, output, callback) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      invalid_validator_value(action, callback, output, :map_or_output_envelope)
    else
      {:ok, output}
    end
  end

  defp validate_output_shape(action, output, callback) do
    invalid_validator_value(action, callback, output, :map_or_output_envelope)
  end

  defp output_envelope_required(action, output, callback) do
    {:error,
     Error.execution_error("action returned a value that requires an output envelope", %{
       action: action,
       callback: callback,
       output: output
     })}
  end

  defp invalid_validator_value(action, callback, result, expected) do
    {:error,
     Error.execution_error("action validator returned a value with an invalid shape", %{
       action: action,
       callback: callback,
       expected: expected,
       result: result
     })}
  end

  defp invoke_validator(action, callback, value) do
    case apply(action, callback, [value]) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, reason} ->
        {:error, normalize_action_error(reason)}

      other ->
        {:error,
         Error.execution_error("action validator returned an unsupported result", %{
           action: action,
           callback: callback,
           result: other
         })}
    end
  rescue
    exception ->
      {:error,
       Error.execution_error(Exception.message(exception), %{
         action: action,
         callback: callback,
         exception: exception.__struct__
       })}
  catch
    kind, reason ->
      {:error,
       Error.execution_error("action validator #{kind}", %{
         action: action,
         callback: callback,
         reason: reason
       })}
  end

  defp normalize_map(nil, _field), do: {:ok, %{}}
  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      {:error, Error.validation_error("expected a map or keyword list")}
    end
  end

  defp normalize_map(_value, field) do
    {:error, Error.validation_error("#{field} must be a map or keyword list")}
  end

  defp validate_data(schema, data, context, subject, phase) do
    Validation.open_validate(schema, data, %{
      context: context,
      subject: subject,
      phase: phase
    })
  end

  defp normalize_action_error(error) when is_exception(error), do: error

  defp normalize_action_error(reason) do
    Error.execution_error(to_error_message(reason), %{reason: reason})
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
