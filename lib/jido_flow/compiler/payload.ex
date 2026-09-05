defmodule Jido.Flow.Compiler.Payload do
  @moduledoc false

  # Runic identities are portable by default. Jido executes in one BEAM and
  # also accepts local values such as PIDs, references, functions, and structs.
  # Keep those values intact and explicitly project their local identity.
  # This is not a storage codec or a cross-VM identity contract.
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  @doc false
  @spec new(term()) :: t()
  def new(value), do: %__MODULE__{value: value}

  @doc false
  @spec unwrap(term()) :: term()
  def unwrap(%__MODULE__{value: value}), do: value
  # Join and FanIn combine payloads into native lists.
  def unwrap(values) when is_list(values), do: Enum.map(values, &unwrap/1)
  def unwrap(value), do: value
end

defimpl Runic.Identity.Projectable, for: Jido.Flow.Compiler.Payload do
  def identity_document(%{value: value}) do
    digest =
      case :erlang.term_to_iovec(value, [:deterministic]) do
        [bytes] ->
          :crypto.hash(:sha256, bytes)

        segments ->
          segments
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
      end

    {:jido_local_beam_value, 1, digest}
  end
end
