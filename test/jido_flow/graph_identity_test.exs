defmodule Jido.Flow.GraphIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias JidoActionTest.TestActions.Add

  test "author order, reference order, and effective order stay separate" do
    first = Step.new!(name: "first", action: Add)

    final =
      Step.new!(
        name: "final",
        action: Add,
        params: %{value: Ref.result("first", :value)},
        after: ["gate"]
      )

    gate = Step.new!(name: "gate", action: Add)

    flow =
      Flow.new!(
        name: "dependencies",
        components: [first, final, gate],
        output: Ref.result("final")
      )

    assert Enum.map(flow.components, & &1.name) == ["first", "final", "gate"]

    assert {:ok,
            %{
              "final" => %{
                after: ["gate"],
                references: ["first"],
                effective: ["first", "gate"]
              }
            }} = Flow.dependencies(flow)

    assert final.after == ["gate"]
  end

  test "unknown references and cycles fail without changing author data" do
    assert {:error, %InvalidInputError{}} =
             Flow.new(
               name: "unknown",
               components: [Step.new!(name: "one", action: Add, after: ["missing"])],
               output: Ref.result("one")
             )

    assert {:error, %InvalidInputError{message: message}} =
             Flow.new(
               name: "cycle",
               components: [
                 Step.new!(name: "one", action: Add, after: ["two"]),
                 Step.new!(name: "two", action: Add, after: ["one"])
               ],
               output: Ref.result("one")
             )

    assert message =~ "cycle"
  end

  test "source order does not change semantic identity" do
    one = Step.new!(name: "one", action: Add)
    two = Step.new!(name: "two", action: Add)

    first =
      Flow.new!(
        name: "identity",
        components: [one, two],
        output: %{one: Ref.result("one"), two: Ref.result("two")}
      )

    second =
      Flow.new!(
        name: "identity",
        components: [two, one],
        output: %{one: Ref.result("one"), two: Ref.result("two")}
      )

    refute first == second
    assert Flow.semantic_identity(first) == Flow.semantic_identity(second)
  end
end
