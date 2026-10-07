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

  Return `{:ok, output, requests}` to request deferred
  effects. Actions and Flows return the same explicit batch contract. Exec
  never dispatches requests. A failed complete call returns no executable
  batch, including effects collected before a continuation. Requests must be a
  proper list. See `Jido.Action` for the result and ordering contract.

  Each Action invocation uses a fresh supervised Task for input validation,
  the callback, output validation, and result normalization. This includes
  synchronous calls with `timeout: :infinity`, Flow Actions, and continuations.
  Each root Flow also uses a fresh Task for validation and graph work. Each
  root executable Task exits before the next executable starts.

  One control Task runs under the selected `task_supervisor`. It owns a private
  supervisor for executable and runnable Tasks. Caller or async owner death
  stops the call. Control, Flow, or compound runnable death stops its workers,
  including callbacks that trap exits. Paused operations create a new call
  and leave no active workers after return. See the execution guide for
  process costs and external resource cleanup.

  ## Step-wise Flow execution

  `ready/1` returns small `Jido.Exec.Work` descriptions. Each value identifies
  one native work unit, including support work such as Join, input binding,
  fan-out, and fan-in. `step/1`, `step/2`, and `wave/1` keep these stopping
  points. Jido does not hide or drain support work.

  Pass a ready Work's opaque `token` to `step/2`. Tokens select one unit in
  one execution revision. Get new tokens after each mutation, including for
  work that remains ready. Step and wave results keep the input tokens and
  report each admitted unit's status without retaining application payloads.
  Use `continue/1` and `result/1` to get the same final result as `run/4`.

  `native/1` is the advanced, read-only view of native workflow, compilation,
  and ready data. Its native shapes depend on the Runic version.

  The caller owns the execution lifecycle. Each successful `step/2` or
  `wave/1` call atomically consumes one execution revision. Concurrent use or
  reuse of an older execution returns a `stale flow execution` error before
  Jido dispatches Action work. Always pass the latest returned execution to
  the next operation. Execution values are not persistent checkpoints and
  cannot continue safely after deployment or process recovery.

  Execution keeps Jido Action and Flow telemetry. Map, Reduce, and Iterate can
  also emit item or iteration telemetry. Native Runic support nodes do not get
  an artificial Jido component lifecycle. With invocation replay, lifecycle
  telemetry can describe a replayed Action position. It does not prove that
  Action validation or the Action callback ran.

  `run/4` and `run_async/4` accept an optional `:invocation` configuration.
  A `Jido.Exec.Invocation` host can allow Action work, supply a prior receipt,
  or accept a fresh receipt. Replay starts a new Exec call. It reruns
  orchestration and replaces host-approved Action work with normalized receipt
  outcomes. This edge does not store receipts or provide a durable engine.
  `start/4` rejects the option because an Execution is only in-memory state.

  Telemetry handlers run synchronously in the process that emits the event.
  Supervisor startup also uses a normal synchronous OTP call. Blocked startup
  or cleanup handlers can delay a timeout or cancellation response. Keep host
  registry functions and telemetry handlers short. No helper process isolates them.
  """

  alias Jido.Action.Error
  alias Jido.Exec.Controller
  alias Jido.Exec.Execution
  alias Jido.Exec.Flow.Engine
  alias Jido.Exec.Options
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Transition
  alias Jido.Flow
  alias Jido.Flow.Error, as: FlowError
  alias Jido.Instruction

  @typedoc "The result of an Action, Instruction, or Flow execution."
  @type exec_result ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:error, Exception.t()}

  @typedoc "The opaque one-shot state token shared by one asynchronous handle."
  @opaque async_state :: {:jido_exec_async_state, :atomics.atomics_ref(), pid()}

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
          | {:invocation, Jido.Exec.Invocation.config()}

  @typedoc "Options for a paused Flow execution."
  @type start_option ::
          {:task_supervisor, task_supervisor()} | {:max_concurrency, pos_integer()}

  @doc """
  Runs an executable Jido artifact.

  The `task_supervisor:` option accepts a local Task.Supervisor PID, name, or
  via route. It defaults to `Jido.Exec.TaskSupervisor`. Exec preserves the route
  through nested work and continuations. Names resolve at each task start;
  a PID selects one process. An unavailable supervisor is an error.

  All targets accept `timeout: milliseconds | :infinity`. The default is
  `:infinity`. Zero returns an immediate timeout before work starts. A finite
  timeout covers the complete execution and terminates its worker and active
  child work. Supervisor startup is synchronous and can delay the response
  beyond this limit. Cleanup telemetry can also delay the response. The
  deadline is not reset between Actions or continuations. Exec does not retry.

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

  The optional `invocation:` map must contain exactly `:host`, `:ref`,
  `:run_key`, and `:compatibility`. It applies to each Action in the complete call. The host
  implements `Jido.Exec.Invocation`. See that module and the execution guide
  for the callback and receipt contracts. `start/4` does not accept this
  option.
  """
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, [run_option()]) ::
          exec_result()
  def run(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    Controller.sync(executable, input, context, opts)
  end

  @doc """
  Returns the remaining time recorded in an execution context.

  Returns non-negative milliseconds for a finite execution budget, `:infinity`
  for untimed work, or `nil` when no valid budget is present. An expired budget
  returns `0`. This is a read-only observation, not a cancellation check or a
  guarantee that an external operation has time to finish.

  Exec reserves `context.__jido_exec__` for runtime metadata and adds a
  `:deadline` with an absolute monotonic time in milliseconds or `:infinity`.
  All other context fields stay unchanged. Malformed reserved metadata is
  rejected by execution before Action work starts.

  Pass the context to nested `run/4` or `run_async/4` calls to preserve or
  shorten the budget. Subflows and continuations pass it automatically. Tasks
  can read the budget when given the context; no process-local state is used.
  Passing context does not transfer cancellation ownership or add a timer.

  Step-wise execution retains its supplied context, including any deadline.
  Pause time therefore reduces a supplied finite budget, but does not cause
  automatic cancellation. Without a supplied budget, step-wise work reads
  `:infinity`. Do not persist this runtime metadata or send it to another VM.
  """
  @spec remaining_time(map()) :: non_neg_integer() | :infinity | nil
  def remaining_time(context), do: Jido.Exec.Budget.remaining(context)

  @doc false
  @spec run_controlled(term(), term(), term(), keyword(), map()) :: exec_result()
  def run_controlled(executable, input, context, opts, control),
    do: do_run(executable, input, context, opts, control)

  defp do_run(executable, input, context, opts, control) do
    execution_id = Telemetry.execution_id()
    owner = initial_timeout_owner(executable)

    with {:ok, timeout, run_opts} <- Options.take_timeout(opts, owner),
         {:ok, limit} <- Options.continuation_limit(run_opts, owner) do
      if timeout == 0 do
        {:error,
         Jido.Exec.Error.call_timeout_error("Execution timed out before dispatch", %{
           timeout: 0,
           execution_id: execution_id,
           retry: false
         })}
      else
        Controller.run(
          timeout,
          execution_id,
          control,
          Keyword.has_key?(run_opts, :invocation),
          fn controller ->
            run_chain(executable, input, context, %{
              controller: controller,
              options: run_opts,
              count: 0,
              continuation_limit: limit,
              effect_batches: [],
              transition: nil,
              timeout_owner: owner,
              timeout_target: execution_name(executable)
            })
          end
        )
      end
    end
  end

  defp run_chain(executable, input, context, chain) do
    call = Map.put(chain.controller.call, :chain_index, chain.count)
    transition = chain.transition
    options = chain.options

    {result, error_owner, timeout_target} =
      Controller.execute(
        chain.controller,
        fn ->
          resolution =
            if transition,
              do: resolve_transition_target(transition),
              else: resolve_run_target(executable, input, context)

          with {:ok, instruction} <- resolution do
            Controller.resolved(
              call,
              timeout_owner(instruction),
              execution_name(instruction)
            )

            run_with_lifecycle(instruction, options, call)
          end
        end,
        chain.timeout_owner,
        chain.timeout_target
      )

    case result do
      {:continue, %Transition{} = transition} ->
        next = %{
          chain
          | count: chain.count + 1,
            transition: transition,
            timeout_owner: error_owner,
            timeout_target: timeout_target,
            effect_batches: [transition.effects | chain.effect_batches]
        }

        with :ok <- check_continuation_limit(transition, next.count, next.continuation_limit) do
          run_chain(transition.target, transition.input, transition.context, next)
        end

      result ->
        Jido.Exec.Effects.attach(result, chain.effect_batches |> Enum.reverse() |> Enum.concat())
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
    with {:ok, %Instruction{} = instruction} <-
           Instruction.resolve(transition.target, transition.input, transition.context),
         :ok <- Instruction.validate_resolved(instruction) do
      {:ok, instruction}
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

  The optional invocation host protocol is also the same as `run/4`.

  The handle is tied to the mailbox of the process that starts the execution.
  Only that process can wait for, handle, or cancel it. These operations are
  alternative one-shot terminal consumers.

  Malformed options or invalid routing raise `Jido.Action.Error.InvalidInputError`
  before a handle exists. Failure to start the async control task raises
  `Jido.Exec.Error.AsyncExecutionError`. Once a handle exists, failures use its
  normal result and message contract.
  """
  @spec run_async(term(), map() | keyword() | nil, map() | keyword() | nil, [run_option()]) ::
          async_ref()
  def run_async(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    Controller.start(executable, input, context, opts)
  end

  @doc "Waits up to 5 seconds for an asynchronous execution result."
  @spec await(async_ref()) :: exec_result()
  def await(async_ref), do: Controller.await(async_ref)

  @doc """
  Waits for an asynchronous execution result.

  A finite wait timeout cancels the running execution and returns a
  `Jido.Exec.Error.AsyncTimeoutError`. Use `:infinity` to wait without a
  caller-side limit. The `timeout:` option passed to `run_async/4` remains the
  separate complete-call execution limit.
  """
  @spec await(async_ref(), timeout()) :: exec_result()
  def await(async_ref, timeout), do: Controller.await(async_ref, timeout)

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
  def handle_message(async_ref, message), do: Controller.handle_message(async_ref, message)

  @doc """
  Cancels a caller-owned asynchronous execution.

  Pass the complete handle returned by `run_async/4`.

  Cancellation stops active Action and Flow work. It does not undo side
  effects that already completed and it does not return a partial Flow
  execution value. The owner waits up to 500 milliseconds for a normal stop,
  then forces a stop and waits up to 500 milliseconds for its exit.
  """
  @spec cancel(async_ref()) :: :ok | {:error, Exception.t()}
  def cancel(async_ref), do: Controller.cancel(async_ref)

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
  asynchronous execution, cancellation, invocation replay, persistence, or
  rewind options.
  """
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, [start_option()]) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    execution_id = Telemetry.execution_id()

    Controller.operation(
      fn _call ->
        with {:ok, instruction} <- resolve_run_target(executable, input, context) do
          do_start(instruction, opts, execution_id)
          |> detach_execution()
        end
      end,
      opts,
      execution_id
    )
  end

  @doc """
  Returns small `Jido.Exec.Work` descriptions of the ready units.
  """
  @spec ready(Execution.t()) :: [Jido.Exec.Work.t()]
  def ready(%Execution{} = execution), do: Engine.ready(execution)

  @doc """
  Returns the current Flow execution status.

  The result is `:running`, `:succeeded`, or `:failed`.
  """
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{} = execution), do: Engine.status(execution)

  @doc """
  Returns native data for advanced, read-only inspection.

  The map contains the live prepared `:workflow`, derived `:compiled` data,
  and native `:ready` runnables. Their shapes depend on the Runic version.
  These values can retain application data and callbacks. They are not small
  descriptors or a storage format. This function does not consume a revision.
  A native workflow changed outside Exec cannot be applied back to Execution.
  """
  @spec native(Execution.t()) :: %{
          workflow: Runic.Workflow.t(),
          compiled: Jido.Flow.Compiled.t(),
          ready: [Runic.Workflow.Runnable.t()]
        }
  def native(%Execution{} = execution) do
    Map.take(execution, [:workflow, :compiled, :ready])
  end

  @doc """
  Executes the first ready work unit, including support work.
  """
  @spec step(Execution.t()) ::
          {:ok, Jido.Exec.Work.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution),
    do: mutate(execution, &Engine.step(execution, :first_ready, &1))

  @doc """
  Executes one ready unit selected by its opaque `t:Jido.Exec.Work.token/0`.

  Get the token from `ready/1`. A token is valid only in that execution
  revision. Invalid, stale, and foreign tokens fail before Action work starts.

  A work failure is returned in the Work with `status: :failed`.
  The operation returns `:ok` because the result was applied to the workflow.
  """
  @spec step(Execution.t(), Jido.Exec.Work.token()) ::
          {:ok, Jido.Exec.Work.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, token),
    do: mutate(execution, &Engine.step(execution, token, &1))

  @doc """
  Executes runnables from the set that is currently ready.

  Runnables that become ready during the wave wait for the next operation.
  The stored `max_concurrency` limit applies to the wave. A failed runnable
  stops admission of pending work. Already admitted runnables finish before
  Jido applies their results in the original ready order. A failure can thus
  return fewer runnables than the initial ready set.
  """
  @spec wave(Execution.t()) ::
          {:ok, [Jido.Exec.Work.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{} = execution), do: mutate(execution, &Engine.wave(execution, &1))

  @doc """
  Continues a paused Flow execution until it reaches a terminal status.

  The function returns the updated execution. Use `result/1` to read its cached
  Flow result.
  """
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{} = execution), do: mutate(execution, &Engine.continue(execution, &1))

  @doc """
  Returns the cached result of a terminal Flow execution.

  The function returns a validation error while the execution is still running.
  It does not repeat Flow output validation.
  """
  @spec result(Execution.t()) :: exec_result()
  def result(%Execution{} = execution), do: Engine.result(execution)

  defp mutate(execution, work) do
    Controller.operation(
      fn call -> work.(call) |> detach_execution() end,
      execution.options,
      execution.id
    )
  end

  defp detach_execution({:ok, %Execution{} = execution}), do: {:ok, Engine.detach(execution)}

  defp detach_execution({:ok, work, %Execution{} = execution}),
    do: {:ok, work, Engine.detach(execution)}

  defp detach_execution(result), do: result

  defp timeout_owner(%Instruction{kind: :flow}), do: FlowError
  defp timeout_owner(%Instruction{kind: :action}), do: Error

  defp initial_timeout_owner(%Instruction{target: target}), do: initial_timeout_owner(target)
  defp initial_timeout_owner(%Flow{}), do: FlowError
  defp initial_timeout_owner(_executable), do: Error

  defp execution_name(%Instruction{target: target}),
    do: execution_name(target)

  defp execution_name(%Flow{name: name}), do: name
  defp execution_name(module) when is_atom(module), do: module
  defp execution_name(executable), do: executable

  defp resolve_run_target(%Instruction{} = instruction, input, context),
    do: Instruction.resolve(instruction, input, context)

  defp resolve_run_target(target, input, context) do
    with {:ok, %Instruction{} = instruction} <- Instruction.resolve(target),
         {:ok, input, context} <- normalize_direct_call(instruction.kind, input, context) do
      Instruction.resolve(instruction, input, context)
    end
  end

  defp normalize_direct_call(:action, input, context), do: {:ok, input, context}

  defp normalize_direct_call(:flow, input, context) do
    with {:ok, input} <- normalize_flow_map(input, :input),
         {:ok, context} <- normalize_flow_map(context, :context) do
      {:ok, input, context}
    end
  end

  defp normalize_flow_map(nil, _field), do: {:ok, %{}}
  defp normalize_flow_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_flow_map(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      {:error, FlowError.invalid_execution_error("expected a map or keyword list")}
    end
  end

  defp normalize_flow_map(_value, field) do
    {:error, FlowError.invalid_execution_error("#{field} must be a map or keyword list")}
  end

  defp run_with_lifecycle(%Instruction{} = instruction, opts, call) do
    with {:ok, context} <- Jido.Exec.Budget.attach(instruction.context, call.deadline) do
      instruction = %{instruction | context: context}
      adapter = adapter_for(instruction)

      case adapter.lifecycle_metadata(instruction, call.execution_id) do
        {:ok, metadata} ->
          action_span = Telemetry.start([:jido, :action], metadata)
          result = adapter.run(instruction, opts, call)
          Telemetry.finish(action_span, result)
          result

        :none ->
          adapter.run(instruction, opts, call)
      end
    end
  end

  defp do_start(%Instruction{kind: :flow} = instruction, opts, execution_id) do
    adapter_for(instruction).start(instruction, opts, execution_id)
  end

  defp do_start(%Instruction{kind: :action}, _opts, _execution_id),
    do: stepwise_flow_required(:action)

  defp adapter_for(%Instruction{kind: :action}), do: Jido.Exec.Action.Adapter
  defp adapter_for(%Instruction{kind: :flow}), do: Jido.Exec.Flow.Adapter

  defp stepwise_flow_required(executable_type) do
    {:error,
     Error.validation_error("step-wise execution is only supported for flows", %{
       executable_type: executable_type
     })}
  end
end
