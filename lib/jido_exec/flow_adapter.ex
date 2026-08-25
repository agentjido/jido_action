defmodule Jido.Exec.FlowAdapter do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Action.Telemetry
  alias Jido.Action.Validation
  alias Jido.Executable
  alias Jido.Exec.Execution
  alias Jido.Exec.FlowEngine
  alias Jido.Exec.Options
  alias Jido.Exec.TargetRunner
  alias Jido.Flow
  alias Jido.Flow.Error
  alias Jido.Instruction

  @doc false
  @spec validate(Executable.t()) :: :ok | {:error, Exception.t()}
  def validate(%Executable{kind: :flow, target: %Flow{}}), do: :ok

  def validate(%Executable{kind: :flow, target: module}) when is_atom(module) do
    case Executable.validate_action_compatible_callbacks(module) do
      :ok ->
        if function_exported?(module, :flow, 0) do
          :ok
        else
          {:error,
           Error.validation_error("module is not a valid Jido flow", %{
             flow: module,
             reason: "missing flow/0"
           })}
        end

      {:error, error} ->
        {:error, flow_definition_error(error, module)}
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
  @spec run_instruction(Executable.t(), Instruction.t(), keyword(), String.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_instruction(executable, %Instruction{} = instruction, opts, execution_id) do
    with :ok <- validate(executable) do
      run(executable, instruction.params, instruction.context, opts, execution_id)
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
    try do
      case module.flow() do
        %Flow{} = flow ->
          source_map = module_source_map(module)

          with {:ok, compiled} <- Flow.compile(flow, source_map: source_map) do
            {:ok, flow, compiled}
          end

        value ->
          {:error,
           Error.validation_error("Flow flow/0 must return a Jido.Flow", %{
             flow: module,
             value: value
           })}
      end
    rescue
      error ->
        if Error.owned?(error),
          do: {:error, error},
          else: {:error, flow_definition_error(error, module)}
    catch
      kind, reason ->
        {:error,
         Error.internal_error("Flow materialization failed", %{
           flow: module,
           kind: kind,
           reason: reason
         })}
    end
  end

  defp module_source_map(module) do
    if function_exported?(module, :__jido_flow_source_map__, 0) do
      case module.__jido_flow_source_map__() do
        source_map when is_map(source_map) ->
          source_map

        value ->
          raise Error.validation_error("Flow source map must be a map", %{
                  flow: module,
                  value: value
                })
      end
    else
      %{}
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
     Error.invalid_execution_error("Flow input validation must return a map", %{
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

  defp tag_flow_output_error({:error, error}, flow) do
    {:error, flow_boundary_error(error, "Flow output", flow, :flow_output)}
  end

  defp validate_flow_output_shape(flow, output) when is_map(output) do
    flow
    |> validate_output_shape(output, :output_schema)
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

  defp validate_output_shape(_action, %Output{} = output, _callback), do: Output.validate(output)

  defp validate_output_shape(action, output, callback) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      invalid_validator_value(action, callback, output, :map_or_output_envelope)
    else
      {:ok, output}
    end
  end

  defp output_envelope_required(flow, output, callback) do
    {:error,
     Error.execution_error("Flow returned a value that requires an output envelope", %{
       flow: flow,
       callback: callback,
       output: output
     })}
  end

  defp invalid_validator_value(flow, callback, result, expected) do
    {:error,
     Error.execution_error("Flow validator returned a value with an invalid shape", %{
       flow: flow,
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
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{
        context: context,
        subject: subject,
        phase: phase,
        cause: error.__struct__
      })

    Error.invalid_execution_error(Exception.message(error), details)
  end

  defp flow_definition_error(error, module) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{flow: module, cause: error.__struct__})

    Error.validation_error(Exception.message(error), details)
  end
end
