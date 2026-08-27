defmodule Jido.Exec do
  @moduledoc """
  Runs Actions, Instructions, and Flows through one public execution boundary.

  `run/4` validates the executable and its input, runs the requested work,
  validates normal output, and returns structured errors. A Flow is compiled to
  one native Runic workflow before execution.

      {:ok, output} = Jido.Exec.run(MyApp.SendNotice, %{address: "a@example.com"})

      {:ok, output} =
        Jido.Exec.run(MyApp.NoticeFlow, %{address: "a@example.com"}, %{},
          timeout: 5_000
        )

  ## Step-wise Flow execution

  `ready/1` returns native `Runic.Workflow.Runnable` values. These values can
  represent authored Steps or Runic support nodes such as Join, InputBinding,
  FanOut, and FanIn. `step/1`, `step/2`, and `wave/1` execute and apply these
  native work units. Jido does not hide or drain support runnables.

  Use `continue/1` and `result/1` to get the same final result as `run/4`.
  A failed runnable stops the Flow after Jido applies the failure.

  `workflow/1` returns the live prepared `Runic.Workflow`. `compiled/1`
  returns its `Jido.Flow.Compiled` index and source map. These functions are
  the supported escape hatch for native inspection during a paused execution.

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
  alias Jido.Exec.Flow.Engine
  alias Jido.Exec.Options
  alias Jido.Flow
  alias Jido.Flow.Error, as: FlowError
  alias Jido.Instruction

  @doc """
  Runs an executable Jido artifact.

  All targets accept `jido: MyApp.Jido` for Jido instance routing. This option
  runs Action work under `MyApp.Jido.TaskSupervisor`. The instance must be
  running. Exec does not fall back to its global Task Supervisor when a caller
  requests an instance.

  All targets accept `timeout: milliseconds | :infinity`. The default is
  `:infinity`. A finite timeout covers the complete call and terminates its
  execution process and active child work. It does not retry the target.

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

    with {:ok, resolved} <- resolve_run_target(executable),
         timeout_owner = timeout_owner(resolved),
         {:ok, timeout, run_opts} <- Options.take_timeout(opts, timeout_owner) do
      execute_with_timeout(
        fn ->
          run_with_lifecycle(executable, resolved, input, context, run_opts, execution_id)
        end,
        timeout,
        timeout_owner,
        resolved,
        execution_id
      )
    end
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

  A paused execution has no running timeout. `start/4` does not accept the
  `:timeout` option. The current step-wise API also does not accept retry,
  deadline, cancellation, persistence, or rewind options.
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
  def ready(%Execution{} = execution), do: Engine.ready(execution)

  @doc """
  Returns the current Flow execution status.

  The result is `:running`, `:succeeded`, or `:failed`.
  """
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{} = execution), do: Engine.status(execution)

  @doc """
  Returns the live native Runic workflow for a paused execution.

  This is the execution-state escape hatch to Runic. The returned workflow is
  prepared with the Flow input and Jido runtime context. A caller that executes
  or changes it outside `Jido.Exec` owns the resulting state and cannot apply
  that state back to the Execution value through this API.
  """
  @spec workflow(Execution.t()) :: Runic.Workflow.t()
  def workflow(%Execution{workflow: workflow}), do: workflow

  @doc """
  Returns the derived Flow compilation data for a paused execution.

  Use its component index and source map to connect native Runic nodes to
  authored Flow components.
  """
  @spec compiled(Execution.t()) :: Jido.Flow.Compiled.t()
  def compiled(%Execution{compiled: compiled}), do: compiled

  @doc """
  Executes the first ready native Runic runnable.
  """
  @spec step(Execution.t()) ::
          {:ok, Runic.Workflow.Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution), do: Engine.step(execution)

  @doc """
  Executes one ready runnable selected by its value or integer ID.

  A work failure is returned in the native Runnable with `status: :failed`.
  The operation returns `:ok` because the result was applied to the workflow.
  """
  @spec step(Execution.t(), Runic.Workflow.Runnable.t() | integer()) ::
          {:ok, Runic.Workflow.Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, runnable), do: Engine.step(execution, runnable)

  @doc """
  Executes the complete set of runnables that is currently ready.

  Runnables that become ready during the wave wait for the next operation.
  Stored asynchronous options apply to the wave. All runnables in the selected
  ready set finish before Jido applies the wave results.
  """
  @spec wave(Execution.t()) ::
          {:ok, [Runic.Workflow.Runnable.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{} = execution), do: Engine.wave(execution)

  @doc """
  Continues a paused Flow execution until it reaches a terminal status.

  The function returns the updated execution. Use `result/1` to read its cached
  Flow result.
  """
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{} = execution), do: Engine.continue(execution)

  @doc """
  Returns the cached result of a terminal Flow execution.

  The function returns a validation error while the execution is still running.
  It does not repeat Flow output validation.
  """
  @spec result(Execution.t()) :: {:ok, term()} | {:error, Exception.t()}
  def result(%Execution{} = execution), do: Engine.result(execution)

  defp execute_with_timeout(work, :infinity, _owner, _executable, _execution_id), do: work.()

  defp execute_with_timeout(_work, 0, owner, executable, execution_id) do
    {:error, timeout_error(owner, executable, 0, execution_id)}
  end

  defp execute_with_timeout(work, timeout, owner, executable, execution_id)
       when is_integer(timeout) and timeout > 0 do
    caller = self()
    caller_group_leader = Process.group_leader()
    caller_logger_metadata = Logger.metadata()
    result_ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> terminate_with_caller(caller, worker) end)
        Process.group_leader(worker, caller_group_leader)
        Logger.metadata(caller_logger_metadata)
        send(caller, {result_ref, worker, work.()})
      end)

    receive_execution_result(
      worker,
      monitor,
      result_ref,
      max(deadline - System.monotonic_time(:millisecond), 0),
      owner,
      executable,
      timeout,
      execution_id
    )
  end

  defp receive_execution_result(
         worker,
         monitor,
         result_ref,
         remaining,
         owner,
         executable,
         timeout,
         execution_id
       ) do
    receive do
      {^result_ref, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, execution_process_error(owner, reason)}
    after
      remaining ->
        Process.exit(worker, :kill)
        await_worker_down(monitor, worker)
        flush_execution_results(result_ref, worker)
        {:error, timeout_error(owner, executable, timeout, execution_id)}
    end
  end

  defp await_worker_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp flush_execution_results(result_ref, worker) do
    receive do
      {^result_ref, ^worker, _result} -> flush_execution_results(result_ref, worker)
    after
      0 -> :ok
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

  defp timeout_owner(%Executable{kind: :flow}), do: FlowError
  defp timeout_owner(%Executable{kind: :action}), do: Error

  defp timeout_error(FlowError, executable, timeout, execution_id) do
    FlowError.timeout_error("Flow execution timed out after #{timeout}ms", %{
      timeout: timeout,
      flow: execution_name(executable),
      execution_id: execution_id,
      retry: false
    })
  end

  defp timeout_error(Error, executable, timeout, execution_id) do
    Error.timeout_error("Action execution timed out after #{timeout}ms", %{
      timeout: timeout,
      action: execution_name(executable),
      execution_id: execution_id,
      retry: false
    })
  end

  defp execution_process_error(FlowError, reason) do
    FlowError.internal_error("Flow execution process exited", %{reason: reason})
  end

  defp execution_process_error(Error, reason) do
    Error.internal_error("Action execution process exited", %{reason: reason})
  end

  defp execution_name(%Executable{target: target}), do: execution_name(target)
  defp execution_name(%Flow{name: name}), do: name
  defp execution_name(module) when is_atom(module), do: module

  defp resolve_run_target(%Instruction{target: target}) do
    Executable.resolve(target)
  end

  defp resolve_run_target(executable), do: Executable.resolve(executable)

  defp run_with_lifecycle(
         %Instruction{} = instruction,
         %Executable{} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    metadata = %{
      execution_id: execution_id,
      kind: :instruction,
      name: target_name(instruction.target)
    }

    action_span = Telemetry.start([:jido, :action], metadata)
    result = run_instruction(instruction, executable, input, context, opts, execution_id)
    Telemetry.finish(action_span, result)
    result
  end

  defp run_with_lifecycle(
         _target,
         %Executable{} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    run_resolved_with_lifecycle(executable, input, context, opts, execution_id)
  end

  defp run_resolved_with_lifecycle(
         %Executable{} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    adapter = adapter_for(executable)

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

  defp run_instruction(
         instruction,
         %Executable{} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context) do
      adapter = adapter_for(executable)
      adapter.run_instruction(executable, instruction, opts, execution_id)
    end
  end

  defp do_start(%Instruction{} = instruction, input, context, opts, execution_id) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context),
         {:ok, %Executable{} = executable} <- Executable.resolve(instruction.target) do
      case executable do
        %Executable{kind: :flow} ->
          adapter = adapter_for(executable)
          adapter.start(executable, instruction.params, instruction.context, opts, execution_id)

        %Executable{kind: :action} ->
          stepwise_flow_required(:instruction)
      end
    end
  end

  defp do_start(executable, input, context, opts, execution_id) do
    with {:ok, %Executable{} = executable} <- Executable.resolve(executable) do
      adapter = adapter_for(executable)
      adapter.start(executable, input, context, opts, execution_id)
    end
  end

  defp adapter_for(%Executable{kind: :action}), do: Jido.Exec.Action.Adapter
  defp adapter_for(%Executable{kind: :flow}), do: Jido.Exec.Flow.Adapter

  defp stepwise_flow_required(executable_type) do
    {:error,
     Error.validation_error("step-wise execution is only supported for flows", %{
       executable_type: executable_type
     })}
  end

  defp normalize_instruction(executable, input, context) do
    {:ok, Instruction.normalize_resolved!(executable, input, context)}
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
