defmodule Jido.Exec do
  @moduledoc """
  Public v4 execution boundary.

  The first Flow foundation establishes this module as the single execution
  entry point. Concrete action, instruction, and Flow execution behavior is
  layered in later implementation units.

  ## Telemetry

  Execution emits minimal span events:

  - `[:jido, :exec, :run]` wraps public action, instruction, and flow execution
    with metadata `%{kind: :action | :instruction | :flow, name: term()}`.
  - `[:jido, :flow, :node]` wraps each flow node action invocation with
    metadata `%{flow: flow_name, node: node_name, action: action_module}`.

  Stop events include `:status`; error stop events also include
  `:error_type`. Flow node events may be emitted from task processes when
  flow execution uses `async: true`.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Action.Validation
  alias Jido.Flow
  alias Jido.Instruction

  @flow_run_option_keys [:async, :max_concurrency]

  @doc """
  Runs an executable Jido artifact.

  Flow execution accepts `:async` and `:max_concurrency` options. `:async`
  defaults to `false`; when `true`, independent Flow branches are scheduled by
  Runic with the supplied maximum concurrency. Action and instruction execution
  do not accept run options.
  """
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}
  def run(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    metadata = exec_metadata(executable)

    :telemetry.span([:jido, :exec, :run], metadata, fn ->
      result = do_run(executable, input, context, opts)
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  defp do_run(%Instruction{} = instruction, input, context, opts) do
    with :ok <- reject_run_opts(opts, :instruction),
         {:ok, instruction} <- normalize_instruction(instruction, input, context) do
      run_instruction(instruction)
    end
  end

  defp do_run(%Flow{} = flow, input, context, opts) do
    with {:ok, run_opts} <- validate_flow_run_opts(opts),
         {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow),
         {:ok, input} <- normalize_map(input, :input),
         {:ok, context} <- normalize_map(context, :context),
         {:ok, input} <- validate_data(flow.schema, input, "Flow", flow, :flow_input),
         {:ok, input} <- validate_flow_input_shape(flow, input),
         {:ok, output} <- Flow.Compiler.run_validated(flow, input, context, run_opts),
         {:ok, output} <- validate_flow_output(flow, output) do
      {:ok, output}
    end
  end

  defp do_run(module, input, context, opts) when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} ->
        if function_exported?(module, :__jido_flow__, 0) do
          do_run(module.flow(), input, context, opts)
        else
          with :ok <- reject_run_opts(opts, :action),
               {:ok, instruction} <- normalize_instruction(module, input, context) do
            run_instruction(instruction)
          end
        end

      {:error, reason} ->
        {:error,
         Error.config_error("unknown executable: #{inspect(module)}", %{
           executable: module,
           reason: reason
         })}
    end
  end

  defp do_run(executable, _input, _context, _opts) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{executable: executable})}
  end

  defp exec_metadata(%Instruction{action: action}) do
    %{kind: :instruction, name: action_name(action)}
  end

  defp exec_metadata(%Flow{} = flow), do: %{kind: :flow, name: flow.name}

  defp exec_metadata(module) when is_atom(module) and not is_nil(module) do
    if flow_module?(module) do
      exec_metadata(module.flow())
    else
      %{kind: :action, name: action_name(module)}
    end
  end

  defp exec_metadata(_executable), do: %{kind: :unknown, name: :unknown}

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

  defp result_metadata({:error, error}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp result_metadata({:error, error, _extras}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp result_metadata(_result), do: %{status: :ok}

  defp error_type(error), do: error |> Error.to_map() |> Map.get(:type)

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

  defp run_instruction(%Instruction{action: action} = instruction) do
    if flow_module?(action) do
      with :ok <- Instruction.validate_action_contract(action) do
        do_run(action.flow(), instruction.params, instruction.context, [])
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

  defp tag_flow_output_error({:error, error}, _flow), do: {:error, error}

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
