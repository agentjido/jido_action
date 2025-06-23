defmodule Jido.FlowTest do
  use ExUnit.Case
  alias Jido.Flow
  alias Jido.Flow.{Step, Context}

  doctest Jido.Flow

  describe "basic flow operations" do
    test "creates a new flow" do
      flow = Flow.new("test_flow")
      assert flow.name == "test_flow"
      assert Graph.vertices(flow.flow) == [:root]
    end

    test "adds a function-based step" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "upcase", work: &String.upcase/1)

      steps = Flow.steps(flow)
      assert length(steps) == 1
      assert hd(steps).name == "upcase"
    end

    test "adds steps in sequence" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "downcase", work: &String.downcase/1)
        |> Flow.add_step("downcase", name: "upcase", work: &String.upcase/1)

      steps = Flow.steps(flow)
      assert length(steps) == 2

      # Check that steps are connected
      step1 = Flow.get_step(flow, "downcase")
      step2 = Flow.get_step(flow, "upcase")
      
      assert step1 != nil
      assert step2 != nil
    end
  end

  describe "execution" do
    test "executes a single function step" do
      step = Step.new(name: "upcase", work: &String.upcase/1)
      context = Context.new("hello")

      {:ok, result_context} = Flow.run({step, context})
      assert result_context.value == "HELLO"
    end

    test "finds next runnables from root" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "step1", work: &String.upcase/1)
        |> Flow.add_step(name: "step2", work: &String.reverse/1)

      context = Context.new("hello")
      runnables = Flow.next_runnables(flow, context)

      # Should have 2 runnables from root
      assert length(runnables) == 2
      step_names = Enum.map(runnables, fn {step, _ctx} -> step.name end)
      assert "step1" in step_names
      assert "step2" in step_names
    end

    test "finds next runnables after step execution" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "first", work: &String.upcase/1)
        |> Flow.add_step("first", name: "second", work: &String.reverse/1)

      context = Context.new("hello")
      
      # Get initial runnables
      initial_runnables = Flow.next_runnables(flow, context)
      assert length(initial_runnables) == 1

      # Execute first step
      {first_step, first_context} = hd(initial_runnables)
      {:ok, result_context} = Flow.run({first_step, first_context})

      # Get next runnables after first step
      next_runnables = Flow.next_runnables(flow, result_context)
      assert length(next_runnables) == 1

      {second_step, _} = hd(next_runnables)
      assert second_step.name == "second"
    end
  end

  describe "step operations" do
    test "gets step by name" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "find_me", work: &String.upcase/1)

      step = Flow.get_step(flow, "find_me")
      assert step.name == "find_me"

      missing = Flow.get_step(flow, "missing")
      assert missing == nil
    end

    test "checks if flow is acyclic" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "step1", work: &String.upcase/1)
        |> Flow.add_step("step1", name: "step2", work: &String.reverse/1)

      assert Flow.acyclic?(flow) == true
    end

    test "gets topological order" do
      flow =
        Flow.new("test_flow")
        |> Flow.add_step(name: "first", work: &String.upcase/1)
        |> Flow.add_step("first", name: "second", work: &String.reverse/1)

      order = Flow.topological_order(flow)
      assert length(order) == 2

      step_names = Enum.map(order, & &1.name)
      first_index = Enum.find_index(step_names, &(&1 == "first"))
      second_index = Enum.find_index(step_names, &(&1 == "second"))

      # First should come before second in topological order
      assert first_index < second_index
    end
  end

  describe "metadata operations" do
    test "adds and gets flow metadata" do
      flow =
        Flow.new("test_flow")
        |> Flow.put_meta(:version, "1.0")
        |> Flow.put_meta(:author, "test")

      assert Flow.get_meta(flow, :version) == "1.0"
      assert Flow.get_meta(flow, :author) == "test"
      assert Flow.get_meta(flow, :missing, "default") == "default"
    end
  end

  describe "error handling" do
    test "handles step execution errors" do
      failing_step = Step.new(name: "fail", work: fn _x -> raise "oops" end)
      context = Context.new("hello")

      {:error, error} = Flow.run({failing_step, context})
      assert error.type == :execution_error
      assert String.contains?(error.message, "Step fail failed")
    end
  end
end
