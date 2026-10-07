defmodule Jido.Exec.Flow.TargetRunner do
  @moduledoc false

  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Invocation.Runtime, as: InvocationRuntime
  alias Jido.Exec.Transition
  alias Jido.Exec.Telemetry
  alias Jido.Flow.Compiler.Target

  @doc false
  @spec run(
          module(),
          term(),
          map(),
          String.t(),
          String.t(),
          Target.t(),
          map() | nil,
          (function() -> term())
        ) ::
          {:ok, term()}
          | {:ok, term(), Jido.Action.effects()}
          | {:continue, Transition.t()}
          | {:error, :input | :execution | :output, Exception.t()}
  def run(target, params, context, execution_id, flow_name, owner, invocation, invoke) do
    span = start_span(target, execution_id, flow_name, owner)

    result =
      invoke.(fn ->
        Runner.run_target(target, params, context, bind_invocation(invocation, owner))
      end)
      |> authorize_transition(owner)

    finish_span(span, result)
  end

  defp bind_invocation(nil, _owner), do: nil

  defp bind_invocation(%{config: config, chain_index: chain_index} = invocation, owner) do
    Map.put(invocation, :id, InvocationRuntime.target_id(config, chain_index, owner))
  end

  defp start_span(target, execution_id, flow_name, owner) do
    metadata = Target.telemetry_metadata(owner, target)

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

  defp authorize_transition(
         {:continue, %Transition{} = transition},
         %Target{kind: :dispatch, details: %{dispatch_phase: :expander}}
       ),
       do: {:continue, transition}

  defp authorize_transition({:continue, %Transition{} = transition}, %Target{} = owner) do
    {:error, :execution,
     Jido.Action.Error.execution_error(
       "action continuation is not allowed from this Flow position",
       %{
         action: transition.origin,
         component: owner.details.node,
         component_kind: owner.kind,
         retry: false
       }
     )}
  end

  defp authorize_transition(result, _owner), do: result
end
