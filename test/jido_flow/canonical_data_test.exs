defmodule JidoActionTest.Flow.CanonicalDataTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Ref
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.NestedFlow

  test "constructs the canonical Flow data" do
    load = %{
      kind: :step,
      name: "load",
      action: Add,
      params: %{value: Ref.input(:value), amount: 1},
      needs: [],
      meta: %{label: "Load"}
    }

    save = %{
      kind: :step,
      name: "save",
      action: Add,
      params: %{value: Ref.result("load", :value), amount: 1},
      needs: ["audit"],
      meta: %{}
    }

    audit = %{
      kind: :step,
      name: "audit",
      action: Add,
      params: %{value: Ref.input(:value), amount: 0},
      needs: [],
      meta: %{}
    }

    assert {:ok,
            %Flow{
              name: "canonical",
              components: %{
                "load" => %{
                  kind: :call,
                  call: {%Instruction{kind: :action, target: Add}, load_params},
                  meta: %{label: "Load"}
                },
                "save" => %{
                  kind: :call,
                  call: {%Instruction{kind: :action, target: Add}, save_params},
                  needs: ["audit"]
                },
                "audit" => %{
                  kind: :call,
                  call: {%Instruction{kind: :action, target: Add}, audit_params}
                }
              },
              output: %Ref{source: :result, component: "save", path: []}
            } = flow} =
             Flow.new(%{
               name: "canonical",
               components: [load, save, audit],
               output: Ref.result("save")
             })

    assert load_params == load.params
    assert save_params == save.params
    assert audit_params == audit.params

    assert {:ok,
            %{
              "load" => %{needs: [], references: [], effective: []},
              "save" => %{
                needs: ["audit"],
                references: ["load"],
                effective: ["audit", "load"]
              },
              "audit" => %{needs: [], references: [], effective: []}
            }} = Flow.dependencies(flow)
  end

  test "canonical validation rejects bound and malformed Instruction templates" do
    flow = step_flow()
    node = flow.components["step"]
    {template, params} = node.call

    for {field, value} <- [
          kind: :worker,
          target: "Elixir.InvalidAction",
          params: %{bound: true},
          context: %{bound: true},
          metadata: %{source: "canonical"},
          metadata: [:not_a_map]
        ] do
      invalid_template = Map.put(template, field, value)
      invalid = put_in(flow.components["step"].call, {invalid_template, params})
      assert_invalid_canonical(invalid)
    end
  end

  test "canonical validation requires an exact Instruction call tuple" do
    flow = step_flow()
    {template, params} = flow.components["step"].call

    for call <- [
          {%{kind: :action, target: Add}, params},
          {template},
          {template, params, :extra},
          [template, params]
        ] do
      invalid = put_in(flow.components["step"].call, call)
      assert_invalid_canonical(invalid)
    end
  end

  test "canonical validation rejects unknown fields on every node kind" do
    flow =
      Flow.new!(%{
        name: "canonical_node_keys",
        components: [
          %{kind: :step, name: "step", action: Add},
          %{kind: :subflow, name: "subflow", flow: NestedFlow},
          %{
            kind: :choice,
            name: "choice",
            options: [%{name: "yes", condition: true, action: Add}],
            fallback: %{action: Add}
          },
          %{kind: :map, name: "map", collection: [], action: Add},
          %{kind: :reduce, name: "reduce", collection: [], initial: %{}, action: Add},
          %{
            kind: :iterate,
            name: "iterate",
            action: Add,
            state: %{initial: %{}, update: %{}},
            completion: true,
            max_iterations: 1
          }
        ],
        output: Ref.result("step")
      })

    for name <- Map.keys(flow.components) do
      invalid = put_in(flow.components[name], Map.put(flow.components[name], :extra, true))
      assert_invalid_canonical(invalid)
    end

    choice = flow.components["choice"]
    [option] = choice.options

    invalid_option =
      put_in(flow.components["choice"].options, [Map.put(option, :extra, true)])

    assert_invalid_canonical(invalid_option)

    invalid_state =
      put_in(
        flow.components["iterate"].state,
        Map.put(flow.components["iterate"].state, :extra, true)
      )

    assert_invalid_canonical(invalid_state)
  end

  test "canonical Dispatch requires an exact nil expander value" do
    flow =
      Flow.new!(%{
        name: "canonical_dispatch",
        components: [
          %{
            kind: :dispatch,
            name: "dispatch",
            decision: Add,
            expander: Add,
            params: %{value: 1, amount: 1}
          }
        ],
        output: Ref.result("dispatch")
      })

    assert Flow.validate(flow) == {:ok, flow}

    {expander, nil} = flow.components["dispatch"].expander

    invalid = put_in(flow.components["dispatch"].expander, {expander, %{bound: true}})
    assert_invalid_canonical(invalid)

    invalid =
      put_in(flow.components["dispatch"], Map.put(flow.components["dispatch"], :extra, true))

    assert_invalid_canonical(invalid)
  end

  test "canonical validation preserves valid artifacts and rejects value normalization" do
    flow = step_flow()

    assert Flow.validate(flow) == {:ok, flow}
    assert Flow.validate_executable(flow) == {:ok, flow}

    invalid_params = put_in(flow.components["step"].call, replace_params(flow, Ref.item()))
    assert_invalid_canonical(invalid_params)

    assert_invalid_canonical(%{flow | output: Ref.item()})

    non_canonical_ref = %{flow.output | component: :step}

    assert {:error,
            %InvalidDefinitionError{
              message: "Flow artifact contains non-canonical data",
              details: %{path: [:output], reason: :non_canonical}
            }} = Flow.validate(%{flow | output: non_canonical_ref})
  end

  test "canonical Iterate state errors use the state field path" do
    flow =
      Flow.new!(%{
        name: "canonical_state_paths",
        components: [
          %{
            kind: :iterate,
            name: "loop",
            action: Add,
            state: %{schema: [], initial: %{}, update: %{}},
            completion: true,
            max_iterations: 1
          }
        ],
        output: Ref.result("loop")
      })

    state = flow.components["loop"].state

    for {invalid_state, expected_path} <- [
          {Map.put(state, :extra, true), [:components, "loop", :state, :extra]},
          {Map.delete(state, :update), [:components, "loop", :state, :update]},
          {:invalid, [:components, "loop", :state]},
          {%{state | schema: :invalid}, [:components, "loop", :state, :schema]},
          {%{state | initial: Ref.item()}, [:components, "loop", :state, :initial]}
        ] do
      invalid = put_in(flow.components["loop"].state, invalid_state)

      assert {:error, %InvalidDefinitionError{details: %{path: ^expected_path}}} =
               Flow.validate(invalid)
    end
  end

  defp step_flow do
    Flow.new!(%{
      name: "canonical_step",
      components: [%{kind: :step, name: "step", action: Add}],
      output: Ref.result("step")
    })
  end

  defp replace_params(flow, params) do
    {template, _params} = flow.components["step"].call
    {template, params}
  end

  defp assert_invalid_canonical(flow) do
    for validate <- [&Flow.validate/1, &Flow.validate_executable/1] do
      assert {:error, %InvalidDefinitionError{}} = validate.(flow)
    end
  end
end
