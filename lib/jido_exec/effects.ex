defmodule Jido.Exec.Effects do
  @moduledoc false

  @doc false
  @spec attach(Jido.Exec.exec_result(), Jido.Action.effects()) :: Jido.Exec.exec_result()
  def attach({:ok, output, effects}, prefix), do: attach({:ok, output}, prefix ++ effects)
  def attach(result, []), do: result
  def attach({:ok, output}, effects), do: {:ok, output, effects}
  def attach(result, _effects), do: result
end
