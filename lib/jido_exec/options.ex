defmodule Jido.Exec.Options do
  @moduledoc false

  alias Jido.Action.Error

  @flow_run_option_keys [:async, :max_concurrency]

  @doc false
  @spec validate_flow(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def validate_flow(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_flow_options(opts),
         :ok <- validate_async(Keyword.get(opts, :async, false)),
         :ok <- validate_max_concurrency(Keyword.get(opts, :max_concurrency, 1)) do
      {:ok,
       [
         async: Keyword.get(opts, :async, false),
         max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online())
       ]}
    end
  end

  @doc false
  @spec reject(keyword(), :action | :instruction) :: :ok | {:error, Exception.t()}
  def reject(opts, executable_type) do
    with :ok <- validate_keyword(opts) do
      if opts == [] do
        :ok
      else
        {:error,
         Error.validation_error("run options are only supported for flows", %{
           executable_type: executable_type,
           options: Keyword.keys(opts)
         })}
      end
    end
  end

  defp validate_keyword(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, Error.validation_error("run options must be a keyword list")}
    end
  end

  defp validate_keyword(_opts),
    do: {:error, Error.validation_error("run options must be a keyword list")}

  defp validate_known_flow_options(opts) do
    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in @flow_run_option_keys))
    |> case do
      nil ->
        :ok

      option ->
        {:error,
         Error.validation_error("unknown run option: #{inspect(option)}", %{option: option})}
    end
  end

  defp validate_async(async) when is_boolean(async), do: :ok

  defp validate_async(_async) do
    {:error, Error.validation_error("async option must be a boolean", %{option: :async})}
  end

  defp validate_max_concurrency(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency(_max_concurrency) do
    {:error,
     Error.validation_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end
end
