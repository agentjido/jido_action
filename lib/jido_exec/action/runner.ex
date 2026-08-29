defmodule Jido.Exec.Action.Runner do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Exec.Transition
  alias Jido.Instruction
  alias Jido.Exec.Telemetry

  @type target_phase :: :input | :execution | :output
  @type target_result ::
          {:ok, term()}
          | {:continue, Transition.t()}
          | {:error, target_phase(), Exception.t()}

  @doc "Runs one Action Instruction through the isolated Action boundary."
  @spec run(Instruction.t(), keyword()) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:continue, Transition.t()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}
  def run(%Instruction{target: action} = instruction, run_opts \\ []) do
    task_supervisor = Keyword.fetch!(run_opts, :task_supervisor)

    case run_isolated(task_supervisor, fn -> do_run(instruction) end) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, process_exit_error(action, reason)}
      {:start_error, reason} -> {:error, process_start_error(action, task_supervisor, reason)}
    end
  end

  defp do_run(%Instruction{target: action} = instruction) do
    with {:ok, params} <- validate_params(action, instruction.params) do
      case invoke_result(action, params, instruction.context) do
        {:ok, output, extras} ->
          case validate_output(action, output) do
            {:ok, output} -> success_result(output, extras)
            {:error, error} -> error_result(error, extras)
          end

        {:error, error, extras} ->
          error_result(error, extras)

        {:continue, %Transition{} = transition} ->
          {:continue, transition}
      end
    end
  end

  @doc false
  @spec run_target(module(), term(), map(), keyword()) :: target_result()
  def run_target(action, params, context, run_opts) do
    task_supervisor = Keyword.fetch!(run_opts, :task_supervisor)

    case run_isolated(task_supervisor, fn -> do_run_target(action, params, context) end) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, :execution, process_exit_error(action, reason)}

      {:start_error, reason} ->
        {:error, :execution, process_start_error(action, task_supervisor, reason)}
    end
  end

  defp do_run_target(action, params, context) do
    case validate_params(action, params) do
      {:ok, params} -> run_validated_target(action, params, context)
      {:error, error} -> {:error, :input, error}
    end
  end

  defp run_validated_target(action, params, context) do
    case invoke_result(action, params, context) do
      {:ok, output, _extras} ->
        case validate_output(action, output) do
          {:ok, output} -> {:ok, output}
          {:error, error} -> {:error, :output, error}
        end

      {:error, error, _extras} ->
        {:error, :execution, error}

      {:continue, %Transition{} = transition} ->
        {:continue, transition}
    end
  end

  defp invoke_result(action, params, context) do
    case action.run(params, context) do
      {:ok, output} ->
        {:ok, output, :no_extras}

      {:ok, output, extras} ->
        {:ok, output, {:extras, extras}}

      {:error, reason} ->
        {:error, normalize_action_error(reason), :no_extras}

      {:error, reason, extras} ->
        {:error, normalize_action_error(reason), {:extras, extras}}

      {:continue, input, target} when is_map(input) and not is_struct(input, Output) ->
        {:continue, Transition.new(input, target, action, context)}

      {:continue, input, _target} ->
        {:error,
         programming_error("action returned an invalid continuation", %{
           action: action,
           reason: :invalid_input,
           input: input
         }), :no_extras}

      other ->
        {:error,
         programming_error("action returned an unsupported result", %{
           action: action,
           result: other
         }), :no_extras}
    end
  rescue
    exception ->
      {:error,
       caught_execution_error(
         Exception.message(exception),
         %{
           action: action,
           exception: exception.__struct__
         },
         __STACKTRACE__
       ), :no_extras}
  catch
    kind, reason ->
      {:error,
       caught_execution_error(
         "action #{kind}",
         %{
           action: action,
           reason: reason
         },
         __STACKTRACE__
       ), :no_extras}
  end

  defp success_result(output, :no_extras), do: {:ok, output}
  defp success_result(output, {:extras, extras}), do: {:ok, output, extras}

  defp error_result(error, :no_extras), do: {:error, error}
  defp error_result(error, {:extras, extras}), do: {:error, error, extras}

  defp validate_params(action, params) do
    with {:ok, validated} <- invoke_validator(action, :validate_params, params) do
      if is_map(validated) do
        {:ok, validated}
      else
        invalid_validator_value(action, :validate_params, validated, :map)
      end
    end
  end

  defp validate_output(_action, %Output{} = output), do: Output.validate(output)

  defp validate_output(action, output) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      output_envelope_required(action, output, :run)
    else
      with {:ok, validated} <- invoke_validator(action, :validate_output, output) do
        validate_output_shape(action, validated, :validate_output)
      end
    end
  end

  defp validate_output(action, output) do
    output_envelope_required(action, output, :run)
  end

  defp validate_output_shape(_action, %Output{} = output, _callback),
    do: Output.validate(output)

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
     programming_error("action returned a value that requires an output envelope", %{
       action: action,
       callback: callback,
       output: output
     })}
  end

  defp invalid_validator_value(action, callback, result, expected) do
    {:error,
     programming_error("action validator returned a value with an invalid shape", %{
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
         programming_error("action validator returned an unsupported result", %{
           action: action,
           callback: callback,
           result: other
         })}
    end
  rescue
    exception ->
      {:error,
       caught_execution_error(
         Exception.message(exception),
         %{
           action: action,
           callback: callback,
           exception: exception.__struct__
         },
         __STACKTRACE__
       )}
  catch
    kind, reason ->
      {:error,
       caught_execution_error(
         "action validator #{kind}",
         %{
           action: action,
           callback: callback,
           reason: reason
         },
         __STACKTRACE__
       )}
  end

  defp caught_execution_error(message, details, stacktrace) do
    Error.ExecutionFailureError.exception(
      message: message,
      details: Map.put(details, :retry, false),
      stacktrace: stacktrace,
      splode: Error
    )
  end

  defp normalize_action_error(error) when is_exception(error), do: error

  defp normalize_action_error(reason) do
    Error.execution_error(to_error_message(reason), %{
      reason: reason,
      retry: Error.retryable?(reason)
    })
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)

  defp run_isolated(task_supervisor, work) do
    caller = self()
    caller_group_leader = Process.group_leader()
    caller_logger_metadata = Logger.metadata()
    telemetry_tracker = Telemetry.tracker()
    ref = make_ref()

    case start_worker(task_supervisor, fn ->
           worker = self()
           spawn(fn -> terminate_with_caller(caller, worker) end)
           Telemetry.put_tracker(telemetry_tracker)

           receive do
             {^ref, :run} ->
               Process.group_leader(worker, caller_group_leader)
               Logger.metadata(caller_logger_metadata)
               send(caller, {ref, worker, work.()})
           end
         end) do
      {:ok, worker} -> await_worker(worker, ref)
      {:error, reason} -> {:start_error, reason}
    end
  end

  defp start_worker(task_supervisor, work) do
    Task.Supervisor.start_child(task_supervisor, work)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp await_worker(worker, ref) do
    monitor = Process.monitor(worker)
    send(worker, {ref, :run})

    receive do
      {^ref, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:exit, reason}
    end
  end

  defp terminate_with_caller(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp process_exit_error(action, reason) do
    programming_error("action execution process exited", %{
      action: action,
      reason: reason
    })
  end

  defp process_start_error(action, task_supervisor, reason) do
    programming_error("action execution process could not start", %{
      action: action,
      task_supervisor: task_supervisor,
      reason: reason
    })
  end

  defp programming_error(message, details) do
    Error.execution_error(message, Map.put(details, :retry, false))
  end
end
