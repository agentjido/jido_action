defmodule Jido.Exec.FactTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Fact, as: JidoFact
  alias Runic.Identity.CanonicalError
  alias Runic.Workflow.Fact, as: RunicFact

  test "local facts preserve process-local values across native Runic facts" do
    reference = make_ref()
    root = JidoFact.local_root(%{reference: reference})

    native_fact =
      RunicFact.new(
        value: [root.value],
        ancestry: {:native_join, root.hash}
      )

    child =
      JidoFact.child(native_fact,
        value: %{reference: reference, uri: URI.parse("/home")},
        ancestry: {:jido_node, native_fact.hash}
      )

    assert JidoFact.value(child) == %{reference: reference, uri: URI.parse("/home")}
  end

  test "local facts bound deeply nested identity documents" do
    value = Enum.reduce(1..100, :leaf, fn _index, nested -> [nested] end)

    assert value == value |> JidoFact.local_root() |> JidoFact.value()
  end

  test "local facts preserve improper lists until the Action validates them" do
    reference = make_ref()
    value = %{effects: [reference | :improper], nested: {[:head | self()], []}}
    assert value == value |> JidoFact.local_root() |> JidoFact.value()
  end

  test "long proper lists keep their ordinary value representation" do
    value = Enum.to_list(1..100)
    assert JidoFact.local_root(value).value == value
  end

  test "canonical facts still reject process-local child values" do
    parent = RunicFact.new(value: %{})

    assert_raise CanonicalError, fn ->
      JidoFact.child(parent, value: make_ref(), ancestry: {:jido_node, parent.hash})
    end
  end
end
