defmodule Jido.Exec.Flow.TargetRunner do
  @moduledoc false

  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Invocation.Runtime, as: InvocationRuntime
  alias Jido.Exec.Transition
  alias Jido.Exec.Telemetry
  alias Jido.Flow.Compiler.Target
  alias Jido.Instruction

  @doc false
  @spec run(
          Instruction.t(),
          String.t(),
          String.t(),
          map() | nil,
          (function() -> term())
        ) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Transition.t()}
          | {:error, :input | :execution | :output, Exception.t()}
  def run(%Instruction{} = instruction, execution_id, flow_name, invocation, invoke) do
    span = start_span(instruction, execution_id, flow_name)

    result =
      invoke.(fn ->
        Runner.run_target(instruction, bind_invocation(invocation, instruction))
      end)
      |> authorize_transition(instruction)

    finish_span(span, result)
  end

  defp bind_invocation(nil, _instruction), do: nil

  defp bind_invocation(%{config: config, chain_index: chain_index} = invocation, instruction) do
    Map.put(invocation, :id, InvocationRuntime.target_id(config, chain_index, instruction))
  end

  defp start_span(%Instruction{target: target} = instruction, execution_id, flow_name) do
    metadata = Target.telemetry_metadata(instruction, target)

    Telemetry.start(
      [:jido, :flow, :target],
      Map.merge(metadata, %{execution_id: execution_id, flow: flow_name})
    )
  end

  defp finish_span(span, {:error, _phase, error} = result) do
    Telemetry.error(span, error)
    result
  end

  defp finish_span(span, result) do
    Telemetry.stop(span)
    result
  end

  defp authorize_transition({:continue, %Transition{} = transition}, instruction) do
    if Target.kind(instruction) == :dispatch and
         Target.details(instruction).dispatch_phase == :expander do
      {:continue, transition}
    else
      continuation_not_allowed(transition, instruction)
    end
  end

  defp authorize_transition(result, _instruction), do: result

  defp continuation_not_allowed(%Transition{} = transition, instruction) do
    details = Target.details(instruction)

    {:error, :execution,
     Jido.Action.Error.execution_error(
       "action continuation is not allowed from this Flow position",
       %{
         action: transition.origin,
         component: details.node,
         component_kind: Target.kind(instruction),
         retry: false
       }
     )}
  end
end
