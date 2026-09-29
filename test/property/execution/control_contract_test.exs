Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.ControlContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Iterate, Reduce, Ref, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Property.Runtime

  defmodule Probe do
    use Jido.Action, name: "property_concurrency_probe"
    @impl true
    def run(%{value: value}, context) do
      Agent.update(context.probe, fn state ->
        active = state.active + 1
        %{state | active: active, maximum: max(state.maximum, active)}
      end)

      send(context.observer, {context.token, :ready, value, self()})

      token = context.token

      receive do
        {^token, :release} -> :ok
      end

      Agent.update(context.probe, &%{&1 | active: &1.active - 1})
      {:ok, %{value: value}}
    end
  end

  defmodule Child do
    use Jido.Flow, name: "property_concurrency_child"

    flow do
      map "work",
        collection: input(:items),
        action: JidoActionTest.Property.Execution.ControlContractTest.Probe,
        params: %{value: item()}

      output %{items: result("work")}
    end
  end

  @tag contracts: ["EXEC-001", "EXEC-002"]
  @tag contract_cases: [
         "EXEC-002/foreign",
         "EXEC-002/previous-token",
         "EXEC-002/invalid",
         "EXEC-001/stale-apis"
       ]
  property "foreign and previous-revision tokens reject without consuming current work" do
    check all(count <- integer(2..5), max_runs: 30) do
      Runtime.with_context(fn context ->
        flow = emit_flow(count)
        foreign_context = %{context | token: make_ref()}
        {:ok, execution} = Exec.start(flow, %{}, context, Runtime.options(context))
        {:ok, foreign} = Exec.start(flow, %{}, foreign_context, Runtime.options(context))
        [first, second | _] = Exec.ready(execution)
        [foreign_work | _] = Exec.ready(foreign)
        {:ok, _, current} = Exec.step(execution, first.token)

        first_value =
          first.component_path |> hd() |> String.trim_leading("n") |> String.to_integer()

        Runtime.assert_calls(context, [first_value])

        try do
          ready = Exec.ready(current)

          for token <- [foreign_work.token, first.token, second.token, make_ref(), nil] do
            assert {:error,
                    %Flow.Error.InvalidExecutionError{details: %{reason: :invalid_work_token}}} =
                     Exec.step(current, token)

            assert Exec.ready(current) == ready
          end

          for operation <- [:step, :wave, :continue] do
            assert {:error,
                    %Flow.Error.InvalidExecutionError{details: %{reason: :stale_revision}}} =
                     apply(Exec, operation, [execution])
          end

          Runtime.assert_calls(context, [])
          assert {:ok, _, done} = Exec.wave(current)
          assert {:ok, %{done: true}, effects} = Exec.result(done)
          assert effects == Enum.to_list(1..count)
          observed = Runtime.calls(context)

          assert Enum.sort(Enum.map(observed, &elem(&1, 0))) ==
                   List.delete(Enum.to_list(1..count), first_value)

          Runtime.assert_workers_stopped(Enum.map(observed, &elem(&1, 1)))
        after
          Exec.continue(current)
          Exec.continue(foreign)
          Runtime.calls(foreign_context)
        end
      end)
    end
  end

  @tag contracts: ["EXEC-004", "EFFECT-002"]
  @tag contract_cases: ["EXEC-004/concurrent-pending", "EXEC-004/admitted-completion"]
  property "a concurrent failure stops pending admission while already-started work can finish" do
    check all(count <- integer(3..6), max_runs: 25) do
      Runtime.with_context(fn context ->
        token = context.token
        flow = gated_flow(count)
        handle = Exec.run_async(flow, %{}, context, Runtime.options(context, 2))

        try do
          assert_receive {^token, :ready, _first_value, first}, 1_000
          assert_receive {^token, :ready, second_value, second}, 1_000
          monitor = Process.monitor(second)

          try do
            send(second, {context.token, :fail})
            assert_receive {:DOWN, ^monitor, :process, ^second, _}, 1_000
          after
            Process.demonitor(monitor, [:flush])
          end

          assert Process.alive?(first)
          send(first, {context.token, :release})

          assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
                   Exec.await(handle)

          assert details.reason == {:rejected, second_value}
          refute_received {^token, :ready, _, _}
          Runtime.assert_workers_stopped([first, second])
        after
          Exec.cancel(handle)
        end
      end)
    end
  end

  @tag contracts: ["EXEC-001"]
  @tag contract_cases: ["EXEC-001/step-claim", "EXEC-001/wave-claim", "EXEC-001/continue-claim"]
  property "each mutation API has one claimant while its callback is blocked" do
    check all(value <- integer(), max_runs: 20) do
      for operation <- [:step, :wave, :continue] do
        Runtime.with_context(fn context ->
          token = context.token

          flow =
            Flow.new!(
              name: "claim",
              components: [
                Step.new!(name: "blocked", action: Runtime.Gate, params: %{value: value})
              ],
              output: %{done: true}
            )

          {:ok, execution} = Exec.start(flow, %{}, context, Runtime.options(context))
          [work] = ready = Exec.ready(execution)
          caller = Task.async(fn -> apply(Exec, operation, [execution]) end)

          try do
            assert_receive {^token, :ready, ^value, worker}, 1_000

            for args <- [[execution], [execution, work.token]] do
              assert {:error,
                      %Flow.Error.InvalidExecutionError{
                        details: %{reason: :operation_in_progress}
                      }} =
                       apply(Exec, :step, args)
            end

            for rejected <- [:wave, :continue] do
              assert {:error,
                      %Flow.Error.InvalidExecutionError{
                        details: %{reason: :operation_in_progress}
                      }} =
                       apply(Exec, rejected, [execution])
            end

            assert Exec.ready(execution) == ready
            refute_received {^token, :ready, _, _}
            send(worker, {token, :release})
            result = Task.await(caller)
            current = elem(result, tuple_size(result) - 1)
            assert Exec.result(current) == {:ok, %{done: true}, [value]}
            Runtime.assert_workers_stopped([worker])
          after
            Task.shutdown(caller, :brutal_kill)
          end
        end)
      end
    end
  end

  @tag contracts: ["EXEC-005"]
  @tag contract_cases: [
         "EXEC-005/limit-one",
         "EXEC-005/limit-two",
         "EXEC-005/limit-three",
         "EXEC-005/steps",
         "EXEC-005/map",
         "EXEC-005/nested",
         "EXEC-005/serial-reduce",
         "EXEC-005/serial-iterate"
       ]
  property "one concurrency cap covers Steps Map and nested Maps and Reduce stays serial" do
    check all(count <- integer(3..5), max_runs: 15) do
      items = Enum.to_list(1..count)

      for limit <- 1..3, kind <- [:steps, :map, :nested, :reduce, :iterate] do
        Runtime.with_context(fn context ->
          token = context.token
          {:ok, probe} = Agent.start_link(fn -> %{active: 0, maximum: 0} end)
          context = Map.put(context, :probe, probe)
          {flow, calls, effective_limit} = probe_flow(kind, items, limit)
          handle = Exec.run_async(flow, %{}, context, Runtime.options(context, limit))

          try do
            # Hold a full batch. The probe counts active callbacks before announcing readiness.
            batch =
              for _ <- 1..effective_limit do
                assert_receive {^token, :ready, _, pid}, 1_000
                pid
              end

            assert Agent.get(probe, & &1.maximum) == effective_limit
            Enum.each(batch, &send(&1, {context.token, :release}))

            rest =
              for _ <- List.duplicate(:work, calls - effective_limit) do
                assert_receive {^token, :ready, _, pid}, 1_000
                send(pid, {context.token, :release})
                pid
              end

            assert {:ok, _} = Exec.await(handle)
            assert Agent.get(probe, & &1.active) == 0
            assert Agent.get(probe, & &1.maximum) <= effective_limit
            Runtime.assert_workers_stopped(batch ++ rest ++ [handle.pid])
            refute_received {^token, :ready, _, _}
          after
            Exec.cancel(handle)
            Agent.stop(probe)
          end
        end)
      end
    end
  end

  defp emit_flow(count) do
    Flow.new!(
      name: "tokens",
      components:
        for(
          index <- 1..count,
          do: Step.new!(name: "n#{index}", action: Runtime.Emit, params: %{value: index})
        ),
      output: %{done: true}
    )
  end

  defp gated_flow(count) do
    Flow.new!(
      name: "fail_fast",
      components:
        for(
          index <- 1..count,
          do: Step.new!(name: "n#{index}", action: Runtime.Gate, params: %{value: index})
        ),
      output: %{done: true}
    )
  end

  defp probe_flow(:steps, items, limit) do
    steps =
      for item <- items, do: Step.new!(name: "n#{item}", action: Probe, params: %{value: item})

    {Flow.new!(name: "steps", components: steps, output: %{done: true}), length(items), limit}
  end

  defp probe_flow(:map, items, limit) do
    component =
      FlowMap.new!(name: "work", collection: items, action: Probe, params: %{value: Ref.item()})

    {Flow.new!(name: "map", components: [component], output: %{items: Ref.result("work")}),
     length(items), limit}
  end

  defp probe_flow(:nested, items, limit) do
    components =
      for name <- ["left", "right"],
          do: Subflow.new!(name: name, flow: Child, params: %{items: items})

    {Flow.new!(name: "nested", components: components, output: %{done: true}), length(items) * 2,
     limit}
  end

  defp probe_flow(:reduce, items, _limit) do
    component =
      Reduce.new!(
        name: "work",
        collection: items,
        initial: %{},
        action: Probe,
        params: %{value: Ref.item()}
      )

    {Flow.new!(name: "reduce", components: [component], output: Ref.result("work")),
     length(items), 1}
  end

  defp probe_flow(:iterate, items, _limit) do
    count = length(items)

    component =
      Iterate.new!(
        name: "work",
        action: Probe,
        params: %{value: Ref.iteration_index()},
        state: Iterate.State.new!(initial: %{}, update: %{}),
        completion: Expr.new!(:gte, [Ref.iteration_index(), count]),
        max_iterations: count
      )

    {Flow.new!(name: "iterate", components: [component], output: Ref.result("work")), count, 1}
  end
end
