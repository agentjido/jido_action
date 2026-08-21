defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Ref
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures

  describe "builder" do
    test "exposes the complete closed Loop expression and operation surface" do
      left = Builder.value(1)
      right = Builder.value(2)
      equal = Builder.eq(left, right)

      assert Builder.iteration_index() == Syntax.iteration_index()
      assert Builder.lt(left, right) == Syntax.lt(left, right)
      assert Builder.lte(left, right) == Syntax.lte(left, right)
      assert Builder.gt(left, right) == Syntax.gt(left, right)
      assert Builder.in(left, right) == Syntax.in(left, right)
      assert Builder.all([equal]) == Syntax.all([equal])
      assert Builder.any([equal]) == Syntax.any([equal])
      assert Builder.not(equal) == Syntax.not(equal)

      builder =
        Builder.new(name: "closed_surface")
        |> Builder.map(
          :mapped,
          Builder.value([]),
          JidoTest.TestActions.Add,
          %{value: Builder.item()}
        )
        |> Builder.loop(
          :counted,
          JidoTest.TestActions.Add,
          %{value: Builder.state(:count)},
          %{schema: [], initial: %{count: left}, update: %{count: Builder.body_result(:value)}}
        )

      assert [%Syntax.Operation{kind: :map}, %Syntax.Operation{kind: :loop}] =
               Builder.syntax(builder).operations
    end

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

    test "direct Date choice values match explicit builder values" do
      date = ~D[2026-08-21]

      direct =
        Builder.new(name: "date_choice")
        |> Builder.choice(
          :route,
          [
            Builder.option(
              :match,
              Builder.eq(Builder.input(:date), date),
              JidoTest.TestActions.Add,
              date
            )
          ],
          Builder.fallback(JidoTest.TestActions.Add, date)
        )
        |> Builder.return(Builder.result(:route))

      explicit =
        Builder.new(name: "date_choice")
        |> Builder.choice(
          :route,
          [
            Builder.option(
              :match,
              Builder.eq(Builder.input(:date), Builder.value(date)),
              JidoTest.TestActions.Add,
              Builder.value(date)
            )
          ],
          Builder.fallback(JidoTest.TestActions.Add, Builder.value(date))
        )
        |> Builder.return(Builder.result(:route))

      assert {:ok, direct_flow} = Builder.build(direct)
      assert {:ok, explicit_flow} = Builder.build(explicit)
      assert Flow.to_map(direct_flow) == Flow.to_map(explicit_flow)

      assert [%Jido.Flow.Choice{options: [option], fallback: fallback}] = direct_flow.nodes
      assert option.condition.operands == [Ref.input(:date), Ref.value(date)]
      assert option.input == Ref.value(date)
      assert fallback.input == Ref.value(date)
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

    test "builder exposes scoped local expression delegates" do
      assert Builder.item() == Syntax.item()
      assert Builder.item([:output, :value]) == Syntax.item([:output, :value])
      assert Builder.item_index() == Syntax.item_index()
      assert Builder.item_id() == Syntax.item_id()
      assert Builder.accumulator() == Syntax.accumulator()
      assert Builder.accumulator(:total) == Syntax.accumulator(:total)
    end

    test "builder and direct syntax produce equal Map and Reduce flows" do
      syntax =
        Syntax.new(name: "fan_out_in")
        |> Syntax.map(
          :mapped,
          Syntax.input(:items),
          JidoTest.TestActions.EchoParamsAction,
          %{item: Syntax.item(), index: Syntax.item_index(), item_id: Syntax.item_id()},
          on_error: :collect_errors,
          bind: :mapped_result
        )
        |> Syntax.reduce(
          nil,
          Syntax.binding(:mapped_result),
          Syntax.value(%{total: 0}),
          JidoTest.TestActions.EchoParamsAction,
          %{acc: Syntax.accumulator(), item: Syntax.item(:output)},
          bind: :summary,
          after: [:mapped]
        )
        |> Syntax.return(Syntax.binding(:summary))

      builder =
        Builder.new(name: "fan_out_in")
        |> Builder.map(
          :mapped,
          Builder.input(:items),
          JidoTest.TestActions.EchoParamsAction,
          %{item: Builder.item(), index: Builder.item_index(), item_id: Builder.item_id()},
          on_error: :collect_errors,
          bind: :mapped_result
        )
        |> Builder.reduce(
          nil,
          Builder.binding(:mapped_result),
          Builder.value(%{total: 0}),
          JidoTest.TestActions.EchoParamsAction,
          %{acc: Builder.accumulator(), item: Builder.item(:output)},
          bind: :summary,
          after: [:mapped]
        )
        |> Builder.return(Builder.binding(:summary))

      assert {:ok, syntax_flow} = Lowerer.lower(syntax)
      assert {:ok, builder_flow} = Builder.build(builder)
      assert Flow.to_map(builder_flow) == Flow.to_map(syntax_flow)
      assert Flow.dependencies(builder_flow) == Flow.dependencies(syntax_flow)
      assert Flow.explain(builder_flow) == Flow.explain(syntax_flow)
      assert Flow.semantic_identity(builder_flow) == Flow.semantic_identity(syntax_flow)
    end

    test "builder and direct syntax produce equal bounded Loop flows" do
      state = %{
        schema: [],
        initial: %{count: Syntax.input(:count)},
        update: %{count: Syntax.body_result(:value)}
      }

      syntax =
        Syntax.new(name: "loop")
        |> Syntax.loop(
          :count,
          JidoTest.TestActions.Add,
          %{value: Syntax.state(:count)},
          state,
          until: Syntax.gte(Syntax.state(:count), Syntax.value(3)),
          max_iterations: 5,
          bind: :counted
        )
        |> Syntax.return(Syntax.binding(:counted))

      builder_state = %{
        schema: [],
        initial: %{count: Builder.input(:count)},
        update: %{count: Builder.body_result(:value)}
      }

      builder =
        Builder.new(name: "loop")
        |> Builder.loop(
          :count,
          JidoTest.TestActions.Add,
          %{value: Builder.state(:count)},
          builder_state,
          until: Builder.gte(Builder.state(:count), Builder.value(3)),
          max_iterations: 5,
          bind: :counted
        )
        |> Builder.return(Builder.binding(:counted))

      assert {:ok, syntax_flow} = Lowerer.lower(syntax)
      assert {:ok, builder_flow} = Builder.build(builder)
      assert Flow.to_map(builder_flow) == Flow.to_map(syntax_flow)
    end
  end
end
