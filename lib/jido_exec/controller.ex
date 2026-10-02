defmodule Jido.Exec.Controller do
  @moduledoc false

  alias Jido.Exec
  alias Jido.Exec.Error
  alias Jido.Exec.{Runtime, Telemetry, Worker}

  @default_await_timeout 5_000
  @stop_wait_ms 500
  @max_receive_timeout 2_147_483_647
  @active 0
  @claimed 1
  @terminal 2

  @type call :: %{
          supervisor: pid(),
          controller: pid(),
          deadline: integer() | :infinity,
          execution_id: String.t(),
          group_leader: pid()
        }
  @type t :: %{
          call: call(),
          owner_monitor: reference(),
          ref: reference(),
          timeout: timeout(),
          host: pid()
        }
  @type async_ref :: %{
          ref: reference(),
          pid: pid(),
          owner: pid(),
          monitor_ref: reference(),
          state: {:jido_exec_async_state, :atomics.atomics_ref(), pid()}
        }
  @type exec_result :: Exec.exec_result()

  @doc false
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          async_ref()
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    start_control(
      fn control ->
        Exec.run_controlled(executable, input, context, opts, control)
      end,
      opts
    )
  end

  @doc false
  @spec sync(term(), term(), term(), keyword()) :: term()
  def sync(executable, input, context, opts) do
    executable |> start(input, context, opts) |> await(:infinity)
  rescue
    error in Error.AsyncExecutionError ->
      {:error,
       Jido.Action.Error.internal_error("Execution process could not start", error.details)}

    error ->
      {:error, error}
  end

  @doc false
  @spec operation((call() -> term()), keyword(), String.t()) :: term()
  def operation(work, opts, execution_id) do
    start_control(
      fn control ->
        run(:infinity, execution_id, control, fn controller ->
          {result, _, _} =
            execute(controller, fn -> work.(controller.call) end, Jido.Flow.Error, :flow)

          result
        end)
      end,
      opts
    )
    |> await(:infinity)
  rescue
    error -> {:error, error}
  end

  defp start_control(control_work, opts) do
    started_at = System.monotonic_time(:millisecond)
    owner = self()
    ref = make_ref()
    task_supervisor = task_supervisor!(opts)
    group_leader = Process.group_leader()

    # A supervised child can finish before start_child/2 returns. Do not run
    # user work until the owner has installed its monitor.
    work = fn ->
      case await_monitor(owner, ref) do
        {:ready, owner_monitor, host} ->
          Process.group_leader(self(), group_leader)

          try do
            result =
              control_work.(%{
                ref: ref,
                owner_monitor: owner_monitor,
                started_at: started_at,
                host: host
              })

            send(owner, {:jido_exec_async_result, ref, self(), result})
            result
          after
            Process.demonitor(owner_monitor, [:flush])
          end

        :owner_down ->
          :ok
      end
    end

    case Runtime.start_control(task_supervisor, work) do
      {:ok, pid, supervisor} ->
        monitor_ref = Process.monitor(pid)
        send(pid, {__MODULE__, ref, {:ready, supervisor}})

        %{
          ref: ref,
          pid: pid,
          owner: owner,
          monitor_ref: monitor_ref,
          state: new_state(supervisor)
        }

      {:error, reason} ->
        raise Error.execution_error("Asynchronous execution process could not start", %{
                reason: reason,
                task_supervisor: task_supervisor,
                retry: false
              })
    end
  end

  defp await_monitor(owner, ref) do
    owner_monitor = Process.monitor(owner)

    receive do
      {__MODULE__, ^ref, {:ready, host}} ->
        {:ready, owner_monitor, host}

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :owner_down
    end
  end

  @doc false
  @spec await(async_ref()) :: exec_result()
  def await(async_ref), do: await(async_ref, @default_await_timeout)

  @doc false
  @spec await(async_ref(), timeout()) :: exec_result()
  def await(async_ref, timeout) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :await),
         :ok <- validate_timeout(timeout) do
      case claim(async_ref) do
        :ok -> await_valid(async_ref, timeout)
        :consumed -> {:error, consumed_handle_error(async_ref, :await)}
      end
    end
  end

  @doc false
  @spec handle_message(async_ref(), term()) ::
          {:done, exec_result()} | :ignore | {:error, Exception.t()}
  def handle_message(async_ref, message) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :handle_message) do
      handle_message_valid(async_ref, message)
    end
  end

  @doc false
  @spec cancel(async_ref()) :: :ok | {:error, Exception.t()}
  def cancel(%{} = async_ref) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :cancel) do
      case claim(async_ref) do
        :ok -> cancel_valid(async_ref)
        :consumed -> cleanup(async_ref)
      end
    end
  end

  def cancel(value) do
    {:error,
     Error.invalid_handle_error("Invalid asynchronous execution handle", %{
       operation: :cancel,
       value: value
     })}
  end

  defp handle_message_valid(async_ref, message) do
    case classify_message(async_ref, message) do
      :ignore ->
        :ignore

      terminal_message ->
        case claim(async_ref) do
          :ok -> finish_message(async_ref, terminal_message)
          :consumed -> cleanup(async_ref, :ignore)
        end
    end
  end

  defp classify_message(%{ref: ref, pid: pid}, {:jido_exec_async_result, ref, pid, result}),
    do: {:result, result}

  defp classify_message(
         %{pid: pid, monitor_ref: monitor_ref},
         {:DOWN, monitor_ref, :process, pid, reason}
       ),
       do: {:down, reason}

  defp classify_message(_async_ref, _message), do: :ignore

  defp finish_message(async_ref, message) do
    {:done, complete(async_ref, terminal_result(async_ref, message, :handle_message))}
  end

  defp terminal_result(_async_ref, {:result, result}, _operation), do: result

  defp terminal_result(async_ref, {:down, :normal}, operation),
    do: missing_result(async_ref, operation)

  defp terminal_result(async_ref, {:down, reason}, operation) do
    {:error,
     Error.execution_error("Asynchronous execution process exited", %{
       operation: operation,
       pid: async_ref.pid,
       reason: reason,
       retry: false
     })}
  end

  defp await_valid(%{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref, timeout) do
    alive? = Process.alive?(pid)
    deadline = deadline(if alive?, do: timeout, else: 0)

    case receive_result(ref, pid, monitor_ref, deadline) do
      :timeout when not alive? ->
        result =
          {:error,
           Error.execution_error("Asynchronous execution is no longer running", %{
             operation: :await,
             pid: pid,
             reason: :noproc,
             retry: false
           })}

        complete(async_ref, result)

      :timeout ->
        error =
          Error.timeout_error("Asynchronous execution did not finish within #{timeout}ms", %{
            operation: :await,
            timeout: timeout,
            retry: false
          })

        stop(async_ref, error)
        complete(async_ref, {:error, error})

      message ->
        complete(async_ref, terminal_result(async_ref, message, :await))
    end
  end

  defp cancel_valid(async_ref) do
    error =
      Error.cancelled_error("Asynchronous execution was cancelled", %{
        operation: :cancel,
        pid: async_ref.pid,
        retry: false
      })

    stop(async_ref, error)
    complete(async_ref, :ok)
  end

  defp stop(%{ref: ref, pid: pid, monitor_ref: monitor_ref}, error) do
    if Process.alive?(pid) do
      send(pid, {__MODULE__, ref, {:stop, error}})

      case await_stop(ref, pid, monitor_ref, @stop_wait_ms) do
        :stopped -> :ok
        :timeout -> force_stop(pid, monitor_ref)
      end
    else
      :ok
    end
  end

  defp await_stop(ref, pid, monitor_ref, timeout) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, _result} ->
        await_down(monitor_ref, pid, timeout)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :stopped
    after
      timeout -> :timeout
    end
  end

  defp force_stop(pid, monitor_ref) do
    Process.exit(pid, :kill)
    await_down(monitor_ref, pid, @stop_wait_ms)
  end

  defp await_down(monitor_ref, pid, timeout) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :stopped
    after
      timeout -> :timeout
    end
  end

  defp receive_result(ref, pid, monitor_ref, deadline) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} -> {:result, result}
      {:DOWN, ^monitor_ref, :process, ^pid, reason} -> {:down, reason}
    after
      remaining(deadline) ->
        if expired?(deadline),
          do: :timeout,
          else: receive_result(ref, pid, monitor_ref, deadline)
    end
  end

  defp missing_result(async_ref, operation) do
    case take_result(async_ref) do
      {:ok, result} ->
        result

      :none ->
        {:error,
         Error.execution_error("Asynchronous execution finished without a result", %{
           operation: operation,
           pid: async_ref.pid,
           reason: :normal,
           retry: false
         })}
    end
  end

  defp take_result(%{ref: ref, pid: pid}) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp complete(async_ref, result) do
    # Release the host slot before the owner can start its next call.
    if Process.alive?(async_ref.pid) do
      pid = async_ref.pid
      monitor = async_ref.monitor_ref

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      end
    end

    {:jido_exec_async_state, _token, supervisor} = async_ref.state
    Runtime.retire_child(supervisor, async_ref.pid)
    mark_terminal(async_ref)
    cleanup(async_ref, result)
  end

  defp cleanup(%{ref: ref, pid: pid, monitor_ref: monitor_ref}, result \\ :ok) do
    Process.demonitor(monitor_ref, [:flush])
    flush_handle(ref, pid, monitor_ref)
    result
  end

  defp flush_handle(ref, pid, monitor_ref) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, _result} -> flush_handle(ref, pid, monitor_ref)
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> flush_handle(ref, pid, monitor_ref)
    after
      0 -> :ok
    end
  end

  defp validate_handle(%{
         ref: ref,
         pid: pid,
         owner: owner,
         monitor_ref: monitor_ref,
         state: state
       })
       when is_reference(ref) and is_pid(pid) and is_pid(owner) and is_reference(monitor_ref),
       do: validate_state(state)

  defp validate_handle(value), do: invalid_handle(value)

  defp validate_state({:jido_exec_async_state, token, supervisor} = state)
       when is_pid(supervisor) do
    if :atomics.get(token, 1) in [@active, @claimed, @terminal] do
      :ok
    else
      invalid_handle(state)
    end
  rescue
    ArgumentError -> invalid_handle(state)
  end

  defp validate_state(state), do: invalid_handle(state)

  defp invalid_handle(value) do
    {:error,
     Error.invalid_handle_error("Invalid asynchronous execution handle", %{
       value: value
     })}
  end

  defp validate_owner(%{owner: owner}, operation) do
    caller = self()

    if caller == owner do
      :ok
    else
      {:error,
       Error.invalid_handle_error(
         "Only the owner process can #{operation} this asynchronous execution",
         %{operation: operation, owner: owner, caller: caller}
       )}
    end
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok

  defp validate_timeout(timeout) do
    {:error,
     Error.invalid_handle_error("Await timeout must be :infinity or a non-negative integer", %{
       operation: :await,
       timeout: timeout
     })}
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp new_state(supervisor),
    do: {:jido_exec_async_state, :atomics.new(1, signed: false), supervisor}

  defp claim(%{state: {:jido_exec_async_state, token, _supervisor}}) do
    case :atomics.compare_exchange(token, 1, @active, @claimed) do
      :ok -> :ok
      phase when phase in [@claimed, @terminal] -> :consumed
    end
  end

  defp mark_terminal(%{state: {:jido_exec_async_state, token, _supervisor}}),
    do: :atomics.put(token, 1, @terminal)

  defp consumed_handle_error(async_ref, operation) do
    Error.invalid_handle_error("Asynchronous execution handle was already consumed", %{
      operation: operation,
      pid: async_ref.pid,
      ref: async_ref.ref
    })
  end

  defp task_supervisor!(opts) do
    case Runtime.task_supervisor(opts) do
      {:ok, supervisor} -> supervisor
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec run(timeout(), String.t(), map(), (t() -> term())) :: term()
  def run(timeout, execution_id, control, work) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = Task.Supervisor.start_link()

    call = %{
      supervisor: supervisor,
      controller: self(),
      deadline: if(timeout == :infinity, do: :infinity, else: control.started_at + timeout),
      execution_id: execution_id,
      group_leader: Process.group_leader()
    }

    try do
      work.(%{
        call: call,
        owner_monitor: control.owner_monitor,
        ref: control.ref,
        timeout: timeout,
        host: control.host
      })
    after
      shutdown(supervisor, control.host)
    end
  end

  @doc false
  @spec execute(t(), (-> term()), module(), term()) :: {term(), module(), term()}
  def execute(controller, work, error_owner, target) do
    # Keep only the root gate. Startup can block beyond the deadline, and a
    # continuation must not start after queued cancellation or owner death.
    gated = fn -> receive do: (:run -> work.()) end

    case Worker.start(controller.call, gated) do
      {:ok, task} ->
        controller
        |> Map.merge(%{
          task: task,
          compounds: %{},
          spans: %{},
          error_owner: error_owner,
          target: target
        })
        |> start_root()

      {:error, reason} ->
        {{:error,
          error_owner.internal_error("Execution process could not start", %{
            reason: reason,
            retry: false
          })}, error_owner, target}
    end
  end

  @doc false
  @spec resolved(call(), module(), term()) :: term()
  def resolved(call, error_owner, target),
    do: send(call.controller, {:resolved, error_owner, target})

  defp start_root(%{owner_monitor: owner_monitor, ref: ref} = state) do
    receive do
      {__MODULE__, ^ref, {:stop, error}} -> stop_call(state, error)
      {:DOWN, ^owner_monitor, :process, owner, reason} -> owner_down(state, owner, reason)
    after
      0 ->
        if expired?(state.call.deadline) do
          stop_call(state, timeout_error(state))
        else
          send(state.task.pid, :run)
          receive_root(state)
        end
    end
  end

  defp advance(state) do
    if expired?(state.call.deadline),
      do: stop_call(state, timeout_error(state)),
      else: receive_root(state)
  end

  defp receive_root(%{task: task, call: call, owner_monitor: owner_monitor, ref: ref} = state) do
    task_ref = task.ref
    supervisor = call.supervisor
    host = state.host
    compounds = state.compounds

    receive do
      {^task_ref, result} ->
        Worker.finish(task)
        finish_call(state, result)

      {:DOWN, ^task_ref, :process, _worker, reason} ->
        stop_call(
          state,
          state.error_owner.internal_error(
            "#{label(state.error_owner)} execution process exited",
            %{reason: reason}
          )
        )

      {:compound, worker} ->
        advance(%{state | compounds: Map.put(compounds, worker, true)})

      {:resolved, error_owner, target} ->
        advance(%{state | error_owner: error_owner, target: target})

      {:telemetry, event} ->
        advance(%{state | spans: Telemetry.record(state.spans, event)})

      {:worker_error, child, error} ->
        advance(%{
          state
          | spans: Telemetry.fail(Telemetry.drain(state.spans), error, child)
        })

      {__MODULE__, ^ref, {:stop, error}} ->
        stop_call(state, error)

      {:DOWN, ^owner_monitor, :process, owner, reason} ->
        owner_down(state, owner, reason)

      {:EXIT, ^supervisor, reason} ->
        stop_call(
          state,
          state.error_owner.internal_error(
            "Execution Task Supervisor exited",
            %{reason: reason, retry: false}
          )
        )

      {:EXIT, ^host, reason} ->
        stop_call(
          state,
          state.error_owner.internal_error(
            "Execution control supervisor exited",
            %{reason: reason, retry: false}
          )
        )

      {:EXIT, compound, reason} when reason != :normal and is_map_key(compounds, compound) ->
        stop_call(
          state,
          Jido.Flow.Error.internal_error(
            "Flow runnable process exited",
            %{reason: reason}
          )
        )

      {:EXIT, worker, _reason} ->
        advance(%{state | compounds: Map.delete(compounds, worker)})
    after
      remaining(call.deadline) -> advance(state)
    end
  end

  defp owner_down(state, owner, reason) do
    stop_call(
      state,
      Error.cancelled_error("Execution owner exited", %{
        operation: :owner_exit,
        owner: owner,
        reason: reason,
        retry: false
      })
    )
  end

  defp stop_call(state, error), do: finish_call(state, {:error, error})

  defp finish_call(state, result) do
    # Stop the group before recovering spans. Links also find surviving Tasks
    # when a hard-killed private supervisor could not run its own shutdown.
    if match?({:error, _}, result), do: shutdown(state.call.supervisor, state.host)
    spans = Telemetry.drain(state.spans)
    if match?({:error, _}, result), do: Telemetry.fail(spans, elem(result, 1))
    {result, state.error_owner, state.target}
  end

  defp timeout_error(state) do
    field = if state.error_owner == Jido.Flow.Error, do: :flow, else: :action

    state.error_owner.timeout_error(
      "#{label(state.error_owner)} execution timed out after #{state.timeout}ms",
      %{
        field => state.target,
        timeout: state.timeout,
        execution_id: state.call.execution_id,
        retry: false
      }
    )
  end

  defp label(Jido.Flow.Error), do: "Flow"
  defp label(_), do: "Action"
  defp expired?(:infinity), do: false
  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline
  defp remaining(:infinity), do: :infinity

  defp remaining(deadline),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), @max_receive_timeout)

  defp shutdown(supervisor, host) do
    stop_supervisor(supervisor)
    {:links, links} = Process.info(self(), :links)
    workers = for pid <- links, pid != host, do: {pid, Process.monitor(pid)}
    for {pid, _monitor} <- workers, do: Process.exit(pid, :kill)

    for {pid, monitor} <- workers do
      receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
    end

    :ok
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor, :normal, :infinity)
  catch
    :exit, _reason -> :ok
  end
end
