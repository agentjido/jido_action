defmodule JidoActionTest.Exec.ChoiceValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Ref}

  alias JidoActionTest.TestActions.{
    AtomValidationAction,
    EchoParamsAction,
    InvalidValidatedParamsAction,
    InvalidValidationResultAction,
    RaisingValidationAction
  }

  describe "selected Action input validation" do
    test "preserves a raised validator error in serial and async runs" do
      flow =
        choice_flow(
          "choice_raising_validator",
          RaisingValidationAction,
          EchoParamsAction
        )

      for opts <- [[], [async: true]] do
        assert {:error, %ExecutionFailureError{message: "validator failed", details: details}} =
                 Exec.run(flow, %{}, %{}, opts)

        assert details.callback == :validate_params
        assert details.exception == RuntimeError
        assert_choice_details(details, "matched", RaisingValidationAction)
      end
    end

    test "preserves an unsupported fallback validator result" do
      flow =
        choice_flow(
          "choice_unsupported_validator_result",
          EchoParamsAction,
          InvalidValidationResultAction,
          false
        )

      assert {:error,
              %ExecutionFailureError{
                message: "action validator returned an unsupported result",
                details: details
              }} = Exec.run(flow, %{}, %{})

      assert details.callback == :validate_params
      assert details.result == :ok
      assert_choice_details(details, :fallback, InvalidValidationResultAction)
    end

    test "preserves a non-map validated value" do
      flow =
        choice_flow(
          "choice_non_map_validated_value",
          InvalidValidatedParamsAction,
          EchoParamsAction
        )

      assert {:error,
              %ExecutionFailureError{
                message: "action validator returned a value with an invalid shape",
                details: details
              }} = Exec.run(flow, %{}, %{})

      assert details.callback == :validate_params
      assert details.expected == :map
      assert details.result == 42
      assert_choice_details(details, "matched", InvalidValidatedParamsAction)
    end

    test "preserves a validator error reason" do
      flow =
        choice_flow(
          "choice_validator_reason",
          AtomValidationAction,
          EchoParamsAction
        )

      assert {:error,
              %ExecutionFailureError{
                message: "bad_params",
                class: :execution,
                details: details
              }} = Exec.run(flow, %{}, %{})

      assert details.reason == :bad_params
      assert_choice_details(details, "matched", AtomValidationAction)
    end
  end

  defp choice_flow(name, option_action, fallback_action, matches? \\ true) do
    Flow.new!(
      name: name,
      nodes: [
        Choice.new!(
          name: :route,
          options: [
            [
              name: :matched,
              condition: Condition.eq(Ref.value(matches?), Ref.value(true)),
              action: option_action
            ]
          ],
          fallback: [action: fallback_action]
        )
      ],
      return: Ref.result(:route)
    )
  end

  defp assert_choice_details(details, option, target) do
    assert details.phase == :choice_target_input
    assert details.node == "route"
    assert details.option == option
    assert details.target == target
  end
end
