defmodule Jido.PlanMissingDependencyTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Plan

  defmodule TestAction do
    use Jido.Action,
      name: "plan_missing_dependency_test_action",
      description: "Simple action for missing dependency validation tests"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  describe "normalize/1 missing dependency validation" do
    test "returns a validation error for a single missing dependency" do
      plan =
        Plan.new()
        |> Plan.add(:step1, TestAction, depends_on: :missing_step)

      assert {:error, %Error.InvalidInputError{} = error} = Plan.normalize(plan)
      assert error.message =~ "undefined steps"
      assert error.details[:missing_dependencies_by_step] == %{step1: [:missing_step]}
      assert error.details[:available_steps] == [:step1]
    end

    test "returns a full mapping for multiple missing dependencies" do
      plan =
        Plan.new()
        |> Plan.add(:step1, TestAction, depends_on: [:missing_a, :missing_b])
        |> Plan.add(:step2, TestAction, depends_on: [:missing_b, :missing_c])

      assert {:error, %Error.InvalidInputError{} = error} = Plan.normalize(plan)

      assert %{
               step1: step1_missing,
               step2: step2_missing
             } = error.details[:missing_dependencies_by_step]

      assert Enum.sort(step1_missing) == [:missing_a, :missing_b]
      assert Enum.sort(step2_missing) == [:missing_b, :missing_c]
      assert error.details[:available_steps] == [:step1, :step2]
    end

    test "succeeds when all dependencies are defined" do
      plan =
        Plan.new()
        |> Plan.add(:step1, TestAction)
        |> Plan.add(:step2, TestAction, depends_on: :step1)
        |> Plan.add(:step3, TestAction, depends_on: [:step1, :step2])

      assert {:ok, {_graph, _instructions}} = Plan.normalize(plan)
    end
  end

  describe "execution_phases/1 with missing dependencies" do
    test "returns the same validation error surfaced by normalize/1" do
      plan =
        Plan.new()
        |> Plan.add(:step1, TestAction, depends_on: :missing_step)

      assert {:error, %Error.InvalidInputError{} = error} = Plan.execution_phases(plan)
      assert error.message =~ "undefined steps"
      assert error.details[:missing_dependencies_by_step] == %{step1: [:missing_step]}
    end
  end
end
