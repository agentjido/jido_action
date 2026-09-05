defmodule JidoActionTest.Exec.InstructionExecutionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jido.Action.Error.{ConfigurationError, InvalidInputError, TimeoutError}
  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow
  alias JidoActionTest.Fixtures.Actions.Add

  defmodule CountingDescriptorAction do
    def __jido_executable__ do
      if counter = Process.get(:descriptor_counter) do
        Agent.update(counter, &(&1 + 1))
      end

      Jido.Executable.action(__MODULE__)
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  test "resolves each execution target once" do
    counter = start_supervised!({Agent, fn -> 0 end})
    Process.put(:descriptor_counter, counter)

    assert Exec.run(CountingDescriptorAction, %{value: 1}) == {:ok, %{value: 1}}
    assert Agent.get(counter, & &1) == 1

    instruction = Instruction.new!(target: CountingDescriptorAction, params: %{value: 2})
    assert Agent.get(counter, & &1) == 2

    assert Exec.run(instruction) == {:ok, %{value: 2}}
    assert Agent.get(counter, & &1) == 3
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

  test "runs a legacy action struct literal after warning and normalization" do
    instruction = %Instruction{
      action: Add,
      params: %{value: 5, amount: 1},
      context: %{trace_id: "base"}
    }

    {result, log} =
      with_log(fn -> Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"}) end)

    assert result == {:ok, %{value: 8}}
    assert log =~ "Jido.Instruction received the deprecated :action field"
    assert log =~ "Use :target instead"
  end

  test "forwards legacy timeout and supervisor options with one grouped warning" do
    instruction = %Instruction{
      target: Add,
      params: %{value: 5},
      opts: [timeout: 0, task_supervisor: Jido.Exec.TaskSupervisor]
    }

    {result, log} = with_log(fn -> Exec.run(instruction) end)

    assert {:error, %TimeoutError{timeout: 0}} = result
    assert log =~ "Jido.Instruction received the deprecated :opts field"
    assert log =~ "Forwarded to Jido.Exec.run/4: [:timeout, :task_supervisor]"
    assert log =~ "Move execution options to Jido.Exec.run/4"
    assert length(Regex.scan(~r/received the deprecated :opts field/, log)) == 1
    refute log =~ "Not applied because"
  end

  test "gives direct Exec options precedence over legacy Instruction options" do
    instruction = %Instruction{
      target: Add,
      params: %{value: 5},
      opts: [timeout: 0]
    }

    {result, log} = with_log(fn -> Exec.run(instruction, %{}, %{}, timeout: 100) end)

    assert result == {:ok, %{value: 6}}
    assert log =~ "Forwarded to Jido.Exec.run/4: [:timeout]"
  end

  test "warns and leaves out known version 2 options" do
    instruction = %Instruction{
      target: Add,
      params: %{value: 5},
      opts: [
        max_retries: 3,
        backoff: 10,
        log_level: :debug,
        telemetry: :silent,
        context_propagators: [SecretPropagator],
        context_propagator_failure_mode: :strict,
        error_normalization: :legacy
      ]
    }

    {result, log} = with_log(fn -> Exec.run(instruction) end)

    assert result == {:ok, %{value: 6}}
    assert log =~ "Not applied because Jido Action 3 removed them"
    assert log =~ ":max_retries"
    assert log =~ ":context_propagators"
    assert log =~ "This call runs once"
    refute log =~ "SecretPropagator"
  end

  test "warns and rejects unknown legacy options without logging values" do
    instruction = %Instruction{
      target: Add,
      params: %{value: 5},
      opts: [custom_secret: "do-not-log"]
    }

    {result, log} = with_log(fn -> Exec.run(instruction) end)

    assert {:error,
            %InvalidInputError{
              details: %{
                options: [:custom_secret],
                reason: :unknown_instruction_options
              }
            }} = result

    assert log =~ "Unknown options cannot be migrated: [:custom_secret]"
    assert log =~ "Jido cannot continue"
    refute log =~ "do-not-log"
  end

  test "warns and rejects malformed opts in a raw struct literal" do
    instruction = %Instruction{target: Add, params: %{value: 5}, opts: [:not_keyword]}

    {result, log} = with_log(fn -> Exec.run(instruction) end)

    assert {:error, %InvalidInputError{details: %{field: :opts, reason: :not_keyword_list}}} =
             result

    assert log =~ "received an invalid deprecated :opts field"
    assert log =~ "The value must be a keyword list"
  end

  test "does not warn for an empty compatibility field" do
    instruction = %Instruction{target: Add, params: %{value: 5}, opts: []}

    {result, log} = with_log(fn -> Exec.run(instruction) end)

    assert result == {:ok, %{value: 6}}
    refute log =~ "deprecated :opts field"
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

  test "runs a typed Flow struct literal" do
    instruction = %Instruction{flow: MathFlow, params: %{value: 3}}

    assert {:ok, %{value: 8}} = Exec.run(instruction, %{}, %{}, max_concurrency: 2)
  end

  test "starts module and runtime Flow Instructions step-wise" do
    for target <- [MathFlow, MathFlow.flow()] do
      instruction = Instruction.new!(target: target, params: %{value: 3})

      assert {:ok, execution} = Exec.start(instruction)
      assert [%Runic.Workflow.Runnable{}] = Exec.ready(execution)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == {:ok, %{value: 8}}
    end
  end

  test "warns and rejects a legacy timeout for step-wise Flow execution" do
    instruction = Instruction.new!(target: MathFlow, params: %{value: 3}, opts: [timeout: 100])

    {result, log} = with_log(fn -> Exec.start(instruction) end)

    assert {:error, %Jido.Flow.Error.InvalidExecutionError{details: %{option: :timeout}}} =
             result

    assert log =~ "Not applied by Jido.Exec.start/4: [:timeout]"
    assert log =~ "A paused Flow does not have a whole-call timeout"
  end

  test "rejects step-wise execution for an Action Instruction" do
    instruction = Instruction.new!(target: Add, params: %{value: 1})

    assert {:error, %InvalidInputError{details: %{executable_type: :instruction}}} =
             Exec.start(instruction)
  end
end
