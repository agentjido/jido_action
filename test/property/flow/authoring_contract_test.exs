Code.require_file("../support/authoring.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)
Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.AuthoringContractTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias JidoActionTest.Property.Fuzz
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Codec, Ref, Step}
  alias JidoActionTest.Property.Runtime
  @generated JidoActionTest.Property.Flow.GeneratedGraph
  @tag contracts: ["FLOW-001", "FLOW-002", "EFFECT-001"]
  @tag contract_cases: [
         "FLOW-001/dsl",
         "FLOW-002/chain",
         "FLOW-002/diamond",
         "FLOW-002/disconnected",
         "FLOW-002/fan-in",
         "FLOW-002/fan-out",
         "FLOW-002/references",
         "FLOW-002/needs",
         "FLOW-002/combined"
       ]
  property("all authoring forms agree for every graph shape and dependency source") do
    check(
      all(
        seed <- integer(-5..5),
        delta <- integer(-5..5),
        max_runs: 8
      )
    ) do
      for shape <- [:chain, :diamond, :disconnected, :fan_in, :fan_out],
          edge <- [:references, :needs, :both] do
        assert_forms(parents(shape), edge, delta, seed)
      end
    end
  end

  @tag :fuzz
  @tag max_runs: 100, max_run_time: 300_000, timeout: 900_000, max_nodes: 8
  @tag contracts: ["FLOW-001", "FLOW-006", "ACT-005"]
  @tag contract_cases: [
         "FLOW-001/fuzz-all-forms",
         "FLOW-006/fuzz-extension",
         "ACT-005/fuzz-lexical-helper",
         "ACT-005/fuzz-extracted-action"
       ]
  test(
    "fuzz: generated source data forms inline Actions and extensions retain meaning",
    context
  ) do
    generator =
      fixed_map(%{
        "edges" =>
          list_of(list_of(integer(0..20), max_length: 4),
            min_length: 1,
            max_length: context.max_nodes
          ),
        "seed" => integer(-100..100),
        "delta" => integer(-20..20)
      })

    Fuzz.check("authoring_equivalence", generator, Map.to_list(context), fn sample ->
      parents =
        sample["edges"]
        |> Enum.with_index()
        |> Enum.map(fn {edges, index} ->
          refs =
            if index == 0 do
              []
            else
              Enum.map(edges, &"n#{rem(&1, index)}") |> Enum.uniq() |> Enum.sort()
            end

          {"n#{index}", refs}
        end)

      for edge <- [:references, :needs, :both] do
        assert_forms(parents, edge, sample["delta"], sample["seed"])
      end

      alias JidoActionTest.Property.AuthoringFixtures.{Inline, Extended}
      value = sample["seed"]
      action = Inline.step_action("work")

      direct =
        Flow.new!(
          name: "property_inline",
          components: [
            Step.new!(name: "work", action: action, params: %{value: Ref.input(:value)})
          ],
          output: Ref.result("work")
        )

      assert direct == Inline.flow()

      for target <- [action, Inline, direct] do
        assert Exec.run(target, %{value: value}) == {:ok, %{value: value * 3 - 7}, [value]}
      end

      assert_raise ArgumentError, fn -> Inline.step_action("absent") end

      extended =
        Flow.new!(
          name: "property_extended",
          components: [
            Step.new!(name: "work", action: Runtime.Emit, params: %{value: Ref.input(:value)})
          ],
          output: Ref.result("work")
        )

      data = %{
        output: Ref.result("work"),
        components: [
          %{kind: :step, name: "work", action: Runtime.Emit, params: %{value: Ref.input(:value)}}
        ],
        name: "property_extended"
      }

      assert {:ok, ^extended} = Jido.Flow.new(data)
      assert Extended.flow() == extended

      Runtime.with_context(fn runtime ->
        assert Exec.run(Extended, %{value: value}, runtime) == {:ok, %{value: value}, [value]}
        Runtime.assert_calls(runtime, [value])
      end)

      ["nodes:#{length(parents)}", "dsl", "inline", "extension"]
    end)
  end

  defp compile(parents, edge, delta) do
    steps =
      for {name, dependencies} <- Enum.reverse(parents) do
        refs =
          if edge == :needs do
            []
          else
            dependencies
          end

        value =
          Enum.reduce(
            refs,
            quote do
              input(:seed) + unquote(delta)
            end,
            fn parent, value ->
              quote do
                unquote(value) + result(unquote(parent), :value)
              end
            end
          )

        needs =
          if edge == :references do
            []
          else
            dependencies
          end

        quote line: 1 do
          step(unquote(name),
            action: JidoActionTest.Property.Runtime.Emit,
            params: %{value: unquote(value), label: unquote(name)},
            needs: unquote(needs)
          )
        end
      end

    output =
      {:%{}, [],
       Enum.map(parents, fn {name, _} ->
         {name,
          quote do
            result(unquote(name), :value)
          end}
       end)}

    Code.compile_quoted(
      quote line: 1 do
        defmodule unquote(@generated) do
          use Jido.Flow, name: "classified_graph"

          flow do
            unquote_splicing(steps)
            output(unquote(output))
          end
        end
      end
    )
  end

  defp parents(:chain) do
    [{"n1", []}, {"n2", ["n1"]}, {"n3", ["n2"]}, {"n4", ["n3"]}]
  end

  defp parents(:diamond) do
    [{"n1", []}, {"n2", ["n1"]}, {"n3", ["n1"]}, {"n4", ["n2", "n3"]}]
  end

  defp parents(:disconnected) do
    [{"n1", []}, {"n2", []}, {"n3", []}, {"n4", []}]
  end

  defp parents(:fan_in) do
    [{"n1", []}, {"n2", []}, {"n3", []}, {"n4", ["n1", "n2", "n3"]}]
  end

  defp parents(:fan_out) do
    [{"n1", []}, {"n2", ["n1"]}, {"n3", ["n1"]}, {"n4", ["n1"]}]
  end

  defp assert_forms(parents, edge, delta, seed) do
    components =
      for {name, dependencies} <- Enum.reverse(parents) do
        refs =
          if edge == :needs do
            []
          else
            dependencies
          end

        value =
          Enum.reduce(refs, Expr.new!(:add, [Ref.input(:seed), delta]), fn parent, value ->
            Expr.new!(:add, [value, Ref.result(parent, :value)])
          end)

        Step.new!(
          name: name,
          action: Runtime.Emit,
          params: %{value: value, label: name},
          needs:
            if edge == :references do
              []
            else
              dependencies
            end
        )
      end

    output = Map.new(parents, fn {name, _} -> {name, Ref.result(name, :value)} end)
    direct = Flow.new!(name: "classified_graph", components: components, output: output)

    data = %{
      output: output,
      components:
        Enum.map(
          components,
          fn step ->
            %{
              kind: :step,
              name: step.name,
              action: step.action,
              params: step.params,
              needs: step.needs
            }
          end
        ),
      name: direct.name
    }

    assert {:ok, built} = Jido.Flow.new(data)
    assert {:ok, document, registry} = Codec.encode(direct)
    assert {:ok, decoded} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)

    try do
      compile(parents, edge, delta)
      assert apply(@generated, :flow, []) == direct
      assert built == direct
      assert decoded == direct

      expected =
        Enum.reduce(parents, %{}, fn {name, dependencies}, values ->
          refs =
            if edge == :needs do
              []
            else
              dependencies
            end

          value = seed + delta + Enum.sum(Enum.map(refs, &Map.fetch!(values, &1)))
          Map.put(values, name, value)
        end)

      for target <- [@generated, direct, built, decoded] do
        Runtime.with_context(fn context ->
          assert {:ok, ^expected, effects} =
                   Exec.run(target, %{seed: seed}, context, Runtime.options(context, 3))

          depths =
            Enum.reduce(parents, %{}, fn {name, dependencies}, acc ->
              Map.put(
                acc,
                name,
                Enum.reduce(dependencies, 0, fn parent, depth -> max(depth, acc[parent] + 1) end)
              )
            end)

          assert effects == parents |> Enum.map(&elem(&1, 0)) |> Enum.sort_by(&{depths[&1], &1})
          calls = Runtime.calls(context)
          names = Enum.map(calls, &elem(&1, 0))
          assert Enum.sort(names) == Enum.sort(Map.keys(expected))
          positions = names |> Enum.with_index() |> Map.new()

          for {name, dependencies} <- parents, parent <- dependencies do
            assert positions[parent] < positions[name]
          end

          Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
        end)
      end
    after
      # This source defines one module. Also clean up when compilation fails.
      :code.delete(@generated)
      :code.purge(@generated)
    end
  end
end
