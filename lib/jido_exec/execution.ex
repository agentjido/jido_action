defmodule Jido.Exec.Execution do
  @moduledoc """
  Opaque state for a paused Flow execution.

  Create an execution with `Jido.Exec.start/4`. Pass the latest returned value
  to the other step-wise execution functions. The internal representation is
  not a storage or interchange format.
  """

  alias Jido.Flow
  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  @typedoc "Current state of a Flow execution."
  @opaque t :: %__MODULE__{
            id: reference(),
            flow_name: String.t(),
            status: :running | :succeeded | :failed,
            revision: non_neg_integer(),
            flow: Flow.t(),
            input: map(),
            context: map(),
            options: keyword(),
            workflow: Workflow.t(),
            ordered_nodes: [String.t()],
            ready: %{String.t() => Runnable.t()},
            node_results: %{String.t() => Jido.Exec.NodeResult.t()},
            node_errors: %{String.t() => Exception.t()},
            engine_error: Exception.t() | nil,
            finalizer: (term() -> {:ok, term()} | {:error, Exception.t()}),
            final_result: {:ok, term()} | {:error, Exception.t()} | nil
          }

  @derive {Inspect, only: [:id, :flow_name, :status, :revision]}
  @enforce_keys [
    :id,
    :flow_name,
    :status,
    :revision,
    :flow,
    :input,
    :context,
    :options,
    :workflow,
    :ordered_nodes,
    :ready,
    :node_results,
    :node_errors,
    :engine_error,
    :finalizer,
    :final_result
  ]
  defstruct @enforce_keys
end
