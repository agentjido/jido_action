defmodule Jido.Exec.Action.Runner do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Exec.Transition
  alias Jido.Instruction

  @type target_phase :: :input | :execution | :output
  @type target_result ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Transition.t()}
          | {:error, target_phase(), Exception.t()}

  @typep invocation_result ::
           {:ok, term(), Jido.Action.effects()}
           | {:continue, Transition.t()}
           | {:error, target_phase(), Exception.t()}

  @doc "Runs one Action Instruction in the current execution process."
  @spec run(Instruction.t(), keyword()) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Transition.t()}
          | {:error, Exception.t()}
  def run(%Instruction{target: action} = instruction, _run_opts \\ []) do
    direct_result(run_target(action, instruction.params, instruction.context, []))
  end

  @doc false
  @spec run_target(module(), term(), map(), keyword()) :: target_result()
  def run_target(action, params, context, _run_opts) do
    normalize_result(invoke(action, params, context))
  end

  @spec invoke(module(), term(), map()) :: invocation_result()
  defp invoke(action, params, context) do
    with {:ok, params} <- validate_params(action, params) do
      case invoke_result(action, params, context) do
        {:ok, output, effects} ->
          case validate_output(action, output) do
            {:ok, output} -> {:ok, output, effects}
            {:error, error} -> {:error, :output, error}
          end

        {:error, error} ->
          {:error, :execution, error}

        {:continue, %Transition{} = transition} ->
          {:continue, transition}
      end
    else
      {:error, error} -> {:error, :input, error}
    end
  end

  defp invoke_result(action, params, context) do
    case action.run(params, context) do
      {:ok, output} ->
        {:ok, output, []}

      {:ok, output, effects} ->
        if is_list(effects) and not List.improper?(effects) do
          {:ok, output, effects}
        else
          {:error,
           programming_error(
             "the third success element must be a proper list of effect requests",
             %{
               action: action,
               reason: :invalid_effects
             }
           )}
        end

      {:error, reason} ->
        {:error, normalize_action_error(reason)}

      {:error, reason, _extras} ->
        {:error, normalize_action_error(reason)}

      {:continue, %Output{} = input, _target} ->
        invalid_continuation_input(action, input)

      {:continue, input, target} when is_map(input) ->
        {:continue, Transition.new(input, target, action, context)}

      {:continue, input, _target} ->
        invalid_continuation_input(action, input)

      other ->
        {:error,
         programming_error("action returned an unsupported result", %{
           action: action,
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
           exception: exception.__struct__
         },
         __STACKTRACE__
       )}
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
       )}
  end

  defp direct_result({:error, _phase, error}), do: {:error, error}
  defp direct_result(result), do: result

  defp normalize_result({:ok, output, effects}),
    do: Jido.Exec.Effects.attach({:ok, output}, effects)

  defp normalize_result(result), do: result

  defp invalid_continuation_input(action, input) do
    {:error,
     programming_error("action returned an invalid continuation", %{
       action: action,
       reason: :invalid_input,
       input: input
     })}
  end

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

  defp programming_error(message, details) do
    Error.execution_error(message, Map.put(details, :retry, false))
  end
end
