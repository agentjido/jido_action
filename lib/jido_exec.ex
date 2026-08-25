defmodule Jido.Exec do
  @moduledoc """
  Runs Actions, Instructions, and Flows through one public execution boundary.

  `run/4` validates the executable and its input, runs the requested work,
  validates normal output, and returns structured errors. Flows also support
  paused, step-wise execution. One Flow execution is a caller-owned, in-memory
  session with its own bounded concurrency settings.

  ## Telemetry

  Execution emits 21 stable events. The first 12 describe Action, Flow, named
  node, and selected target lifecycles:

  - `[:jido, :action, :start]`, `[:jido, :action, :stop]`, and
    `[:jido, :action, :error]` for each direct Action or Instruction execution.
  - `[:jido, :flow, :start]`, `[:jido, :flow, :stop]`, and
    `[:jido, :flow, :error]` for each Flow execution.
  - `[:jido, :flow, :node, :start]`, `[:jido, :flow, :node, :stop]`, and
    `[:jido, :flow, :node, :error]` for each named Flow node.
  - `[:jido, :flow, :target, :start]`, `[:jido, :flow, :target, :stop]`, and
    `[:jido, :flow, :target, :error]` for each Step target and selected Choice
    target.

  Nine work-unit events describe Action calls inside collection nodes:

  - Map items use `[:jido, :flow, :map, :item, :start]`, `:stop`, and `:error`.
  - Reduce items use `[:jido, :flow, :reduce, :item, :start]`, `:stop`, and
    `:error`.
  - Iterate iterations use `[:jido, :flow, :iterate, :iteration, :start]`,
    `:stop`, and `:error`.

  Start measurements are exactly `%{system_time: integer,
  monotonic_time: integer}`. Stop and error measurements are exactly
  `%{duration: integer, monotonic_time: integer}`.

  Action metadata is exactly `%{execution_id: binary,
  kind: :action | :instruction, name: term}`. Flow metadata is exactly
  `%{execution_id: binary, flow: binary}`. Node metadata is exactly
  `%{execution_id: binary, flow: binary, node: binary, kind: :step | :choice |
  :map | :reduce | :iterate}`. Error metadata adds exactly `:error` and
  `:error_type` to the lifecycle metadata.

  Target metadata is exactly `%{execution_id: binary, flow: binary, node:
  binary, kind: :step | :choice, target: module, option: term}`. `option` is
  `nil` for a Step and is the selected option name for a Choice.

  Map and Reduce item metadata adds `node`, `target`, `item_index`, and
  `item_id` to the Flow correlation fields. Iterate iteration metadata adds
  `node`, `target`, `iteration_index`, `iteration_id`, and `state_revision`.
  Their `kind` values are `:map_item`, `:reduce_item`, and
  `:iterate_iteration`.

  One `execution_id` correlates a lifecycle with any nested Flow work. A direct
  Action emits Action start and then Action stop or error. Serial Flow execution
  emits Flow start, node spans, and then Flow stop or error. A nested Flow starts
  inside its owning node span. An Instruction that targets a Flow has the Flow
  lifecycle inside its Action lifecycle. With `async: true`, each worker starts
  and finishes its node span around the actual node work. These spans can overlap,
  and their start and stop events can follow scheduler and completion order.
  Asynchronous workers copy the caller's Logger metadata at dispatch time.

  `start/4` opens the Flow lifecycle. Each `step/2` or `wave/1` emits spans only
  for the nodes that it runs. The call that makes the execution terminal closes
  the Flow lifecycle. An execution that the caller abandons has no stop or error
  event. A Step or selected Choice Action is represented by its node and target
  spans. A collection Action is represented by its node and work-unit spans.
  Flow targets do not emit a separate direct Action lifecycle. Work-unit events
  can have high volume. Attach a handler only when you need item or iteration
  detail.

  Telemetry observes execution only. It does not select ready nodes, control
  scheduling, create helper processes, send runtime messages, or change a
  result.

  ## Step-wise Flow execution

  Use `start/4` to create a paused Flow execution. Use `ready/1` to inspect
  available nodes, `step/1` or `step/2` to execute one node, and `wave/1` to
  execute the current ready set. Use `continue/1` and `result/1` to finish and
  read the same result that `run/4` returns.

  A node failure stops the Flow before Jido dispatches more work. A serial wave
  stops at its first failed node. Nodes in an asynchronous wave are already in
  progress and can also finish. If two or more of them fail, `result/1` returns
  `Jido.Exec.FlowFailureError` with all failures in canonical node order.

  The caller owns the execution lifecycle. Each successful `step/2` or
  `wave/1` call atomically consumes one execution revision. Concurrent use or
  reuse of an older execution returns a `stale flow execution` error before
  Jido dispatches Action work. Always pass the latest returned execution to
  the next operation. Execution values are not persistent checkpoints and
  cannot continue safely after deployment or process recovery.
  """

  alias Jido.Action.Error
  alias Jido.Action.Telemetry
  alias Jido.Executable
  alias Jido.Exec.Execution
  alias Jido.Exec.FlowEngine
  alias Jido.Exec.NodeResult
  alias Jido.Exec.Options
  alias Jido.Instruction

  @doc """
  Runs an executable Jido artifact.

  Flow execution accepts `:async` and `:max_concurrency` options. `:async`
  defaults to `false`. When it is `true`, independent Flow nodes and Map items
  can run concurrently. One shared `max_concurrency` budget limits active
  Action calls across the execution and nested Flow targets. The same numeric
  limit separately bounds asynchronous helper workers. Nested work runs inline
  when all helper-worker slots are in use. Action and Instruction execution do
  not accept run options.
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

  The function accepts a Flow artifact or a module that uses `Jido.Flow`. It
  validates the Flow, input, context, and run options before it returns. The
  returned execution is paused before the first named Flow node.

  `:async` and `:max_concurrency` are stored on the execution and used by
  `wave/1` and `continue/1`. `step/1` and `step/2` always execute one node.

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
  Returns the ready Flow node names in canonical order.
  """
  @spec ready(Execution.t()) :: [String.t()]
  def ready(%Execution{} = execution), do: FlowEngine.ready(execution)

  @doc """
  Returns the current Flow execution status.

  The result is `:running`, `:succeeded`, or `:failed`.
  """
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{} = execution), do: FlowEngine.status(execution)

  @doc """
  Executes the first ready Flow node in canonical order.
  """
  @spec step(Execution.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution), do: FlowEngine.step(execution)

  @doc """
  Executes one named Flow node when it is ready.

  A node failure is returned as a `Jido.Exec.NodeResult` with `status: :error`.
  The operation still returns `:ok` because the failure was applied to the Flow
  execution. Selection and state errors return `{:error, exception}`.
  """
  @spec step(Execution.t(), String.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution, node), do: FlowEngine.step(execution, node)

  @doc """
  Executes the complete set of nodes that is currently ready.

  Nodes that become ready during the wave wait for the next `step/1`, `wave/1`,
  or `continue/1` call. Stored asynchronous options apply to the wave. A serial
  wave stops at its first failure. An asynchronous wave lets work that is
  already in progress finish, then stops the Flow.
  """
  @spec wave(Execution.t()) ::
          {:ok, [NodeResult.t()], Execution.t()} | {:error, Exception.t()}
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
      name: action_name(instruction.action)
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
    with :ok <- Options.reject(opts, :instruction),
         {:ok, instruction} <- normalize_instruction(instruction, input, context),
         :ok <- Instruction.validate_action_contract(instruction.action),
         {:ok, %Executable{adapter: adapter} = executable} <-
           Executable.resolve(instruction.action) do
      adapter.run_instruction(executable, instruction, execution_id)
    end
  end

  defp do_start(%Instruction{}, _input, _context, _opts, _execution_id) do
    stepwise_flow_required(:instruction)
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
end
