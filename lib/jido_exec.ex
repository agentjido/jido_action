defmodule Jido.Exec do
  @moduledoc """
  Public v4 execution boundary.

  The first Flow foundation establishes this module as the single execution
  entry point. Concrete action, instruction, and Flow execution behavior is
  layered in later implementation units.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Instruction

  @doc """
  Runs an executable Jido artifact.
  """
  @spec run(term(), map(), map()) ::
          {:ok, term()} | {:ok, term(), term()} | {:error, Exception.t()}
  def run(executable, input \\ %{}, context \\ %{})

  def run(%Instruction{} = instruction, input, context) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context) do
      run_action_instruction(instruction)
    end
  end

  def run(%Flow{} = flow, input, context) do
    with {:ok, input} <- normalize_map(input, :input),
         {:ok, context} <- normalize_map(context, :context),
         {:ok, input} <- validate_data(flow.schema, input, "Flow", flow, :flow_input),
         {:ok, output} <- Flow.Compiler.run(flow, input, context),
         {:ok, output} <-
           validate_data(flow.output_schema, output, "Flow output", flow, :flow_output) do
      {:ok, output}
    end
  end

  def run(module, input, context) when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} ->
        if function_exported?(module, :flow, 0) do
          run(module.flow(), input, context)
        else
          with {:ok, instruction} <- normalize_instruction(module, input, context) do
            run_action_instruction(instruction)
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

  def run(executable, _input, _context) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{executable: executable})}
  end

  defp normalize_instruction(executable, input, context) do
    {:ok, Instruction.normalize!(executable, input, context)}
  rescue
    exception -> {:error, Error.validation_error(Exception.message(exception))}
  end

  defp run_action_instruction(%Instruction{} = instruction) do
    action = instruction.action

    with :ok <- Instruction.validate_action_contract(action),
         {:ok, params} <- action.validate_params(instruction.params),
         {:ok, output, extras} <- call_action(action, params, instruction.context),
         {:ok, output} <- validate_action_output(action, output) do
      case extras do
        :none -> {:ok, output}
        extras -> {:ok, output, extras}
      end
    end
  end

  defp call_action(action, params, context) do
    case action.run(params, context) do
      {:ok, output} ->
        {:ok, output, :none}

      {:ok, output, extras} ->
        {:ok, output, extras}

      {:error, reason} ->
        {:error, normalize_action_error(reason)}

      {:error, reason, _extras} ->
        {:error, normalize_action_error(reason)}

      other ->
        {:error,
         Error.execution_error("action returned an unsupported result", %{
           action: action,
           result: other
         })}
    end
  rescue
    exception ->
      {:error,
       Error.execution_error(Exception.message(exception), %{
         action: action,
         exception: exception.__struct__
       })}
  catch
    kind, reason ->
      {:error,
       Error.execution_error("action #{kind}", %{
         action: action,
         reason: reason
       })}
  end

  defp validate_action_output(_action, %Output{} = output), do: Output.validate(output)
  defp validate_action_output(action, output), do: action.validate_output(output)

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

  defp validate_data([], data, _context, _subject, _phase), do: {:ok, data}

  defp validate_data(schema, data, context, subject, phase) do
    if zoi_schema?(schema) do
      schema
      |> parse_schema(data)
      |> handle_validation_result(data, schema, context, subject, phase)
    else
      {:error,
       Error.validation_error("Unsupported schema type", %{
         context: context,
         subject: subject,
         phase: phase
       })}
    end
  end

  defp parse_schema(schema, data) do
    if is_map(data) and object_schema?(schema) do
      {known_data, unknown_data} = Map.split(data, schema_keys(schema))
      {Zoi.parse(schema, known_data), unknown_data}
    else
      {Zoi.parse(schema, data), %{}}
    end
  end

  defp handle_validation_result(
         {{:ok, validated}, unknown},
         _data,
         schema,
         _context,
         _subject,
         _phase
       ) do
    validated = if is_struct(validated), do: Map.from_struct(validated), else: validated

    if is_map(validated) and object_schema?(schema) do
      {:ok, Map.merge(unknown, validated)}
    else
      {:ok, validated}
    end
  end

  defp handle_validation_result(
         {{:error, errors}, _unknown},
         _data,
         _schema,
         context,
         subject,
         phase
       ) do
    {:error,
     Error.validation_error(Zoi.prettify_errors(errors), %{
       context: context,
       subject: subject,
       phase: phase,
       errors: Enum.map(errors, &format_zoi_error/1)
     })}
  end

  defp object_schema?(%{__struct__: Zoi.Types.Map}), do: true
  defp object_schema?(%{__struct__: Zoi.Types.Struct}), do: true
  defp object_schema?(_schema), do: false

  defp schema_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(_schema), do: []

  defp format_zoi_error(%{path: path, message: message} = error) do
    %{
      path: path,
      message: message,
      code: Map.get(error, :code)
    }
  end

  defp zoi_schema?(value), do: is_struct(value) && Zoi.Type.impl_for(value) != nil

  defp normalize_action_error(error) when is_exception(error), do: error

  defp normalize_action_error(reason) do
    Error.execution_error(to_error_message(reason), %{reason: reason})
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
