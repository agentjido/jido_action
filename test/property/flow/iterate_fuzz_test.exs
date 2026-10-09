Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.IterateFuzzTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Advance do
    use Jido.Action, name: "fuzz_iterate_advance"
    @impl true
    def run(params, context) do
      Agent.update(context.probe, fn state ->
        active = state.active + 1
        %{active: active, maximum: max(active, state.maximum)}
      end)

      token = context.token
      send(context.observer, {token, :ready, params, self()})

      try do
        receive do
          {^token, :release} ->
            cond do
              params.fault == "body" and params.index == params.at ->
                {:error, {:iteration_failed, params.index}, [:discard]}

              params.fault == "update" and params.index == params.at ->
                {:ok, %{value: "invalid"}, [params.index]}

              true ->
                {:ok, %{value: params.value * params.scale + params.delta}, [params.index]}
            end
        end
      after
        Agent.update(context.probe, &%{&1 | active: &1.active - 1})
      end
    end
  end

  @tag :fuzz
  @tag max_runs: 200, max_run_time: 300_000, timeout: 900_000, max_iterations: 12
  @tag contracts: ["EXEC-003", "EXEC-004", "EXEC-005", "EFFECT-001", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-003/fuzz-iterate-zero",
         "EXEC-003/fuzz-state-initial",
         "EXEC-003/fuzz-state-update",
         "EXEC-004/fuzz-iterate-failure",
         "EXEC-005/fuzz-iterate-serial",
         "EFFECT-002/fuzz-iterate-exhaustion"
       ]
  test "fuzz: Iterate matches a recurrence and rejects invalid State without extra work",
       context do
    generator =
      fixed_map(%{
        "seed" => integer(-20..20),
        "scale" => integer(-3..3),
        "delta" => integer(-20..20),
        "count" => integer(0..context.max_iterations),
        "at" => integer(0..context.max_iterations),
        "fault" => member_of(~w(none initial update body exhausted))
      })

    base = %{"seed" => 2, "scale" => -2, "delta" => 1, "count" => 3, "at" => 1}

    examples =
      [Map.merge(base, %{"count" => 0, "fault" => "none"})] ++
        for(fault <- ~w(none initial update body exhausted), do: Map.put(base, "fault", fault))

    Fuzz.check(
      "iterate_state",
      generator,
      Map.to_list(context) ++ [examples: examples],
      &check_iterator/1
    )
  end

  defp check_iterator(sample) do
    count = if sample["fault"] == "none", do: sample["count"], else: max(sample["count"], 1)
    at = rem(sample["at"], max(count, 1))
    fault = sample["fault"]

    calls =
      cond do
        fault == "initial" -> 0
        fault in ["body", "update"] -> at + 1
        true -> count
      end

    initial = if fault == "initial", do: "invalid", else: sample["seed"]
    target = if fault == "exhausted", do: count + 1, else: count

    loop =
      JidoActionTest.FlowComponent.iterate!(
        name: "loop",
        action: Advance,
        needs: ["prior"],
        params: %{
          value: Ref.state(:value),
          index: Ref.iteration_index(),
          scale: sample["scale"],
          delta: sample["delta"],
          fault: fault,
          at: at
        },
        state:
          JidoActionTest.FlowComponent.state!(
            schema: Zoi.object(%{value: Zoi.integer()}),
            initial: %{value: initial},
            update: %{value: Ref.body_result(:value)}
          ),
        completion: Expr.new!(:>=, [Ref.iteration_index(), target]),
        max_iterations: max(count, 1)
      )

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "iterate_fuzz",
        components: [
          JidoActionTest.FlowComponent.step!(
            name: "prior",
            action: Runtime.Emit,
            params: %{value: :prior}
          ),
          loop,
          JidoActionTest.FlowComponent.step!(
            name: "after",
            action: Runtime.Emit,
            params: %{value: :after},
            needs: ["loop"]
          )
        ],
        output: Ref.result("loop")
      )

    for mode <- [:run, :step, :wave, :continue] do
      Runtime.with_context(fn runtime ->
        {:ok, probe} = Agent.start_link(fn -> %{active: 0, maximum: 0} end)
        runtime = Map.put(runtime, :probe, probe)
        caller = Task.async(fn -> execute(flow, runtime, mode) end)

        try do
          token = runtime.token

          {final, workers} =
            Enum.reduce(List.duplicate(:iteration, calls), {sample["seed"], []}, fn _,
                                                                                    {value, pids} ->
              index = length(pids)
              assert_receive {^token, :ready, params, worker}, 5_000
              assert params.index == index
              assert params.value == value
              assert Agent.get(probe, & &1.active) == 1
              send(worker, {token, :release})
              {value * sample["scale"] + sample["delta"], [worker | pids]}
            end)

          result = Task.await(caller, 5_000)

          case fault do
            "none" ->
              output = %{
                kind: :jido_flow_iterate_result,
                iterations: count,
                state: %{value: final},
                output: if(count == 0, do: nil, else: %{value: final})
              }

              indices = for i <- 0..count, i < count, do: i
              assert result == {:ok, output, [:prior] ++ indices ++ [:after]}
              Runtime.assert_calls(runtime, [:prior, :after])

            "body" ->
              assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} = result
              assert details.phase == :run
              assert details.iteration_index == at
              assert details.state_revision == at
              Runtime.assert_calls(runtime, [:prior])

            other ->
              assert {:error, error} = result

              expected_type =
                if other == "exhausted",
                  do: Flow.Error.ExecutionFailureError,
                  else: Flow.Error.InvalidExecutionError

              assert error.__struct__ == expected_type
              details = error.details

              phase =
                case other do
                  "initial" -> :iterate_state_initial
                  "update" -> :iterate_state_update
                  "exhausted" -> :iterate_exhaustion
                end

              assert details.phase == phase
              if other == "exhausted", do: assert(details.completed_iterations == count)
              Runtime.assert_calls(runtime, [:prior])
          end

          assert Agent.get(probe, & &1.active) == 0
          assert Agent.get(probe, & &1.maximum) == min(calls, 1)
          Runtime.assert_workers_stopped(workers)
          refute_received {^token, :ready, _, _}
        after
          Task.shutdown(caller, :brutal_kill)
          Agent.stop(probe)
        end
      end)
    end

    [fault, "iterations:#{count}", "all-modes"]
  end

  defp execute(flow, context, _mode),
    do: Exec.run(flow, %{}, context, Runtime.options(context, 3))
end
