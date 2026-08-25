defmodule Jido.Exec.Options do
  @moduledoc false

  alias Jido.Action.Error, as: ActionError
  alias Jido.Exec.Supervisor, as: ExecSupervisor
  alias Jido.Flow.Error, as: FlowError

  @routing_option_keys [:jido]
  @flow_run_option_keys [:async, :max_concurrency | @routing_option_keys]
  @default_max_concurrency System.schedulers_online()

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
  @spec validate_flow(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def validate_flow(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_flow_options(opts),
         :ok <- validate_jido(opts, FlowError),
         :ok <- validate_task_supervisor(opts, FlowError),
         max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency),
         :ok <- validate_async(Keyword.get(opts, :async, false)),
         :ok <- validate_max_concurrency(max_concurrency) do
      {:ok,
       [
         async: Keyword.get(opts, :async, false),
         max_concurrency: max_concurrency
       ] ++ routing_options(opts)}
    end
  end

  @doc false
  @spec validate_action(keyword(), :action | :instruction) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def validate_action(opts, executable_type) do
    with :ok <- validate_action_keyword(opts),
         :ok <- validate_known_action_options(opts, executable_type),
         :ok <- validate_jido(opts, ActionError),
         :ok <- validate_task_supervisor(opts, ActionError) do
      {:ok, routing_options(opts)}
    end
  end

  defp routing_options(opts) do
    case Keyword.fetch(opts, :jido) do
      {:ok, jido} -> [jido: jido]
      :error -> []
    end
  end

  defp validate_known_action_options(opts, executable_type) do
    unsupported = Keyword.keys(opts) -- @routing_option_keys

    if unsupported == [] do
      :ok
    else
      {:error,
       ActionError.validation_error("run options are only supported for flows", %{
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
    case ExecSupervisor.task_supervisor(opts) do
      {:ok, _supervisor} ->
        :ok

      {:error, error} ->
        {:error,
         execution_option_error(error_module, Exception.message(error), %{
           option: :jido,
           jido: Keyword.get(opts, :jido),
           task_supervisor: ExecSupervisor.task_supervisor_name(opts)
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

  defp validate_known_flow_options(opts) do
    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in @flow_run_option_keys))
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

  defp validate_async(async) when is_boolean(async), do: :ok

  defp validate_async(_async) do
    {:error,
     FlowError.invalid_execution_error("async option must be a boolean", %{option: :async})}
  end

  defp validate_max_concurrency(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency(_max_concurrency) do
    {:error,
     FlowError.invalid_execution_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end
end
