defmodule Jido.Exec.Execution do
  @moduledoc """
  State for a paused Flow execution.

  Create an execution with `Jido.Exec.start/4`. Pass the latest returned value
  to the other step-wise execution functions. Use `Jido.Exec` functions to
  read or update it. Its fields are internal, and the value is not a storage
  or interchange format. A successful state-changing operation consumes its
  revision. Jido rejects concurrent use and reuse of an older revision before
  it dispatches Action work.
  """

  @typedoc "State for one in-memory Flow execution session."
  @type t :: struct()

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
