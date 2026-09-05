defmodule Jido.Exec.Async do
  @moduledoc false

  alias Jido.Exec
  alias Jido.Exec.Error
  alias Jido.Exec.Runtime

  @default_await_timeout 5_000
  @stop_wait_ms 1_000
  @max_receive_timeout 2_147_483_647
  @owner_key {__MODULE__, :owner}
  @ref_key {__MODULE__, :ref}
  @state_key {__MODULE__, :state}
  @handle_key {__MODULE__, :handle}
  @active 0
  @claimed 1
  @terminal 2

  @typep async_state :: {:jido_exec_async_state, :atomics.atomics_ref()}
  @type async_ref :: %{
          required(:ref) => reference(),
          required(:pid) => pid(),
          required(:owner) => pid(),
          required(:monitor_ref) => reference(),
          required(:state) => async_state()
        }
  @type exec_result :: Exec.exec_result()

  @doc false
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          async_ref()
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    owner = self()
    ref = make_ref()
    state = new_state()
    task_supervisor = task_supervisor!(opts)
    group_leader = Process.group_leader()
    logger_metadata = Logger.metadata()

    work = fn ->
      Process.put(@owner_key, owner)
      Process.put(@ref_key, ref)
      Process.put(@state_key, state)
      Process.group_leader(self(), group_leader)
      Logger.metadata(logger_metadata)

      result = Exec.run_controlled(executable, input, context, opts, ref, owner)
      send(owner, {:jido_exec_async_result, ref, self(), result})
      result
    end

    case Runtime.start_child(task_supervisor, work) do
      {:ok, pid} ->
        handle = %{
          ref: ref,
          pid: pid,
          owner: owner,
          monitor_ref: Process.monitor(pid),
          state: state
        }

        register_handle(handle)
        handle

      {:error, reason} ->
        raise Error.execution_error("Asynchronous execution process could not start", %{
                reason: reason,
                task_supervisor: task_supervisor,
                retry: false
              })
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
  @spec cancel(async_ref() | pid()) :: :ok | {:error, Exception.t()}
  def cancel(%{} = async_ref) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :cancel) do
      case claim(async_ref) do
        :ok -> cancel_valid(async_ref)
        :consumed -> cleanup(async_ref)
      end
    end
  end

  def cancel(pid) when is_pid(pid) do
    case registered_handle(pid) do
      %{owner: owner} = async_ref when owner == self() ->
        cancel(async_ref)

      _other ->
        cancel_unregistered_pid(pid)
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

  defp finish_message(async_ref, {:result, result}) do
    complete(async_ref)
    {:done, result}
  end

  defp finish_message(async_ref, {:down, :normal}) do
    result = missing_result(async_ref, :handle_message)

    complete(async_ref)
    {:done, result}
  end

  defp finish_message(async_ref, {:down, reason}) do
    result =
      {:error,
       Error.execution_error("Asynchronous execution process exited", %{
         operation: :handle_message,
         pid: async_ref.pid,
         reason: reason,
         retry: false
       })}

    complete(async_ref)
    {:done, result}
  end

  defp await_valid(%{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref, timeout) do
    if Process.alive?(pid) or result_waiting?(ref, pid) do
      deadline = deadline(timeout)

      case receive_result(ref, pid, monitor_ref, deadline) do
        {:result, result} ->
          complete(async_ref, result)

        {:down, :normal} ->
          result = missing_result(async_ref, :await)
          complete(async_ref, result)

        {:down, reason} ->
          result =
            {:error,
             Error.execution_error("Asynchronous execution process exited", %{
               operation: :await,
               pid: pid,
               reason: reason,
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
      end
    else
      result =
        {:error,
         Error.execution_error("Asynchronous execution is no longer running", %{
           operation: :await,
           pid: pid,
           reason: :noproc,
           retry: false
         })}

      complete(async_ref, result)
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

  defp receive_result(ref, pid, monitor_ref, :infinity) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} -> {:result, result}
      {:DOWN, ^monitor_ref, :process, ^pid, reason} -> {:down, reason}
    end
  end

  defp receive_result(ref, pid, monitor_ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    receive_timeout = min(remaining, @max_receive_timeout)

    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} ->
        {:result, result}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      receive_timeout ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          receive_result(ref, pid, monitor_ref, deadline)
        end
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

  defp result_waiting?(ref, pid) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} ->
        send(self(), {:jido_exec_async_result, ref, pid, result})
        true
    after
      0 -> false
    end
  end

  defp complete(async_ref, result \\ :ok) do
    mark_terminal(async_ref)
    cleanup(async_ref, result)
  end

  defp cleanup(
         %{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref,
         result \\ :ok
       ) do
    Process.demonitor(monitor_ref, [:flush])
    flush_results(ref, pid)
    flush_down(monitor_ref, pid)
    unregister_handle(async_ref)
    result
  end

  defp flush_results(ref, pid) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, _result} -> flush_results(ref, pid)
    after
      0 -> :ok
    end
  end

  defp flush_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> flush_down(monitor_ref, pid)
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

  defp validate_state(state) do
    case state_from_term(state) do
      {:ok, _state} -> :ok
      :error -> invalid_handle(state)
    end
  end

  defp state_from_term({:jido_exec_async_state, token} = state) do
    if :atomics.get(token, 1) in [@active, @claimed, @terminal] do
      {:ok, state}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp state_from_term(_state), do: :error

  defp invalid_handle(value) do
    {:error,
     Error.invalid_handle_error("Invalid asynchronous execution handle", %{
       value: value
     })}
  end

  defp validate_owner(%{owner: owner}, operation), do: validate_owner_pid(owner, operation)

  defp validate_owner_pid(owner, operation) do
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

  defp new_state, do: {:jido_exec_async_state, :atomics.new(1, signed: false)}

  defp claim(%{state: {:jido_exec_async_state, token}}) do
    case :atomics.compare_exchange(token, 1, @active, @claimed) do
      :ok -> :ok
      phase when phase in [@claimed, @terminal] -> :consumed
    end
  end

  defp mark_terminal(%{state: {:jido_exec_async_state, token}}),
    do: :atomics.put(token, 1, @terminal)

  defp consumed_handle_error(async_ref, operation) do
    Error.invalid_handle_error("Asynchronous execution handle was already consumed", %{
      operation: operation,
      pid: async_ref.pid,
      ref: async_ref.ref
    })
  end

  defp register_handle(%{pid: pid} = async_ref) do
    Process.put({@handle_key, pid}, async_ref)
    :ok
  end

  defp registered_handle(pid), do: Process.get({@handle_key, pid})

  defp unregister_handle(%{pid: pid, state: state}) do
    case registered_handle(pid) do
      %{state: ^state} -> Process.delete({@handle_key, pid})
      _other -> nil
    end

    :ok
  end

  defp cancel_unregistered_pid(pid) do
    if Process.alive?(pid) do
      with {:ok, owner, ref, state} <- pid_identity(pid),
           :ok <- validate_owner_pid(owner, :cancel) do
        cancel(%{
          ref: ref,
          pid: pid,
          owner: owner,
          monitor_ref: Process.monitor(pid),
          state: state
        })
      end
    else
      :ok
    end
  end

  defp pid_identity(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        with {@owner_key, owner} when is_pid(owner) <- List.keyfind(dictionary, @owner_key, 0),
             {@ref_key, ref} when is_reference(ref) <- List.keyfind(dictionary, @ref_key, 0),
             {@state_key, raw_state} <- List.keyfind(dictionary, @state_key, 0),
             {:ok, state} <- state_from_term(raw_state) do
          {:ok, owner, ref, state}
        else
          _value ->
            {:error,
             Error.invalid_handle_error("PID does not identify an asynchronous execution", %{
               operation: :cancel,
               pid: pid
             })}
        end

      _other ->
        {:error,
         Error.invalid_handle_error("PID does not identify an asynchronous execution", %{
           operation: :cancel,
           pid: pid
         })}
    end
  end

  defp task_supervisor!(opts) when is_list(opts) do
    case Runtime.task_supervisor(opts) do
      {:ok, supervisor} -> supervisor
      {:error, error} -> raise error
    end
  end

  defp task_supervisor!(opts) do
    raise Error.execution_error("Asynchronous execution options must be a keyword list", %{
            options: opts,
            retry: false
          })
  end
end
