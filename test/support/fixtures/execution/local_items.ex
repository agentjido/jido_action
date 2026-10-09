defmodule JidoActionTest.Fixtures.LocalItems do
  @moduledoc false
  defstruct count: 1
end

defimpl Enumerable, for: JidoActionTest.Fixtures.LocalItems do
  def reduce(%{count: count}, acc, fun),
    do: Enumerable.List.reduce(List.duplicate(make_ref(), count), acc, fun)

  def count(%{count: count}), do: {:ok, count}
  def member?(_, _), do: {:error, __MODULE__}
  def slice(_), do: {:error, __MODULE__}
end
