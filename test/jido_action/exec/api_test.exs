defmodule JidoTest.ExecApiTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias Jido.Instruction
  alias JidoTest.TestActions.{Add, ContextEcho, ErrorAction, NoParamsAction, NotAnAction}

  describe "run/3 facade dispatch" do
    test "flow execution returns a Jido.Exec.Result" do
      flow = Flow.new(:facade_flow) |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})
      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "action execution runs as a one-step flow" do
      assert {:ok, %Result{} = result} = Exec.run(Add, %{value: 3, amount: 2})

      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
      assert result.workflow.name == :add
    end

    test "instruction execution runs as a one-step flow with runtime input" do
      instruction =
        Instruction.new!(
          action: Add,
          params: %{amount: 2},
          context: %{trace_id: "instruction"}
        )

      assert {:ok, %Result{} = result} = Exec.run(instruction, %{value: 3})

      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "instruction execution treats explicit nil input as an empty runtime fact" do
      instruction = Instruction.new!(action: NoParamsAction)

      assert {:ok, %Result{} = result} = Exec.run(instruction, nil)

      assert result.cycles == 1
      assert Exec.results(result).no_params_action == [%{result: "No params"}]
    end

    test "raw Runic workflow execution is not supported directly" do
      workflow =
        Flow.new(:facade_workflow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.to_workflow()

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(workflow, %{value: 3})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "unsupported executable inputs return validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(%{value: 3, amount: 2})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(%{value: 3}, %{}, [])

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "invalid action contracts are normalized as validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(NotAnAction, %{})

      assert Exception.message(error) =~ "module is not a valid Jido action"

      instruction = Instruction.new!(action: NotAnAction)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(instruction)

      assert Exception.message(error) =~ "module is not a valid Jido action"
    end

    test "one-arity run handles actions, instructions, and already idle flows" do
      instruction = Instruction.new!(action: NoParamsAction)

      assert {:ok, %Result{status: :ok, cycles: 0}} = Exec.run(Flow.new(:idle_run))

      assert {:ok, %Result{} = action_result} = Exec.run(NoParamsAction)
      assert Exec.results(action_result).no_params_action == [%{result: "No params"}]

      assert {:ok, %Result{} = instruction_result} = Exec.run(instruction)
      assert Exec.results(instruction_result).no_params_action == [%{result: "No params"}]
    end

    test "three-arity action and instruction execution pass runtime options" do
      instruction =
        Instruction.new!(
          action: ContextEcho,
          params: %{value: 7},
          context: %{static: true}
        )

      assert {:ok, %Result{} = instruction_result} =
               Exec.run(instruction, %{}, run_context: %{context_echo: %{runtime: true}})

      assert Exec.results(instruction_result).context_echo == [
               %{value: 7, static: true, runtime: true}
             ]

      assert {:ok, %Result{} = action_result} =
               Exec.run(ContextEcho, %{value: 8},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert Exec.results(action_result).context_echo == [
               %{value: 8, static: false, runtime: true}
             ]
    end
  end

  describe "step/3 facade dispatch" do
    test "executes one dispatch cycle for actions, instructions, and flows" do
      instruction = Instruction.new!(action: Add, params: %{amount: 2})
      flow = Flow.new(:step_flow) |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = action_result} = Exec.step(Add, %{value: 3, amount: 2})
      assert {:ok, %Result{} = instruction_result} = Exec.step(instruction, %{value: 3})
      assert {:ok, %Result{} = flow_result} = Exec.step(flow, %{value: 3})

      assert Exec.results(action_result).add == [%{value: 5}]
      assert Exec.results(instruction_result).add == [%{value: 5}]
      assert Exec.results(flow_result).add == [%{value: 5}]
    end

    test "one-arity step handles actions, instructions, flows, and unsupported input" do
      instruction = Instruction.new!(action: NoParamsAction)

      assert {:ok, %Result{status: :ok}} = Exec.step(Flow.new(:idle_step))

      assert {:ok, %Result{} = action_result} = Exec.step(NoParamsAction)
      assert Exec.results(action_result).no_params_action == [%{result: "No params"}]

      assert {:ok, %Result{} = instruction_result} = Exec.step(instruction)
      assert Exec.results(instruction_result).no_params_action == [%{result: "No params"}]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "unsupported step arities return validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{}, %{})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{}, %{}, [])

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "failed action steps return error results from one dispatch cycle" do
      flow = Flow.from_action(ErrorAction, %{error_type: :error}, name: :bad_step)

      assert {:error, %Result{status: :error, cycles: 1, error: error}} =
               silence_logger(fn -> Exec.step(flow, %{}) end)

      assert error.details.node == :bad_step

      assert {:error, %Jido.Action.Error.InvalidInputError{} = invalid} =
               Exec.step(NotAnAction)

      assert Exception.message(invalid) =~ "module is not a valid Jido action"
    end

    test "three-arity step accepts runtime context for flows, instructions, and actions" do
      instruction = Instruction.new!(action: ContextEcho, params: %{value: 3})
      flow = Flow.from_action(ContextEcho, %{value: 4}, name: :context_echo)

      assert {:ok, %Result{} = flow_result} =
               Exec.step(flow, %{}, run_context: %{context_echo: %{static: false, runtime: true}})

      assert {:ok, %Result{} = instruction_result} =
               Exec.step(instruction, %{},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert {:ok, %Result{} = action_result} =
               Exec.step(ContextEcho, %{value: 5},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert Exec.results(flow_result).context_echo == [%{value: 4, static: false, runtime: true}]

      assert Exec.results(instruction_result).context_echo == [
               %{value: 3, static: false, runtime: true}
             ]

      assert Exec.results(action_result).context_echo == [
               %{value: 5, static: false, runtime: true}
             ]
    end
  end

  describe "resume/3" do
    test "continues successful and max-cycle results" do
      flow =
        Flow.new(:resume_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})
      assert {:ok, %Result{} = resumed} = Exec.resume(result, %{value: 4})

      assert %{add: productions} = Exec.results(resumed)
      assert %{value: 5} in productions
      assert %{value: 6} in productions

      bounded =
        Flow.new(:bounded_resume)
        |> Flow.step(:add, Add, params: %{amount: 1})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      assert {:error, %Result{status: :max_cycles} = maxed} =
               Exec.run(bounded, %{value: 1}, max_cycles: 1)

      assert {:ok, %Result{} = resumed_maxed} = Exec.resume(maxed, nil)
      assert Exec.results(resumed_maxed).again == [%{value: 3}]
    end

    test "rejects failed results and non-result inputs" do
      flow =
        Flow.new(:failed_resume) |> Flow.step(:bad, ErrorAction, params: %{error_type: :error})

      assert {:error, %Result{status: :error} = result} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(result, %{})

      assert Exception.message(error) =~ "cannot resume failed execution result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(flow, %{})

      assert Exception.message(error) =~ "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(flow, %{}, [])

      assert Exception.message(error) =~ "expected a Jido.Exec.Result"
    end
  end
end
