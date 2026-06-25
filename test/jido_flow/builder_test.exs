defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures

  describe "builder" do
    test "builder-created syntax and direct syntax emit equal canonical maps" do
      assert builder = FlowFixtures.math_builder()
      assert %Syntax{} = Builder.syntax(builder)
      assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.math_syntax())
      assert {:ok, builder_flow} = Builder.build(builder)

      assert Flow.to_map(builder_flow) == Flow.to_map(direct_flow)
      assert Flow.to_map(builder_flow) == FlowFixtures.math_canonical_map()
    end

    test "builder and direct syntax support binding handles" do
      assert builder = FlowFixtures.binding_builder()
      assert %Syntax{} = Builder.syntax(builder)
      assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.binding_syntax())
      assert {:ok, builder_flow} = Builder.build(builder)

      assert Flow.to_map(builder_flow) == Flow.to_map(direct_flow)
      assert Flow.to_map(builder_flow) == FlowFixtures.binding_canonical_map()
    end

    test "builder exposes projection and shape helpers" do
      assert Builder.select(Builder.input(:payload), [:items, 0, :id]) ==
               Syntax.select(Syntax.input(:payload), [:items, 0, :id])

      data = %{total: Builder.select(Builder.binding(:quote), :total)}

      assert Builder.shape(data) == Syntax.shape(data)
    end

    test "builder passes explicit after targets to syntax" do
      after_targets = [:load_cart, Builder.binding(:quote)]

      builder =
        Builder.new(name: "explicit_edges")
        |> Builder.step(:audit_quote, JidoTest.TestActions.Add, %{event: "quoted"},
          after: after_targets
        )

      assert [
               %Syntax.Operation{
                 kind: :step,
                 attrs: %{
                   name: :audit_quote,
                   action: JidoTest.TestActions.Add,
                   after: ^after_targets
                 }
               }
             ] = Builder.syntax(builder).operations
    end

    test "builder exposes branch grouping helpers" do
      step = Syntax.operation(:step, %{name: :price_cart, action: JidoTest.TestActions.Add})
      branch = Builder.branch(:pricing, [step])

      builder =
        Builder.new(name: "branching")
        |> Builder.parallel([branch], provenance: %{line: 9})

      assert branch == Syntax.branch(:pricing, [step])

      assert [
               %Syntax.Operation{
                 kind: :parallel,
                 attrs: %{branches: [^branch]},
                 provenance: %{line: 9}
               }
             ] = Builder.syntax(builder).operations
    end
  end
end
