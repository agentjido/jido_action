defmodule Jido.Exec.Result do
  @moduledoc """
  Result value returned by Runic-backed Jido execution.

  The result keeps the underlying `Runic.Workflow` available for advanced use
  while presenting a small Jido-facing shape for status, results, events, cycle
  count, and errors.
  """

  alias Runic.Workflow

  defstruct [
    :workflow,
    :status,
    :results,
    :events,
    :cycles,
    :error
  ]

  @type status :: :ok | :error | :halted | :max_cycles
  @type t :: %__MODULE__{
          workflow: Workflow.t(),
          status: status(),
          results: term(),
          events: [term()],
          cycles: non_neg_integer(),
          error: term() | nil
        }

  @doc false
  @spec new(Workflow.t(), status(), keyword()) :: t()
  def new(%Workflow{} = workflow, status, opts \\ []) when is_list(opts) do
    %__MODULE__{
      workflow: workflow,
      status: status,
      results: Keyword.get_lazy(opts, :results, fn -> Workflow.results(workflow) end),
      events: Keyword.get_lazy(opts, :events, fn -> workflow_events(workflow) end),
      cycles: Keyword.get(opts, :cycles, 0),
      error: Keyword.get(opts, :error)
    }
  end

  defp workflow_events(%Workflow{} = workflow) do
    Workflow.event_log(workflow)
  rescue
    _ -> Map.get(workflow, :runnable_events, [])
  catch
    _, _ -> Map.get(workflow, :runnable_events, [])
  end
end
