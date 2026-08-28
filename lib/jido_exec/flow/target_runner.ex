defmodule Jido.Exec.Flow.TargetRunner do
  @moduledoc false

  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Transition
  alias Jido.Exec.Telemetry
  alias Jido.Flow.Compiler.Target

  @doc false
  @spec run(module(), term(), map(), String.t(), keyword(), String.t(), Target.t()) ::
          {:ok, term()}
          | {:continue, Transition.t()}
          | {:error, :input | :execution | :output, Exception.t()}
  def run(target, params, context, execution_id, run_opts, flow_name, owner) do
    span = start_span(target, execution_id, flow_name, owner)

    result =
      target
      |> Runner.run_target(params, context, run_opts)
      |> authorize_transition(owner)

    finish_span(span, result)
  end

  defp start_span(target, execution_id, flow_name, owner) do
    case Target.telemetry_metadata(owner, target) do
      {:ok, metadata} ->
        Telemetry.start(
          [:jido, :flow, :target],
          Map.merge(metadata, %{execution_id: execution_id, flow: flow_name})
        )

      :none ->
        nil
    end
  end

  defp finish_span(nil, result), do: result

  defp finish_span(span, {:continue, %Transition{}} = result) do
    Telemetry.stop(span)
    result
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
         %Target{kind: :dynamic, details: %{dynamic_phase: :expander}}
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
