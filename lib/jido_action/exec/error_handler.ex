defmodule Jido.Exec.ErrorHandler do
  @moduledoc """
  Error handling and compensation functionality for Jido.Exec.
  
  This module handles:
  - Action error processing and compensation
  - Compensation result handling
  - Error propagation with directives
  """

  use ExDbug, enabled: false

  alias Jido.Action.Error

  require Logger
  require OK

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer()]

  @doc """
  Handles action errors and compensation logic.
  
  If compensation is enabled for the action, it will attempt to run the
  compensation function. Otherwise, it returns the original error.
  """
  @spec handle_action_error(
          action(),
          params(),
          context(),
          Error.t() | {Error.t(), any()},
          run_opts()
        ) ::
          {:error, Error.t() | map()} | {:error, Error.t(), any()}
  def handle_action_error(action, params, context, error_or_tuple, opts) do
    Logger.debug("Handle Action Error in handle_action_error: #{inspect(opts)}")
    dbug("Handling action error", action: action, error: error_or_tuple)

    # Extract error and directive if present
    {error, directive} =
      case error_or_tuple do
        {error, directive} -> {error, directive}
        error -> {error, nil}
      end

    if compensation_enabled?(action) do
      metadata = action.__action_metadata__()
      compensation_opts = metadata[:compensation] || []

      timeout =
        Keyword.get(opts, :timeout) ||
          case compensation_opts do
            opts when is_list(opts) -> Keyword.get(opts, :timeout, 5_000)
            %{timeout: timeout} -> timeout
            _ -> 5_000
          end

      dbug("Starting compensation", action: action, timeout: timeout)

      task =
        Task.async(fn ->
          action.on_error(params, error, context, [])
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} ->
          dbug("Compensation completed", result: result)
          handle_compensation_result(result, error, directive)

        nil ->
          dbug("Compensation timed out", timeout: timeout)

          error_result =
            Error.compensation_error(
              error,
              %{
                compensated: false,
                compensation_error: "Compensation timed out after #{timeout}ms"
              }
            )

          if directive, do: {:error, error_result, directive}, else: OK.failure(error_result)
      end
    else
      dbug("Compensation not enabled", action: action)
      if directive, do: {:error, error, directive}, else: OK.failure(error)
    end
  end

  @doc """
  Handles the result of a compensation attempt.
  """
  @spec handle_compensation_result(any(), Error.t(), any()) ::
          {:error, Error.t()} | {:error, Error.t(), any()}
  def handle_compensation_result(result, original_error, directive) do
    error_result =
      case result do
        {:ok, comp_result} ->
          # Extract fields that should be at the top level of the details
          {top_level_fields, remaining_fields} =
            Map.split(comp_result, [:test_value, :compensation_context])

          # Create the details map with the compensation result
          details =
            Map.merge(
              %{
                compensated: true,
                compensation_result: remaining_fields
              },
              top_level_fields
            )

          Error.compensation_error(original_error, details)

        {:error, comp_error} ->
          Error.compensation_error(
            original_error,
            %{
              compensated: false,
              compensation_error: comp_error
            }
          )

        _ ->
          Error.compensation_error(
            original_error,
            %{
              compensated: false,
              compensation_error: "Invalid compensation result"
            }
          )
      end

    if directive, do: {:error, error_result, directive}, else: OK.failure(error_result)
  end

  @doc """
  Checks if compensation is enabled for the given action.
  """
  @spec compensation_enabled?(action()) :: boolean()
  def compensation_enabled?(action) do
    metadata = action.__action_metadata__()
    compensation_opts = metadata[:compensation] || []

    enabled =
      case compensation_opts do
        opts when is_list(opts) -> Keyword.get(opts, :enabled, false)
        %{enabled: enabled} -> enabled
        _ -> false
      end

    enabled && function_exported?(action, :on_error, 4)
  end
end
