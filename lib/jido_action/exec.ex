defmodule Jido.Exec do
  @moduledoc """
  Action execution engine with modular architecture for robust action processing.

  This module provides the core execution interface for Jido Actions with specialized
  helper modules handling specific concerns:

  - **Jido.Exec.Validator** - Parameter and output validation
  - **Jido.Exec.Telemetry** - Logging and telemetry events
  - **Jido.Exec.Retry** - Exponential backoff and retry logic
  - **Jido.Exec.Compensation** - Error handling and compensation
  - **Jido.Exec.Async** - Asynchronous execution management
  - **Jido.Exec.Chain** - Sequential action execution
  - **Jido.Exec.Closure** - Action closures with pre-applied context

  ## Core Features

  - Synchronous and asynchronous action execution
  - Automatic retries with exponential backoff
  - Timeout handling for long-running actions
  - Parameter and context normalization
  - Comprehensive error handling and compensation
  - Telemetry integration for monitoring and tracing
  - Action cancellation and cleanup

  ## Usage

  Basic action execution:

      Jido.Exec.run(MyAction, %{param1: "value"}, %{context_key: "context_value"})

  Asynchronous execution:

      async_ref = Jido.Exec.run_async(MyAction, params, context)
      # ... do other work ...
      result = Jido.Exec.await(async_ref)

  See `Jido.Action` for how to define an Action.
  """
  use Private

  alias Jido.Action.Error
  alias Jido.Exec.Async
  alias Jido.Exec.Compensation
  alias Jido.Exec.Retry
  alias Jido.Exec.Supervisors
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Validator
  alias Jido.Instruction

  require Logger

  @default_timeout 30_000

  # Helper functions to get configuration values with fallbacks
  defp get_default_timeout,
    do: Application.get_env(:jido_action, :default_timeout, @default_timeout)

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer(), jido: atom()]
  @type async_ref :: %{ref: reference(), pid: pid()}

  # Execution result types
  @type exec_success :: {:ok, map()}
  @type exec_success_dir :: {:ok, map(), any()}
  @type exec_error :: {:error, Exception.t()}
  @type exec_error_dir :: {:error, Exception.t(), any()}

  @type exec_result ::
          exec_success
          | exec_success_dir
          | exec_error
          | exec_error_dir

  @doc """
  Executes a Action synchronously with the given parameters and context.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution:
    - `:timeout` - Maximum time (in ms) allowed for the Action to complete (configurable via `:jido_action, :default_timeout`).
    - `:max_retries` - Maximum number of retry attempts (configurable via `:jido_action, :default_max_retries`).
    - `:backoff` - Initial backoff time in milliseconds, doubles with each retry (configurable via `:jido_action, :default_backoff`).
    - `:log_level` - Override the global Logger level for this specific action. Accepts #{inspect(Logger.levels())}.
    - `:jido` - Optional instance name for isolation. Routes execution through instance-scoped supervisors (e.g., `MyApp.Jido.TaskSupervisor`).

  ## Action Metadata in Context

  The action's metadata (name, description, category, tags, version, etc.) is made available
  to the action's `run/2` function via the `context` parameter under the `:action_metadata` key.
  This allows actions to access their own metadata when needed.

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution.

  ## Examples

      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{user_id: 123})
      {:ok, %{result: "processed value"}}

      iex> Jido.Exec.run(MyAction, %{invalid: "input"}, %{}, timeout: 1000)
      {:error, %Jido.Action.Error{type: :validation_error, message: "Invalid input"}}

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
  @spec run(Instruction.t()) :: exec_result()
  @spec run(action(), params(), context(), run_opts()) :: exec_result()
  def run(%Instruction{} = instruction) do
    run(
      instruction.action,
      instruction.params,
      instruction.context,
      instruction.opts
    )
  end

  def run(action, params \\ %{}, context \\ %{}, opts \\ [])

  def run(action, params, context, opts) when is_atom(action) and is_list(opts) do
    log_level = Keyword.get(opts, :log_level, :info)

    with {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- Validator.validate_action(action),
         {:ok, validated_params} <- Validator.validate_params(action, normalized_params) do
      enhanced_context =
        Map.put(normalized_context, :action_metadata, action.__action_metadata__())

      Telemetry.cond_log_start(log_level, action, validated_params, enhanced_context)

      do_run_with_retry(action, validated_params, enhanced_context, opts)
    else
      {:error, reason} ->
        Telemetry.cond_log_failure(log_level, inspect(reason))
        {:error, reason}
    end
  rescue
    e in [FunctionClauseError, BadArityError, BadFunctionError] ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_function_error(log_level, e)

      {:error,
       Error.validation_error("Invalid action module: #{Telemetry.extract_safe_error_message(e)}")}

    e ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_unexpected_error(log_level, e)

      {:error,
       Error.internal_error(
         "An unexpected error occurred: #{Telemetry.extract_safe_error_message(e)}"
       )}
  catch
    kind, reason ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_caught_error(log_level, reason)

      {:error, Error.internal_error("Caught #{kind}: #{inspect(reason)}")}
  end

  def run(action, _params, _context, _opts) do
    {:error, Error.validation_error("Expected action to be a module, got: #{inspect(action)}")}
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
    Async.start(action, params, context, opts)
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
  @spec await(async_ref()) :: exec_result
  def await(async_ref), do: Async.await(async_ref)

  @doc """
  Awaits the completion of an asynchronous Action with a custom timeout.

  ## Parameters

  - `async_ref`: The async reference returned by `run_async/4`.
  - `timeout`: Maximum time to wait in milliseconds.

  ## Returns

  - `{:ok, result}` if the Action completes successfully.
  - `{:error, reason}` if an error occurs or timeout is reached.
  """
  @spec await(async_ref(), timeout()) :: exec_result
  def await(async_ref, timeout), do: Async.await(async_ref, timeout)

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
  @spec cancel(async_ref() | pid()) :: :ok | exec_error
  def cancel(async_ref_or_pid), do: Async.cancel(async_ref_or_pid)

  # Private functions are exposed to the test suite
  private do
    @spec normalize_params(params()) :: {:ok, map()} | {:error, Exception.t()}
    defp normalize_params(%_{} = error) when is_exception(error), do: {:error, error}
    defp normalize_params(params) when is_map(params), do: {:ok, params}
    defp normalize_params(params) when is_list(params), do: {:ok, Map.new(params)}
    defp normalize_params({:ok, params}) when is_map(params), do: {:ok, params}
    defp normalize_params({:ok, params}) when is_list(params), do: {:ok, Map.new(params)}
    defp normalize_params({:error, reason}), do: {:error, Error.validation_error(reason)}

    defp normalize_params(params),
      do: {:error, Error.validation_error("Invalid params type: #{inspect(params)}")}

    @spec normalize_context(context()) :: {:ok, map()} | {:error, Exception.t()}
    defp normalize_context(context) when is_map(context), do: {:ok, context}
    defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}

    defp normalize_context(context),
      do: {:error, Error.validation_error("Invalid context type: #{inspect(context)}")}

    @spec do_run_with_retry(action(), params(), context(), run_opts()) :: exec_result
    defp do_run_with_retry(action, params, context, opts) do
      retry_opts = Retry.extract_retry_opts(opts)
      max_retries = retry_opts[:max_retries]
      backoff = retry_opts[:backoff]
      do_run_with_retry(action, params, context, opts, 0, max_retries, backoff)
    end

    @spec do_run_with_retry(
            action(),
            params(),
            context(),
            run_opts(),
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer()
          ) :: exec_result
    defp do_run_with_retry(action, params, context, opts, retry_count, max_retries, backoff) do
      case do_run(action, params, context, opts) do
        {:ok, result} ->
          {:ok, result}

        {:ok, result, other} ->
          {:ok, result, other}

        {:error, reason, other} ->
          maybe_retry(
            action,
            params,
            context,
            opts,
            retry_count,
            max_retries,
            backoff,
            {:error, reason, other}
          )

        {:error, reason} ->
          maybe_retry(
            action,
            params,
            context,
            opts,
            retry_count,
            max_retries,
            backoff,
            {:error, reason}
          )
      end
    end

    defp maybe_retry(
           action,
           params,
           context,
           opts,
           retry_count,
           max_retries,
           initial_backoff,
           error
         ) do
      if Retry.should_retry?(error, retry_count, max_retries, opts) do
        Retry.execute_retry(action, retry_count, max_retries, initial_backoff, opts, fn ->
          do_run_with_retry(
            action,
            params,
            context,
            opts,
            retry_count + 1,
            max_retries,
            initial_backoff
          )
        end)
      else
        error
      end
    end

    @spec do_run(action(), params(), context(), run_opts()) :: exec_result
    defp do_run(action, params, context, opts) do
      timeout = Keyword.get(opts, :timeout, get_default_timeout())
      telemetry = Keyword.get(opts, :telemetry, :full)

      result =
        case telemetry do
          :silent ->
            execute_action_with_timeout(action, params, context, timeout)

          _ ->
            span_metadata = %{
              action: action,
              params: params,
              context: context
            }

            :telemetry.span(
              [:jido, :action],
              span_metadata,
              fn ->
                result = execute_action_with_timeout(action, params, context, timeout, opts)
                {result, %{}}
              end
            )
        end

      case result do
        {:ok, _result} = success ->
          success

        {:ok, _result, _other} = success ->
          success

        {:error, %Jido.Action.Error.TimeoutError{}} = timeout_err ->
          timeout_err

        {:error, error, other} ->
          handle_action_error(action, params, context, {error, other}, opts)

        {:error, error} ->
          handle_action_error(action, params, context, error, opts)
      end
    end

    @spec handle_action_error(
            action(),
            params(),
            context(),
            Exception.t() | {Exception.t(), any()},
            run_opts()
          ) :: exec_result
    defp handle_action_error(action, params, context, error_or_tuple, opts) do
      Compensation.handle_error(action, params, context, error_or_tuple, opts)
    end

    @spec execute_action_with_timeout(
            action(),
            params(),
            context(),
            non_neg_integer(),
            run_opts()
          ) :: exec_result
    defp execute_action_with_timeout(action, params, context, timeout, opts \\ [])

    defp execute_action_with_timeout(action, params, context, 0, opts) do
      execute_action(action, params, context, opts)
    end

    @dialyzer {:nowarn_function, execute_action_with_timeout: 5}
    defp execute_action_with_timeout(action, params, context, timeout, opts)
         when is_integer(timeout) and timeout > 0 do
      # Get the current process's group leader for IO routing
      current_gl = Process.group_leader()

      # Resolve supervisor based on jido: option (defaults to global)
      task_sup = Supervisors.task_supervisor(opts)

      # Spawn task under supervisor using async_nolink
      task =
        Task.Supervisor.async_nolink(task_sup, fn ->
          # Use the parent's group leader to ensure IO is properly captured
          Process.group_leader(self(), current_gl)

          execute_action(action, params, context, opts)
        end)

      # Wait for task completion or timeout
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error,
           Error.execution_error("Task exited: #{inspect(reason)}", %{
             reason: reason,
             action: action
           })}

        nil ->
          {:error,
           Error.timeout_error(
             "Action #{inspect(action)} timed out after #{timeout}ms",
             %{
               timeout: timeout,
               action: action
             }
           )}
      end
    end

    defp execute_action_with_timeout(action, params, context, _timeout, opts) do
      execute_action_with_timeout(action, params, context, get_default_timeout(), opts)
    end

    @spec execute_action(action(), params(), context(), run_opts()) :: exec_result
    defp execute_action(action, params, context, opts) do
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_execution_debug(log_level, action, params, context)

      action.run(params, context)
      |> handle_action_result(action, log_level, opts)
    rescue
      e ->
        handle_action_exception(e, __STACKTRACE__, action, opts)
    end

    # Handle successful results with extra data
    defp handle_action_result({:ok, result, other}, action, log_level, opts) do
      validate_and_log_success(action, result, log_level, opts, other)
    end

    # Handle successful results
    defp handle_action_result({:ok, result}, action, log_level, opts) do
      validate_and_log_success(action, result, log_level, opts, nil)
    end

    # Handle errors with extra data
    defp handle_action_result({:error, reason, other}, action, log_level, _opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {:error, reason, other}
    end

    # Handle exception errors
    defp handle_action_result({:error, %_{} = error}, action, log_level, _opts)
         when is_exception(error) do
      Telemetry.cond_log_error(log_level, action, error)
      {:error, error}
    end

    # Handle generic errors
    defp handle_action_result({:error, reason}, action, log_level, _opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {:error, Error.execution_error(reason)}
    end

    # Handle unexpected return shapes
    defp handle_action_result(unexpected_result, action, log_level, _opts) do
      error = Error.execution_error("Unexpected return shape: #{inspect(unexpected_result)}")
      Telemetry.cond_log_error(log_level, action, error)
      {:error, error}
    end

    # Validate output and log success, with optional extra data
    defp validate_and_log_success(action, result, log_level, opts, other) do
      case Validator.validate_output(action, result, opts) do
        {:ok, validated_result} ->
          log_validated_success(action, validated_result, log_level, other)

        {:error, validation_error} ->
          log_validation_failure(action, validation_error, log_level, other)
      end
    end

    defp log_validated_success(action, validated_result, log_level, nil) do
      Telemetry.cond_log_end(log_level, action, {:ok, validated_result})
      {:ok, validated_result}
    end

    defp log_validated_success(action, validated_result, log_level, other) do
      Telemetry.cond_log_end(log_level, action, {:ok, validated_result, other})
      {:ok, validated_result, other}
    end

    defp log_validation_failure(action, validation_error, log_level, nil) do
      Telemetry.cond_log_validation_failure(log_level, action, validation_error)
      {:error, validation_error}
    end

    defp log_validation_failure(action, validation_error, log_level, other) do
      Telemetry.cond_log_validation_failure(log_level, action, validation_error)
      {:error, validation_error, other}
    end

    # Handle exceptions raised during action execution
    defp handle_action_exception(e, stacktrace, action, opts) do
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_error(log_level, action, e)

      error_message = build_exception_message(e, action)

      {:error,
       Error.execution_error(error_message, %{
         original_exception: e,
         action: action,
         stacktrace: stacktrace
       })}
    end

    defp build_exception_message(%RuntimeError{} = e, action) do
      "Server error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
    end

    defp build_exception_message(%ArgumentError{} = e, action) do
      "Argument error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
    end

    defp build_exception_message(e, action) do
      "An unexpected error occurred during execution of #{inspect(action)}: #{inspect(e)}"
    end
  end
end
