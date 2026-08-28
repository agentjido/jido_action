defmodule Jido.Exec.Options do
  @moduledoc false

  alias Jido.Action.Error, as: ActionError
  alias Jido.Exec.Runtime
  alias Jido.Flow.Error, as: FlowError

  @routing_option_keys [:jido]
  @common_run_option_keys [:max_concurrency, :max_continuations | @routing_option_keys]
  @flow_run_option_keys @common_run_option_keys
  @flow_start_option_keys [:max_concurrency | @routing_option_keys]
  @action_run_option_keys @common_run_option_keys
  @default_max_concurrency 8
  @default_max_continuations 32
  @maximum_continuations 10_000

  @doc false
  @spec take_timeout(term(), ActionError | FlowError) ::
          {:ok, timeout(), term()} | {:error, Exception.t()}
  def take_timeout(opts, error_module) when is_list(opts) do
    if Keyword.keyword?(opts) do
      timeout = Keyword.get(opts, :timeout, :infinity)

      if timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
        {:ok, timeout, Keyword.delete(opts, :timeout)}
      else
        {:error,
         execution_option_error(
           error_module,
           "timeout option must be :infinity or a non-negative integer",
           %{option: :timeout, value: timeout}
         )}
      end
    else
      {:ok, :infinity, opts}
    end
  end

  def take_timeout(opts, _error_module), do: {:ok, :infinity, opts}

  @doc false
  @spec continuation_limit(term(), ActionError | FlowError) ::
          {:ok, non_neg_integer()} | {:error, Exception.t()}
  def continuation_limit(opts, error_module) when is_list(opts) do
    if Keyword.keyword?(opts) do
      value = Keyword.get(opts, :max_continuations, @default_max_continuations)

      if is_integer(value) and value in 0..@maximum_continuations do
        {:ok, value}
      else
        {:error,
         execution_option_error(
           error_module,
           "max_continuations option must be an integer from 0 through #{@maximum_continuations}",
           %{option: :max_continuations, value: value}
         )}
      end
    else
      {:ok, @default_max_continuations}
    end
  end

  def continuation_limit(_opts, _error_module), do: {:ok, @default_max_continuations}

  @doc false
  @spec validate_flow(keyword(), :run | :start) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def validate_flow(opts, mode \\ :run) when mode in [:run, :start] do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_flow_options(opts, mode),
         :ok <- validate_jido(opts, FlowError),
         {:ok, task_supervisor} <- validate_task_supervisor(opts, FlowError),
         max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency),
         :ok <- validate_max_concurrency(max_concurrency, FlowError),
         {:ok, continuation_options} <- continuation_options(opts, mode) do
      {:ok,
       [max_concurrency: max_concurrency, task_supervisor: task_supervisor] ++
         continuation_options ++ routing_options(opts)}
    end
  end

  @doc false
  @spec validate_action(keyword(), :action | :instruction) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def validate_action(opts, executable_type) do
    with :ok <- validate_action_keyword(opts),
         :ok <- validate_known_action_options(opts, executable_type),
         :ok <- validate_jido(opts, ActionError),
         {:ok, task_supervisor} <- validate_task_supervisor(opts, ActionError),
         max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency),
         :ok <- validate_max_concurrency(max_concurrency, ActionError),
         {:ok, max_continuations} <- continuation_limit(opts, ActionError) do
      {:ok,
       [
         max_concurrency: max_concurrency,
         max_continuations: max_continuations,
         task_supervisor: task_supervisor
       ] ++ routing_options(opts)}
    end
  end

  defp routing_options(opts) do
    case Keyword.fetch(opts, :jido) do
      {:ok, jido} -> [jido: jido]
      :error -> []
    end
  end

  defp validate_known_action_options(opts, executable_type) do
    unsupported = Keyword.keys(opts) -- @action_run_option_keys

    if unsupported == [] do
      :ok
    else
      {:error,
       ActionError.validation_error("unknown Action run option", %{
         executable_type: executable_type,
         options: unsupported
       })}
    end
  end

  defp validate_jido(opts, error_module) do
    case Keyword.fetch(opts, :jido) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, jido} when is_atom(jido) ->
        :ok

      {:ok, jido} ->
        {:error,
         execution_option_error(error_module, "jido option must be an atom or nil", %{
           option: :jido,
           value: jido
         })}
    end
  end

  defp validate_task_supervisor(opts, error_module) do
    case Runtime.task_supervisor(opts) do
      {:ok, supervisor} ->
        {:ok, supervisor}

      {:error, error} ->
        {:error,
         execution_option_error(error_module, Exception.message(error), %{
           option: :jido,
           jido: Keyword.get(opts, :jido),
           task_supervisor: Runtime.task_supervisor_name(opts)
         })}
    end
  end

  defp execution_option_error(FlowError, message, details) do
    FlowError.invalid_execution_error(message, details)
  end

  defp execution_option_error(ActionError, message, details) do
    ActionError.validation_error(message, details)
  end

  defp validate_action_keyword(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, ActionError.validation_error("run options must be a keyword list")}
  end

  defp validate_action_keyword(_opts),
    do: {:error, ActionError.validation_error("run options must be a keyword list")}

  defp validate_keyword(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, FlowError.invalid_execution_error("run options must be a keyword list")}
    end
  end

  defp validate_keyword(_opts),
    do: {:error, FlowError.invalid_execution_error("run options must be a keyword list")}

  defp validate_known_flow_options(opts, mode) do
    known_options = if mode == :run, do: @flow_run_option_keys, else: @flow_start_option_keys

    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in known_options))
    |> case do
      nil ->
        :ok

      option ->
        {:error,
         FlowError.invalid_execution_error("unknown run option: #{inspect(option)}", %{
           option: option
         })}
    end
  end

  defp continuation_options(opts, :run) do
    with {:ok, limit} <- continuation_limit(opts, FlowError) do
      {:ok, [max_continuations: limit]}
    end
  end

  defp continuation_options(_opts, :start), do: {:ok, []}

  defp validate_max_concurrency(max_concurrency, _error_module)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency(_max_concurrency, FlowError) do
    {:error,
     FlowError.invalid_execution_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end

  defp validate_max_concurrency(_max_concurrency, ActionError) do
    {:error,
     ActionError.validation_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end
end
