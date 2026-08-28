defmodule Jido.Exec.Action.Adapter do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Executable
  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Continuation
  alias Jido.Exec.Options
  alias Jido.Instruction

  @doc false
  @spec run(Executable.t(), term(), term(), term(), String.t()) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}
  def run(%Executable{target: action} = executable, input, context, opts, execution_id) do
    with {:ok, run_opts} <- Options.validate_action(opts, :action),
         {:ok, instruction} <- normalize_instruction(action, input, context),
         :ok <- Executable.validate(executable) do
      run_instruction_result(action, instruction, run_opts, context, execution_id)
    end
  end

  @doc false
  @spec run_instruction(Executable.t(), Instruction.t(), keyword(), String.t()) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}
  def run_instruction(executable, %Instruction{} = instruction, opts, execution_id) do
    with {:ok, run_opts} <- Options.validate_action(opts, :instruction),
         :ok <- Executable.validate(executable) do
      run_instruction_result(
        executable.target,
        instruction,
        run_opts,
        instruction.context,
        execution_id
      )
    end
  end

  @doc false
  @spec start(Executable.t(), term(), term(), term(), String.t()) :: {:error, Exception.t()}
  def start(_executable, _input, _context, _opts, _execution_id) do
    {:error,
     Error.validation_error("step-wise execution is only supported for flows", %{
       executable_type: :action
     })}
  end

  @doc false
  @spec lifecycle_metadata(Executable.t(), String.t()) :: {:ok, map()}
  def lifecycle_metadata(%Executable{target: action}, execution_id) do
    {:ok, %{execution_id: execution_id, kind: :action, name: action_name(action)}}
  end

  defp normalize_instruction(action, input, context) do
    {:ok, Instruction.normalize_resolved!(action, input, context)}
  rescue
    exception -> {:error, Error.validation_error(Exception.message(exception))}
  end

  defp action_name(module) do
    if function_exported?(module, :name, 0), do: module.name(), else: module
  rescue
    _exception -> module
  catch
    _kind, _reason -> module
  end

  defp run_instruction_result(action, instruction, run_opts, context, execution_id) do
    case Runner.run(instruction, run_opts) do
      {:continue, input, target} ->
        Continuation.run_direct(action, input, target, context, run_opts, execution_id)

      result ->
        result
    end
  end
end
