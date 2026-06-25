defmodule Jido.Action.OutputTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Output

  describe "constructors" do
    test "build explicit abnormal output envelopes" do
      assert %Output{kind: :raw, value: {:ok, 1}, meta: %{source: :test}} =
               Output.raw({:ok, 1}, meta: %{source: :test})

      stream = Stream.map(1..3, &(&1 * 2))

      assert %Output{kind: :stream, value: ^stream, meta: %{}} =
               Output.stream(stream)

      assert %Output{kind: :batch, value: [%{id: 1}], meta: %{page: 1}} =
               Output.batch([%{id: 1}], meta: %{page: 1})

      assert %Output{kind: :opaque, value: {:external, :resource}, meta: %{}} =
               Output.opaque({:external, :resource})
    end

    test "reject invalid constructor inputs" do
      assert_raise ArgumentError, ~r/invalid action output envelope/, fn ->
        Output.raw(:value, meta: [])
      end

      assert_raise ArgumentError, ~r/invalid action output envelope/, fn ->
        Output.stream(:not_enumerable)
      end

      assert_raise ArgumentError, ~r/invalid action output envelope/, fn ->
        Output.batch(:not_a_list)
      end
    end
  end

  describe "validation" do
    test "validates existing output envelopes" do
      assert {:ok, %Output{kind: :raw, value: "payload", meta: %{}}} =
               Output.validate(%Output{kind: :raw, value: "payload", meta: %{}})
    end

    test "reports malformed output envelopes" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Output.validate(%Output{kind: :batch, value: :not_a_list, meta: %{}})

      assert Exception.message(error) == "invalid action output envelope"
      assert error.details.value == %Output{kind: :batch, value: :not_a_list, meta: %{}}
    end
  end
end
