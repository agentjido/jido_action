defmodule Jido.Exec do
  @moduledoc """
  Runs Actions, Instructions, and Flows through one public execution boundary.

  `run/4` validates the executable and its input, runs the requested work,
  validates normal output, and returns structured errors. A Flow is compiled to
  one native Runic workflow before execution.

  ## Step-wise Flow execution

  `ready/1` returns native `Runic.Workflow.Runnable` values. These values can
  represent authored Steps or Runic support nodes such as Join, InputBinding,
  FanOut, and FanIn. `step/1`, `step/2`, and `wave/1` execute and apply these
  native work units. Jido does not hide or drain support runnables.

  Use `continue/1` and `result/1` to get the same final result as `run/4`.
  A failed runnable stops the Flow after Jido applies the failure.

  The caller owns the execution lifecycle. Each successful `step/2` or
  `wave/1` call atomically consumes one execution revision. Concurrent use or
  reuse of an older execution returns a `stale flow execution` error before
  Jido dispatches Action work. Always pass the latest returned execution to
  the next operation. Execution values are not persistent checkpoints and
  cannot continue safely after deployment or process recovery.

  Execution keeps Jido Action and Flow telemetry. Map, Reduce, and Iterate can
  also emit item or iteration telemetry. Native Runic support nodes do not get
  an artificial Jido component lifecycle.
  """

  alias Jido.Action.Error
  alias Jido.Action.Telemetry
  alias Jido.Executable
  alias Jido.Exec.Execution
  alias Jido.Exec.FlowEngine
  alias Jido.Instruction

  @doc """
  Runs an executable Jido artifact.

  All targets accept `jido: MyApp.Jido` for Jido instance routing. This option
  runs Action work under `MyApp.Jido.TaskSupervisor`. The instance must be
  running. Exec does not fall back to its global Task Supervisor when a caller
  requests an instance.

  A Flow target also accepts `:async` and `:max_concurrency`. `:async` defaults
  to `false`. When it is `true`, independent Runic runnables and Map items can
  run concurrently. One shared `max_concurrency` budget limits active Action
  calls across the execution and nested Flow targets. The same numeric limit
  separately bounds asynchronous helper workers. Nested work runs inline when
  all helper-worker slots are in use. An Instruction uses the option rules of
  its resolved target. An Action target accepts no Flow policy options.
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

  @doc """
  Starts a paused Flow execution.

  The function accepts a Flow artifact, a module that uses `Jido.Flow`, or an
  Instruction with either Flow target. It validates the Flow, input, context,
  and run options before it returns. The returned execution is paused before
  the first native Runic runnable.

  `:async`, `:max_concurrency`, and common `:jido` routing are stored on the
  execution. `wave/1` and `continue/1` use the scheduling options. `step/1` and
  `step/2` always execute one runnable.

  The current public API does not accept retry, timeout, deadline,
  persistence, cancellation, or rewind options.
  """
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    execution_id = Telemetry.execution_id()
    do_start(executable, input, context, opts, execution_id)
  end

  @doc """
  Returns the native Runic runnables that are ready.
  """
  @spec ready(Execution.t()) :: [Runic.Workflow.Runnable.t()]
  def ready(%Execution{} = execution), do: FlowEngine.ready(execution)

  @doc """
  Returns the current Flow execution status.

  The result is `:running`, `:succeeded`, or `:failed`.
  """
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{} = execution), do: FlowEngine.status(execution)

  @doc """
  Executes the first ready native Runic runnable.
  """
  @spec step(Execution.t()) ::
          {:ok, Runic.Workflow.Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution), do: FlowEngine.step(execution)

  @doc """
  Executes one ready runnable selected by its value or integer ID.

  A work failure is returned in the native Runnable with `status: :failed`.
  The operation returns `:ok` because the result was applied to the workflow.
  """
  @spec step(Execution.t(), Runic.Workflow.Runnable.t() | integer()) ::
          {:ok, Runic.Workflow.Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, runnable), do: FlowEngine.step(execution, runnable)

  @doc """
  Executes the complete set of runnables that is currently ready.

  Runnables that become ready during the wave wait for the next operation.
  Stored asynchronous options apply to the wave. All runnables in the selected
  ready set finish before Jido applies the wave results.
  """
  @spec wave(Execution.t()) ::
          {:ok, [Runic.Workflow.Runnable.t()], Execution.t()} | {:error, Exception.t()}
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

  defp run_with_lifecycle(%Instruction{} = instruction, input, context, opts, execution_id) do
    metadata = %{
      execution_id: execution_id,
      kind: :instruction,
      name: target_name(instruction.target)
    }

    action_span = Telemetry.start([:jido, :action], metadata)
    result = run_instruction(instruction, input, context, opts, execution_id)
    Telemetry.finish(action_span, result)
    result
  end

  defp run_with_lifecycle(executable, input, context, opts, execution_id) do
    with {:ok, resolved} <- Executable.resolve(executable) do
      run_resolved_with_lifecycle(resolved, input, context, opts, execution_id)
    end
  end

  defp run_resolved_with_lifecycle(
         %Executable{adapter: adapter} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    case adapter.lifecycle_metadata(executable, execution_id) do
      {:ok, metadata} ->
        action_span = Telemetry.start([:jido, :action], metadata)
        result = adapter.run(executable, input, context, opts, execution_id)
        Telemetry.finish(action_span, result)
        result

      :none ->
        adapter.run(executable, input, context, opts, execution_id)
    end
  end

  defp run_instruction(instruction, input, context, opts, execution_id) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context),
         {:ok, %Executable{adapter: adapter} = executable} <-
           Executable.resolve(instruction.target) do
      adapter.run_instruction(executable, instruction, opts, execution_id)
    end
  end

  defp do_start(%Instruction{} = instruction, input, context, opts, execution_id) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context),
         {:ok, %Executable{} = executable} <- Executable.resolve(instruction.target) do
      case executable do
        %Executable{kind: :flow, adapter: adapter} ->
          adapter.start(executable, instruction.params, instruction.context, opts, execution_id)

        %Executable{kind: :action} ->
          stepwise_flow_required(:instruction)
      end
    end
  end

  defp do_start(executable, input, context, opts, execution_id) do
    with {:ok, %Executable{adapter: adapter} = executable} <-
           Executable.resolve(executable) do
      adapter.start(executable, input, context, opts, execution_id)
    end
  end

  defp stepwise_flow_required(executable_type) do
    {:error,
     Error.validation_error("step-wise execution is only supported for flows", %{
       executable_type: executable_type
     })}
  end

  defp normalize_instruction(executable, input, context) do
    {:ok, Instruction.normalize!(executable, input, context)}
  rescue
    exception -> {:error, Error.validation_error(Exception.message(exception))}
  end

  defp target_name(module) when is_atom(module) do
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

  defp target_name(target), do: target
end
