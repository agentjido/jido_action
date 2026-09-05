defmodule JidoActionTest.Flow.Compiler.PayloadTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Compiler.Payload
  alias Runic.Workflow.Fact

  test "payload projection keeps the deterministic external-term digest" do
    binary = :binary.copy(<<42>>, 1_048_576)

    for value <- [42, %{data: binary}, {binary, binary}, [self(), make_ref(), <<5::3>>]] do
      expected = :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))

      assert Runic.Identity.Projectable.identity_document(Payload.new(value)) ==
               {:jido_local_beam_value, 1, expected}
    end
  end

  test "local payload identities preserve map order independence and term distinctions" do
    left = Enum.into([{:a, 1}, {:b, 2}], %{})
    right = Enum.into([{:b, 2}, {:a, 1}], %{})
    assert fact(left).hash == fact(right).hash

    for {left, right} <- [
          {1, 1.0},
          {:value, "value"},
          {[1], {1}},
          {make_ref(), make_ref()},
          {MapSet.new([1]), %{map: %{1 => []}}}
        ] do
      refute fact(left).hash == fact(right).hash
    end

    assert %Runic.Identity{domain: :fact_occurrence, digest: digest} = fact(left).hash
    assert byte_size(digest) == 32
  end

  test "hashing local streams and functions does not execute or replace them" do
    owner = self()

    stream =
      Stream.map([1, 2], fn value ->
        send(owner, {:enumerated, value})
        value
      end)

    value = %{
      stream: stream,
      pid: owner,
      reference: make_ref(),
      callback: fn x -> x end,
      improper: [1 | 2]
    }

    assert %Fact{value: payload} = fact(value)
    assert Payload.unwrap(payload) === value
    refute_received {:enumerated, _}
    assert Enum.to_list(Payload.unwrap(payload).stream) == [1, 2]
    assert_received {:enumerated, 1}
    assert_received {:enumerated, 2}
  end

  test "native joins unwrap each payload without traversing its user data" do
    left = Payload.new([1 | 2])
    right = Payload.new(%{value: make_ref()})
    assert Payload.unwrap([left, right]) == [[1 | 2], right.value]
    assert Payload.unwrap(:waiting) == :waiting
  end

  defp fact(value), do: Fact.new(value: Payload.new(value))
end
