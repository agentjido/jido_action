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

  `run_async/4` starts the same run-to-completion work and returns a
  caller-owned handle. Use `await/1`, `await/2`, `handle_message/2`, or
  `cancel/1` from the process that created the handle.

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

  Finite-timeout and async calls deliver telemetry in an owned process.
  Terminal cleanup allows 100 milliseconds for pending delivery. A blocked
  or slow handler can lose events, but cannot prevent timeout or cancellation.
  Keep handlers short. See the execution guide for the delivery contract.
  """

  alias Jido.Action.Error
  alias Jido.Executable
  alias Jido.Exec.Async
  alias Jido.Exec.Execution
  alias Jido.Exec.Flow.Engine
  alias Jido.Exec.Options
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Telemetry.Tracker
  alias Jido.Exec.Transition
  alias Jido.Flow
  alias Jido.Flow.Error, as: FlowError
  alias Jido.Instruction

  @max_receive_timeout 2_147_483_647

  @typedoc "The result of an Action, Instruction, or Flow execution."
  @type exec_result ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:error, Exception.t()}
          | {:error, Exception.t(), term()}

  @typedoc "The opaque one-shot state token shared by one asynchronous handle."
  @opaque async_state :: {:jido_exec_async_state, :atomics.atomics_ref()}

  @typedoc "A caller-owned handle for one asynchronous run-to-completion execution."
  @type async_ref :: %{
          required(:ref) => reference(),
          required(:pid) => pid(),
          required(:owner) => pid(),
          required(:monitor_ref) => reference(),
          required(:state) => async_state()
        }

  @typedoc "The classification result for one asynchronous owner mailbox message."
  @type async_message_result :: {:done, exec_result()} | :ignore | {:error, Exception.t()}

  @type async_control :: %{required(:ref) => reference(), required(:owner) => pid()}

  @typedoc "A local Task.Supervisor PID, registered name, or via reference."
  @type task_supervisor :: pid() | atom() | {:via, module(), term()}

  @typedoc "Options for run-to-completion execution."
  @type run_option ::
          {:task_supervisor, task_supervisor()}
          | {:timeout, timeout()}
          | {:max_concurrency, pos_integer()}
          | {:max_continuations, non_neg_integer()}

  @typedoc "Options for a paused Flow execution."
  @type start_option ::
          {:task_supervisor, task_supervisor()} | {:max_concurrency, pos_integer()}

  @doc """
  Runs an executable Jido artifact.

  All targets accept `task_supervisor: reference`. Use a local Task.Supervisor
  PID, registered name, or `{:via, module, name}` reference, including
  PartitionSupervisor routes. The default is `Jido.Exec.TaskSupervisor`.
  The same reference is kept through nested work and continuations. Exec does
  not derive names or partition keys from its workers and does not fall back
  when the selected supervisor is absent or refuses work.

  Names and via references are resolved at each task start. A later task can
  use a replacement registered under the same name. A PID always selects the
  original process. Tasks are temporary; shutdown stops active tasks and does
  not restart completed or interrupted work. See the configuration guide for
  supervision and migration examples. The former `jido:` option is an error.

  All targets accept `timeout: milliseconds | :infinity`. The default is
  `:infinity`. A finite timeout covers the complete call and terminates its
  execution process and active child work. It does not retry the target.

  All targets accept `:max_concurrency`, which defaults to `8`. A value
  of `1` runs ready work serially. A value greater than `1` runs independent
  ready work concurrently, up to that limit. Map items are native Runic
  runnables, so the same rule applies to them. An Action does not use this
  option itself, but a continuation can select a Flow in the same call. An
  Instruction uses the option rules of its resolved target.

  An Action can return `{:continue, input, target}`. The current executable
  ends, and Exec runs the target as the next executable in the same complete
  call. The default `:max_continuations` value is `256`. Its valid range is 0
  through 10,000. This limit and the complete-call timeout stop infinite
  continuation chains.
  """
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, [run_option()]) ::
          exec_result()
  def run(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    do_run(executable, input, context, opts, nil)
  end

  @doc false
  @spec run_controlled(
          term(),
          map() | keyword() | nil,
          map() | keyword() | nil,
          keyword(),
          reference(),
          pid()
        ) :: exec_result()
  def run_controlled(executable, input, context, opts, ref, owner)
      when is_reference(ref) and is_pid(owner) do
    do_run(executable, input, context, opts, %{ref: ref, owner: owner})
  end

  defp do_run(executable, input, context, opts, control) do
    execution_id = Telemetry.execution_id()
    timeout_owner = initial_timeout_owner(executable)

    with {:ok, opts} <- prepare_run_options(executable, opts),
         :ok <- Options.reject_jido(opts, timeout_owner),
         {:ok, timeout, run_opts} <- Options.take_timeout(opts, timeout_owner),
         {:ok, continuation_limit} <- Options.continuation_limit(run_opts, timeout_owner) do
      execute_with_timeout(
        fn notify ->
          run_chain(
            executable,
            input,
            context,
            run_opts,
            execution_id,
            notify,
            0,
            continuation_limit
          )
        end,
        timeout,
        timeout_owner,
        executable,
        execution_id,
        control
      )
    end
  end

  defp run_chain(
         executable,
         input,
         context,
         opts,
         execution_id,
         notify,
         count,
         continuation_limit
       ) do
    with {:ok, executable, resolved, run_opts} <-
           resolve_run_target(executable, opts, :run) do
      run_resolved_chain(
        executable,
        resolved,
        input,
        context,
        run_opts,
        execution_id,
        notify,
        count,
        continuation_limit
      )
    end
  end

  defp run_resolved_chain(
         executable,
         %Executable{} = resolved,
         input,
         context,
         opts,
         execution_id,
         notify,
         count,
         continuation_limit
       ) do
    notify.({:resolved, timeout_owner(resolved), resolved})

    case run_with_lifecycle(executable, resolved, input, context, opts, execution_id) do
      {:continue, %Transition{} = transition} ->
        continue_chain(
          transition,
          opts,
          execution_id,
          notify,
          count + 1,
          continuation_limit
        )

      result ->
        result
    end
  end

  defp continue_chain(
         %Transition{} = transition,
         opts,
         execution_id,
         notify,
         count,
         continuation_limit
       ) do
    with :ok <- check_continuation_limit(transition, count, continuation_limit) do
      with {:ok, resolved} <- resolve_transition_target(transition) do
        run_resolved_chain(
          transition.target,
          resolved,
          transition.input,
          transition.context,
          opts,
          execution_id,
          notify,
          count,
          continuation_limit
        )
      end
    end
  end

  defp check_continuation_limit(_transition, count, limit) when count <= limit, do: :ok

  defp check_continuation_limit(%Transition{} = transition, count, limit) do
    {:error,
     Error.execution_error("continuation limit exceeded", %{
       action: transition.origin,
       count: count,
       max_continuations: limit,
       retry: false
     })}
  end

  defp resolve_transition_target(%Transition{} = transition) do
    with {:ok, %Executable{} = executable} <- Executable.resolve(transition.target),
         :ok <- Executable.validate(executable) do
      {:ok, executable}
    else
      {:error, cause} ->
        {:error,
         Error.execution_error("action returned an invalid continuation target", %{
           action: transition.origin,
           target: transition.target,
           cause: cause,
           retry: false
         })}
    end
  end

  @doc """
  Runs an executable asynchronously and immediately returns a caller-owned handle.

  The executable can be any target accepted by `run/4`. The background process
  uses the same validation, timeout, telemetry, and result contract as
  `run/4`. Use `await/2` to receive its final result, `handle_message/2` in an
  OTP callback, or `cancel/1` to stop it.

  The handle is tied to the mailbox of the process that starts the execution.
  Only that process can wait for, handle, or cancel it. These operations are
  alternative one-shot terminal consumers.

  Invalid routing raises `Jido.Action.Error.InvalidInputError` before a handle
  exists. Failure to start the async control task raises
  `Jido.Exec.Error.AsyncExecutionError`. Once a handle exists, failures use its
  normal result and message contract.
  """
  @spec run_async(term(), map() | keyword() | nil, map() | keyword() | nil, [run_option()]) ::
          async_ref()
  def run_async(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    Async.start(executable, input, context, opts)
  end

  @doc "Waits up to 5 seconds for an asynchronous execution result."
  @spec await(async_ref()) :: exec_result()
  def await(async_ref), do: Async.await(async_ref)

  @doc """
  Waits for an asynchronous execution result.

  A finite wait timeout cancels the running execution and returns a
  `Jido.Exec.Error.AsyncTimeoutError`. Use `:infinity` to wait without a
  caller-side limit. The `timeout:` option passed to `run_async/4` remains the
  separate complete-call execution limit.
  """
  @spec await(async_ref(), timeout()) :: exec_result()
  def await(async_ref, timeout), do: Async.await(async_ref, timeout)

  @doc """
  Classifies one mailbox message for a caller-owned asynchronous execution.

  Use this function from an OTP callback such as `handle_info/2`. It returns
  `{:done, result}` for the handle's completion message, `:ignore` for an
  unrelated message, or `{:error, error}` for an invalid handle or owner.

  A completion consumes the handle and removes its matching result and
  monitor messages. The same owner process must use `run_async/4` and this
  function.
  """
  @spec handle_message(async_ref(), term()) :: async_message_result()
  def handle_message(async_ref, message), do: Async.handle_message(async_ref, message)

  @doc """
  Cancels a caller-owned asynchronous execution.

  Cancellation stops active Action and Flow work. It does not undo side
  effects that already completed and it does not return a partial Flow
  execution value.
  """
  @spec cancel(async_ref() | pid()) :: :ok | {:error, Exception.t()}
  def cancel(async_ref_or_pid), do: Async.cancel(async_ref_or_pid)

  @doc """
  Starts a paused Flow execution.

  The function accepts a Flow artifact, a module that uses `Jido.Flow`, or an
  Instruction with either Flow target. It validates the Flow, input, context,
  and run options before it returns. The returned execution is paused before
  the first native Runic runnable.

  `:max_concurrency` and the `:task_supervisor` reference are stored on the execution.
  `wave/1` and `continue/1` use the scheduling options. `step/1` and `step/2`
  always execute one runnable.

  A paused execution has no running timeout. `start/4` does not accept the
  `:timeout` option. The step-wise API also does not accept retry, deadline,
  asynchronous execution, cancellation, persistence, or rewind options.
  """
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, [start_option()]) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    execution_id = Telemetry.execution_id()

    with {:ok, executable, resolved, opts} <- resolve_run_target(executable, opts, :start) do
      do_start(executable, resolved, input, context, opts, execution_id)
    end
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
  Executes one ready runnable selected by its value or Runic identity.

  A work failure is returned in the native Runnable with `status: :failed`.
  The operation returns `:ok` because the result was applied to the workflow.
  """
  @spec step(Execution.t(), Runic.Workflow.Runnable.t() | Runic.Identity.t() | integer()) ::
          {:ok, Runic.Workflow.Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, runnable), do: Engine.step(execution, runnable)

  @doc """
  Executes runnables from the set that is currently ready.

  Runnables that become ready during the wave wait for the next operation.
  The stored `max_concurrency` limit applies to the wave. A failed runnable
  stops admission of pending work. Already admitted runnables finish before
  Jido applies their results in the original ready order. A failure can thus
  return fewer runnables than the initial ready set.
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

  defp execute_with_timeout(
         work,
         :infinity,
         _owner,
         _executable,
         _execution_id,
         nil
       ) do
    work.(fn _update -> :ok end)
  end

  defp execute_with_timeout(_work, 0, owner, executable, execution_id, _control) do
    {:error, timeout_error(owner, executable, 0, execution_id)}
  end

  defp execute_with_timeout(work, timeout, owner, executable, execution_id, control)
       when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    caller = self()
    caller_group_leader = Process.group_leader()
    caller_logger_metadata = Logger.metadata()
    result_ref = make_ref()
    deadline = execution_deadline(timeout)
    {:ok, telemetry_tracker} = Tracker.start_link()
    owner_monitor = monitor_control_owner(control)

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> terminate_with_caller(caller, worker) end)
        Process.group_leader(worker, caller_group_leader)
        Logger.metadata(caller_logger_metadata)
        notify = fn update -> send(caller, {result_ref, worker, :update, update}) end

        result = Telemetry.with_tracker(telemetry_tracker, fn -> work.(notify) end)
        send(caller, {result_ref, worker, :result, result})
      end)

    receive_execution_result(
      worker,
      monitor,
      result_ref,
      deadline,
      owner,
      executable,
      timeout,
      execution_id,
      telemetry_tracker,
      control,
      owner_monitor
    )
  end

  defp receive_execution_result(
         worker,
         monitor,
         result_ref,
         deadline,
         owner,
         executable,
         timeout,
         execution_id,
         telemetry_tracker,
         control,
         owner_monitor
       ) do
    receive_timeout = execution_receive_timeout(deadline)

    receive do
      {^result_ref, ^worker, :result, result} ->
        Process.demonitor(monitor, [:flush])
        demonitor_control_owner(owner_monitor)
        Tracker.stop(telemetry_tracker)
        result

      {^result_ref, ^worker, :update, {:resolved, next_owner, next_executable}} ->
        receive_execution_result(
          worker,
          monitor,
          result_ref,
          deadline,
          next_owner,
          next_executable,
          timeout,
          execution_id,
          telemetry_tracker,
          control,
          owner_monitor
        )

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        error = execution_process_error(owner, reason)
        demonitor_control_owner(owner_monitor)
        close_telemetry_tracker(telemetry_tracker, error)
        {:error, error}

      {Async, control_ref, {:stop, error}}
      when not is_nil(control) and control.ref == control_ref and is_exception(error) ->
        demonitor_control_owner(owner_monitor)

        terminate_managed_execution(
          worker,
          monitor,
          result_ref,
          telemetry_tracker,
          error
        )

        {:error, error}

      {:DOWN, ^owner_monitor, :process, control_owner, reason}
      when not is_nil(control) and control.owner == control_owner ->
        error =
          Jido.Exec.Error.cancelled_error("Asynchronous execution owner exited", %{
            operation: :owner_exit,
            owner: control_owner,
            reason: reason,
            retry: false
          })

        terminate_managed_execution(
          worker,
          monitor,
          result_ref,
          telemetry_tracker,
          error
        )

        {:error, error}
    after
      receive_timeout ->
        if execution_deadline_reached?(deadline) do
          error = timeout_error(owner, executable, timeout, execution_id)
          demonitor_control_owner(owner_monitor)

          terminate_managed_execution(
            worker,
            monitor,
            result_ref,
            telemetry_tracker,
            error
          )

          {:error, error}
        else
          receive_execution_result(
            worker,
            monitor,
            result_ref,
            deadline,
            owner,
            executable,
            timeout,
            execution_id,
            telemetry_tracker,
            control,
            owner_monitor
          )
        end
    end
  end

  defp terminate_managed_execution(worker, monitor, result_ref, telemetry_tracker, error) do
    Process.exit(worker, :kill)
    await_worker_down(monitor, worker)
    flush_execution_results(result_ref, worker)
    Tracker.fail_all(telemetry_tracker, error)
    Tracker.stop(telemetry_tracker)
  end

  defp execution_deadline(:infinity), do: :infinity

  defp execution_deadline(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp execution_receive_timeout(:infinity), do: :infinity

  defp execution_receive_timeout(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    min(remaining, @max_receive_timeout)
  end

  defp execution_deadline_reached?(:infinity), do: false

  defp execution_deadline_reached?(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp monitor_control_owner(nil), do: nil
  defp monitor_control_owner(%{owner: owner}), do: Process.monitor(owner)

  defp demonitor_control_owner(nil), do: :ok
  defp demonitor_control_owner(monitor), do: Process.demonitor(monitor, [:flush])

  defp await_worker_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp flush_execution_results(result_ref, worker) do
    receive do
      {^result_ref, ^worker, _kind, _value} -> flush_execution_results(result_ref, worker)
    after
      0 -> :ok
    end
  end

  defp close_telemetry_tracker(tracker, error) do
    Tracker.fail_all(tracker, error)
    Tracker.stop(tracker)
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

  defp initial_timeout_owner(%Instruction{flow: flow}) when not is_nil(flow), do: FlowError
  defp initial_timeout_owner(%Instruction{action: action}) when not is_nil(action), do: Error
  defp initial_timeout_owner(%Instruction{target: target}), do: initial_timeout_owner(target)
  defp initial_timeout_owner(%Flow{}), do: FlowError
  defp initial_timeout_owner(_executable), do: Error

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

  defp execution_name(%Instruction{target: target}) when not is_nil(target),
    do: execution_name(target)

  defp execution_name(%Instruction{action: action}) when not is_nil(action),
    do: execution_name(action)

  defp execution_name(%Instruction{flow: flow}) when not is_nil(flow), do: execution_name(flow)
  defp execution_name(%Flow{name: name}), do: name
  defp execution_name(module) when is_atom(module), do: module
  defp execution_name(executable), do: executable

  defp resolve_run_target(%Instruction{} = instruction, opts, :run) do
    Instruction.prepare_execution_target(instruction, opts)
  end

  defp resolve_run_target(%Instruction{} = instruction, opts, mode) do
    Instruction.prepare_execution(instruction, opts, mode)
  end

  defp resolve_run_target(executable, opts, _mode) do
    with {:ok, %Executable{} = resolved} <- Executable.resolve(executable) do
      {:ok, executable, resolved, opts}
    end
  end

  defp prepare_run_options(%Instruction{} = instruction, opts) do
    Instruction.prepare_run_options(instruction, opts)
  end

  defp prepare_run_options(_executable, opts), do: {:ok, opts}

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

  defp do_start(
         %Instruction{} = instruction,
         %Executable{} = executable,
         input,
         context,
         opts,
         execution_id
       ) do
    with {:ok, instruction} <- normalize_instruction(instruction, input, context) do
      case executable do
        %Executable{kind: :flow} ->
          adapter = adapter_for(executable)
          adapter.start(executable, instruction.params, instruction.context, opts, execution_id)

        %Executable{kind: :action} ->
          stepwise_flow_required(:instruction)
      end
    end
  end

  defp do_start(_target, %Executable{} = executable, input, context, opts, execution_id) do
    adapter = adapter_for(executable)
    adapter.start(executable, input, context, opts, execution_id)
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
