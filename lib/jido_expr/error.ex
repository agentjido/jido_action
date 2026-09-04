defmodule Jido.Expr.Error do
  @moduledoc """
  A structured expression construction, validation, or evaluation failure.

  `path` identifies the expression location. Operand paths use `:operands`
  followed by the zero-based operand index. Lists use indexes and maps use
  keys. `details` contains types or limit information, not runtime values.
  """

  defexception [:reason, :operator, path: [], details: %{}]

  @typedoc "An expression failure with an exact location and safe metadata."
  @type t :: %__MODULE__{
          reason: atom(),
          operator: atom() | nil,
          path: list(),
          details: map()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(error) do
    "invalid expression: #{error.reason}" <>
      if(error.operator, do: " (#{error.operator})", else: "") <>
      " at #{inspect(error.path)}"
  end
end
