defmodule JidoActionTest.Exec.CustomFlowValidationTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Ref, Step, Subflow}

  defmodule CustomError do
    defexception [:message, :details, :stacktrace]
  end

  defmodule Echo do
    use Jido.Action, name: "custom_flow_echo"

    def run(params, context) do
      if context[:observer], do: send(context.observer, :action_ran)
      {:ok, params}
    end
  end

  defmodule CustomFlow do
    @behaviour Jido.Executable
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      Flow.new!(
        name: "custom_validation",
        components: [Step.new!(name: "echo", action: Echo, params: Ref.input([]))],
        output: Ref.result("echo")
      )
    end

    def validate_params(%{stage: :input, failure: failure}), do: fail(failure)
    def validate_params(%{stage: :input, reason: reason}), do: {:error, reason}
    def validate_params(params), do: {:ok, Map.put(params, :value, 10)}
    def validate_output(%{stage: :output, failure: failure}), do: fail(failure)
    def validate_output(%{stage: :output, reason: reason}), do: {:error, reason}
    def validate_output(output), do: {:ok, Map.put(output, :checked, true)}

    defp fail(:raise), do: raise(CustomError, message: "callback failed", details: nil)
    defp fail(:throw), do: throw(:rejected)
    defp fail(:invalid), do: :invalid
  end

  defmodule BrokenFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise(CustomError, message: "definition failed", details: nil)
    def validate_params(value), do: {:ok, value}
    def validate_output(value), do: {:ok, value}
  end

  defmodule Continue do
    use Jido.Action, name: "continue_custom_flow"
    def run(params, _), do: {:continue, params, CustomFlow}
  end

  defp parent do
    Flow.new!(
      name: "custom_parent",
      components: [Subflow.new!(name: "child", flow: CustomFlow, params: Ref.input([]))],
      output: Ref.result("child")
    )
  end

  test "module validators apply across execution entry points" do
    expected = {:ok, %{value: 10, checked: true}}

    for target <- [CustomFlow, Instruction.new!(target: CustomFlow), parent(), Continue] do
      assert Exec.run(target, %{value: 3}) == expected
      assert target |> Exec.run_async(%{value: 3}) |> Exec.await() == expected
    end

    for target <- [CustomFlow, Instruction.new!(target: CustomFlow), parent()] do
      assert {:ok, execution} = Exec.start(target, %{value: 3})
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == expected
    end

    assert Exec.run(CustomFlow.flow(), %{value: 3}) == {:ok, %{value: 3}}
  end

  test "Flow boundaries preserve plain reasons and optional exception details" do
    stacktrace = [{__MODULE__, :validate, 1, [file: ~c"custom.ex", line: 1]}]

    reasons =
      [:rejected, "rejected", %{code: :rejected}, RuntimeError.exception("rejected")] ++
        for details <- [nil, [:extra], %{code: :rejected}] do
          %CustomError{message: "rejected", details: details, stacktrace: stacktrace}
        end

    for target <- [CustomFlow, parent()], stage <- [:input, :output], reason <- reasons do
      assert {:error, %Flow.Error.InvalidExecutionError{} = error} =
               Exec.run(target, %{stage: stage, reason: reason}, %{observer: self()})

      assert error.details.phase in [:flow_input, :flow_output, :subflow_input, :subflow_output]

      if is_exception(reason) do
        assert error.message == Exception.message(reason)
        assert error.details.cause == reason.__struct__
        if match?(%CustomError{}, reason), do: assert(error.stacktrace == stacktrace)
      else
        assert error.details.reason == reason
      end

      if stage == :input, do: refute_received(:action_ran), else: assert_received(:action_ran)
    end
  end

  test "callback raises, throws, and invalid results return structured errors" do
    for target <- [CustomFlow, parent()],
        stage <- [:input, :output],
        failure <- [:raise, :throw, :invalid] do
      assert {:error, %Flow.Error.InvalidExecutionError{} = error} =
               Exec.run(target, %{stage: stage, failure: failure}, %{observer: self()})

      assert error.details.phase in [:flow_input, :flow_output, :subflow_input, :subflow_output]

      case failure do
        :raise ->
          assert error.message == "callback failed"
          assert error.details.cause == CustomError
          assert [_ | _] = error.stacktrace

        :throw ->
          assert error.details.reason == :rejected

        :invalid ->
          assert error.details.result == :invalid
      end

      if stage == :input, do: refute_received(:action_ran), else: assert_received(:action_ran)
    end
  end

  test "a custom materialization exception remains a structured definition error" do
    assert {:error, %Flow.Error.InvalidDefinitionError{} = error} = Exec.run(BrokenFlow)
    assert error.message == "definition failed"
    assert error.details.cause == CustomError
  end
end
