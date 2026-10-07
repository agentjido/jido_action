defmodule Jido.Exec.Transition do
  @moduledoc false

  alias Jido.Instruction

  @type t :: %__MODULE__{
          input: map(),
          target: Instruction.target() | Instruction.t(),
          origin: module(),
          effects: [term()],
          context: map()
        }

  @enforce_keys [:input, :target, :origin, :context]
  defstruct @enforce_keys ++ [effects: []]

  @doc false
  @spec new(map(), Instruction.target() | Instruction.t(), module(), map()) :: t()
  def new(input, target, origin, context)
      when is_map(input) and is_atom(origin) and is_map(context) do
    %__MODULE__{input: input, target: target, origin: origin, context: context}
  end
end
