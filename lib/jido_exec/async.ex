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
  @token_key {__MODULE__, :token}

  @type async_ref :: Exec.async_ref()
  @type exec_result :: Exec.exec_result()

  @doc false
  @spec start(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) ::
          async_ref()
  def start(executable, input \\ %{}, context \\ %{}, opts \\ []) do
    owner = self()
    ref = make_ref()
    token = :atomics.new(1, signed: false)
    task_supervisor = task_supervisor!(opts)
    group_leader = Process.group_leader()
    logger_metadata = Logger.metadata()

    work = fn ->
      Process.put(@owner_key, owner)
      Process.put(@ref_key, ref)
      Process.put(@token_key, token)
      Process.group_leader(self(), group_leader)
      Logger.metadata(logger_metadata)

      result = Exec.run_controlled(executable, input, context, opts, ref, owner)
      send(owner, {:jido_exec_async_result, ref, self(), result})
      result
    end

    case start_child(task_supervisor, work) do
      {:ok, pid} ->
        %{ref: ref, pid: pid, owner: owner, monitor_ref: Process.monitor(pid), token: token}

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
         :ok <- validate_timeout(timeout),
         :ok <- claim(async_ref, :await) do
      await_valid(async_ref, timeout)
    end
  end

  @doc false
  @spec handle_message(async_ref(), term()) ::
          {:done, exec_result()} | :ignore | {:error, Exception.t()}
  def handle_message(async_ref, message) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :handle_message) do
      handle_valid_message(async_ref, message)
    end
  end

  @doc false
  @spec cancel(async_ref() | pid()) :: :ok | {:error, Exception.t()}
  def cancel(%{} = async_ref) do
    with :ok <- validate_handle(async_ref),
         :ok <- validate_owner(async_ref, :cancel),
         :ok <- claim(async_ref, :cancel) do
      cancel_valid(async_ref)
    end
  end

  def cancel(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      with {:ok, owner, ref, token} <- pid_identity(pid),
           :ok <- validate_owner_pid(owner, :cancel),
           async_ref = %{
             ref: ref,
             pid: pid,
             owner: owner,
             monitor_ref: Process.monitor(pid),
             token: token
           },
           :ok <- claim(async_ref, :cancel) do
        cancel_valid(async_ref)
      end
    else
      :ok
    end
  end

  def cancel(value) do
    {:error,
     Error.invalid_handle_error("Invalid asynchronous execution handle", %{
       operation: :cancel,
       value: value
     })}
  end

  defp await_valid(%{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref, timeout) do
    if Process.alive?(pid) or result_waiting?(ref, pid) do
      deadline = deadline(timeout)

      case receive_result(ref, pid, monitor_ref, deadline) do
        {:result, result} ->
          cleanup(ref, pid, monitor_ref)
          terminal(async_ref)
          result

        {:down, :normal} ->
          result = receive_late_result(ref, pid)
          cleanup(ref, pid, monitor_ref)
          terminal(async_ref)
          result

        {:down, reason} ->
          cleanup(ref, pid, monitor_ref)
          terminal(async_ref)

          {:error,
           Error.execution_error("Asynchronous execution process exited", %{
             operation: :await,
             pid: pid,
             reason: reason,
             retry: false
           })}

        :timeout ->
          error =
            Error.timeout_error("Asynchronous execution did not finish within #{timeout}ms", %{
              operation: :await,
              timeout: timeout,
              retry: false
            })

          stop(ref, pid, monitor_ref, error)
          cleanup(ref, pid, monitor_ref)
          terminal(async_ref)
          {:error, error}
      end
    else
      cleanup(ref, pid, monitor_ref)
      terminal(async_ref)

      {:error,
       Error.execution_error("Asynchronous execution is no longer running", %{
         operation: :await,
         pid: pid,
         reason: :noproc,
         retry: false
       })}
    end
  end

  defp cancel_valid(%{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref) do
    error =
      Error.cancelled_error("Asynchronous execution was cancelled", %{
        operation: :cancel,
        pid: pid,
        retry: false
      })

    stop(ref, pid, monitor_ref, error)
    cleanup(ref, pid, monitor_ref)
    terminal(async_ref)
    :ok
  end

  defp handle_valid_message(
         %{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref,
         {:jido_exec_async_result, ref, pid, result}
       ) do
    case claim_for_message(async_ref) do
      :ok ->
        cleanup(ref, pid, monitor_ref)
        terminal(async_ref)
        {:done, result}

      :terminal ->
        :ignore
    end
  end

  defp handle_valid_message(
         %{ref: ref, pid: pid, monitor_ref: monitor_ref} = async_ref,
         {:DOWN, monitor_ref, :process, pid, reason}
       ) do
    case claim_for_message(async_ref) do
      :ok ->
        result = down_result(ref, pid, reason)
        cleanup(ref, pid, monitor_ref)
        terminal(async_ref)
        {:done, result}

      :terminal ->
        :ignore
    end
  end

  defp handle_valid_message(_async_ref, _message), do: :ignore

  defp down_result(ref, pid, :normal) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} -> result
    after
      0 ->
        {:error,
         Error.execution_error("Asynchronous execution finished without a result", %{
           operation: :handle_message,
           pid: pid,
           retry: false
         })}
    end
  end

  defp down_result(_ref, pid, reason) do
    {:error,
     Error.execution_error("Asynchronous execution process exited", %{
       operation: :handle_message,
       pid: pid,
       reason: reason,
       retry: false
     })}
  end

  defp stop(ref, pid, monitor_ref, error) do
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

  defp receive_late_result(ref, pid) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, result} -> result
    after
      100 ->
        {:error,
         Error.execution_error("Asynchronous execution finished without a result", %{
           operation: :await,
           pid: pid,
           retry: false
         })}
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

  defp cleanup(ref, pid, monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    flush_results(ref, pid)
  end

  defp flush_results(ref, pid) do
    receive do
      {:jido_exec_async_result, ^ref, ^pid, _result} -> flush_results(ref, pid)
    after
      0 -> :ok
    end
  end

  defp validate_handle(%{
         ref: ref,
         pid: pid,
         owner: owner,
         monitor_ref: monitor_ref,
         token: token
       })
       when is_reference(ref) and is_pid(pid) and is_pid(owner) and is_reference(monitor_ref) do
    if valid_token?(token), do: :ok, else: invalid_handle(token)
  end

  defp validate_handle(value) do
    {:error,
     Error.invalid_handle_error("Invalid asynchronous execution handle", %{
       value: value
     })}
  end

  defp invalid_handle(value) do
    {:error, Error.invalid_handle_error("Invalid asynchronous execution handle", %{value: value})}
  end

  defp valid_token?(token) do
    :atomics.get(token, 1) in [0, 1, 2]
  rescue
    _error -> false
  end

  defp claim(%{token: token}, operation) do
    case :atomics.compare_exchange(token, 1, 0, 1) do
      :ok ->
        :ok

      _state ->
        {:error,
         Error.invalid_handle_error("Asynchronous execution handle was already consumed", %{
           operation: operation
         })}
    end
  end

  defp claim_for_message(%{token: token}) do
    case :atomics.compare_exchange(token, 1, 0, 1) do
      :ok -> :ok
      _state -> :terminal
    end
  end

  defp terminal(%{token: token}), do: :atomics.put(token, 1, 2)

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

  defp pid_identity(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        with {@owner_key, owner} when is_pid(owner) <- List.keyfind(dictionary, @owner_key, 0),
             {@ref_key, ref} when is_reference(ref) <- List.keyfind(dictionary, @ref_key, 0),
             {@token_key, token} <- List.keyfind(dictionary, @token_key, 0),
             true <- valid_token?(token) do
          {:ok, owner, ref, token}
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

  defp start_child(task_supervisor, work) do
    Task.Supervisor.start_child(task_supervisor, work)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
