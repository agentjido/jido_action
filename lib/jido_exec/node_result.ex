defmodule Jido.Exec.NodeResult do
  @moduledoc """
  Result of one named Flow node execution.

  `status` is `:ok` when the node produced `output`. It is `:error` when the
  node produced `error`. A failed node is still an applied execution
  transition, so step-wise functions return it inside an `:ok` tuple with the
  updated execution.

  `attempt` is `1` in the current runtime. Retry policy is not part of the
  public Flow execution API.
  """

  @type status :: :ok | :error

  @type t :: %__MODULE__{
          node: String.t(),
          status: status(),
          output: term() | nil,
          error: Exception.t() | nil,
          attempt: pos_integer()
        }

  @enforce_keys [:node, :status, :output, :error, :attempt]
  defstruct @enforce_keys
end
