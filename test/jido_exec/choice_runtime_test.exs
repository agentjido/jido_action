defmodule Jido.Exec.ChoiceRuntimeTest do
  use JidoTest.ActionCase, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref}
  alias Jido.Instruction

  alias JidoTest.ExecFixtures.{
    ChoiceCountedAction,
    ChoiceEnvelopePublicPaths,
    ChoiceNestedEnvelopeFlow,
    ChoiceNestedErrorFlow,
    ChoiceNestedFlow,
    ChoicePublicEnvelopePaths,
    ChoicePublicNestedPaths,
    ChoicePublicPaths,
    PreflightRecorder,
    Transforms,
    UnselectedTarget
  }

  alias JidoTest.TestActions.{
    Add,
    EchoParamsAction,
    MissingRun
  }

  describe "Choice and nested Flow execution" do
    test "runs the selected nested Flow validation boundary exactly once" do
      target = ChoiceNestedFlow

      flow =
        Flow.new!(
          name: "choice_nested_once",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      reset_flow_transform_counts()

      assert {:ok, %{value: 3, input_passes: 1, output_passes: 1}} = Exec.run(flow, %{}, %{})
      assert Transforms.calls(:input) == 1
      assert Transforms.calls(:output) == 1
    end

    test "preserves a selected nested Flow Output envelope and its input transform boundary" do
      target = ChoiceNestedEnvelopeFlow

      flow =
        Flow.new!(
          name: "choice_nested_envelope",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      reset_flow_transform_counts()

      assert {:ok, %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Exec.run(flow, %{}, %{})

      assert Transforms.calls(:input) == 1
      assert Transforms.calls(:envelope_output) == 0
    end

    test "keeps a selected nested Flow error class and reason with Choice execution metadata" do
      target = ChoiceNestedErrorFlow

      flow =
        Flow.new!(
          name: "choice_nested_error",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
               Exec.run(flow, %{}, %{})

      assert details.reason == "Validation error"
      assert details.phase == :choice_target_execution
      assert details.node == "route"
      assert details.option == "nested"
      assert details.target == target
    end

    test "runs selected leaf Action validation and work exactly once" do
      target = ChoiceCountedAction

      flow =
        Flow.new!(
          name: "choice_leaf_once",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3), test_pid: Ref.context(:test_pid)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{value: 3, test_pid: _test_pid}} = Exec.run(flow, %{}, %{test_pid: self()})
      assert_receive {^target, :params}
      assert_receive {^target, :run}
      assert_receive {^target, :output}
      refute_received {^target, _kind}
    end

    test "selects the same Choice option through every public Flow path" do
      module = ChoicePublicPaths

      for {path, run} <- flow_execution_paths(module, %{kind: :priority, value: 3}) do
        assert {:ok, %{value: 4}} = run.(), to_string(path)
      end
    end

    test "preserves a selected Choice Action Output envelope through every public Flow path" do
      module = ChoiceEnvelopePublicPaths

      expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}

      for {path, run} <- flow_execution_paths(module, %{kind: :envelope, value: 3}) do
        assert {:ok, ^expected} = run.(), to_string(path)
      end
    end

    test "runs selected nested Flow transforms exactly once through every public Flow path" do
      module = ChoicePublicNestedPaths

      for {path, run} <- flow_execution_paths(module, %{kind: :nested, value: 3}) do
        reset_flow_transform_counts()

        assert {:ok, %{value: 3, output_passes: 1}} = run.(), to_string(path)
        assert Transforms.calls(:input) == 1, to_string(path)
        assert Transforms.calls(:output) == 1, to_string(path)
      end
    end

    test "preserves selected nested Flow Output envelopes through every public Flow path" do
      module = ChoicePublicEnvelopePaths

      expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :nested}}

      for {path, run} <- flow_execution_paths(module, %{kind: :nested, value: 3}) do
        reset_flow_transform_counts()

        assert {:ok, ^expected} = run.(), to_string(path)
        assert Transforms.calls(:input) == 1, to_string(path)
        assert Transforms.calls(:envelope_output) == 0, to_string(path)
      end
    end

    test "rejects an invalid unselected Choice target before graph execution" do
      before = PreflightRecorder

      flow =
        Flow.new!(
          name: "choice_preflight",
          nodes: [
            Node.new!(
              name: :before_choice,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: Add,
                  input: %{value: Ref.input(:value), amount: Ref.value(0)}
                ],
                [
                  name: :invalid,
                  condition: Condition.eq(Ref.value(false), Ref.value(true)),
                  action: MissingRun,
                  input: %{value: Ref.input(:value)}
                ]
              ],
              fallback: [action: Add, input: %{value: Ref.input(:value), amount: Ref.value(0)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.reason == "missing run/2"
      assert details.choice == "route"
      assert details.option == "invalid"
      assert details.target == MissingRun
      refute_received {^before, :run}
    end

    test "does not validate or run an unselected Choice target" do
      target = UnselectedTarget

      flow =
        Flow.new!(
          name: "choice_unselected_target",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: Add,
                  input: %{value: Ref.value(3), amount: Ref.value(0)}
                ],
                [
                  name: :unselected,
                  condition: Condition.eq(Ref.value(false), Ref.value(true)),
                  action: target,
                  input: %{test_pid: Ref.context(:test_pid)}
                ]
              ],
              fallback: [action: Add, input: %{value: Ref.value(0), amount: Ref.value(0)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{value: 3}} = Exec.run(flow, %{}, %{test_pid: self()})
      refute_received {^target, _kind}
    end
  end

  defp flow_execution_paths(module, input) do
    flow = module.flow()
    instruction = Instruction.new!(action: module, params: input)

    parent =
      Flow.new!(
        name: "parent_#{System.unique_integer([:positive])}",
        nodes: [Node.new!(name: :inner, action: module, input: Ref.input([]))],
        return: Ref.result(:inner)
      )

    [
      artifact: fn -> Exec.run(flow, input, %{}) end,
      marked_module: fn -> Exec.run(module, input, %{}) end,
      instruction: fn -> Exec.run(instruction, %{}, %{}) end,
      parent: fn -> Exec.run(parent, input, %{}) end
    ]
  end

  defp reset_flow_transform_counts do
    Transforms.reset()
  end
end
