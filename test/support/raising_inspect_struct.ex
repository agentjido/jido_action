defmodule JidoTest.Support.RaisingInspectStruct do
  @moduledoc false

  defstruct [:value]
end

defimpl Inspect, for: JidoTest.Support.RaisingInspectStruct do
  def inspect(_term, _opts), do: raise("boom")
end
