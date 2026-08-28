defmodule Jido.Exec.Flow.TargetRunner do
  @moduledoc false

  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Continuation
  alias Jido.Exec.Telemetry
  alias Jido.Flow.Compiler.Target

  @doc false
  @spec run(module(), term(), map(), String.t(), keyword(), String.t(), Target.t()) ::
          {:ok, term()}
          | {:continue, Continuation.t()}
          | {:error, :input | :execution | :output, Exception.t()}
  def run(target, params, context, execution_id, run_opts, flow_name, owner) do
    span = start_span(target, execution_id, flow_name, owner)

    result =
      case Runner.run_target(target, params, context, run_opts) do
        {:continue, input, continuation_target} ->
          input
          |> Continuation.new(continuation_target, target, owner)
          |> Continuation.with_span(span)
          |> then(&{:continue, &1})

        result ->
          result
      end

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

  defp finish_span(_span, {:continue, %Continuation{}} = result), do: result

  defp finish_span(span, {:error, _phase, error} = result) do
    Telemetry.error(span, error)
    result
  end

  defp finish_span(span, result) do
    Telemetry.stop(span)
    result
  end
end
