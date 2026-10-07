Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.EffectFailureContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.Runtime

  @tag contracts: ["EXEC-004", "EFFECT-002"]
  @tag contract_cases: ["EXEC-004/each-failure-position", "EFFECT-002/prior-effects"]
  property "failure at each chain position stops downstream work and discards all prior effects" do
    check all(count <- integer(2..5), value <- integer(-20..20), max_runs: 20) do
      for failure <- 1..count do
        components =
          for index <- 1..count do
            JidoActionTest.FlowComponent.step!(
              name: "n#{index}",
              action: Runtime.Emit,
              params: %{value: value, label: index, fail: index == failure},
              needs: if(index == 1, do: [], else: ["n#{index - 1}"])
            )
          end

        flow =
          JidoActionTest.FlowBuilder.new!(
            name: "failure_chain",
            components: components,
            output: %{done: true}
          )

        for mode <- [:run, :step, :wave, :continue] do
          Runtime.with_context(fn context ->
            assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
                     execute(flow, context, mode)

            assert details.reason == {:rejected, value}
            Runtime.assert_calls(context, Enum.to_list(1..failure))
          end)
        end
      end
    end
  end

  @tag contracts: ["EXEC-004", "EFFECT-001", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-004/map-fail-fast",
         "EXEC-004/reduce-fail-fast",
         "EFFECT-001/collected-success",
         "EFFECT-002/collected-failure"
       ]
  property "Map collects ordered outcomes and successful effects while fail-fast Map and Reduce stop" do
    check all(count <- integer(2..5), max_runs: 25) do
      for failure <- [1, div(count, 2) + 1, count] |> Enum.uniq() do
        items = for index <- 1..count, do: %{value: index, label: index, fail: index == failure}

        collected =
          JidoActionTest.FlowComponent.map!(
            name: "work",
            collection: items,
            action: Runtime.Emit,
            params: Ref.item(),
            on_error: :collect_errors
          )

        flow =
          JidoActionTest.FlowBuilder.new!(
            name: "collect",
            components: [collected],
            output: %{items: Ref.result("work")}
          )

        for mode <- [:run, :step, :wave, :continue] do
          Runtime.with_context(fn context ->
            assert {:ok, %{items: outcomes}, effects} = execute(flow, context, mode)
            assert effects == List.delete(Enum.to_list(1..count), failure)

            assert Enum.map(outcomes, & &1.status) ==
                     Enum.map(1..count, &if(&1 == failure, do: :error, else: :ok))

            assert Enum.at(outcomes, failure - 1).error.details.reason == {:rejected, failure}
            calls = Runtime.calls(context)
            assert Enum.sort(Enum.map(calls, &elem(&1, 0))) == Enum.to_list(1..count)
            Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
          end)
        end

        for component <- [
              %{collected | on_error: :fail_fast},
              JidoActionTest.FlowComponent.reduce!(
                name: "work",
                collection: items,
                initial: %{},
                action: Runtime.Emit,
                params: Ref.item()
              )
            ] do
          flow =
            JidoActionTest.FlowBuilder.new!(
              name: "fail_collection",
              components: [component],
              output: %{done: true}
            )

          Runtime.with_context(fn context ->
            assert {:error, _} = execute(flow, context, :run)
            Runtime.assert_calls(context, Enum.to_list(1..failure))
          end)
        end
      end
    end
  end

  defp execute(flow, context, :run), do: Exec.run(flow, %{}, context, Runtime.options(context))

  defp execute(flow, context, mode) do
    {:ok, execution} = Exec.start(flow, %{}, context, Runtime.options(context))
    Runtime.finish(execution, mode)
  end
end
