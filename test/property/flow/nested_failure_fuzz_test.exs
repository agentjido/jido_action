Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.NestedFailureFuzzTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Work do
    use Jido.Action, name: "fuzz_nested_work"
    @impl true
    def run(params, context) do
      Agent.update(context.probe, fn state ->
        active = state.active + 1
        %{active: active, maximum: max(active, state.maximum)}
      end)

      token = context.token
      send(context.observer, {token, :ready, params, self()})

      forced_failure =
        receive do
          {^token, :release} -> false
          {^token, :fail} -> true
        end

      Agent.update(context.probe, &%{&1 | active: &1.active - 1})
      send(context.observer, {token, :call, {params.group, params.item.index}, self()})

      if forced_failure or params.item.fail do
        {:error, {:nested_failure, params.item.index}, [:discard]}
      else
        {:ok, %{value: Map.get(params, :acc, 0) * 3 - params.item.value},
         [{params.group, params.item.index}]}
      end
    end
  end

  defmodule Fast do
    use Jido.Flow, name: "fuzz_nested_fast"

    flow do
      map "items",
        collection: input(:items),
        action: JidoActionTest.Property.Flow.NestedFailureFuzzTest.Work,
        params: %{item: item(), group: input(:group)},
        on_error: :fail_fast

      output %{items: result("items")}
    end
  end

  defmodule Collect do
    use Jido.Flow, name: "fuzz_nested_collect"

    flow do
      map "items",
        collection: input(:items),
        action: JidoActionTest.Property.Flow.NestedFailureFuzzTest.Work,
        params: %{item: item(), group: input(:group)},
        on_error: :collect_errors

      output %{items: result("items")}
    end
  end

  defmodule Fold do
    use Jido.Flow, name: "fuzz_nested_fold"

    flow do
      reduce "items",
        collection: input(:items),
        initial: %{value: 0},
        action: JidoActionTest.Property.Flow.NestedFailureFuzzTest.Work,
        params: %{item: item(), group: input(:group), acc: accumulator(:value)}

      output result("items")
    end
  end

  @tag :fuzz
  @tag max_runs: 250, max_run_time: 300_000, timeout: 900_000, max_items: 10
  @tag contracts: ["EXEC-003", "EXEC-004", "EXEC-005", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-003/fuzz-nested-collect",
         "EXEC-004/fuzz-nested-fail-fast",
         "EXEC-005/fuzz-shared-cap",
         "EXEC-005/fuzz-reduce-serial",
         "EFFECT-002/fuzz-nested-failure"
       ]
  test "fuzz: nested collections retain their failure policy and shared worker limit", context do
    generator =
      fixed_map(%{
        "values" => list_of(integer(-10..10), min_length: 4, max_length: context.max_items),
        "kind" => member_of(~w(fast collect reduce)),
        "fail" => boolean(),
        "first" => boolean(),
        "limit" => integer(1..3),
        "groups" => integer(1..3),
        "failure" => integer(0..20)
      })

    examples =
      for kind <- ~w(fast collect reduce), fail <- [false, true] do
        %{
          "values" => [1, 2, 2, -1],
          "kind" => kind,
          "fail" => fail,
          "first" => true,
          "limit" => 2,
          "groups" => 3,
          "failure" => 0
        }
      end

    Fuzz.check(
      "nested_execution_failures",
      generator,
      Map.to_list(context) ++ [examples: examples],
      &check_nested/1
    )
  end

  defp check_nested(sample) do
    kind = sample["kind"]
    terminal_failure = sample["fail"] and kind != "collect"
    groups = if terminal_failure or kind == "reduce", do: 1, else: sample["groups"]
    count = length(sample["values"])
    limit = sample["limit"]
    failure = rem(sample["failure"], count)

    items =
      sample["values"]
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        %{
          index: index,
          value: value,
          fail: sample["fail"] and kind == "collect" and index == failure
        }
      end)

    child =
      case kind do
        "fast" -> Fast
        "collect" -> Collect
        "reduce" -> Fold
      end

    choice =
      JidoActionTest.FlowComponent.choice!(
        name: "route",
        options: [
          JidoActionTest.FlowComponent.option!(
            name: "first",
            condition: sample["first"],
            action: Runtime.Emit,
            params: %{value: :first}
          )
        ],
        fallback:
          JidoActionTest.FlowComponent.fallback!(
            action: Runtime.Emit,
            params: %{value: :fallback}
          )
      )

    components =
      for group <- 1..groups do
        JidoActionTest.FlowComponent.subflow!(
          name: "child_#{group}",
          flow: child,
          params: %{items: items, group: group},
          needs: ["route"]
        )
      end

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "nested_failures",
        components: [choice | components],
        output: Map.new(1..groups, &{"child_#{&1}", Ref.result("child_#{&1}")})
      )

    Runtime.with_context(fn runtime ->
      {:ok, probe} = Agent.start_link(fn -> %{active: 0, maximum: 0} end)
      runtime = Map.put(runtime, :probe, probe)
      handle = Exec.run_async(flow, %{}, runtime, Runtime.options(runtime, limit))

      try do
        effective = if kind == "reduce", do: 1, else: limit
        batch = for _ <- 1..effective, do: ready(runtime)
        assert Agent.get(probe, & &1.maximum) == effective
        # The first batch is held, so the bound is checked under actual pressure.
        {result, all, failed_index} =
          if terminal_failure do
            # Advance a generated number of callbacks while keeping a full batch
            # held. Select a failing callback from work actually admitted.
            cut = rem(sample["failure"], count - effective)
            {active, released} = advance(batch, cut, runtime, [])
            {failed, worker} = Enum.at(active, rem(sample["failure"], effective))
            send(worker, {runtime.token, :fail})
            Runtime.assert_workers_stopped([worker])
            for {_, pid} <- active, pid != worker, do: send(pid, {runtime.token, :release})
            {Exec.await(handle, 5_000), released ++ active, failed.item.index}
          else
            Enum.each(batch, fn {_params, pid} -> send(pid, {runtime.token, :release}) end)
            {result, rest} = finish(handle, runtime, [])
            {result, batch ++ rest, nil}
          end

        assert Agent.get(probe, & &1.active) == 0
        assert Agent.get(probe, & &1.maximum) <= effective
        Runtime.assert_workers_stopped(Enum.map(all, &elem(&1, 1)) ++ [handle.pid])
        token = runtime.token
        refute_received {^token, :ready, _, _}
        calls = Runtime.calls(runtime) |> Enum.map(&elem(&1, 0))
        selected = if sample["first"], do: :first, else: :fallback
        assert hd(calls) == selected
        seen = tl(calls)
        assert length(seen) == length(Enum.uniq(seen))

        if terminal_failure do
          assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} = result
          assert details.reason == {:nested_failure, failed_index}
          assert {1, failed_index} in seen
          expected = Enum.map(all, fn {params, _} -> {params.group, params.item.index} end)
          assert Enum.sort(seen) == Enum.sort(expected)
          assert length(seen) < count
        else
          assert {:ok, output, effects} = result
          successful = for item <- items, not item.fail, do: item.index

          assert effects ==
                   [selected] ++ for(group <- 1..groups, index <- successful, do: {group, index})

          assert Enum.sort(seen) ==
                   for(group <- 1..groups, index <- 0..(count - 1), do: {group, index})

          for group <- 1..groups do
            value = output["child_#{group}"]

            case kind do
              "fast" ->
                assert value == %{items: Enum.map(items, &%{value: -&1.value})}

              "reduce" ->
                assert value == %{value: Enum.reduce(items, 0, &(&2 * 3 - &1.value))}

              "collect" ->
                assert Enum.map(value.items, & &1.status) ==
                         Enum.map(items, &if(&1.fail, do: :error, else: :ok))

                for {outcome, item} <- Enum.zip(value.items, items), item.fail do
                  assert outcome.error.details.reason == {:nested_failure, item.index}
                end

                for {outcome, item} <- Enum.zip(value.items, items), not item.fail do
                  assert outcome.value == %{value: -item.value}
                end
            end
          end
        end
      after
        Exec.cancel(handle)
        Agent.stop(probe)
      end
    end)

    [
      kind,
      if(terminal_failure, do: "terminal-error", else: "success"),
      "limit:#{limit}",
      "groups:#{groups}"
    ]
  end

  defp ready(context) do
    token = context.token
    assert_receive {^token, :ready, params, pid}, 5_000
    {params, pid}
  end

  defp advance(active, 0, _context, released), do: {active, Enum.reverse(released)}

  defp advance(active, count, context, released) do
    [next | rest] = Enum.sort_by(active, fn {params, _} -> params.item.index end)
    send(elem(next, 1), {context.token, :release})
    admitted = ready(context)
    advance(rest ++ [admitted], count - 1, context, [next | released])
  end

  defp finish(handle, context, workers) do
    token = context.token
    ref = handle.ref
    pid = handle.pid

    receive do
      {^token, :ready, params, worker} ->
        send(worker, {token, :release})
        finish(handle, context, [{params, worker} | workers])

      {:jido_exec_async_result, ^ref, ^pid, _} = message ->
        assert {:done, result} = Exec.handle_message(handle, message)
        {result, Enum.reverse(workers)}
    after
      5_000 -> flunk("nested execution did not finish or announce work")
    end
  end
end
