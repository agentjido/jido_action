defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures

  describe "builder" do
    test "does not expose variable binding aliases in the first foundation" do
      refute function_exported?(Syntax, :var, 1)
      refute function_exported?(Syntax, :var, 2)
      refute function_exported?(Syntax, :bind, 3)
      refute function_exported?(Builder, :var, 1)
      refute function_exported?(Builder, :var, 2)
      refute function_exported?(Builder, :bind, 3)
    end

    test "builder-created syntax and direct syntax emit equal canonical maps" do
      assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.math_syntax())
      assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())

      assert Flow.to_map(builder_flow) == Flow.to_map(direct_flow)
      assert Flow.to_map(builder_flow) == FlowFixtures.math_canonical_map()
    end

    test "builder syntax cannot shortcut the canonical map" do
      assert builder = FlowFixtures.math_builder()
      assert %Syntax{} = Builder.syntax(builder)
      assert {:ok, flow} = Builder.build(builder)

      canonical = Flow.to_map(flow)
      refute Map.has_key?(canonical, :bindings)
      refute canonical |> inspect() |> String.contains?("added")
      refute canonical |> inspect() |> String.contains?("builder")
    end
  end
end
