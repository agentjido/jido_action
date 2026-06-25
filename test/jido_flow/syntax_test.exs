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
  end

  describe "projection and shape expressions" do
    test "builds select expressions over projection-capable sources" do
      source = Syntax.input(:payload)

      assert %Syntax.Expr{
               type: :select,
               source: ^source,
               path: [:items, 0, :id]
             } = Syntax.select(source, [:items, 0, :id])
    end

    test "builds shape expressions without lowering the data" do
      data = %{
        total: Syntax.select(Syntax.binding(:quote), :total),
        metadata: [Syntax.input(:trace_id), "literal"]
      }

      assert %Syntax.Expr{type: :shape, data: ^data} = Syntax.shape(data)
    end
  end
end
