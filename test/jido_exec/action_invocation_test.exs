defmodule JidoActionTest.Exec.ActionInvocationTest do
  use ExUnit.Case, async: true

  alias Jido.Action.{Error, Output}
  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Ref, Step}

  defmodule FinalAction do
    use Jido.Action, name: "invocation_final"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule Probe do
    @behaviour Jido.Action
    @behaviour Jido.Executable

    @impl true
    def __jido_executable__, do: Jido.Executable.action(__MODULE__)

    @impl true
    def validate_params(params) do
      record(params, :input)

      if params.mode == :input_error,
        do: {:error, Error.validation_error("input rejected", %{source: :probe})},
        else: {:ok, Map.put(params, :validated_input, true)}
    end

    @impl true
    def run(%{validated_input: true} = params, %{invocation: invocation}) do
      record(params, :execution)
      true = invocation == params.invocation

      case params.mode do
        :execution_error -> {:error, Error.execution_error("work rejected"), params.extras}
        :invalid_output -> {:ok, 42, params.extras}
        :envelope -> {:ok, Output.raw(42), params.extras}
        :continue -> {:continue, %{value: 42}, FinalAction}
        _ -> {:ok, Map.put(params, :ran, true), params.extras}
      end
    end

    @impl true
    def validate_output(%{ran: true} = params) do
      record(params, :output)

      if params.mode == :output_error,
        do: {:error, Error.validation_error("output rejected", %{source: :probe})},
        else: {:ok, %{value: 42}}
    end

    defp record(%{counter: counter}, phase) do
      worker = self()
      Agent.update(counter, &[{phase, worker} | &1])
    end
  end

  for {mode, phases} <- [
        success: [:input, :execution, :output],
        input_error: [:input],
        execution_error: [:input, :execution],
        output_error: [:input, :execution, :output],
        invalid_output: [:input, :execution],
        envelope: [:input, :execution],
        continue: [:input, :execution]
      ] do
    test "#{mode} runs each required phase once in one isolated worker" do
      counter = start_supervised!({Agent, fn -> [] end})
      supervisor = start_supervised!(Task.Supervisor)
      invocation = make_ref()
      params = %{counter: counter, mode: unquote(mode), extras: nil, invocation: invocation}
      context = %{invocation: invocation}

      for {path, kind, run} <- paths(params, context, supervisor) do
        Agent.update(counter, fn _ -> [] end)
        result = run.()
        assert_result(result, kind, unquote(mode))

        calls = Agent.get(counter, &Enum.reverse/1)
        assert Enum.map(calls, &elem(&1, 0)) == unquote(phases), to_string(path)
        assert [worker] = calls |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        refute worker == self()

        for pid <- Enum.uniq([worker | Task.Supervisor.children(supervisor)]) do
          monitor = Process.monitor(pid)
          assert_receive {:DOWN, ^monitor, :process, ^pid, reason}
          assert reason in [:normal, :noproc]
        end

        assert Task.Supervisor.children(supervisor) == []
      end
    end
  end

  defp paths(params, context, supervisor) do
    instruction = Instruction.new!(target: Probe, params: params, context: context)

    flow =
      Flow.new!(
        name: "invocation_probe",
        components: [Step.new!(name: "probe", action: Probe, params: Ref.input([]))],
        output: Ref.result("probe")
      )

    opts = [task_supervisor: supervisor]

    [
      {:action, :action, fn -> Exec.run(Probe, params, context, opts) end},
      {:instruction, :action, fn -> Exec.run(instruction, %{}, %{}, opts) end},
      {:action_timeout, :action,
       fn -> Exec.run(Probe, params, context, [timeout: 5_000] ++ opts) end},
      {:action_async, :action,
       fn -> Probe |> Exec.run_async(params, context, opts) |> Exec.await() end},
      {:flow, :flow, fn -> Exec.run(flow, params, context, opts) end},
      {:flow_timeout, :flow, fn -> Exec.run(flow, params, context, [timeout: 5_000] ++ opts) end},
      {:flow_async, :flow,
       fn -> flow |> Exec.run_async(params, context, opts) |> Exec.await() end},
      {:step, :flow, fn -> finish_steps(flow, params, context, opts, :step) end},
      {:wave, :flow, fn -> finish_steps(flow, params, context, opts, :wave) end}
    ]
  end

  defp finish_steps(flow, params, context, opts, operation) do
    {:ok, execution} = Exec.start(flow, params, context, opts)
    finish_steps(execution, operation)
  end

  defp finish_steps(execution, operation) do
    if Exec.status(execution) in [:succeeded, :failed] do
      Exec.result(execution)
    else
      {:ok, _work, execution} = apply(Exec, operation, [execution])
      finish_steps(execution, operation)
    end
  end

  defp assert_result(result, kind, mode) when mode in [:success, :envelope] do
    output = if mode == :envelope, do: Output.raw(42), else: %{value: 42}
    expected = if kind == :action, do: {:ok, output, nil}, else: {:ok, output}
    assert result == expected
  end

  defp assert_result(result, :action, :continue), do: assert(result == {:ok, %{value: 42}})

  defp assert_result(result, kind, mode) do
    error =
      if kind == :action and mode in [:execution_error, :output_error, :invalid_output] do
        assert {:error, error, nil} = result
        error
      else
        assert {:error, error} = result
        error
      end

    expected_type =
      if mode in [:input_error, :output_error],
        do: Error.InvalidInputError,
        else: Error.ExecutionFailureError

    assert error.__struct__ == expected_type

    if kind == :flow do
      expected_phase =
        case mode do
          :input_error -> :step_input
          mode when mode in [:output_error, :invalid_output] -> :step_output
          _ -> :step_execution
        end

      assert error.details.phase == expected_phase
      assert error.details.node == "probe"
    end

    if mode in [:input_error, :output_error], do: assert(error.details.source == :probe)
  end
end
