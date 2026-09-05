defmodule JidoActionTest.Exec.InstructionExecutionTest do
  # Descriptor counters use one registered test process.
  use ExUnit.Case, async: false

  alias Jido.Action.Error.{ConfigurationError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow
  alias JidoActionTest.Fixtures.Actions.Add

  def record_call(event) do
    Agent.update(__MODULE__.Counts, &Map.update(&1, event, 1, fn count -> count + 1 end))
  end

  defmodule CountingDescriptorAction do
    def __jido_executable__ do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:descriptor)
      Jido.Executable.action(__MODULE__)
    end

    def validate_params(params) do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:input)
      {:ok, params}
    end

    def validate_output(output) do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:output)
      {:ok, output}
    end

    def run(params, _context) do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:run)
      {:ok, params}
    end
  end

  defmodule CountingDescriptorFlow do
    def __jido_executable__ do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:descriptor)
      Jido.Executable.flow(__MODULE__)
    end

    def flow do
      JidoActionTest.Exec.InstructionExecutionTest.record_call(:flow)
      MathFlow.flow()
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Exec.run(flow(), params, context)
  end

  defmodule CallDataAction do
    use Jido.Action, name: "instruction_call_data"

    @impl true
    def run(params, context), do: {:ok, %{params: params, context: context}}
  end

  defmodule CallDataProbeAction do
    use Jido.Action, name: "instruction_call_data_probe"

    @impl true
    def run(params, _context) do
      send(
        JidoActionTest.Exec.InstructionExecutionTest.CallbackObserver,
        :instruction_action_dispatched
      )

      {:ok, params}
    end
  end

  defmodule CallDataProbeFlow do
    use Jido.Flow, name: "instruction_call_data_probe_flow"

    flow do
      step("probe", action: CallDataProbeAction, params: %{})
      output(result("probe"))
    end
  end

  for field <- [:params, :context, :metadata] do
    @field field
    test "rejects false #{@field} before Action work at every Exec boundary" do
      Process.register(self(), __MODULE__.CallbackObserver)
      message = "expected #{@field} to be a map or keyword list, got: false"

      for target <- [CallDataProbeAction, CallDataProbeFlow, CallDataProbeFlow.flow()] do
        instruction = struct!(Instruction, [{:target, target}, {@field, false}])
        assert {:error, %InvalidInputError{message: ^message}} = Exec.run(instruction)

        assert {:error, %InvalidInputError{message: ^message}} =
                 Exec.run(instruction, %{}, %{}, timeout: 5_000)

        assert {:error, %InvalidInputError{message: ^message}} = Exec.start(instruction)
        handle = Exec.run_async(instruction)
        assert {:error, %InvalidInputError{message: ^message}} = Exec.await(handle)

        # Completed Exec calls are the barrier before the absence assertion.
        refute_received :instruction_action_dispatched
      end
    end
  end

  test "nil raw fields stay valid through run, async, and step-wise Flow execution" do
    Process.register(self(), __MODULE__.CallbackObserver)

    for target <- [CallDataProbeAction, CallDataProbeFlow, CallDataProbeFlow.flow()] do
      instruction = %Instruction{target: target, params: nil, context: nil, metadata: nil}
      assert Exec.run(instruction) == {:ok, %{}}
      assert_received :instruction_action_dispatched
      assert instruction |> Exec.run_async() |> Exec.await() == {:ok, %{}}
      assert_received :instruction_action_dispatched

      unless target == CallDataProbeAction do
        assert {:ok, execution} = Exec.start(instruction)
        refute_received :instruction_action_dispatched
        assert {:ok, execution} = Exec.continue(execution)
        assert Exec.result(execution) == {:ok, %{}}
        assert_received :instruction_action_dispatched
      end
    end
  end

  test "resolves each execution target once in synchronous, timed, and async calls" do
    counter = start_supervised!({Agent, fn -> %{} end})
    Process.register(counter, __MODULE__.Counts)

    for target <- [CountingDescriptorAction, CountingDescriptorFlow],
        mode <- [:sync, :finite, :async] do
      Agent.update(counter, fn _ -> %{} end)
      instruction = Instruction.new!(target: target, params: %{value: 2})
      assert Agent.get(counter, & &1) == %{descriptor: 1}
      Agent.update(counter, fn _ -> %{} end)

      result =
        case mode do
          :sync -> Exec.run(instruction)
          :finite -> Exec.run(instruction, %{}, %{}, timeout: 5_000)
          :async -> instruction |> Exec.run_async() |> Exec.await()
        end

      if target == CountingDescriptorAction do
        assert result == {:ok, %{value: 2}}
        assert Agent.get(counter, & &1) == %{descriptor: 1, input: 1, output: 1, run: 1}
      else
        assert result == {:ok, %{value: 6}}
        assert Agent.get(counter, & &1) == %{descriptor: 1, flow: 1}
      end
    end

    Agent.update(counter, fn _ -> %{} end)
    assert Exec.run(CountingDescriptorAction, %{value: 1}) == {:ok, %{value: 1}}
    assert Agent.get(counter, & &1) == %{descriptor: 1, input: 1, output: 1, run: 1}
  end

  test "resolves and materializes an Instruction once before step-wise Flow work" do
    counter = start_supervised!({Agent, fn -> %{} end})
    Process.register(counter, __MODULE__.Counts)
    instruction = %Instruction{target: CountingDescriptorFlow, params: %{value: 2}}

    assert {:ok, execution} = Exec.start(instruction)
    assert Agent.get(counter, & &1) == %{descriptor: 1, flow: 1}
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.result(execution) == {:ok, %{value: 6}}
    assert Agent.get(counter, & &1) == %{descriptor: 1, flow: 1}
  end

  test "keeps shallow merges and metadata separate from execution policy" do
    instruction =
      Instruction.new!(
        target: CallDataAction,
        params: %{nested: %{old: true}, keep: 1},
        context: %{nested: %{old: true}, keep: 2},
        metadata: %{timeout: 0, max_concurrency: 0, task_supervisor: :not_a_route}
      )

    expected =
      {:ok, %{params: %{nested: %{new: true}, keep: 1}, context: %{nested: nil, keep: 2}}}

    assert Exec.run(instruction, [nested: %{new: true}], nested: nil) == expected
    handle = Exec.run_async(instruction, [nested: %{new: true}], [nested: nil], timeout: 5_000)
    assert Exec.await(handle) == expected
  end

  test "rejects malformed raw invocation maps through every Instruction execution boundary" do
    for target <- [Add, MathFlow, MathFlow.flow()], field <- [:params, :context, :metadata] do
      instruction = struct!(Instruction, [{:target, target}, {field, [:not_keyword]}])
      assert {:error, %InvalidInputError{message: message}} = Exec.run(instruction)
      assert message =~ "expected a map or keyword list"
      assert {:error, %InvalidInputError{message: ^message}} = Exec.start(instruction)

      assert {:error, %InvalidInputError{message: ^message}} =
               instruction |> Exec.run_async() |> Exec.await()
    end
  end

  test "accepts only direct run policy and rejects step-wise timeouts" do
    for target <- [Add, MathFlow, MathFlow.flow()] do
      instruction = Instruction.new!(target: target, params: %{value: 2})
      expected = if target == Add, do: {:ok, %{value: 3}}, else: {:ok, %{value: 6}}

      assert Exec.run(instruction, %{}, %{},
               timeout: 5_000,
               max_concurrency: 1,
               max_continuations: 0
             ) == expected

      assert {:error, %{details: %{option: :max_continuations}}} =
               Exec.run(instruction, %{}, %{}, max_continuations: -1)

      assert {:error, %{details: %{option: :max_concurrency}}} =
               Exec.run(instruction, %{}, %{}, max_concurrency: 0)
    end

    for target <- [MathFlow, MathFlow.flow()] do
      instruction = Instruction.new!(target: target, params: %{value: 2})

      assert {:error, %Jido.Flow.Error.InvalidExecutionError{details: %{option: :timeout}}} =
               Exec.start(instruction, %{}, %{}, timeout: 100)
    end
  end

  test "merges Instruction and call-site input and context" do
    instruction =
      Instruction.new!(
        target: Add,
        params: %{value: 5, amount: 1},
        context: %{trace_id: "base"}
      )

    assert {:ok, %{value: 8}} =
             Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"})
  end

  test "rejects invalid call-site input" do
    instruction = Instruction.new!(target: Add)

    assert {:error, %InvalidInputError{message: message}} =
             Exec.run(instruction, :not_params, %{})

    assert message =~ "expected params to be a map or keyword list"
  end

  test "rejects malformed raw Instruction structs" do
    for target <- ["not_a_module", nil] do
      instruction = %Instruction{target: target, params: %{}, context: %{}}

      assert {:error, %ConfigurationError{}} =
               Exec.run(instruction)

      assert {:error, %ConfigurationError{}} = Exec.start(instruction)
    end
  end

  test "runs module and runtime Flow Instructions with Flow options" do
    for target <- [MathFlow, MathFlow.flow()] do
      instruction =
        Instruction.new!(
          target: target,
          params: %{value: 2},
          context: %{tenant: "acme"}
        )

      assert {:ok, %{value: 8}} =
               Exec.run(instruction, %{value: 3}, %{}, max_concurrency: 2)
    end
  end

  test "starts module and runtime Flow Instructions step-wise" do
    for target <- [MathFlow, MathFlow.flow()] do
      instruction = Instruction.new!(target: target, params: %{value: 3})

      assert {:ok, execution} = Exec.start(instruction)
      assert [%Jido.Exec.Work{}] = Exec.ready(execution)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == {:ok, %{value: 8}}
    end
  end

  test "rejects step-wise execution for an Action Instruction" do
    instruction = Instruction.new!(target: Add, params: %{value: 1})

    assert {:error, %InvalidInputError{details: %{executable_type: :instruction}}} =
             Exec.start(instruction)
  end
end
