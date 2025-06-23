defmodule Jido.Flow.ActionIntegrationTest do
  use ExUnit.Case
  alias Jido.Flow
  alias Jido.Flow.{Step, Context}

  # Define a test action for integration testing
  defmodule TestAction do
    use Jido.Action,
      name: "test_action",
      description: "A test action for flow integration",
      schema: [
        input: [type: :string, required: true]
      ],
      output_schema: [
        result: [type: :string, required: true]
      ]

    @impl true
    def run(%{input: input}, _context) do
      {:ok, %{result: String.upcase(input)}}
    end
  end

  # Another test action that expects different input format
  defmodule ProcessAction do
    use Jido.Action,
      name: "process_action",
      description: "Processes result data",
      schema: [
        result: [type: :string, required: true]
      ]

    @impl true
    def run(%{result: result}, _context) do
      {:ok, %{processed: String.reverse(result)}}
    end
  end

  describe "Action integration" do
    test "executes Action-based step" do
      step = Step.new(name: "test_step", action: TestAction)
      context = Context.new(%{input: "hello"})

      {:ok, result_context} = Flow.run({step, context})
      assert result_context.value == %{result: "HELLO"}
    end

    test "chains Action-based steps in flow" do
      flow =
        Flow.new("action_flow")
        |> Flow.add_step(name: "first_action", action: TestAction)
        |> Flow.add_step("first_action", name: "second_action", action: ProcessAction)

      # Start with input data
      context = Context.new(%{input: "hello"})
      
      # Get first runnable
      [first_runnable] = Flow.next_runnables(flow, context)
      {:ok, first_result} = Flow.run(first_runnable)
      
      # Verify first result
      assert first_result.value == %{result: "HELLO"}
      
      # Get next runnable
      [second_runnable] = Flow.next_runnables(flow, first_result)
      {:ok, second_result} = Flow.run(second_runnable)
      
      # Verify final result
      assert second_result.value == %{processed: "OLLEH"}
    end

    test "handles Action validation errors" do
      step = Step.new(name: "test_step", action: TestAction)
      # Missing required 'input' field
      context = Context.new(%{wrong_field: "hello"})

      {:error, error} = Flow.run({step, context})
      assert error.type == :validation_error
    end

    test "mixes function and Action steps" do
      flow =
        Flow.new("mixed_flow")
        |> Flow.add_step(name: "prepare", work: fn data -> %{input: String.downcase(data)} end)
        |> Flow.add_step("prepare", name: "action", action: TestAction)
        |> Flow.add_step("action", name: "finalize", work: fn %{result: result} -> "Final: #{result}" end)

      context = Context.new("HELLO WORLD")
      
      # Execute preparation step
      [prep_runnable] = Flow.next_runnables(flow, context)
      {:ok, prep_result} = Flow.run(prep_runnable)
      assert prep_result.value == %{input: "hello world"}
      
      # Execute action step  
      [action_runnable] = Flow.next_runnables(flow, prep_result)
      {:ok, action_result} = Flow.run(action_runnable)
      assert action_result.value == %{result: "HELLO WORLD"}
      
      # Execute finalization step
      [final_runnable] = Flow.next_runnables(flow, action_result)
      {:ok, final_result} = Flow.run(final_runnable)
      assert final_result.value == "Final: HELLO WORLD"
    end
  end

  describe "Step type checking" do
    test "identifies Action steps" do
      action_step = Step.new(name: "action", action: TestAction)
      work_step = Step.new(name: "work", work: &String.upcase/1)

      assert Step.action_step?(action_step) == true
      assert Step.action_step?(work_step) == false
    end

    test "identifies work steps" do
      action_step = Step.new(name: "action", action: TestAction)
      work_step = Step.new(name: "work", work: &String.upcase/1)

      assert Step.work_step?(action_step) == false
      assert Step.work_step?(work_step) == true
    end
  end

  describe "Context enhancements" do
    test "tracks metadata through execution" do
      step = Step.new(name: "test", work: &String.upcase/1)
      context = 
        Context.new("hello")
        |> Context.put_meta(:source, "test")
        |> Context.put_meta(:timestamp, DateTime.utc_now())

      {:ok, result_context} = Flow.run({step, context})
      
      # Metadata should be preserved
      assert Context.get_meta(result_context, :source) == "test"
      assert Context.get_meta(result_context, :timestamp) != nil
    end

    test "handles error accumulation" do
      context = Context.new("hello")
      
      # Context should not have errors initially
      assert Context.has_errors?(context) == false
      
      # Add an error
      error = Jido.Action.Error.validation_error("Test error")
      context_with_error = Context.add_error(context, error)
      
      assert Context.has_errors?(context_with_error) == true
      assert length(context_with_error.errors) == 1
    end

    test "cleans context for next step" do
      step = Step.new(name: "test", work: &String.upcase/1)
      context = Context.new("hello")
      
      {:ok, result_context} = Flow.run({step, context})
      
      # Result should have runnable set
      assert result_context.runnable != nil
      
      # Cleaned context should not have runnable
      cleaned = Context.clean(result_context)
      assert cleaned.runnable == nil
      assert cleaned.value == result_context.value
    end
  end
end
