defmodule Jido.Exec.Flow.Adapter do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Action.Validation
  alias Jido.Exec.Execution
  alias Jido.Exec.Flow.Engine
  alias Jido.Exec.Invocation.Runtime, as: InvocationRuntime
  alias Jido.Exec.Options
  alias Jido.Exec.Telemetry
  alias Jido.Flow
  alias Jido.Flow.Compiler
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Error
  alias Jido.Instruction

  defp validate(%Instruction{kind: :flow, target: module} = instruction)
       when is_atom(module) do
    case Instruction.validate_resolved(instruction) do
      :ok ->
        :ok

      {:error, error} ->
        {:error, Error.wrap(error, %{flow: module}, Error.InvalidDefinitionError)}
    end
  end

  @doc false
  @spec run(Instruction.t(), keyword(), Jido.Exec.Controller.call()) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Jido.Exec.Transition.t()}
          | {:error, Exception.t()}
  def run(%Instruction{} = instruction, opts, call) do
    with {:ok, flow, compiled} <- materialize(instruction),
         {:ok, execution} <-
           start_flow(instruction, flow, compiled, opts, call, :run),
         {:ok, execution} <- Engine.run_to_completion(execution, call) do
      Engine.result(execution)
    else
      {:continue, %Jido.Exec.Transition{} = transition} -> {:continue, transition}
      {:error, _error} = error -> error
    end
  end

  @doc false
  @spec start(Instruction.t(), keyword(), String.t()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(%Instruction{} = instruction, opts, execution_id) do
    with {:ok, flow, compiled} <- materialize(instruction),
         :ok <- reject_stepwise_dispatch(flow) do
      start_flow(instruction, flow, compiled, opts, execution_id, :start)
    end
  end

  defp reject_stepwise_dispatch(%Flow{components: components}) do
    if Enum.any?(components, &match?(%Dispatch{}, &1)) do
      {:error,
       Error.invalid_execution_error("step-wise execution does not support Dispatch", %{
         component: :dispatch
       })}
    else
      :ok
    end
  end

  @doc false
  @spec lifecycle_metadata(Instruction.t(), String.t()) :: :none
  def lifecycle_metadata(_instruction, _execution_id), do: :none

  defp materialize(%Instruction{target: %Flow{} = flow}) do
    Compiler.prepare(flow)
  end

  defp materialize(%Instruction{target: module} = instruction) do
    try do
      with :ok <- validate(instruction) do
        case module.flow() do
          %Flow{} = flow ->
            source_map = module_source_map(module)

            Compiler.prepare(flow, [source_map: source_map], [module])

          value ->
            {:error,
             Error.validation_error("Flow flow/0 must return a Jido.Flow", %{
               flow: module,
               value: value
             })}
        end
      end
    rescue
      error ->
        if Error.owned?(error) do
          {:error, error}
        else
          error =
            if is_nil(Map.get(error, :stacktrace)) do
              Map.put(error, :stacktrace, %Splode.Stacktrace{stacktrace: __STACKTRACE__})
            else
              error
            end

          {:error, Error.wrap(error, %{flow: module}, Error.InvalidDefinitionError)}
        end
    catch
      kind, reason ->
        error =
          Error.internal_error("Flow materialization failed", %{
            flow: module,
            kind: kind,
            reason: reason
          })

        {:error, %{error | stacktrace: %Splode.Stacktrace{stacktrace: __STACKTRACE__}}}
    end
  end

  defp module_source_map(module) do
    if function_exported?(module, :__jido_flow_source_map__, 0) do
      module.__jido_flow_source_map__()
    else
      %{}
    end
  end

  defp start_flow(instruction, flow, compiled, opts, call_or_id, mode) do
    execution_id = execution_id(call_or_id)
    validator_module = if is_atom(instruction.target), do: instruction.target

    flow_span =
      Telemetry.start([:jido, :flow], %{execution_id: execution_id, flow: flow.name})

    result =
      with {:ok, run_opts} <- Options.validate_flow(opts, mode),
           {:ok, input} <- normalize_map(instruction.params, :input),
           {:ok, context} <- normalize_map(instruction.context, :context),
           {:ok, context} <- Jido.Exec.Budget.attach(context, :infinity),
           {:ok, input} <- validate_flow_input(validator_module, flow, input),
           {:ok, input} <- validate_flow_input_shape(flow, input) do
        control = %{
          options: run_opts,
          finalizer: fn output -> validate_flow_output(validator_module, flow, output) end,
          execution_id: execution_id,
          lifecycle: %{flow: flow_span},
          invocation: invocation(run_opts, instruction, compiled, call_or_id)
        }

        Engine.start(flow, compiled, input, context, control)
      end

    case result do
      {:ok, _execution} ->
        result

      {:error, error} ->
        Telemetry.error(flow_span, error)
        result
    end
  end

  defp invocation(run_opts, instruction, compiled, %{chain_index: chain_index} = call) do
    case Keyword.fetch(run_opts, :invocation) do
      {:ok, config} ->
        %{
          config: config,
          evidence: InvocationRuntime.flow_evidence(instruction.target, compiled),
          chain_index: chain_index,
          control: call
        }

      :error ->
        nil
    end
  end

  defp invocation(_run_opts, _instruction, _compiled, _execution_id), do: nil

  defp execution_id(%{execution_id: execution_id}), do: execution_id
  defp execution_id(execution_id) when is_binary(execution_id), do: execution_id

  defp validate_flow_input(module, flow, input) when is_atom(module) and not is_nil(module) do
    case Compiler.validate_callback(module, :validate_params, input) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, flow_boundary_error(error, "Flow", flow, :flow_input)}
    end
  end

  defp validate_flow_input(_module, flow, input),
    do: validate_data(flow.schema, input, "Flow", flow, :flow_input)

  defp validate_flow_output(module, flow, output)
       when is_atom(module) and not is_nil(module) and is_map(output) do
    with {:ok, output} <- Compiler.validate_output_shape(flow, output, :run),
         {:ok, output} <- Compiler.validate_callback(module, :validate_output, output) do
      validate_flow_output_shape(flow, output)
    else
      {:error, error} -> tag_flow_output_error({:error, error}, flow)
    end
  end

  defp validate_flow_output(_module, flow, output), do: validate_flow_output(flow, output)

  defp validate_flow_input_shape(_flow, input) when is_map(input), do: {:ok, input}

  defp validate_flow_input_shape(flow, input) do
    {:error,
     Error.invalid_execution_error("Flow input validation must return a map", %{
       context: "Flow",
       subject: flow,
       phase: :flow_input,
       value: input
     })}
  end

  defp validate_flow_output(flow, %Output{} = output) do
    flow
    |> Compiler.validate_output_shape(output, :output_schema)
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

  defp tag_flow_output_error({:error, error}, flow) do
    {:error, flow_boundary_error(error, "Flow output", flow, :flow_output)}
  end

  defp validate_flow_output_shape(flow, output) when is_map(output) do
    flow
    |> Compiler.validate_output_shape(output, :output_schema)
    |> tag_flow_output_error(flow)
  end

  defp validate_flow_output_shape(flow, output) do
    {:error,
     Error.invalid_execution_error("Flow output validation must return a map", %{
       context: "Flow output",
       subject: flow,
       phase: :flow_output,
       value: output
     })}
  end

  defp output_envelope_required(flow, output, callback) do
    {:error,
     Error.execution_error("Flow returned a value that requires an output envelope", %{
       flow: flow,
       callback: callback,
       output: output
     })}
  end

  defp normalize_map(nil, _field), do: {:ok, %{}}
  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      {:error, Error.invalid_execution_error("expected a map or keyword list")}
    end
  end

  defp normalize_map(_value, field) do
    {:error, Error.invalid_execution_error("#{field} must be a map or keyword list")}
  end

  defp validate_data(schema, data, context, subject, phase) do
    case Validation.open_validate(schema, data, %{
           context: context,
           subject: subject,
           phase: phase
         }) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, flow_boundary_error(error, context, subject, phase)}
    end
  end

  defp flow_boundary_error(error, context, subject, phase) do
    wrapped = Error.wrap(error, %{context: context, subject: subject, phase: phase})

    case error do
      %Jido.Action.Error.InvalidInputError{
        message: message,
        details: %{context: action_context, value: value}
      }
      when not is_map(value) and action_context in ["Action", "Action output"] and
             message in [
               "Action validation must return a map",
               "Action output validation must return a map"
             ] ->
        label = if phase == :flow_input, do: "Flow input", else: "Flow output"
        %{wrapped | message: "#{label} validation must return a map"}

      _ ->
        wrapped
    end
  end
end
