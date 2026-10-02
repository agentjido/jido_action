defmodule JidoActionTest.Exec.CustomFlowValidationTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Action.Output
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

    def validate_params(%{frame: :raise}), do: raise("probe frame")
    def validate_params(%{frame: :throw}), do: throw(:probe_frame)
    def validate_params(%{frame: :exit}), do: exit(:probe_frame)

    def validate_params(%{frame: frame}) when frame in [:output, :output_throw, :output_exit],
      do: {:ok, %{frame: frame}}

    def validate_params(%{stage: :input, failure: failure}), do: fail(failure)
    def validate_params(%{stage: :input, reason: reason}), do: {:error, reason}
    def validate_params(params), do: {:ok, Map.put(params, :value, 10)}

    def validate_output(%{frame: :output}), do: raise("probe output frame")
    def validate_output(%{frame: :output_throw}), do: throw(:probe_output_frame)
    def validate_output(%{frame: :output_exit}), do: exit(:probe_output_frame)
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

  defmodule OutputEffect do
    use Jido.Action, name: "custom_flow_output_effect"
    def run(params, _context), do: {:ok, params, [:child_effect]}
  end

  defmodule OutputFlow do
    @behaviour Jido.Executable
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      Flow.new!(
        name: "custom_output_shape",
        components: [Step.new!(name: "effect", action: OutputEffect)],
        output: Ref.input(:output)
      )
    end

    def validate_params(params), do: {:ok, params}

    def validate_output(output) do
      :telemetry.execute([:jido_action_test, :custom_flow, :output], %{}, %{output: output})

      case output do
        %{replace_with: value} -> {:ok, value}
        value when is_list(value) -> {:ok, %{repaired: value}}
        value -> {:ok, value}
      end
    end
  end

  test "root and nested custom Flows enforce output shapes around one validation call" do
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:jido_action_test, :custom_flow, :output],
        &__MODULE__.record_output_validation/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    parent =
      Flow.new!(
        name: "custom_output_parent",
        components: [Subflow.new!(name: "child", flow: OutputFlow, params: Ref.input([]))],
        output: %{child: Ref.result("child")}
      )

    invalid = [[1], MapSet.new([1]), %Output{kind: :batch, value: :not_a_list}]
    stream = Output.stream(Stream.map([1], fn _ -> raise "stream was consumed" end))
    valid = [%{value: 1}, Output.raw(1), Output.batch([1]), stream]

    cases =
      Enum.map(invalid, &{&1, :error, 0}) ++
        Enum.map(invalid, &{%{replace_with: &1}, :error, 1}) ++
        Enum.map(valid, &{&1, {:ok, &1}, 1}) ++
        [{%{replace_with: %{value: 2}}, {:ok, %{value: 2}}, 1}]

    for {target, nested?} <- [{OutputFlow, false}, {parent, true}],
        mode <- [:run, :async, :paused],
        {output, expected, calls} <- cases do
      result = execute_output_flow(target, %{output: output}, mode)

      case expected do
        :error ->
          assert {:error, error} = result
          assert is_exception(error)

          if nested? do
            assert error.details.phase == :subflow_output
            assert error.details.node_path == ["child"]
            assert error.details.component == "child"
          end

        {:ok, value} ->
          value = if nested?, do: %{child: value}, else: value
          assert result == {:ok, value, [:child_effect]}
      end

      if calls == 1, do: assert_received({:output_validated, ^output})
      refute_received {:output_validated, _}
    end
  end

  def record_output_validation(_event, _measurements, %{output: output}, owner) do
    send(owner, {:output_validated, output})
  end

  defp execute_output_flow(target, input, :run), do: Exec.run(target, input)

  defp execute_output_flow(target, input, :async),
    do: target |> Exec.run_async(input) |> Exec.await()

  defp execute_output_flow(target, input, :paused) do
    assert {:ok, execution} = Exec.start(target, input)
    assert {:ok, execution} = Exec.continue(execution)
    Exec.result(execution)
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

  test "preserves original frames for standard Flow validator failures" do
    cases = [
      {:raise, :validate_params, "probe frame"},
      {:throw, :validate_params, "Flow validator throw"},
      {:exit, :validate_params, "Flow validator exit"},
      {:output, :validate_output, "probe output frame"},
      {:output_throw, :validate_output, "Flow validator throw"},
      {:output_exit, :validate_output, "Flow validator exit"}
    ]

    for target <- [CustomFlow, parent()], {frame, function, message} <- cases do
      assert {:error, %Flow.Error.InvalidExecutionError{message: ^message} = error} =
               Exec.run(target, %{frame: frame})

      assert_original_frame(error, CustomFlow, function, 1)
    end

    assert {:error, error} = CustomFlow |> Exec.run_async(%{frame: :raise}) |> Exec.await()
    assert_original_frame(error, CustomFlow, :validate_params, 1)

    assert {:error, error} = Exec.start(CustomFlow, %{frame: :raise})
    assert_original_frame(error, CustomFlow, :validate_params, 1)
  end

  test "preserves the original flow/0 frame for a standard definition raise" do
    assert {:error, %Flow.Error.InvalidDefinitionError{} = error} =
             Exec.run(__MODULE__.RuntimeDefinition)

    assert error.message == "definition frame"
    assert error.details.cause == RuntimeError
    assert_original_frame(error, __MODULE__.RuntimeDefinition, :flow, 0)
  end

  test "preserves the original child flow/0 frame when a Subflow cannot materialize" do
    flow =
      Flow.new!(
        name: "bad_child_parent",
        components: [Subflow.new!(name: "child", flow: __MODULE__.BadChild, params: %{})],
        output: Ref.result("child")
      )

    assert {:error, %Flow.Error.InvalidDefinitionError{} = error} = Exec.run(flow)
    assert error.message == "Subflow flow/0 failed"
    assert_original_frame(error, __MODULE__.BadChild, :flow, 0)
  end

  defmodule RuntimeDefinition do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise("definition frame")
    def validate_params(value), do: {:ok, value}
    def validate_output(value), do: {:ok, value}
  end

  defmodule BadChild do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise("child definition frame")
    def validate_params(value), do: {:ok, value}
    def validate_output(value), do: {:ok, value}
  end

  defp assert_original_frame(error, module, function, arity) do
    stacktrace =
      case error.stacktrace do
        %Splode.Stacktrace{stacktrace: stacktrace} -> stacktrace
        stacktrace when is_list(stacktrace) -> stacktrace
      end

    assert Enum.any?(stacktrace, fn
             {^module, ^function, ^arity, _location} -> true
             _frame -> false
           end)
  end
end
