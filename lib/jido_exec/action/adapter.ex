defmodule Jido.Exec.Action.Adapter do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Executable
  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Invocation.Runtime, as: InvocationRuntime
  alias Jido.Exec.Options
  alias Jido.Instruction

  @doc false
  @spec run(Executable.t(), term(), term(), term(), Jido.Exec.Controller.call()) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Jido.Exec.Transition.t()}
          | {:error, Exception.t()}
  def run(%Executable{target: action} = executable, input, context, opts, call) do
    with :ok <- Options.validate_action(opts, :action),
         {:ok, instruction} <- normalize_instruction(action, input, context),
         :ok <- Executable.validate(executable) do
      Runner.run(instruction, invocation(opts, call, action))
    end
  end

  @doc false
  @spec run_instruction(
          Executable.t(),
          Instruction.t(),
          keyword(),
          Jido.Exec.Controller.call()
        ) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Jido.Exec.Transition.t()}
          | {:error, Exception.t()}
  def run_instruction(executable, %Instruction{} = instruction, opts, call) do
    with :ok <- Options.validate_action(opts, :instruction),
         :ok <- Executable.validate(executable) do
      Runner.run(instruction, invocation(opts, call, instruction.target))
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

  defp invocation(opts, call, action) do
    case Keyword.fetch(opts, :invocation) do
      {:ok, config} ->
        %{
          config: config,
          evidence: InvocationRuntime.action_evidence(action),
          id: InvocationRuntime.root_id(config, Map.fetch!(call, :chain_index))
        }

      :error ->
        nil
    end
  end

  defp action_name(module) do
    if function_exported?(module, :name, 0), do: module.name(), else: module
  rescue
    _exception -> module
  catch
    _kind, _reason -> module
  end
end
