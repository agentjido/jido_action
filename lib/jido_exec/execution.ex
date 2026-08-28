defmodule Jido.Exec.Execution do
  @moduledoc """
  State for a paused Flow execution.

  Create an execution with `Jido.Exec.start/4`. Pass the latest returned value
  to the other step-wise execution functions. Use `Jido.Exec` functions to
  read or update it. Its fields are internal, and the value is not a storage
  or interchange format. A successful state-changing operation consumes its
  revision. Jido rejects concurrent use and reuse of an older revision before
  it dispatches Action work. Use `Jido.Exec.continue/1` to finish the
  lifecycle.
  """

  alias Jido.Flow
  alias Jido.Flow.Compiled
  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  @typedoc "State for one in-memory Flow execution session."
  @type t :: %__MODULE__{
          id: String.t(),
          flow_name: String.t(),
          status: :running | :succeeded | :failed,
          revision: non_neg_integer(),
          guard: :atomics.atomics_ref(),
          flow: Flow.t(),
          compiled: Compiled.t(),
          input: map(),
          context: map(),
          options: keyword(),
          workflow: Workflow.t(),
          ready: [Runnable.t()],
          runnable_errors: [%{runnable: Runnable.t(), error: Exception.t()}],
          engine_error: Exception.t() | nil,
          finalizer: (term() -> {:ok, term()} | {:error, Exception.t()}),
          final_result:
            {:ok, term()}
            | {:error, Exception.t()}
            | nil,
          lifecycle: %{flow: map()}
        }

  @derive {Inspect, only: [:id, :flow_name, :status, :revision]}
  @enforce_keys [
    :id,
    :flow_name,
    :status,
    :revision,
    :guard,
    :flow,
    :compiled,
    :input,
    :context,
    :options,
    :workflow,
    :ready,
    :runnable_errors,
    :engine_error,
    :finalizer,
    :final_result,
    :lifecycle
  ]
  defstruct @enforce_keys
end
