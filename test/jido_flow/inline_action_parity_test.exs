defmodule Jido.Flow.InlineActionParityTest do
  use ExUnit.Case, async: false

  alias Jido.{Exec, Expr, Flow}

  alias Jido.Flow.{
    Builder,
    Choice,
    Codec,
    Condition,
    Dispatch,
    Iterate,
    Reduce,
    Ref,
    Registry,
    Step
  }

  alias Jido.Flow.Map, as: FlowMap

  defmodule Owner do
    use Jido.Flow, name: "inline_roles"

    flow do
      step "seed" do
        action value <- input(:value), do: {:ok, %{value: value + 1}}
      end

      map "mapped" do
        collection input(:items)

        action [value <- item() * 2, gate <- false and result("seed", :missing)] do
          {:ok, %{value: value, gate: gate}}
        end
      end

      reduce "total" do
        collection result("mapped")
        initial %{value: 0}

        action [value <- item(:value), total <- accumulator(:value)] do
          {:ok, %{value: total + value}}
        end
      end

      choice "route" do
        option "selected" do
          condition input(:enabled)
          action value <- result("total", :value), do: {:ok, %{value: value + 10}}
        end

        otherwise do
          action value <- result("total", :value), do: {:ok, %{value: value - 10}}
        end
      end

      iterate "loop" do
        state [], initial: result("route")
        action value <- state(:value), do: {:ok, %{value: value + 1}}
        update body_result()
        repeat 2
      end

      dispatch "next" do
        decision value <- result("loop", [:state, :value]), do: {:ok, %{value: value + 1}}
        expander %{value: value}, do: {:ok, %{value: value + 1}}
      end

      output result("next")
    end
  end

  test "all roles keep canonical data, static dependencies, identities, results, and failures" do
    direct = direct_flow()
    assert {:ok, built} = builder() |> Builder.build()
    dsl = Owner.flow()
    assert dsl == direct
    assert built == direct
    registry = registry()
    assert {:ok, document} = Codec.encode(direct, registry)
    assert document["version"] == 2
    assert {:ok, decoded} = document |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)
    assert decoded == direct

    assert {:ok, dependencies} = Flow.dependencies(dsl)
    assert dependencies["mapped"].references == ["seed"]
    assert {:ok, identity} = Flow.semantic_identity(dsl)
    expected_failure = failure_map(dsl)

    for flow <- [dsl, built, direct, decoded] do
      assert Flow.dependencies(flow) == {:ok, dependencies}
      assert Flow.semantic_identity(flow) == {:ok, identity}

      for {enabled, expected} <- [{true, 26}, {false, 6}] do
        assert Exec.run(flow, %{value: 1, items: [1, 2, 3], enabled: enabled}) ==
                 {:ok, %{value: expected}}
      end

      assert {:error, error} =
               Exec.run(flow, %{value: 1, items: ["private-operand"], enabled: true})

      assert error.details.operator == :multiply
      assert error.details.reason == :invalid_numeric_operands
      assert error.details.expression_path == [:value]
      refute inspect(error, limit: :infinity) =~ "private-operand"
      assert Flow.Error.to_map(error) == expected_failure
    end
  end

  test "every role target can be reused with new params and no source dependencies" do
    for {id, target} <- targets() do
      params =
        if id == "reduce",
          do: %{value: Ref.input(:new), total: 100},
          else: %{value: Ref.input(:new)}

      params = if id == "map", do: Map.put(params, :gate, true), else: params

      direct =
        Flow.new!(
          name: "reuse",
          components: [Step.new!(name: "new", action: target, params: params)],
          output: Ref.result("new")
        )

      assert {:ok, built} =
               Builder.new(name: "reuse")
               |> Builder.step("new", target, params)
               |> Builder.output(Ref.result("new"))
               |> Builder.build()

      assert built == direct
      assert {:ok, document, registry} = Codec.encode(built)
      assert document["version"] == 1

      assert {:ok, decoded} =
               document |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)

      assert decoded == direct

      assert Flow.dependencies(decoded) ==
               {:ok, %{"new" => %{after: [], references: [], effective: []}}}

      expected =
        case id do
          "map" -> %{value: 9, gate: true}
          "reduce" -> %{value: 109}
          "option" -> %{value: 19}
          "fallback" -> %{value: -1}
          _ -> %{value: 10}
        end

      for flow <- [direct, built, decoded],
          do: assert(Exec.run(flow, %{new: 9}) == {:ok, expected})
    end
  end

  test "only stored Expr nodes select version two, not binding or body syntax" do
    for {params, version, value} <- [
          {%{value: Ref.input(:new)}, 1, 4},
          {%{value: 3}, 1, 4},
          {%{value: Expr.new!(:add, [Ref.input(:new), 2])}, 2, 6}
        ] do
      flow =
        Flow.new!(
          name: "version",
          components: [
            Step.new!(name: "body", action: target(step: "seed", role: :action), params: params)
          ],
          output: Ref.result("body")
        )

      assert {:ok, document, registry} = Codec.encode(flow)
      assert document["version"] == version

      assert {:ok, decoded} =
               document |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)

      assert Exec.run(decoded, %{new: 3}) == {:ok, %{value: value}}
    end
  end

  test "Registry and stored Expr failures cannot select source or allocate target atoms" do
    assert {:ok, document} = Codec.encode(direct_flow(), registry())
    invalid = put_in(document, ["components", Access.at(1), "action"], "missing/inline/target")
    assert {:error, warm_error} = Codec.decode(invalid, registry())
    assert warm_error.details.path == ["components", 1, "action"]
    # Prepare input and warm all error paths before the allocation check.
    documents =
      for index <- 1..20,
          do: put_in(invalid, ["components", Access.at(1), "action"], "missing/inline/#{index}")

    registry = registry()
    # Warm the loop and match path with a separate sentinel, never these identifiers.
    for unknown <- [invalid], do: assert({:error, _} = Codec.decode(unknown, registry))
    atoms = :erlang.system_info(:atom_count)
    for unknown <- documents, do: assert({:error, _} = Codec.decode(unknown, registry))
    assert :erlang.system_info(:atom_count) == atoms

    malformed =
      put_in(document, ["components", Access.at(1), "params"], %{
        "$expr" => %{"operator" => "add", "operands" => [1]}
      })

    assert {:error, error} =
             malformed |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)

    assert error.details.path == ["components", 1, "params", "$expr"]

    literal = %{"do" => "System.halt()", "$expr" => %{"operator" => "add", "operands" => [1, 2]}}

    flow =
      Flow.new!(
        name: "literal",
        components: [
          Step.new!(
            name: "safe",
            action: target(dispatch: "next", role: :expander),
            params: %{value: 0}
          )
        ],
        output: literal
      )

    assert {:ok, stored, literal_registry} = Codec.encode(flow)
    assert stored["version"] == 1

    assert {:ok, decoded} =
             stored |> JSON.encode!() |> JSON.decode!() |> Codec.decode(literal_registry)

    assert Exec.run(decoded) == {:ok, literal}
  end

  defp failure_map(flow) do
    {:error, error} = Exec.run(flow, %{value: 1, items: ["private-operand"], enabled: true})
    Flow.Error.to_map(error)
  end

  defp target(path), do: Jido.Action.Inline.target!(Owner, [host: Jido.Flow] ++ path)

  defp targets do
    [
      {"step", target(step: "seed", role: :action)},
      {"map", target(map: "mapped", role: :action)},
      {"reduce", target(reduce: "total", role: :action)},
      {"option", target(choice: "route", option: "selected", role: :action)},
      {"fallback", target(choice: "route", fallback: :otherwise, role: :action)},
      {"iterate", target(iterate: "loop", role: :action)},
      {"decision", target(dispatch: "next", role: :decision)},
      {"expander", target(dispatch: "next", role: :expander)}
    ]
  end

  defp registry do
    entries = for {id, target} <- targets(), into: %{}, do: {"action/#{id}", {:action, target}}

    atoms =
      for atom <- [:value, :items, :enabled, :gate, :total, :missing, :state],
          into: %{},
          do: {"atom/#{atom}", {:atom, atom}}

    Registry.new!(entries |> Map.merge(atoms) |> Map.put("schema/empty", {:schema, []}))
  end

  defp mapped_params,
    do: %{
      value: Expr.new!(:multiply, [Ref.item(), 2]),
      gate: Expr.new!(:all, [false, Ref.result("seed", :missing)])
    }

  defp state, do: Iterate.State.new!(initial: Ref.result("route"), update: Ref.body_result())
  defp completion, do: Condition.gte(Ref.iteration_index(), 2)

  defp option,
    do:
      Choice.Option.new!(
        name: "selected",
        condition: Ref.input(:enabled),
        action: target(choice: "route", option: "selected", role: :action),
        params: %{value: Ref.result("total", :value)}
      )

  defp fallback,
    do:
      Choice.Fallback.new!(
        action: target(choice: "route", fallback: :otherwise, role: :action),
        params: %{value: Ref.result("total", :value)}
      )

  defp direct_flow do
    Flow.new!(
      name: "inline_roles",
      components: [
        Step.new!(
          name: "seed",
          action: target(step: "seed", role: :action),
          params: %{value: Ref.input(:value)}
        ),
        FlowMap.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: target(map: "mapped", role: :action),
          params: mapped_params()
        ),
        Reduce.new!(
          name: "total",
          collection: Ref.result("mapped"),
          initial: %{value: 0},
          action: target(reduce: "total", role: :action),
          params: %{value: Ref.item(:value), total: Ref.accumulator(:value)}
        ),
        Choice.new!(name: "route", options: [option()], fallback: fallback()),
        Iterate.new!(
          name: "loop",
          action: target(iterate: "loop", role: :action),
          params: %{value: Ref.state(:value)},
          state: state(),
          completion: completion(),
          max_iterations: 2
        ),
        Dispatch.new!(
          name: "next",
          decision: target(dispatch: "next", role: :decision),
          expander: target(dispatch: "next", role: :expander),
          params: %{value: Ref.result("loop", [:state, :value])}
        )
      ],
      output: Ref.result("next")
    )
  end

  defp builder do
    Builder.new(name: "inline_roles")
    |> Builder.step("seed", target(step: "seed", role: :action), %{value: Ref.input(:value)})
    |> Builder.map(
      "mapped",
      Ref.input(:items),
      target(map: "mapped", role: :action),
      mapped_params()
    )
    |> Builder.reduce(
      "total",
      Ref.result("mapped"),
      %{value: 0},
      target(reduce: "total", role: :action),
      %{value: Ref.item(:value), total: Ref.accumulator(:value)}
    )
    |> Builder.choice("route", [option()], fallback())
    |> Builder.iterate(
      "loop",
      target(iterate: "loop", role: :action),
      %{value: Ref.state(:value)},
      state(),
      completion: completion(),
      max_iterations: 2
    )
    |> Builder.dispatch(
      "next",
      target(dispatch: "next", role: :decision),
      target(dispatch: "next", role: :expander),
      %{value: Ref.result("loop", [:state, :value])}
    )
    |> Builder.output(Ref.result("next"))
  end
end
