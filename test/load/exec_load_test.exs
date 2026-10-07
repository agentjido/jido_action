defmodule JidoActionTest.Load.ExecLoadTest do
  use ExUnit.Case, async: false

  @moduletag :load
  @moduletag timeout: 30_000

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Actions.Add

  test "concurrent one-step workflows keep their own inputs" do
    results =
      1..200
      |> Task.async_stream(
        fn value -> Exec.run(Add, %{value: value, amount: 1}) end,
        max_concurrency: System.schedulers_online(),
        ordered: true,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == Enum.map(1..200, &{:ok, %{value: &1 + 1}})
  end
end
