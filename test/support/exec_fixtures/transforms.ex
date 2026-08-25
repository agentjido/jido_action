defmodule JidoActionTest.ExecFixtures.Transforms do
  @moduledoc false

  @kinds [:input, :invalid_input, :output, :envelope_output, :invalid_output]

  def count(value, kind, _opts) do
    Process.put({__MODULE__, kind}, calls(kind) + 1)

    transformed =
      case kind do
        :input -> Map.update(value, :input_passes, 1, &(&1 + 1))
        :invalid_input -> :invalid
        :output -> Map.update(value, :output_passes, 1, &(&1 + 1))
        :envelope_output -> value
        :invalid_output -> :invalid
      end

    {:ok, transformed}
  end

  def calls(kind), do: Process.get({__MODULE__, kind}, 0)

  def reset do
    Enum.each(@kinds, &Process.delete({__MODULE__, &1}))
    :ok
  end
end
