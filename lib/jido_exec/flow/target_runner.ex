defmodule Jido.Exec.Flow.TargetRunner do
  @moduledoc false

  alias Jido.Action.Telemetry
  alias Jido.Exec.Action.Runner
  alias Jido.Flow.Compiler.Target

  @doc false
  @spec run(module(), term(), map(), String.t(), keyword(), String.t(), Target.t()) ::
          {:ok, term()} | {:error, :input | :execution | :output, Exception.t()}
  def run(target, params, context, execution_id, run_opts, flow_name, owner) do
    span = start_span(target, execution_id, flow_name, owner)

    result =
      Runner.run_target(
        target,
        params,
        context,
        Jido.Exec.ConcurrencyLimiter.whereis(execution_id),
        run_opts
      )

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

  defp finish_span(span, {:error, _phase, error} = result) do
    Telemetry.error(span, error)
    result
  end

  defp finish_span(span, result) do
    Telemetry.stop(span)
    result
  end
end
