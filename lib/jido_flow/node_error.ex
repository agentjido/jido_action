defmodule Jido.Flow.NodeError do
  @moduledoc false

  defexception [:node, :error]

  @type t :: %__MODULE__{
          node: String.t(),
          error: Exception.t()
        }

  @impl true
  def message(%__MODULE__{node: node, error: error}) do
    "flow node #{inspect(node)} failed: #{Exception.message(error)}"
  end
end
