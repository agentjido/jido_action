# Define test actions outside the test module
defmodule TestAction1 do
  use Jido.Action,
    name: "test_action_1",
    schema: [
      input: [type: :string, required: true]
    ]

  @impl true
  def run(%{input: input}, _context) do
    {:ok, %{output: "processed_#{input}"}}
  end
end

defmodule TestAction2 do
  use Jido.Action,
    name: "test_action_2",
    schema: [
      output: [type: :string, required: true]
    ]

  @impl true
  def run(%{output: output}, _context) do
    {:ok, %{final_result: String.upcase(output)}}
  end
end

defmodule Jido.Tools.FlowToolTest do
  use ExUnit.Case, async: true

  # Define a test FlowTool
  defmodule TestFlowTool do
    use Jido.Tools.FlowTool,
      name: "test_flow",
      description: "A test flow",
      timeout: 5000

    flow "test_flow" do
      action TestAction1
      action TestAction2
    end
  end

  describe "FlowTool definition" do
    test "defines metadata correctly" do
      assert TestFlowTool.name() == "test_flow"
      assert TestFlowTool.description() == "A test flow"
    end

    test "provides JSON metadata" do
      metadata = TestFlowTool.to_json()
      
      assert metadata.name == "test_flow"
      assert metadata.description == "A test flow"
    end

    test "builds flow definition" do
      flow = TestFlowTool.get_flow()
      
      assert flow.name == "test_flow"
      assert length(Jido.Flow.steps(flow)) > 0
    end
  end

  describe "FlowTool execution" do
    test "executes flow with valid parameters" do
      params = %{input: "test_data"}
      context = %{}

      assert {:ok, {:ok, flow_result}} = TestFlowTool.run(params, context)
      # The result should contain the flow execution results
      assert is_map(flow_result)
      assert Map.has_key?(flow_result, :results)
      assert Map.has_key?(flow_result, :final_context)
      
      # Check that our actions were executed
      assert length(flow_result.results) == 2
      assert flow_result.final_context.value.final_result == "PROCESSED_TEST_DATA"
    end

    test "handles missing parameters gracefully" do
      params = %{}
      context = %{}

      # This should return an error wrapped in an ok tuple due to FlowTool's error handling
      assert {:ok, {:error, error}} = TestFlowTool.run(params, context)
      assert %Jido.Action.Error{} = error
      assert error.type == :validation_error
    end
  end

  describe "FlowTool validation" do
    test "returns nil when no flow is defined" do
      defmodule InvalidFlowTool do
        use Jido.Tools.FlowTool,
          name: "invalid_flow"
      end
      
      assert InvalidFlowTool.get_flow() == nil
    end

    test "raises error with invalid configuration" do
      assert_raise CompileError, fn ->
        defmodule BadConfigFlowTool do
          use Jido.Tools.FlowTool,
            name: 123  # Should be string
        end
      end
    end
  end

  describe "parallel execution" do
    defmodule ParallelFlowTool do
      use Jido.Tools.FlowTool,
        name: "parallel_flow",
        description: "A flow with parallel actions"

      import Jido.Tools.FlowTool
      import Jido.Flow.DSL, except: [flow: 2]

      flow "parallel_flow" do
        action TestAction1
        
        parallel do
          action TestAction2
          action TestAction2
        end
      end
    end

    test "defines parallel flow correctly" do
      flow = ParallelFlowTool.get_flow()
      steps = Jido.Flow.steps(flow)
      
      # Should have the initial action plus parallel group plus parallel actions
      assert length(steps) >= 2
    end
  end
end
