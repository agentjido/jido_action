defmodule Jido.Integration.FlowParityTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Flow.Builder
  alias Jido.Flow.{ContractBundle, Iterator, Node, Ref}
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer

  alias JidoTest.TestActions.{
    Add,
    EchoParamsAction,
    ErrorAction,
    Multiply,
    RecorderAction
  }

  test "Spark, Syntax, Builder, and stored JSON preserve Step semantics" do
    module = create_step_flow_module("StepParity")

    syntax =
      Syntax.new(name: "step_parity")
      |> Syntax.step(:added, Add, %{value: Syntax.input(:value), amount: 1})
      |> Syntax.step(:doubled, Multiply, %{
        value: Syntax.select(Syntax.result(:added), [:value]),
        amount: 2
      })
      |> Syntax.return(Syntax.result(:doubled))

    builder =
      Builder.new(name: "step_parity")
      |> Builder.step(:added, Add, %{value: Builder.input(:value), amount: 1})
      |> Builder.step(:doubled, Multiply, %{
        value: Builder.select(Builder.result(:added), [:value]),
        amount: 2
      })
      |> Builder.return(Builder.result(:doubled))

    syntax_flow = lower_flow!(syntax)
    builder_flow = build_flow!(builder)
    stored_flow = stored_json_round_trip_flow!(syntax_flow)
    expected = Jido.Flow.to_map(syntax_flow)

    for flow <- [module.flow(), syntax_flow, builder_flow, stored_flow] do
      assert Jido.Flow.to_map(flow) == expected
      assert {:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3}, %{})
    end
  end

  test "Spark Choice preserves order and native condition syntax" do
    module = create_choice_flow_module("ChoiceParity")
    flow = module.flow()
    stored_flow = stored_json_round_trip_flow!(flow)

    assert [%{kind: :choice, options: [first, second]}] = Jido.Flow.to_map(flow).nodes
    assert first.name == "priority"
    assert second.name == "large"

    for candidate <- [flow, stored_flow] do
      assert {:ok, %{value: 4}} =
               Jido.Exec.run(candidate, %{kind: :priority, value: 3}, %{})

      assert {:ok, %{value: 6}} =
               Jido.Exec.run(candidate, %{kind: :standard, value: 3}, %{})
    end
  end

  test "Spark Map and Reduce preserve collection execution" do
    module = create_map_reduce_flow_module("MapReduceParity")
    flow = module.flow()
    stored_flow = stored_json_round_trip_flow!(flow)

    for candidate <- [flow, stored_flow], options <- [[], [async: true, max_concurrency: 2]] do
      assert {:ok, %{value: 12}} =
               Jido.Exec.run(
                 candidate,
                 %{items: [%{value: 1}, %{value: 2}, %{value: 3}]},
                 %{},
                 options
               )
    end
  end

  test "Spark Iterate preserves Iterator runtime behavior and default update" do
    module = create_iterate_flow_module("IterateParity")
    flow = module.flow()
    stored_flow = stored_json_round_trip_flow!(flow)

    assert [%Iterator{name: "count", state: %{update: %Ref{type: :body_result}}}] = flow.nodes

    for candidate <- [flow, stored_flow] do
      assert {:ok, %{kind: :jido_flow_iterate_result, iterations: 3, state: %{value: 4}}} =
               Jido.Exec.run(candidate, %{value: 1}, %{})
    end
  end

  test "public execution returns branch errors while independent roots still run" do
    flow =
      Jido.Flow.new!(
        name: "public_branch_failure",
        nodes: [
          Node.new!(
            name: :bad,
            action: ErrorAction,
            input: %{error_type: Ref.value(:validation)}
          ),
          Node.new!(
            name: :recorder,
            action: RecorderAction,
            input: %{value: Ref.input(:value)}
          ),
          Node.new!(
            name: :dependent,
            action: RecorderAction,
            input: %{from_bad: Ref.result(:bad)}
          )
        ],
        return: Ref.result(:recorder)
      )

    assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
             Jido.Exec.run(flow, %{value: 7}, %{test_pid: self()})

    assert details.phase == :step_execution
    assert details.node == "bad"
    assert_receive {RecorderAction, %{value: 7}}
    refute_receive {RecorderAction, %{from_bad: _}}
  end

  defp create_step_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow, name: "step_parity"

        flow do
          step("added",
            action: unquote(Add),
            params: %{value: input(:value), amount: 1}
          )

          step("doubled",
            action: unquote(Multiply),
            params: %{value: select(result("added"), [:value]), amount: 2}
          )
        end
      end
    )

    module
  end

  defp create_choice_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow, name: "choice_parity"

        flow do
          choice "route" do
            option "priority" do
              condition(input(:kind) == :priority)
              action(unquote(Add))
              params(%{value: input(:value), amount: 1})
            end

            option "large" do
              condition(input(:value) >= 100)
              action(unquote(Add))
              params(%{value: input(:value), amount: 10})
            end

            otherwise(
              action: unquote(Multiply),
              params: %{value: input(:value), amount: 2}
            )
          end
        end
      end
    )

    module
  end

  defp create_map_reduce_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow, name: "map_reduce_parity"

        flow do
          map("mapped",
            collection: input(:items),
            action: unquote(Multiply),
            params: %{value: item(:value), amount: 2}
          )

          reduce "total" do
            collection(result("mapped"))
            initial(%{value: 0})
            action(unquote(Add))
            params(%{value: accumulator(:value), amount: item(:value)})
          end
        end
      end
    )

    module
  end

  defp create_iterate_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow, name: "iterate_parity"

        flow do
          iterate "count" do
            state([], initial: %{value: input(:value)})
            action(unquote(Add))
            params(%{value: state(:value), amount: 1})
            repeat(3)
          end
        end
      end
    )

    module
  end

  defp lower_flow!(syntax) do
    assert {:ok, flow} = Lowerer.lower(syntax)
    flow
  end

  defp build_flow!(builder) do
    assert {:ok, flow} = Builder.build(builder)
    flow
  end

  defp stored_json_round_trip_flow!(flow) do
    namespace = "integration/#{System.unique_integer([:positive])}"
    references = contract_references(namespace)
    bundle = contract_bundle(flow, references)
    bundles = %{bundle.id => bundle}

    stored_opts = [
      format: :stored,
      contracts: references,
      contract_bundles: bundles,
      state_schema_ids: state_schema_ids(flow, namespace)
    ]

    decoded =
      flow
      |> Jido.Flow.to_map(stored_opts)
      |> JSON.encode!()
      |> JSON.decode!()

    assert {:ok, restored} = Jido.Flow.from_map(decoded, contract_bundles: bundles)
    restored
  end

  defp contract_references(namespace) do
    %{
      bundle: "#{namespace}/bundle/v1",
      input_schema: "#{namespace}/input/v1",
      output_schema: "#{namespace}/output/v1",
      action_registry: "#{namespace}/actions/v1"
    }
  end

  defp contract_bundle(flow, references) do
    state_schemas =
      Map.new(flow.nodes, fn
        %Iterator{} = iterator -> {"iterator/#{iterator.name}/state/v1", iterator.state.schema}
        node -> {"unused/#{node.name}", nil}
      end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    ContractBundle.new!(
      id: references.bundle,
      schemas:
        %{
          references.input_schema => flow.schema,
          references.output_schema => flow.output_schema
        }
        |> Map.merge(state_schemas),
      action_registries: %{
        references.action_registry => %{
          "add/v1" => Add,
          "multiply/v1" => Multiply,
          "echo/v1" => EchoParamsAction
        }
      }
    )
  end

  defp state_schema_ids(flow, _namespace) do
    Map.new(flow.nodes, fn
      %Iterator{} = iterator -> {iterator.name, "iterator/#{iterator.name}/state/v1"}
      node -> {node.name, nil}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
