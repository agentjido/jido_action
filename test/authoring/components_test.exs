Code.require_file("support/components.ex", __DIR__)

defmodule JidoActionTest.Authoring.ComponentsTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Builder, Choice, Codec, Dispatch, Iterate, Ref, Reduce, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Authoring.Components

  alias Components.{
    Advance,
    Child,
    ChoiceFlow,
    Decide,
    DispatchFlow,
    DoubleParent,
    Echo,
    Expand,
    Final,
    GatedMapFlow
  }

  alias Components.{
    Fold,
    IterateRepeat,
    IterateWhile,
    MapBlock,
    MapCollect,
    MapItem,
    MapKeyword,
    Parent
  }

  alias Components.ReduceFlow

  test "Map keyword and block forms match direct, Builder, and JSON, including empty input" do
    params = %{value: Ref.item(), index: Ref.item_index(), item_id: Ref.item_id()}

    component =
      FlowMap.new!(name: "items", collection: Ref.input(:items), action: MapItem, params: params)

    output = %{items: Ref.result("items")}

    direct = Flow.new!(name: MapKeyword.name(), components: [component], output: output)

    builder =
      Builder.new(name: MapKeyword.name())
      |> Builder.map("items", Builder.input(:items), MapItem, params)
      |> Builder.output(output)

    forms = parity(MapKeyword, direct, builder)
    assert MapBlock.flow() == direct

    for form <- [MapBlock | forms] do
      assert Exec.run(form, %{items: []}, %{observer: self()}) == {:ok, %{items: []}}
    end

    refute_received {:map_item, _}

    assert {:ok, %{items: mapped}} =
             Exec.run(MapKeyword, %{items: [4, 4, 2]}, %{}, max_concurrency: 3)

    assert Enum.map(mapped, &{&1.value, &1.index}) == [{8, 0}, {8, 1}, {4, 2}]
    assert length(Enum.uniq(Enum.map(mapped, & &1.item_id))) == 3

    for form <- [MapBlock | tl(forms)] do
      assert Exec.run(form, %{items: [4, 4, 2]}, %{}, max_concurrency: 3) ==
               {:ok, %{items: mapped}}
    end
  end

  test "Reduce matches all forms and a non-associative fold runs in source order" do
    component =
      Reduce.new!(
        name: "fold",
        collection: Ref.input(:items),
        initial: %{value: 1},
        action: Fold,
        params: %{acc: Ref.accumulator(:value), item: Ref.item()}
      )

    direct =
      Flow.new!(name: ReduceFlow.name(), components: [component], output: Ref.result("fold"))

    builder =
      Builder.new(name: ReduceFlow.name())
      |> Builder.reduce("fold", Builder.input(:items), %{value: 1}, Fold, %{
        acc: Builder.accumulator(:value),
        item: Builder.item()
      })
      |> Builder.output(Builder.result("fold"))

    forms = parity(ReduceFlow, direct, builder)

    for form <- forms do
      assert Exec.run(form, %{items: []}, %{observer: self()}) == {:ok, %{value: 1}}
      assert Exec.run(form, %{items: [2, 2, 3]}) == {:ok, %{value: 777}}
    end

    refute_received {:fold, _, _}

    assert Exec.run(ReduceFlow, %{items: [2, 2, 3]}, %{observer: self()}) ==
             {:ok, %{value: 777}}

    assert_receive {:fold, 2, 1}
    assert_receive {:fold, 2, 8}
    assert_receive {:fold, 3, 78}
    refute_received {:fold, _, _}
  end

  test "Map fail-fast does not admit an item after a serial item failure" do
    assert {:error, error} =
             Exec.run(MapKeyword, %{items: [1, :bad, 3]}, %{observer: self()}, max_concurrency: 1)

    assert %{
             type: :execution_error,
             message: "bad map item",
             details: %{node_path: ["items"], item_index: 1}
           } = Jido.Flow.Error.to_map(error)

    assert_receive {:map_item, 1}
    assert_receive {:map_item, :bad}
    refute_received {:map_item, 3}
  end

  test "Map keeps input order and item identity when repeated items finish in reverse order" do
    observer = self()

    task =
      Task.async(fn ->
        Exec.run(GatedMapFlow, %{items: [7, 7, 9]}, %{observer: observer}, max_concurrency: 3)
      end)

    started =
      for _ <- 1..3, into: %{} do
        assert_receive {:map_started, index, value, item_id, pid}, 5_000
        {index, {value, item_id, pid}}
      end

    assert Map.keys(started) |> Enum.sort() == [0, 1, 2]
    assert Enum.map(0..2, fn index -> started[index] |> elem(0) end) == [7, 7, 9]
    assert started |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 3

    for index <- [2, 1, 0] do
      send(started[index] |> elem(2), {:release_map_item, index})
    end

    assert {:ok, %{items: results}} = Task.await(task, 10_000)

    expected =
      for index <- 0..2 do
        {index, started[index] |> elem(0), started[index] |> elem(1)}
      end

    assert Enum.map(results, &{&1.index, &1.value, &1.item_id}) == expected
  end

  test "Map collect-errors returns ordered tagged results for every item" do
    assert {:ok, %{items: [first, bad, last]}} =
             Exec.run(MapCollect, %{items: [1, :bad, 3]}, %{observer: self()}, max_concurrency: 1)

    assert first.status == :ok
    assert first.value.value == 2
    assert bad.status == :error
    assert bad.error.message == "bad map item"
    assert last.status == :ok
    assert last.value.value == 6
    assert_receive {:map_item, 1}
    assert_receive {:map_item, :bad}
    assert_receive {:map_item, 3}
    refute_received {:map_item, _}
  end

  test "Reduce failure stops before the next item" do
    assert {:error, error} =
             Exec.run(ReduceFlow, %{items: [2, :bad, 3]}, %{observer: self()})

    assert error.details.node_path == ["fold"]
    assert_receive {:fold, 2, 1}
    assert_receive {:fold, :bad, 8}
    refute_received {:fold, 3, _}
  end

  test "fixed and bounded Iterate forms match all authoring forms" do
    state =
      Iterate.State.new!(
        schema:
          IterateRepeat.flow().components |> hd() |> Map.fetch!(:state) |> Map.fetch!(:schema),
        initial: %{count: 0},
        update: %{count: Ref.body_result(:count)}
      )

    params = %{
      count: Ref.state(:count),
      index: Ref.iteration_index(),
      previous: Ref.body_result()
    }

    output = %{counter: Ref.result("counter")}

    for {module, completion, maximum, input, iterations} <- [
          {IterateRepeat, Expr.new!(:gte, [Ref.iteration_index(), 3]), 3, %{}, 3},
          {IterateWhile,
           Expr.new!(:not, [Expr.new!(:lt, [Ref.state(:count), Ref.input(:limit)])]), 4,
           %{limit: 3}, 3}
        ] do
      direct =
        Flow.new!(
          name: module.name(),
          components: [
            Iterate.new!(
              name: "counter",
              action: Advance,
              params: params,
              state: state,
              completion: completion,
              max_iterations: maximum
            )
          ],
          output: output
        )

      builder =
        Builder.new(name: module.name())
        |> Builder.iterate("counter", Advance, params, state,
          completion: completion,
          max_iterations: maximum
        )
        |> Builder.output(output)

      for form <- parity(module, direct, builder) do
        assert {:ok, %{counter: %{iterations: ^iterations, state: state_value}}} =
                 Exec.run(form, input)

        assert state_value == %{count: 3}
      end
    end

    assert {:ok, %{counter: %{iterations: 0, state: %{count: 0}}}} =
             Exec.run(IterateWhile, %{limit: 0}, %{observer: self()})

    refute_received {:iteration, _, _, _}

    assert {:ok, _} = Exec.run(IterateRepeat, %{}, %{observer: self()})
    assert_receive {:iteration, 0, 0, nil}
    assert_receive {:iteration, 1, 1, %{count: 1, index: 0}}
    assert_receive {:iteration, 2, 2, %{count: 2, index: 1}}
    refute_received {:iteration, _, _, _}
  end

  test "bounded Iterate stops at its limit without one extra body call" do
    assert {:error, error} = Exec.run(IterateWhile, %{limit: 9}, %{observer: self()})
    assert error.details.node == "counter"
    assert error.details.phase == :iterate_exhaustion

    for index <- 0..3 do
      assert_receive {:iteration, ^index, ^index, _previous}
    end

    refute_received {:iteration, 4, _, _}

    assert {:error, body_error} =
             Exec.run(IterateRepeat, %{}, %{observer: self(), fail_at: 1})

    assert body_error.details.node_path == ["counter"]
    assert_receive {:iteration, 0, 0, nil}
    assert_receive {:iteration, 1, 1, %{count: 1, index: 0}}
    refute_received {:iteration, 2, _, _}
  end

  test "Subflow parent and child preserve input, output, context, and schema" do
    output = %{child: Ref.result("child")}

    direct =
      Flow.new!(
        name: Parent.name(),
        components: [
          Subflow.new!(name: "child", flow: Child, params: %{value: Ref.input(:value)})
        ],
        output: output
      )

    builder =
      Builder.new(name: Parent.name())
      |> Builder.step("child", Child, %{value: Builder.input(:value)})
      |> Builder.output(output)

    for form <- parity(Parent, direct, builder) do
      assert Exec.run(form, %{value: 5}, %{label: "shared"}) ==
               {:ok, %{child: %{value: 5, label: "shared"}}}

      assert {:error, error} = Exec.run(form, %{value: "bad"}, %{label: "shared"})
      assert error.details.node_path == ["child"]
    end
  end

  test "two uses of one child keep separate values and error paths" do
    assert Exec.run(DoubleParent, %{left: 1, right: 2}, %{label: "shared"}) ==
             {:ok, %{left: %{value: 1, label: "shared"}, right: %{value: 2, label: "shared"}}}

    assert {:error, error} =
             Exec.run(DoubleParent, %{left: 1, right: "bad"}, %{label: "shared"})

    assert error.details.node_path == ["right"]
  end

  test "Choice matches all forms, selects first matching option, and falls back" do
    options = [
      Choice.Option.new!(
        name: "urgent",
        condition: Expr.new!(:gte, [Ref.input(:score), 90]),
        action: Echo,
        params: %{route: :urgent}
      ),
      Choice.Option.new!(
        name: "priority",
        condition: Expr.new!(:gte, [Ref.input(:score), 50]),
        action: Echo,
        params: %{route: :priority}
      )
    ]

    fallback = Choice.Fallback.new!(action: Echo, params: %{route: :standard})

    direct =
      Flow.new!(
        name: ChoiceFlow.name(),
        components: [Choice.new!(name: "route", options: options, fallback: fallback)],
        output: Ref.result("route")
      )

    builder =
      Builder.new(name: ChoiceFlow.name())
      |> Builder.choice("route", options, fallback)
      |> Builder.output(Builder.result("route"))

    for form <- parity(ChoiceFlow, direct, builder),
        {score, route} <- [{100, :urgent}, {70, :priority}, {10, :standard}] do
      assert Exec.run(form, %{score: score}) == {:ok, %{route: route}}
    end
  end

  test "terminal Dispatch matches all forms and continues to Action or Flow" do
    params = %{mode: Ref.input(:mode), value: Ref.input(:value), target: Ref.input(:target)}

    direct =
      Flow.new!(
        name: DispatchFlow.name(),
        components: [
          Dispatch.new!(name: "route", decision: Decide, expander: Expand, params: params)
        ],
        output: Ref.result("route")
      )

    builder =
      Builder.new(name: DispatchFlow.name())
      |> Builder.dispatch("route", Decide, Expand, params)
      |> Builder.output(Builder.result("route"))

    for form <- parity(DispatchFlow, direct, builder) do
      for {mode, target, expected} <- [
            {:finish, nil, %{value: 5, label: "ctx"}},
            {:continue, Final, %{value: 6, label: "ctx"}},
            {:continue, Components.FinalFlow, %{value: 6, label: "ctx"}}
          ] do
        assert Exec.run(form, %{mode: mode, value: 5, target: target}, %{label: "ctx"}) ==
                 {:ok, expected}
      end

      assert {:error, %Jido.Flow.Error.InvalidExecutionError{}} =
               Exec.start(form, %{mode: :finish, value: 5, target: nil}, %{label: "ctx"})
    end
  end

  defp parity(module, direct, builder) do
    assert module.flow() == direct
    assert {:ok, built} = Builder.build(builder)
    assert built == direct
    assert {:ok, document, registry} = Codec.encode(direct)
    assert {:ok, restored} = Codec.decode(document |> JSON.encode!() |> JSON.decode!(), registry)
    assert restored == direct
    [module, direct, built, restored]
  end
end
