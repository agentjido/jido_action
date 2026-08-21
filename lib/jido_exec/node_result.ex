defmodule Jido.Exec.NodeResult do
  @moduledoc """
  Result of one named Flow node execution.
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
