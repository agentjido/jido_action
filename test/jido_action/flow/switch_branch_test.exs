defmodule JidoTest.FlowSwitchBranchTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Switch.Branch

  describe "default?/1" do
    test "recognizes exact default branch IR" do
      assert Branch.default?(%{flow: [], return: nil})
      assert Branch.default?(%{flow: [%{type: :step}], return: {:result, :step}})
    end

    test "does not treat compact map literals as default branches" do
      refute Branch.default?(%{route: :standard})
      refute Branch.default?(%{flow: [], return: nil, extra: true})
      refute Branch.default?(%{flow: :not_a_flow, return: nil})
    end
  end

  describe "flow?/1" do
    test "recognizes branch match IR" do
      assert Branch.flow?(%{flow: []})
      assert Branch.flow?(%{flow: [%{type: :step}], return: {:result, :step}})
    end

    test "rejects compact and malformed branch matches" do
      refute Branch.flow?(%{then: :premium})
      refute Branch.flow?(%{flow: :bad})
    end
  end

  describe "validate_match/1" do
    test "accepts compact and branch match targets" do
      assert :ok = Branch.validate_match(%{then: :premium})
      assert :ok = Branch.validate_match(%{flow: [], return: nil})
    end

    test "rejects ambiguous or missing match targets" do
      assert {:error, "switch matches must contain only one of then or flow"} =
               Branch.validate_match(%{then: :premium, flow: []})

      assert {:error, "switch branch flow must be a list"} =
               Branch.validate_match(%{flow: :bad})

      assert {:error, "switch matches must contain then or flow"} =
               Branch.validate_match(%{})
    end
  end

  describe "validate_default/1" do
    test "accepts literal defaults and valid branch defaults" do
      assert :ok = Branch.validate_default(nil)
      assert :ok = Branch.validate_default(:standard)
      assert :ok = Branch.validate_default(%{route: :standard})
      assert :ok = Branch.validate_default(%{flow: [], return: nil})
    end

    test "rejects malformed exact branch defaults" do
      assert {:error, "switch branch flow must be a list"} =
               Branch.validate_default(%{flow: :not_a_flow, return: nil})
    end
  end

  describe "validate_flow/1" do
    test "accepts absent or list branch flows" do
      assert :ok = Branch.validate_flow(nil)
      assert :ok = Branch.validate_flow([])
      assert :ok = Branch.validate_flow([%{type: :step}])
    end

    test "rejects malformed branch flows" do
      assert {:error, "switch branch flow must be a list"} = Branch.validate_flow(:bad)
    end
  end
end
