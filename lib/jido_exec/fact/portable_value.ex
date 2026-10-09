defmodule Jido.Exec.Fact.PortableValue do
  @moduledoc false
  @enforce_keys [:value, :digest]
  defstruct [:value, :digest]

  @type t :: %__MODULE__{value: term(), digest: Runic.Identity.t()}
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Fact.PortableValue do
  def identity_document(encoded) do
    %{codec: :jido_portable_value, version: 1, digest: encoded.digest}
  end
end
