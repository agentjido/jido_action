defmodule Jido.Exec.Retry do
  @moduledoc """
  Retry logic for Jido.Exec.

  This module handles:
  - Retry logic with exponential backoff
  - Retry attempt counting and limiting
  - Backoff calculation
  """

  use ExDbug, enabled: false

  alias Jido.Action.Error

  require Logger
  require OK

  import Jido.Action.Util, only: [cond_log: 3]

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer()]

  @default_max_retries 0
  @default_initial_backoff 250

  # Helper functions to get configuration values with fallbacks
  defp get_default_max_retries,
    do: Application.get_env(:jido_action, :default_max_retries, @default_max_retries)

  defp get_default_backoff,
    do: Application.get_env(:jido_action, :default_backoff, @default_initial_backoff)

  @spec run_with_retry(action(), params(), context(), run_opts(), function()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_with_retry(action, params, context, opts, exec_fn) do
    max_retries = Keyword.get(opts, :max_retries, get_default_max_retries())
    backoff = Keyword.get(opts, :backoff, get_default_backoff())
    dbug("Starting run with retry", action: action, max_retries: max_retries, backoff: backoff)
    do_run_with_retry(action, params, context, opts, 0, max_retries, backoff, exec_fn)
  end

  @spec do_run_with_retry(
          action(),
          params(),
          context(),
          run_opts(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          function()
        ) :: {:ok, map()} | {:error, Error.t()}
  defp do_run_with_retry(
         action,
         params,
         context,
         opts,
         retry_count,
         max_retries,
         backoff,
         exec_fn
       ) do
    dbug("Attempting run", action: action, retry_count: retry_count)

    case exec_fn.(action, params, context, opts) do
      OK.success(result) ->
        dbug("Run succeeded", result: result)
        OK.success(result)

      {:ok, result, other} ->
        dbug("Run succeeded with additional info", result: result, other: other)
        {:ok, result, other}

      {:error, reason, other} ->
        dbug("Run failed with additional info", error: reason, other: other)

        maybe_retry(
          action,
          params,
          context,
          opts,
          retry_count,
          max_retries,
          backoff,
          {:error, reason, other},
          exec_fn
        )

      OK.failure(reason) ->
        dbug("Run failed", error: reason)

        maybe_retry(
          action,
          params,
          context,
          opts,
          retry_count,
          max_retries,
          backoff,
          OK.failure(reason),
          exec_fn
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
         backoff,
         error,
         exec_fn
       ) do
    if retry_count < max_retries do
      backoff = calculate_backoff(retry_count, backoff)

      cond_log(
        Keyword.get(opts, :log_level, :info),
        :info,
        "Retrying #{inspect(action)} (attempt #{retry_count + 1}/#{max_retries}) after #{backoff}ms backoff"
      )

      dbug("Retrying after backoff",
        action: action,
        retry_count: retry_count,
        max_retries: max_retries,
        backoff: backoff
      )

      :timer.sleep(backoff)

      do_run_with_retry(
        action,
        params,
        context,
        opts,
        retry_count + 1,
        max_retries,
        backoff,
        exec_fn
      )
    else
      dbug("Max retries reached", action: action, max_retries: max_retries)
      error
    end
  end

  @spec calculate_backoff(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def calculate_backoff(retry_count, backoff) do
    (backoff * :math.pow(2, retry_count))
    |> round()
    |> min(30_000)
  end
end
