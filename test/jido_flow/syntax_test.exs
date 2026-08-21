defmodule Jido.Flow.SyntaxTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow.Syntax
  alias JidoTest.TestActions.Add

  describe "operation/2" do
    test "normalizes keyword attrs to maps" do
      assert %Syntax.Operation{kind: :step, attrs: %{name: :add_one}} =
               Syntax.operation(:step, name: :add_one)
    end

    test "uses empty attrs by default" do
      assert %Syntax.Operation{kind: :return, attrs: %{}} = Syntax.operation(:return)
    end
  end

  describe "path expressions" do
    test "normalize nil paths to empty lists" do
      assert %Syntax.Expr{type: :input, path: []} = Syntax.input(nil)
      assert %Syntax.Expr{type: :context, path: []} = Syntax.context(nil)
      assert %Syntax.Expr{type: :result, node: "add_one", path: []} = Syntax.result(:add_one, nil)
    end
  end

  describe "binding expressions" do
    test "builds source-level binding expressions" do
      assert %Syntax.Expr{type: :binding, binding: :added} = Syntax.binding(:added)
    end

    test "stores binding aliases and operation provenance on steps" do
      syntax =
        Syntax.new(name: "binding")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)},
          bind: :added,
          provenance: %{line: 7}
        )

      assert [
               %Syntax.Operation{
                 kind: :step,
                 attrs: %{name: :add_one, action: Add, binding: :added},
                 provenance: %{line: 7}
               }
             ] = syntax.operations
    end

    test "stores explicit after targets on steps" do
      after_targets = [:load_cart, Syntax.binding(:quote)]

      syntax =
        Syntax.new(name: "explicit_edges")
        |> Syntax.step(:audit_quote, Add, %{event: "quoted"}, after: after_targets)

      assert [
               %Syntax.Operation{
                 kind: :step,
                 attrs: %{
                   name: :audit_quote,
                   action: Add,
                   after: ^after_targets
                 }
               }
             ] = syntax.operations
    end

    test "stores annotation options as step provenance" do
      syntax =
        Syntax.new(name: "annotated")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)},
          label: "Add one",
          tags: ["math", :example],
          note: "Visible only in provenance",
          provenance: %{line: 7}
        )

      assert [
               %Syntax.Operation{
                 kind: :step,
                 attrs: %{name: :add_one, action: Add},
                 provenance: %{
                   line: 7,
                   label: "Add one",
                   tags: ["math", :example],
                   note: "Visible only in provenance"
                 }
               }
             ] = syntax.operations
    end
  end

  describe "projection expressions" do
    test "builds select expressions over projection-capable sources" do
      source = Syntax.context(:payload)

      assert %Syntax.Expr{
               type: :select,
               source: ^source,
               path: [:items, 0, :id]
             } = Syntax.select(source, [:items, 0, :id])
    end

    test "does not expose a shape expression helper" do
      refute function_exported?(Syntax, :shape, 1)
    end
  end

  describe "choice operations" do
    test "builds only the closed choice condition algebra" do
      input = Syntax.input(:mode)
      fast = Syntax.eq(input, Syntax.value("fast"))
      fallback = Syntax.neq(input, Syntax.value("slow"))

      assert %Syntax.Condition{operator: :all, operands: [^fast, ^fallback]} =
               Syntax.all([fast, fallback])

      assert %Syntax.Condition{operator: :not, operands: [^fast]} = Syntax.not(fast)

      assert %Syntax.Condition{operator: :in, operands: [^input, _values]} =
               apply(Syntax, :in, [input, Syntax.value(["fast", "slow"])])

      refute function_exported?(Syntax, :condition, 2)
    end

    test "stores a named choice with ordered options, fallback, binding, deps, and provenance" do
      fast =
        Syntax.option(
          :fast,
          Syntax.eq(Syntax.input(:mode), Syntax.value("fast")),
          Add,
          %{value: Syntax.input(:value)}
        )

      fallback = Syntax.fallback(Add, %{value: Syntax.value(0)})
      after_targets = [:load, Syntax.binding(:prepared)]

      syntax =
        Syntax.new(name: "routing")
        |> Syntax.choice(:route, [fast], fallback,
          bind: :routed,
          after: after_targets,
          provenance: %{line: 12},
          label: "Route request"
        )

      assert [
               %Syntax.Operation{
                 kind: :choice,
                 attrs: %{
                   name: :route,
                   options: [^fast],
                   fallback: ^fallback,
                   binding: :routed,
                   after: ^after_targets
                 },
                 provenance: %{line: 12, label: "Route request"}
               }
             ] = syntax.operations
    end
  end

  describe "branch grouping operations" do
    test "builds named branch operations with ordered step operations" do
      step = Syntax.operation(:step, %{name: :price_cart, action: Add, input: %{}})

      assert %Syntax.Operation{
               kind: :branch,
               attrs: %{name: :pricing, operations: [^step]},
               provenance: %{line: 12}
             } = Syntax.branch(:pricing, [step], provenance: %{line: 12})
    end

    test "stores groups with named branches" do
      pricing = Syntax.branch(:pricing, [Syntax.operation(:step, %{name: :price_cart})])

      inventory =
        Syntax.branch(:inventory, [Syntax.operation(:step, %{name: :reserve_inventory})])

      syntax =
        Syntax.new(name: "branching")
        |> Syntax.group([pricing, inventory], provenance: %{line: 10})

      assert [
               %Syntax.Operation{
                 kind: :group,
                 attrs: %{branches: [^pricing, ^inventory]},
                 provenance: %{line: 10}
               }
             ] = syntax.operations
    end

    test "does not expose a parallel grouping helper" do
      refute function_exported?(Syntax, :parallel, 3)
    end
  end

  describe "Map and Reduce syntax" do
    test "builds all scoped local expressions with normalized paths" do
      assert %Syntax.Expr{type: :item, path: []} = Syntax.item()

      assert %Syntax.Expr{type: :item, path: [:output, :value]} =
               Syntax.item([:output, :value])

      assert %Syntax.Expr{type: :item_index, path: []} = Syntax.item_index()
      assert %Syntax.Expr{type: :item_id, path: []} = Syntax.item_id()
      assert %Syntax.Expr{type: :accumulator, path: []} = Syntax.accumulator()
      assert %Syntax.Expr{type: :accumulator, path: [:total]} = Syntax.accumulator(:total)
    end

    test "stores exact Map operation attributes and resolved default mode" do
      collection = Syntax.input(:items)
      input = %{item: Syntax.item(), index: Syntax.item_index(), id: Syntax.item_id()}

      syntax =
        Syntax.new(name: "map")
        |> Syntax.map(:mapped, collection, Add, input)

      assert [
               %Syntax.Operation{
                 kind: :map,
                 attrs: %{
                   name: :mapped,
                   collection: ^collection,
                   action: Add,
                   input: ^input,
                   on_error: :fail_fast
                 },
                 provenance: %{}
               }
             ] = syntax.operations
    end

    test "stores explicit Map options and provenance" do
      after_targets = [:loaded, Syntax.binding(:prepared)]

      syntax =
        Syntax.new(name: "map")
        |> Syntax.map(nil, Syntax.binding(:prepared), Add, %{item: Syntax.item(:value)},
          on_error: :collect_errors,
          bind: :mapped,
          after: after_targets,
          provenance: %{line: 12},
          label: "Map items"
        )

      assert [
               %Syntax.Operation{
                 kind: :map,
                 attrs: %{
                   name: nil,
                   collection: %Syntax.Expr{type: :binding, binding: :prepared},
                   action: Add,
                   input: %{item: %Syntax.Expr{type: :item, path: [:value]}},
                   on_error: :collect_errors,
                   binding: :mapped,
                   after: ^after_targets
                 },
                 provenance: %{line: 12, label: "Map items"}
               }
             ] = syntax.operations
    end

    test "stores exact Reduce operation attributes" do
      collection = Syntax.result(:mapped, :results)
      initial = Syntax.value(%{total: 0})

      input = %{
        accumulator: Syntax.accumulator(),
        item: Syntax.item(:output),
        index: Syntax.item_index(),
        id: Syntax.item_id()
      }

      syntax =
        Syntax.new(name: "reduce")
        |> Syntax.reduce("summary", collection, initial, Add, input,
          bind: :summary,
          after: [:audit],
          provenance: %{line: 20}
        )

      assert [
               %Syntax.Operation{
                 kind: :reduce,
                 attrs: %{
                   name: "summary",
                   collection: ^collection,
                   initial: ^initial,
                   action: Add,
                   input: ^input,
                   binding: :summary,
                   after: [:audit]
                 },
                 provenance: %{line: 20}
               }
             ] = syntax.operations
    end
  end
end
