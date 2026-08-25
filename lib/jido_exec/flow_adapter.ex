defmodule Jido.Exec.FlowAdapter do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Action.Telemetry
  alias Jido.Action.Validation
  alias Jido.Executable
  alias Jido.Exec.Execution
  alias Jido.Exec.FlowEngine
  alias Jido.Exec.Options
  alias Jido.Exec.TargetRunner
  alias Jido.Flow
  alias Jido.Flow.Compiled
  alias Jido.Instruction

  @doc false
  @spec validate(Executable.t()) :: :ok | {:error, Exception.t()}
  def validate(%Executable{kind: :flow, target: %Flow{}}), do: :ok

  def validate(%Executable{kind: :flow, target: module}) when is_atom(module) do
    with :ok <- Executable.validate_module_callbacks(module) do
      if function_exported?(module, :flow, 0) do
        :ok
      else
        {:error,
         Error.validation_error("module is not a valid Jido flow", %{
           flow: module,
           reason: "missing flow/0"
         })}
      end
    end
  end

  @doc false
  @spec run(Executable.t(), term(), term(), term(), String.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run(executable, input, context, opts, execution_id) do
    with {:ok, execution} <- start(executable, input, context, opts, execution_id),
         {:ok, execution} <- FlowEngine.continue(execution) do
      FlowEngine.result(execution)
    end
  end

  @doc false
  @spec run_instruction(Executable.t(), Instruction.t(), String.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_instruction(executable, %Instruction{} = instruction, execution_id) do
    with :ok <- validate(executable) do
      run(executable, instruction.params, instruction.context, [], execution_id)
    end
  end

  @doc false
  @spec run_target(Executable.t(), term(), map(), String.t(), keyword()) ::
          {:ok, term()} | {:error, :execution, Exception.t()}
  def run_target(executable, params, context, execution_id, run_opts) do
    case run(executable, params, context, run_opts, execution_id) do
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, :execution, error}
    end
  end

  @doc false
  @spec start(Executable.t(), term(), term(), term(), String.t()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(executable, input, context, opts, execution_id) do
    with :ok <- validate(executable),
         {:ok, flow, compiled} <- materialize(executable) do
      start_flow(flow, compiled, input, context, opts, execution_id)
    end
  end

  @doc false
  @spec lifecycle_metadata(Executable.t(), String.t()) :: :none
  def lifecycle_metadata(_executable, _execution_id), do: :none

  defp materialize(%Executable{target: %Flow{} = flow}) do
    with {:ok, compiled} <- Flow.compile(flow), do: {:ok, flow, compiled}
  end

  defp materialize(%Executable{target: module}) do
    flow = module.flow()

    case if(function_exported?(module, :compiled, 0),
           do: module.compiled(),
           else: Flow.compile(flow)
         ) do
      %Compiled{} = compiled -> {:ok, flow, compiled}
      {:ok, %Compiled{} = compiled} -> {:ok, flow, compiled}
      {:error, error} -> {:error, error}
    end
  end

  defp start_flow(flow, compiled, input, context, opts, execution_id) do
    flow_span =
      Telemetry.start([:jido, :flow], %{execution_id: execution_id, flow: flow.name})

    result =
      with {:ok, run_opts} <- Options.validate_flow(opts),
           {:ok, flow} <- Flow.validate_executable(flow),
           {:ok, input} <- normalize_map(input, :input),
           {:ok, context} <- normalize_map(context, :context),
           {:ok, input} <- validate_data(flow.schema, input, "Flow", flow, :flow_input),
           {:ok, input} <- validate_flow_input_shape(flow, input) do
        target_runner = fn target, params, target_context, target_execution_id, owner ->
          TargetRunner.run(
            target,
            params,
            target_context,
            target_execution_id,
            run_opts,
            flow.name,
            owner
          )
        end

        FlowEngine.start(
          flow,
          compiled,
          input,
          context,
          run_opts,
          fn output -> validate_flow_output(flow, output) end,
          target_runner,
          execution_id,
          %{flow: flow_span}
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
end
