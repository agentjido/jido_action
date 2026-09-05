defmodule JidoActionTest.Exec.MapRetentionTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Identity, Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.Actions.{EchoParamsAction, ReduceProbeAction}

  defmodule Counted do
    use Jido.Action, name: "map_retention_counted"

    def run(%{kind: kind} = params, %{counter: counter}) do
      Agent.update(counter, &Elixir.Map.update!(&1, kind, fn count -> count + 1 end))

      case kind do
        :map -> {:ok, %{value: params.item}}
        :reduce -> {:ok, %{values: params.accumulator.values ++ [params.item]}}
        :reader -> {:ok, %{items: params.items}}
        :after -> {:ok, %{done: true}}
      end
    end
  end

  defmodule Child do
    use Jido.Flow, name: "map_retention_child"

    flow do
      map "mapped", collection: input(:items), action: EchoParamsAction, params: %{value: item()}

      reduce "sum",
        collection: result("mapped"),
        initial: %{values: [], indexes: []},
        action: ReduceProbeAction,
        params: %{
          accumulator: accumulator(),
          item: item(),
          index: item_index(),
          item_id: item_id()
        }

      output %{items: result("mapped"), reduced: result("sum")}
    end
  end

  defmodule DiscardDependency do
    use Jido.Action, name: "map_discard_dependency"

    def run(%{item: :fail, dependency: %{large: [1 | _]}}, _context),
      do: {:error, Jido.Action.Error.execution_error("item failed")}

    def run(%{item: item, dependency: %{large: [1 | _]}}, _context),
      do: {:ok, %{value: item}}
  end

  test "completed Map tokens release dependency results after success and collected failure" do
    for {mode, items} <- [
          {:fail_fast, [:a, :b]},
          {:collect_errors, [:a, :b]},
          {:collect_errors, [:a, :fail]}
        ] do
      current =
        Flow.new!(
          name: "map_dependencies",
          components: [
            Step.new!(
              name: "producer",
              action: EchoParamsAction,
              params: %{large: Ref.input(:large)}
            ),
            Map.new!(
              name: "mapped",
              collection: Ref.input(:items),
              action: DiscardDependency,
              on_error: mode,
              params: %{item: Ref.item(), dependency: Ref.result("producer")}
            )
          ],
          output: %{items: Ref.result("mapped")}
        )

      assert {:ok, execution} = Exec.start(current, %{items: items, large: Enum.to_list(1..500)})
      assert {:ok, finished} = Exec.continue(execution)
      assert {:ok, %{items: outputs}} = Exec.result(finished)
      assert length(outputs) == 2
      if mode == :fail_fast, do: assert(outputs == [%{value: :a}, %{value: :b}])

      if mode == :collect_errors do
        assert hd(outputs) == %{status: :ok, value: %{value: :a}}

        if :fail in items do
          assert %{status: :error, error: %{message: "item failed"}} = List.last(outputs)
        else
          assert List.last(outputs) == %{status: :ok, value: %{value: :b}}
        end
      end

      tokens =
        Exec.native(finished).workflow
        |> Runic.Workflow.productions()
        |> Enum.map(&Jido.Flow.Compiler.Payload.unwrap(&1.value))
        |> Enum.filter(&match?(%{kind: :result, index: _}, &1))

      assert Enum.sort(Enum.uniq(Enum.map(tokens, & &1.index))) == [0, 1]

      for token <- tokens do
        refute Elixir.Map.has_key?(token, :results)
        refute Elixir.Map.has_key?(token, :item)
      end
    end
  end

  for mode <- [:run, :async, :step, :wave], items <- [[], [3, 1, 3]] do
    test "retains Map and Reduce with #{mode} and #{inspect(items)}" do
      items = unquote(items)
      expected_items = Enum.map(items, &%{value: &1})
      expected_indexes = items |> Enum.with_index() |> Enum.map(&elem(&1, 1))

      assert execute(flow(), items, unquote(mode)) ==
               {:ok,
                %{
                  items: expected_items,
                  reduced: %{values: expected_items, indexes: expected_indexes}
                }}
    end
  end

  test "Reduce-only output does not depend on the Reduce name" do
    assert execute(flow("sum", :reduce), [1], :run) ==
             {:ok, %{values: [%{value: 1}], indexes: [0]}}
  end

  test "Reduce-only output works when the Map collector is selected first" do
    assert {:ok, execution} = Exec.start(flow("reduced", :reduce), %{items: [1]})
    execution = finish(execution, :collector_first)
    assert Exec.result(execution) == {:ok, %{values: [%{value: 1}], indexes: [0]}}
  end

  test "two reducers, a reader, and an after-only dependent each execute once" do
    counter = start_supervised!({Agent, fn -> %{map: 0, reduce: 0, reader: 0, after: 0} end})

    for items <- [[], [3, 1, 3]] do
      Agent.update(counter, fn _ -> %{map: 0, reduce: 0, reader: 0, after: 0} end)
      mapped = Enum.map(items, &%{value: &1})

      current =
        Flow.new!(
          name: "shared_map",
          components: [
            Map.new!(
              name: "mapped",
              collection: Ref.input(:items),
              action: Counted,
              params: %{kind: :map, item: Ref.item()}
            ),
            counted_reduce("sum"),
            counted_reduce("reduced"),
            Step.new!(
              name: "reader",
              action: Counted,
              params: %{kind: :reader, items: Ref.result("mapped")}
            ),
            Step.new!(name: "after", action: Counted, after: ["mapped"], params: %{kind: :after})
          ],
          output: %{
            items: Ref.result("mapped"),
            sum: Ref.result("sum"),
            reduced: Ref.result("reduced"),
            reader: Ref.result("reader"),
            done: Ref.result("after")
          }
        )

      assert Exec.run(current, %{items: items}, %{counter: counter}, max_concurrency: 3) ==
               {:ok,
                %{
                  items: mapped,
                  sum: %{values: mapped},
                  reduced: %{values: mapped},
                  reader: %{items: mapped},
                  done: %{done: true}
                }}

      assert Agent.get(counter, & &1) ==
               %{map: length(items), reduce: 2 * length(items), reader: 1, after: 1}
    end
  end

  test "nested and JSON-restored Flows retain both results" do
    parent =
      Flow.new!(
        name: "parent",
        components: [
          Subflow.new!(name: "child", flow: Child, params: %{items: Ref.input(:items)})
        ],
        output: Ref.result("child")
      )

    assert {:ok, stored, registry} = Flow.Codec.encode(Child.flow())
    assert {:ok, restored} = Flow.Codec.decode(JSON.decode!(JSON.encode!(stored)), registry)
    assert restored == Child.flow()

    for current <- [parent, restored], items <- [[], [3, 1, 3]] do
      assert execute(current, items, :step) == execute(flow(), items, :run)
    end
  end

  test "Reduce item IDs use the Reduce name and remain stable across calls" do
    current = flow()
    assert {:ok, %{digest: digest}} = Flow.semantic_identity(current)

    expected_ids = Enum.map(0..2, &Identity.item_uuid(digest, "reduced", &1))

    for _ <- 1..2 do
      assert {:ok, _} = Exec.run(current, %{items: [3, 1, 3]}, %{test_pid: self()})

      ids =
        for index <- 0..2 do
          assert_receive {ReduceProbeAction, :called, ^index, id, _, _}, 1000
          refute id == Identity.item_uuid(digest, "mapped", index)
          id
        end

      assert ids == expected_ids
    end

    assert length(Enum.uniq(expected_ids)) == 3
    refute_received {ReduceProbeAction, :called, _, _, _, _}
  end

  test "a bare Map list still requires an output envelope" do
    current = flow()
    [mapped, _] = current.components
    current = Flow.new!(name: "map_only", components: [mapped], output: Ref.result("mapped"))

    assert {:error, %{message: "Flow returned a value that requires an output envelope"}} =
             Exec.run(current, %{items: []})
  end

  defp flow(name \\ "reduced", output \\ :both) do
    Flow.new!(
      name: "retention",
      components: [
        Map.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: EchoParamsAction,
          params: %{value: Ref.item()}
        ),
        Reduce.new!(
          name: name,
          collection: Ref.result("mapped"),
          initial: %{values: [], indexes: []},
          action: ReduceProbeAction,
          params: %{
            accumulator: Ref.accumulator(),
            item: Ref.item(),
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )
      ],
      output:
        if(output == :both,
          do: %{items: Ref.result("mapped"), reduced: Ref.result(name)},
          else: Ref.result(name)
        )
    )
  end

  defp counted_reduce(name) do
    Reduce.new!(
      name: name,
      collection: Ref.result("mapped"),
      initial: %{values: []},
      action: Counted,
      params: %{kind: :reduce, accumulator: Ref.accumulator(), item: Ref.item()}
    )
  end

  defp execute(flow, items, :run), do: Exec.run(flow, %{items: items})
  defp execute(flow, items, :async), do: flow |> Exec.run_async(%{items: items}) |> Exec.await()

  defp execute(flow, items, mode) when mode in [:step, :wave] do
    {:ok, execution} = Exec.start(flow, %{items: items})
    execution |> finish(mode) |> Exec.result()
  end

  defp finish(execution, :wave) do
    if Exec.status(execution) == :running do
      {:ok, _, next} = Exec.wave(execution)
      finish(next, :wave)
    else
      execution
    end
  end

  defp finish(execution, mode) do
    if Exec.status(execution) == :running do
      ready = Exec.ready(execution)

      runnable =
        if mode == :collector_first do
          Enum.find(ready, &(&1.component_path == ["mapped"] and &1.role == :fan_in)) || hd(ready)
        else
          hd(ready)
        end

      {:ok, _, next} = Exec.step(execution, runnable.token)
      finish(next, mode)
    else
      execution
    end
  end
end
