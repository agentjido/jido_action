defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures

  describe "builder" do
    test "builder and syntax emit the same if else choice" do
      syntax =
        Syntax.new(name: "if_else")
        |> Syntax.choice(
          :route,
          [
            Syntax.option(
              :fast,
              Syntax.eq(Syntax.input(:mode), Syntax.value("fast")),
              JidoTest.TestActions.Add,
              %{value: Syntax.input(:value)}
            )
          ],
          Syntax.fallback(JidoTest.TestActions.Add, %{value: Syntax.value(0)}),
          bind: :routed
        )
        |> Syntax.return(Syntax.binding(:routed))

      builder =
        Builder.new(name: "if_else")
        |> Builder.choice(
          :route,
          [
            Builder.option(
              :fast,
              Builder.eq(Builder.input(:mode), Builder.value("fast")),
              JidoTest.TestActions.Add,
              %{value: Builder.input(:value)}
            )
          ],
          Builder.fallback(JidoTest.TestActions.Add, %{value: Builder.value(0)}),
          bind: :routed
        )
        |> Builder.return(Builder.binding(:routed))

      assert {:ok, syntax_flow} = Lowerer.lower(syntax)
      assert {:ok, builder_flow} = Builder.build(builder)
      assert Flow.to_map(builder_flow) == Flow.to_map(syntax_flow)
    end

    test "builder and syntax preserve case option order" do
      syntax =
        Syntax.new(name: "case")
        |> Syntax.choice(
          :route,
          [
            Syntax.option(
              :priority,
              Syntax.eq(Syntax.input(:tier), Syntax.value("priority")),
              JidoTest.TestActions.Add,
              %{value: Syntax.value(1)}
            ),
            Syntax.option(
              :standard,
              Syntax.eq(Syntax.input(:tier), Syntax.value("standard")),
              JidoTest.TestActions.Add,
              %{value: Syntax.value(2)}
            )
          ],
          Syntax.fallback(JidoTest.TestActions.Add, %{value: Syntax.value(0)})
        )
        |> Syntax.return(Syntax.result(:route))

      builder =
        Builder.new(name: "case")
        |> Builder.choice(
          :route,
          [
            Builder.option(
              :priority,
              Builder.eq(Builder.input(:tier), Builder.value("priority")),
              JidoTest.TestActions.Add,
              %{value: Builder.value(1)}
            ),
            Builder.option(
              :standard,
              Builder.eq(Builder.input(:tier), Builder.value("standard")),
              JidoTest.TestActions.Add,
              %{value: Builder.value(2)}
            )
          ],
          Builder.fallback(JidoTest.TestActions.Add, %{value: Builder.value(0)})
        )
        |> Builder.return(Builder.result(:route))

      assert {:ok, syntax_flow} = Lowerer.lower(syntax)
      assert {:ok, builder_flow} = Builder.build(builder)
      assert Flow.to_map(builder_flow) == Flow.to_map(syntax_flow)

      assert [%{options: [%{name: "priority"}, %{name: "standard"}]}] =
               Flow.to_map(builder_flow).nodes
    end

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

    test "builder passes annotation options to syntax provenance" do
      assert builder = FlowFixtures.annotated_builder()

      assert %Syntax.Operation{provenance: provenance} =
               Enum.find(Builder.syntax(builder).operations, &(&1.kind == :step))

      assert provenance.label == "Add one"
      assert provenance.tags == [:math, "example"]
      assert provenance.note == "Visible only in provenance"

      assert {:ok, flow} = Builder.build(builder)
      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
      assert [%{provenance: lowered_provenance}] = Flow.to_map(flow, provenance: true).nodes
      assert lowered_provenance.tags == ["math", "example"]
    end

    test "builder exposes projection helpers without shape sugar" do
      assert Builder.context(:trace_id) == Syntax.context(:trace_id)

      assert Builder.select(Builder.input(:payload), [:items, 0, :id]) ==
               Syntax.select(Syntax.input(:payload), [:items, 0, :id])

      refute function_exported?(Builder, :shape, 1)
    end

    test "builder allows bound steps to derive their node name" do
      builder =
        Builder.new(name: "derived_binding_name")
        |> Builder.step(nil, JidoTest.TestActions.Add, %{value: Builder.input(:value)},
          bind: :added
        )
        |> Builder.return(Builder.binding(:added))

      assert {:ok, flow} = Builder.build(builder)
      assert [%{name: "added"}] = Flow.to_map(flow).nodes
      assert Flow.to_map(flow).return == %{type: :result, node: "added", path: []}
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
      step = Syntax.operation(:step, %{name: "price_cart", action: JidoTest.TestActions.Add})
      branch = Builder.branch(:pricing, [step])

      builder =
        Builder.new(name: "branching")
        |> Builder.group([branch], provenance: %{line: 9})

      assert branch == Syntax.branch(:pricing, [step])

      assert [
               %Syntax.Operation{
                 kind: :group,
                 attrs: %{branches: [^branch]},
                 provenance: %{line: 9}
               }
             ] = Builder.syntax(builder).operations

      refute function_exported?(Builder, :parallel, 3)
    end
  end
end
