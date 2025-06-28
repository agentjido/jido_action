defmodule Jido.Exec do
  @moduledoc """
  Exec provides a streamlined execution engine for Actions (`Jido.Action`).

  This module offers functionality to:
  - Run actions synchronously or asynchronously
  - Optional timeout and retry handling (when explicitly requested)
  - Cancel running actions
  - Normalize and validate input parameters and context
  - Emit telemetry events for monitoring and debugging

  Execs are defined as modules (Actions) that implement specific callbacks, allowing for
  a standardized way of defining and executing complex actions across a distributed system.

  ## Features

  - Fast, direct action execution (happy path - no overhead)
  - Optional retries with exponential backoff (when max_retries > 0)
  - Optional timeout handling for long-running actions (when timeout specified)
  - Synchronous and asynchronous action execution
  - Parameter and context normalization
  - Comprehensive error handling and reporting
  - Telemetry integration for monitoring and tracing
  - Cancellation of running actions

  ## Usage

  Execs are executed using the `run/4` or `run_async/4` functions:

      Jido.Exec.run(MyAction, %{param1: "value"}, %{context_key: "context_value"})

  See `Jido.Action` for how to define an Action.

  For asynchronous execution:

      async_ref = Jido.Exec.run_async(MyAction, params, context)
      # ... do other work ...
      result = Jido.Exec.await(async_ref)

  """

  use Private
  use ExDbug, enabled: false

  alias Jido.Action.Error
  alias Jido.Instruction
  alias Jido.Exec.Validation
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Retry
  alias Jido.Exec.TaskManager
  alias Jido.Exec.ErrorHandler

  require Logger
  require OK

  import Jido.Action.Util, only: [cond_log: 3]

  # Helper functions to get configuration values with fallbacks
  defp get_default_timeout,
    do: Application.get_env(:jido_action, :default_timeout, 5000)

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer(), streaming: :detach]
  @type async_ref :: %{ref: reference(), pid: pid()}

  @doc """
  Executes a Action synchronously with the given parameters and context.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution:
    - `:timeout` - Maximum time (in ms) allowed for the Action to complete. When not specified, actions run without timeout.
    - `:max_retries` - Maximum number of retry attempts (default: 0, no retries). Set to enable retry logic.
    - `:backoff` - Initial backoff time in milliseconds, doubles with each retry (default: 250).
    - `:streaming` - Set to `:detach` to unlink any Task PIDs found in the action result when using timeouts.
    - `:log_level` - Override the global Logger level for this specific action. Accepts #{inspect(Logger.levels())}.

  ## Action Metadata in Context

  The action's metadata (name, description, category, tags, version, etc.) is made available
  to the action's `run/2` function via the `context` parameter under the `:action_metadata` key.
  This allows actions to access their own metadata when needed.

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution.

  ## Examples

      # Simple execution (happy path - no timeout, no retries)
      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{user_id: 123})
      {:ok, %{result: "processed value"}}

      # With timeout (uses Task for timeout handling)
      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{}, timeout: 1000)
      {:ok, %{result: "processed value"}}

      # With retries (enables retry logic)
      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{}, max_retries: 3)
      {:ok, %{result: "processed value"}}

      # With custom log level
      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{}, log_level: :debug)
      {:ok, %{result: "processed value"}}

      # Access action metadata in the action:
      # defmodule MyAction do
      #   use Jido.Action,
      #     name: "my_action",
      #     description: "Example action",
      #     vsn: "1.0.0"
      #
      #   def run(_params, context) do
      #     metadata = context.action_metadata
      #     {:ok, %{name: metadata.name, version: metadata.vsn}}
      #   end
      # end
  """
  @spec run(action(), params(), context(), run_opts()) :: {:ok, map()} | {:error, Error.t()}
  def run(action, params \\ %{}, context \\ %{}, opts \\ [])

  def run(action, params, context, opts) when is_atom(action) and is_list(opts) do
    dbug("Starting action run", action: action, params: params, context: context, opts: opts)
    log_level = Keyword.get(opts, :log_level, :info)

    with {:ok, normalized_params} <- Validation.normalize_params(params),
         {:ok, normalized_context} <- Validation.normalize_context(context),
         :ok <- Validation.validate_action(action),
         OK.success(validated_params) <- Validation.validate_params(action, normalized_params) do
      enhanced_context =
        Map.put(normalized_context, :action_metadata, action.__action_metadata__())

      dbug("Params and context normalized and validated",
        normalized_params: normalized_params,
        normalized_context: enhanced_context,
        validated_params: validated_params
      )

      cond_log(
        log_level,
        :notice,
        "Executing #{inspect(action)} with params: #{inspect(validated_params)} and context: #{inspect(enhanced_context)}"
      )

      # Check if retries are explicitly requested
      max_retries = Keyword.get(opts, :max_retries, 0)

      if max_retries > 0 do
        Retry.run_with_retry(action, validated_params, enhanced_context, opts, &do_run/4)
      else
        do_run(action, validated_params, enhanced_context, opts)
      end
    else
      {:error, reason} ->
        dbug("Error in action setup", error: reason)
        cond_log(log_level, :debug, "Action Execution failed: #{inspect(reason)}")
        OK.failure(reason)

      {:error, reason, other} ->
        dbug("Error with additional info in action setup", error: reason, other: other)
        cond_log(log_level, :debug, "Action Execution failed with directive: #{inspect(reason)}")
        {:error, reason, other}
    end
  rescue
    e in [FunctionClauseError, BadArityError, BadFunctionError] ->
      log_level = Keyword.get(opts, :log_level, :info)
      dbug("Function error in action", error: e)

      cond_log(
        log_level,
        :warning,
        "Function invocation error in action: #{Exception.message(e)}"
      )

      OK.failure(Error.invalid_action("Invalid action module: #{Exception.message(e)}"))

    e ->
      log_level = Keyword.get(opts, :log_level, :info)
      dbug("Unexpected error in action", error: e)
      cond_log(log_level, :error, "Unexpected error in action: #{Exception.message(e)}")

      OK.failure(
        Error.internal_server_error("An unexpected error occurred: #{Exception.message(e)}")
      )
  catch
    kind, reason ->
      log_level = Keyword.get(opts, :log_level, :info)
      dbug("Caught error in action", kind: kind, reason: reason)

      cond_log(
        log_level,
        :warning,
        "Caught unexpected throw/exit in action: #{Exception.message(reason)}"
      )

      OK.failure(Error.internal_server_error("Caught #{kind}: #{inspect(reason)}"))
  end

  def run(%Instruction{} = instruction, _params, _context, _opts) do
    dbug("Running instruction", instruction: instruction)

    run(
      instruction.action,
      instruction.params,
      instruction.context,
      instruction.opts
    )
  end

  def run(action, _params, _context, _opts) do
    dbug("Invalid action type", action: action)
    OK.failure(Error.invalid_action("Expected action to be a module, got: #{inspect(action)}"))
  end

  @doc """
  Executes a Action asynchronously with the given parameters and context.

  This function immediately returns a reference that can be used to await the result
  or cancel the action.

  **Note**: This approach integrates with OTP by spawning tasks under a `Task.Supervisor`.
  Make sure `{Task.Supervisor, name: Jido.Action.TaskSupervisor}` is part of your supervision tree.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution (same as `run/4`).

  ## Returns

  An `async_ref` map containing:
  - `:ref` - A unique reference for this async action.
  - `:pid` - The PID of the process executing the Action.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(MyAction, %{input: "value"}, %{user_id: 123})
      %{ref: #Reference<0.1234.5678>, pid: #PID<0.234.0>}

      iex> result = Jido.Exec.await(async_ref)
      {:ok, %{result: "processed value"}}
  """
  @spec run_async(action(), params(), context(), run_opts()) :: async_ref()
  def run_async(action, params \\ %{}, context \\ %{}, opts \\ []) do
    dbug("Starting async action", action: action, params: params, context: context, opts: opts)
    ref = make_ref()
    parent = self()

    # Start the task under the TaskSupervisor.
    # If the supervisor is not running, this will raise an error.
    {:ok, pid} =
      Task.Supervisor.start_child(Jido.Action.TaskSupervisor, fn ->
        result = run(action, params, context, opts)
        send(parent, {:action_async_result, ref, result})
        result
      end)

    # We monitor the newly created Task so we can handle :DOWN messages in `await`.
    Process.monitor(pid)

    dbug("Async action started", ref: ref, pid: pid)
    %{ref: ref, pid: pid}
  end

  @doc """
  Waits for the result of an asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`.
  - `timeout`: Maximum time (in ms) to wait for the result (default: 5000).

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution or if the action times out.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(MyAction, %{input: "value"})
      iex> Jido.Exec.await(async_ref, 10_000)
      {:ok, %{result: "processed value"}}

      iex> async_ref = Jido.Exec.run_async(SlowAction, %{input: "value"})
      iex> Jido.Exec.await(async_ref, 100)
      {:error, %Jido.Action.Error{type: :timeout, message: "Async action timed out after 100ms"}}
  """
  @spec await(async_ref(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def await(%{ref: ref, pid: pid}, timeout \\ nil) do
    timeout = timeout || get_default_timeout()
    dbug("Awaiting async action result", ref: ref, pid: pid, timeout: timeout)

    receive do
      {:action_async_result, ^ref, result} ->
        dbug("Received async result", result: result)
        result

      {:DOWN, _monitor_ref, :process, ^pid, :normal} ->
        dbug("Process completed normally")
        # Process completed normally, but we might still receive the result
        receive do
          {:action_async_result, ^ref, result} ->
            dbug("Received delayed result", result: result)
            result
        after
          100 ->
            dbug("No result received after normal completion")
            {:error, Error.execution_error("Process completed but result was not received")}
        end

      {:DOWN, _monitor_ref, :process, ^pid, reason} ->
        dbug("Process crashed", reason: reason)
        {:error, Error.execution_error("Server error in async action: #{inspect(reason)}")}
    after
      timeout ->
        dbug("Async action timed out", timeout: timeout)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, _, :process, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        {:error, Error.timeout("Async action timed out after #{timeout}ms")}
    end
  end

  @doc """
  Cancels a running asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`, or just the PID of the process to cancel.

  ## Returns

  - `:ok` if the cancellation was successful.
  - `{:error, reason}` if the cancellation failed or the input was invalid.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(LongRunningAction, %{input: "value"})
      iex> Jido.Exec.cancel(async_ref)
      :ok

      iex> Jido.Exec.cancel("invalid")
      {:error, %Jido.Action.Error{type: :invalid_async_ref, message: "Invalid async ref for cancellation"}}
  """
  @spec cancel(async_ref() | pid()) :: :ok | {:error, Error.t()}
  def cancel(%{ref: _ref, pid: pid}), do: cancel(pid)
  def cancel(%{pid: pid}), do: cancel(pid)

  def cancel(pid) when is_pid(pid) do
    dbug("Cancelling action", pid: pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  def cancel(_), do: {:error, Error.invalid_async_ref("Invalid async ref for cancellation")}

  # Private functions are exposed to the test suite
  private do
    # Delegate validation functions to Validation module
    @spec normalize_params(params()) :: {:ok, map()} | {:error, Error.t()}
    defp normalize_params(params), do: Validation.normalize_params(params)

    @spec normalize_context(context()) :: {:ok, map()} | {:error, Error.t()}
    defp normalize_context(context), do: Validation.normalize_context(context)

    @spec validate_action(action()) :: :ok | {:error, Error.t()}
    defp validate_action(action), do: Validation.validate_action(action)

    @spec validate_params(action(), map()) :: {:ok, map()} | {:error, Error.t()}
    defp validate_params(action, params), do: Validation.validate_params(action, params)

    @spec validate_output(action(), map(), run_opts()) :: {:ok, map()} | {:error, Error.t()}
    defp validate_output(action, output, opts),
      do: Validation.validate_output(action, output, opts)

    # Delegate retry functions to Retry module
    @spec do_run_with_retry(action(), params(), context(), run_opts()) ::
            {:ok, map()} | {:error, Error.t()}
    defp do_run_with_retry(action, params, context, opts) do
      Retry.run_with_retry(action, params, context, opts, &do_run/4)
    end

    @spec calculate_backoff(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
    defp calculate_backoff(retry_count, backoff),
      do: Retry.calculate_backoff(retry_count, backoff)

    @spec do_run(action(), params(), context(), run_opts()) ::
            {:ok, map()} | {:error, Error.t()}
    defp do_run(action, params, context, opts) do
      timeout = Keyword.get(opts, :timeout)
      telemetry = Keyword.get(opts, :telemetry, :full)
      dbug("Starting action execution", action: action, timeout: timeout, telemetry: telemetry)

      result =
        case telemetry do
          :silent ->
            if timeout do
              result = TaskManager.execute_action_with_timeout(
                action,
                params,
                context,
                timeout,
                opts,
                &execute_action/4
              )
              maybe_detach_tasks(result, opts)
            else
              execute_action(action, params, context, opts)
            end

          _ ->
            start_time = System.monotonic_time(:microsecond)
            Telemetry.start_span(action, params, context, telemetry)

            result =
              if timeout do
                result = TaskManager.execute_action_with_timeout(
                  action,
                  params,
                  context,
                  timeout,
                  opts,
                  &execute_action/4
                )
                maybe_detach_tasks(result, opts)
              else
                execute_action(action, params, context, opts)
              end

            end_time = System.monotonic_time(:microsecond)
            duration_us = end_time - start_time
            Telemetry.end_span(action, result, duration_us, telemetry)

            result
        end

      case result do
        {:ok, _result} = success ->
          dbug("Action succeeded", result: success)
          success

        {:ok, _result, _other} = success ->
          dbug("Action succeeded with additional info", result: success)
          success

        {:error, %Error{type: :timeout}} = timeout_err ->
          dbug("Action timed out", error: timeout_err)
          timeout_err

        {:error, error, other} ->
          dbug("Action failed with additional info", error: error, other: other)
          ErrorHandler.handle_action_error(action, params, context, {error, other}, opts)

        {:error, error} ->
          dbug("Action failed", error: error)
          ErrorHandler.handle_action_error(action, params, context, error, opts)
      end
    end

    # Delegate telemetry functions to Telemetry module
    @spec start_span(action(), params(), context(), atom()) :: :ok
    defp start_span(action, params, context, telemetry),
      do: Telemetry.start_span(action, params, context, telemetry)

    @spec end_span(action(), {:ok, map()} | {:error, Error.t()}, non_neg_integer(), atom()) :: :ok
    defp end_span(action, result, duration_us, telemetry),
      do: Telemetry.end_span(action, result, duration_us, telemetry)

    @spec get_metadata(action(), {:ok, map()} | {:error, Error.t()}, non_neg_integer(), atom()) ::
            map()
    defp get_metadata(action, result, duration_us, telemetry),
      do: Telemetry.get_metadata(action, result, duration_us, telemetry)

    @spec get_process_info() :: map()
    defp get_process_info(), do: Telemetry.get_process_info()

    @spec emit_telemetry_event(atom(), map(), atom()) :: :ok
    defp emit_telemetry_event(event, metadata, telemetry),
      do: Telemetry.emit_telemetry_event(event, metadata, telemetry)

    # Delegate task management functions to TaskManager module (for testing)
    @spec execute_action_with_timeout(action(), params(), context(), non_neg_integer()) ::
            {:ok, map()} | {:error, Error.t()}
    defp execute_action_with_timeout(action, params, context, timeout) do
      TaskManager.execute_action_with_timeout(
        action,
        params,
        context,
        timeout,
        [],
        &execute_action/4
      )
    end

    @spec execute_action_with_timeout(
            action(),
            params(),
            context(),
            non_neg_integer(),
            run_opts()
          ) ::
            {:ok, map()} | {:error, Error.t()}
    defp execute_action_with_timeout(action, params, context, timeout, opts) do
      TaskManager.execute_action_with_timeout(
        action,
        params,
        context,
        timeout,
        opts,
        &execute_action/4
      )
    end

    @spec cleanup_task_group(pid()) :: :ok
    defp cleanup_task_group(task_group), do: TaskManager.cleanup_task_group(task_group)

    @spec maybe_detach_tasks(
            {:ok, map()} | {:ok, map(), any()} | {:error, Error.t()},
            run_opts()
          ) ::
            {:ok, map()} | {:ok, map(), any()} | {:error, Error.t()}
    defp maybe_detach_tasks(result, opts) do
      streaming = Keyword.get(opts, :streaming)

      if streaming == :detach do
        detach_tasks_from_result(result)
      else
        result
      end
    end

    @spec detach_tasks_from_result(
            {:ok, map()} | {:ok, map(), any()} | {:error, Error.t()}
          ) ::
            {:ok, map()} | {:ok, map(), any()} | {:error, Error.t()}
    defp detach_tasks_from_result({:ok, result}) do
      detach_pids_from_data(result)
      {:ok, result}
    end

    defp detach_tasks_from_result({:ok, result, other}) do
      detach_pids_from_data(result)
      {:ok, result, other}
    end

    defp detach_tasks_from_result({:error, _} = error), do: error

    @spec detach_pids_from_data(any()) :: :ok
    defp detach_pids_from_data(%Task{pid: pid}) do
      if Process.alive?(pid) do
        Process.unlink(pid)
        dbug("Detached from Task PID", pid: pid)
      end
    end

    defp detach_pids_from_data(data) when is_pid(data) do
      if Process.alive?(data) do
        Process.unlink(data)
        dbug("Detached from raw PID", pid: data)
      end
    end

    defp detach_pids_from_data(data) when is_map(data) do
      Enum.each(data, fn {_key, value} -> detach_pids_from_data(value) end)
    end

    defp detach_pids_from_data(data) when is_list(data) do
      Enum.each(data, &detach_pids_from_data/1)
    end

    defp detach_pids_from_data(data) when is_tuple(data) do
      data
      |> Tuple.to_list()
      |> Enum.each(&detach_pids_from_data/1)
    end

    defp detach_pids_from_data(_data), do: :ok

    @spec execute_action(action(), params(), context(), run_opts()) ::
            {:ok, map()} | {:error, Error.t()}
    defp execute_action(action, params, context, opts) do
      log_level = Keyword.get(opts, :log_level, :info)
      dbug("Executing action", action: action, params: params, context: context)

      cond_log(
        log_level,
        :debug,
        "Starting execution of #{inspect(action)}, params: #{inspect(params)}, context: #{inspect(context)}"
      )

      case action.run(params, context) do
        {:ok, result, other} ->
          dbug("Action succeeded with additional info", result: result, other: other)

          case Validation.validate_output(action, result, opts) do
            {:ok, validated_result} ->
              cond_log(
                log_level,
                :debug,
                "Finished execution of #{inspect(action)}, result: #{inspect(validated_result)}, directive: #{inspect(other)}"
              )

              {:ok, validated_result, other}

            {:error, validation_error} ->
              dbug("Action output validation failed", error: validation_error)

              cond_log(
                log_level,
                :error,
                "Action #{inspect(action)} output validation failed: #{inspect(validation_error)}"
              )

              {:error, validation_error, other}
          end

        OK.success(result) ->
          dbug("Action succeeded", result: result)

          case Validation.validate_output(action, result, opts) do
            {:ok, validated_result} ->
              cond_log(
                log_level,
                :debug,
                "Finished execution of #{inspect(action)}, result: #{inspect(validated_result)}"
              )

              OK.success(validated_result)

            {:error, validation_error} ->
              dbug("Action output validation failed", error: validation_error)

              cond_log(
                log_level,
                :error,
                "Action #{inspect(action)} output validation failed: #{inspect(validation_error)}"
              )

              OK.failure(validation_error)
          end

        {:error, reason, other} ->
          dbug("Action failed with additional info", error: reason, other: other)
          cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(reason)}")
          {:error, reason, other}

        OK.failure(%Error{} = error) ->
          dbug("Action failed with error struct", error: error)
          cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(error)}")
          OK.failure(error)

        OK.failure(reason) ->
          dbug("Action failed with reason", reason: reason)
          cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(reason)}")
          OK.failure(Error.execution_error(reason))

        result ->
          dbug("Action returned unexpected result", result: result)

          case Validation.validate_output(action, result, opts) do
            {:ok, validated_result} ->
              cond_log(
                log_level,
                :debug,
                "Finished execution of #{inspect(action)}, result: #{inspect(validated_result)}"
              )

              OK.success(validated_result)

            {:error, validation_error} ->
              dbug("Action output validation failed", error: validation_error)

              cond_log(
                log_level,
                :error,
                "Action #{inspect(action)} output validation failed: #{inspect(validation_error)}"
              )

              OK.failure(validation_error)
          end
      end
    rescue
      e in RuntimeError ->
        dbug("Runtime error in action", error: e)
        stacktrace = __STACKTRACE__
        log_level = Keyword.get(opts, :log_level, :info)
        cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(e)}")

        OK.failure(
          Error.execution_error(
            "Server error in #{inspect(action)}: #{Exception.message(e)}",
            %{original_exception: e, action: action},
            stacktrace
          )
        )

      e in ArgumentError ->
        dbug("Argument error in action", error: e)
        stacktrace = __STACKTRACE__
        log_level = Keyword.get(opts, :log_level, :info)
        cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(e)}")

        OK.failure(
          Error.execution_error(
            "Argument error in #{inspect(action)}: #{Exception.message(e)}",
            %{original_exception: e, action: action},
            stacktrace
          )
        )

      e ->
        stacktrace = __STACKTRACE__
        log_level = Keyword.get(opts, :log_level, :info)
        cond_log(log_level, :error, "Action #{inspect(action)} failed: #{inspect(e)}")

        OK.failure(
          Error.execution_error(
            "An unexpected error occurred during execution of #{inspect(action)}: #{inspect(e)}",
            %{original_exception: e, action: action},
            stacktrace
          )
        )
    end
  end
end
