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
      assert %Syntax.Expr{type: :result, node: :add_one, path: []} = Syntax.result(:add_one, nil)
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

  describe "projection and shape expressions" do
    test "builds select expressions over projection-capable sources" do
      source = Syntax.context(:payload)

      assert %Syntax.Expr{
               type: :select,
               source: ^source,
               path: [:items, 0, :id]
             } = Syntax.select(source, [:items, 0, :id])
    end

    test "builds shape expressions without lowering the data" do
      data = %{
        total: Syntax.select(Syntax.binding(:quote), :total),
        metadata: [Syntax.context(:trace_id), "literal"]
      }

      assert %Syntax.Expr{type: :shape, data: ^data} = Syntax.shape(data)
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

    test "stores parallel groups with named branches" do
      pricing = Syntax.branch(:pricing, [Syntax.operation(:step, %{name: :price_cart})])

      inventory =
        Syntax.branch(:inventory, [Syntax.operation(:step, %{name: :reserve_inventory})])

      syntax =
        Syntax.new(name: "branching")
        |> Syntax.parallel([pricing, inventory], provenance: %{line: 10})

      assert [
               %Syntax.Operation{
                 kind: :parallel,
                 attrs: %{branches: [^pricing, ^inventory]},
                 provenance: %{line: 10}
               }
             ] = syntax.operations
    end
  end
end
