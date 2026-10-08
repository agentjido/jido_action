Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.GraphContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Codec, Ref}
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Add do
    use Jido.Action, name: "property_graph_add"
    @impl true
    def run(%{left: left, right: right, delta: delta, name: name}, %{
          observer: observer,
          token: token
        }) do
      send(observer, {token, :call, name, self()})
      {:ok, %{value: left + right + delta}, [name]}
    end
  end

  for {suite, runs, maximum, budget} <- [{:property, 60, 6, 10_000}, {:fuzz, 600, 12, 300_000}] do
    @tag [
      {suite, true},
      max_runs: runs,
      max_run_time: budget,
      max_nodes: maximum,
      timeout:
        if suite == :fuzz do
          900_000
        else
          90_000
        end
    ]
    @tag contracts: ["FLOW-001", "FLOW-002", "STORE-001", "EFFECT-001"]
    @tag contract_cases: [
           "FLOW-001/data",
           "FLOW-001/codec",
           "EFFECT-001/graph-once",
           "EFFECT-001/graph-name-order",
           "EFFECT-001/serial-concurrent"
         ]
    test(
      "#{suite}: data forms preserve generated DAG results and canonical effects",
      context
    ) do
      generator =
        map(tuple({graph(context.max_nodes), integer(-20..20)}), fn {nodes, seed} ->
          %{"seed" => seed, "nodes" => Enum.map(nodes, &[&1.left, &1.right, &1.delta])}
        end)

      examples = [
        %{"seed" => 0, "nodes" => [[0, 0, 1], [0, 0, 2]]},
        %{"seed" => -2, "nodes" => [[0, 0, 1], [1, 0, -1], [1, 0, 2], [2, 3, 0]]},
        %{"seed" => 1, "nodes" => List.duplicate([0, 0, 0], context.max_nodes)}
      ]

      Fuzz.check("graph_semantics", generator, Map.to_list(context) ++ [examples: examples], fn %{
                                                                                                  "seed" =>
                                                                                                    seed,
                                                                                                  "nodes" =>
                                                                                                    encoded
                                                                                                } ->
        nodes =
          encoded
          |> Enum.with_index(1)
          |> Enum.map(fn {[left, right, delta], index} ->
            %{name: name(index), left: left, right: right, delta: delta}
          end)

        assert_graph(nodes, seed)
      end)
    end
  end

  defp assert_graph(nodes, seed) do
    # Parent indexes precede children. Reverse declaration order to test scheduling.
    components = Enum.reverse(components(nodes))
    output = Map.new(nodes, &{&1.name, Ref.result(&1.name, :value)})

    direct =
      JidoActionTest.FlowBuilder.new!(
        name: "property_dag",
        components: components,
        output: output
      )

    assert {:ok, built} = JidoActionTest.FlowBuilder.new(data(components, output))
    assert {:ok, stored, registry} = Codec.encode(direct)
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(stored)), registry)
    assert {:ok, stored_again} = Codec.encode(restored, registry)
    assert stored_again == stored
    assert built == direct
    assert restored == direct

    reordered =
      JidoActionTest.FlowBuilder.new!(
        name: "property_dag",
        components: Enum.reverse(components),
        output: output
      )

    # Evaluate the graph as arithmetic, without using Exec to compute the answer.
    expected =
      Enum.reduce(nodes, %{}, fn node, values ->
        value = value(node.left, seed, values) + value(node.right, seed, values) + node.delta
        Map.put(values, node.name, value)
      end)

    # Compute dependency depth from the generated indexes. This oracle does not
    # use Flow canonicalization or a serial Exec result as the expected order.
    depths =
      nodes
      |> Enum.with_index(1)
      |> Enum.reduce(%{0 => -1}, fn {node, index}, depths ->
        Map.put(depths, index, max(depths[node.left], depths[node.right]) + 1)
      end)

    effects =
      nodes
      |> Enum.with_index(1)
      |> Enum.sort_by(fn {node, index} -> {depths[index], node.name} end)
      |> Enum.map(fn {node, _index} -> node.name end)

    Runtime.with_context(fn context ->
      for flow <- [direct, built, restored, reordered], concurrency <- [1, 4] do
        assert run(flow, seed, context, concurrency, nodes) == {:ok, expected, effects}
      end
    end)

    [
      "nodes:#{length(nodes)}",
      if Enum.any?(nodes, &(&1.left != 0 and &1.right != 0)) do
        "join"
      else
        "no-join"
      end,
      if Enum.all?(nodes, &(&1.left == 0 and &1.right == 0)) do
        "independent"
      else
        "dependent"
      end
    ]
  end

  @tag :property
  @tag contracts: ["FLOW-003"]
  @tag contract_cases: ["FLOW-003/cycle"]
  property("a generated back edge is rejected by all data authoring forms") do
    check(all(nodes <- graph(6), max_runs: 40)) do
      components = components(nodes)
      [first | _] = components
      last = List.last(components)
      invalid = List.replace_at(components, 0, %{first | needs: [last.name]})
      # Force a path back to the first node, even if the generated DAG is disconnected.
      invalid = List.update_at(invalid, -1, &%{&1 | needs: [first.name]})
      output = %{value: Ref.result(last.name, :value)}

      valid =
        JidoActionTest.FlowBuilder.new!(
          name: "property_dag",
          components: components,
          output: output
        )

      assert {:ok, stored, registry} = Codec.encode(valid)

      stored =
        stored
        |> update_document_component(first.name, &Map.put(&1, "needs", [last.name]))
        |> update_document_component(last.name, &Map.put(&1, "needs", [first.name]))

      for result <- [
            JidoActionTest.FlowBuilder.new(
              name: "property_dag",
              components: invalid,
              output: output
            ),
            JidoActionTest.FlowBuilder.new(data(invalid, output)),
            Codec.decode(JSON.decode!(JSON.encode!(stored)), registry)
          ] do
        assert {:error,
                %Flow.Error.InvalidDefinitionError{
                  message: "flow dependency graph contains a cycle"
                }} = result
      end
    end
  end

  defp run(flow, seed, context, concurrency, nodes) do
    result = Exec.run(flow, %{seed: seed}, context, Runtime.options(context, concurrency))
    workers = Runtime.calls(context)
    assert Enum.sort(Enum.map(workers, &elem(&1, 0))) == Enum.sort(Enum.map(nodes, & &1.name))
    Runtime.assert_workers_stopped(Enum.map(workers, &elem(&1, 1)))
    Runtime.assert_supervisor_idle(context.supervisor)
    result
  end

  defp graph(maximum) do
    list_of(tuple({integer(0..(maximum - 1)), integer(0..(maximum - 1)), integer(-5..5)}),
      min_length: 2,
      max_length: maximum
    )
    |> map(fn nodes ->
      # A shrink can remove any node. Remap parent indexes so every candidate
      # stays acyclic and list shrinking can reduce the graph itself.
      nodes
      |> Enum.with_index(1)
      |> Enum.map(fn {{left, right, delta}, index} ->
        %{name: name(index), left: rem(left, index), right: rem(right, index), delta: delta}
      end)
    end)
  end

  defp components(nodes) do
    Enum.map(nodes, fn node ->
      JidoActionTest.FlowComponent.step!(
        name: node.name,
        action: Add,
        params: %{
          left: source(node.left),
          right: source(node.right),
          delta: node.delta,
          name: node.name
        }
      )
    end)
  end

  defp data(components, output) do
    %{
      name: "property_dag",
      output: output,
      components:
        Enum.map(components, fn step ->
          %{
            kind: :step,
            name: step.name,
            action: step.action,
            params: step.params,
            needs: step.needs
          }
        end)
    }
  end

  defp update_document_component(document, name, update) do
    index = Enum.find_index(document["components"], &(&1["name"] == name))
    update_in(document, ["components", Access.at(index)], update)
  end

  defp source(0) do
    Ref.input(:seed)
  end

  defp source(index) do
    Ref.result(name(index), :value)
  end

  defp value(0, seed, _values) do
    seed
  end

  defp value(index, _seed, values) do
    Map.fetch!(values, name(index))
  end

  defp name(index) do
    "node_#{index}"
  end
end
