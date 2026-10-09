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

  test "portable facts preserve nested shapes, map keys, and distinct types" do
    uri = URI.parse("/home")

    values = [
      uri,
      [1 | :tail],
      <<1::1>>,
      <<1>>,
      {1, :tail},
      Enum.reduce(1..100, :leaf, fn _, acc -> [acc] end)
    ]

    terms = Map.new(values, &{&1, {&1, [uri, &1]}})
    root = JidoFact.portable_root(terms)
    assert JidoFact.value(root) == terms

    assert root.payload_digest ==
             JidoFact.portable_root(Map.new(Enum.reverse(Map.to_list(terms)))).payload_digest

    digests = Enum.map(values, &JidoFact.portable_root(&1).payload_digest)
    assert length(Enum.uniq(digests)) == length(values)
  end

  test "portable facts retain canonical identity fixtures across supported Elixir and OTP versions" do
    fixtures = [
      {URI.parse("https://example.com"),
       "c9271338edc356d12750dc4a17256159f3296ca8d93b29decc18848de0996384"},
      {[1 | :tail], "56ae67bedbe9a1d096c6f8536fa2d1377ab6b44c64ad850833f32ac5ce5e96f2"},
      {<<1::1>>, "7112ca66acca62dee40a43642a9ca053ebe2fa35701748100b0883a1b7ea76cc"}
    ]

    for {value, digest} <- fixtures do
      root = JidoFact.portable_root(value)
      assert Base.encode16(root.payload_digest.digest, case: :lower) == digest
      assert JidoFact.value(root) == value
    end
  end

  test "canonical facts still reject process-local child values" do
    parent = RunicFact.new(value: %{})

    assert_raise CanonicalError, fn ->
      JidoFact.child(parent, value: make_ref(), ancestry: {:jido_node, parent.hash})
    end
  end
end
