defmodule JidoActionTest.Exec.InvocationReplayTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Dispatch, Iterate, Reduce, Ref, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Execution.InvocationChildFlow, as: ChildFlow
  alias JidoActionTest.Fixtures.Execution.InvocationChanged, as: Changed
  alias JidoActionTest.Fixtures.Execution.InvocationCountedFlow, as: CountedFlow
  alias JidoActionTest.Fixtures.Execution.InvocationFinal, as: Final
  alias JidoActionTest.Fixtures.Execution.InvocationHost, as: Host
  alias JidoActionTest.Fixtures.Execution.InvocationInvalidFlow, as: InvalidFlow
  alias JidoActionTest.Fixtures.Execution.InvocationProbe, as: Probe

  test "a root replay bypasses both validators and the Action callback" do
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{observer: self(), value: 7, effects: [:one, :two]}

    assert Exec.run(Probe, params, %{attempt: :fresh}, invocation: Host.config(store, self())) ==
             {:ok, %{value: 7}, [:one, :two]}

    assert_receive {:before_invoke, _fresh_invocation, fresh_worker}
    assert_receive {:action_phase, :input, ^fresh_worker}
    assert_receive {:action_phase, {:execution, :fresh}, ^fresh_worker}
    assert_receive {:action_phase, :output, ^fresh_worker}
    assert_receive {:after_invoke, receipt, ^fresh_worker}

    assert receipt.outcome == %{kind: :ok, output: %{value: 7}, effects: [:one, :two]}
    assert receipt.invocation.params == params
    refute Map.has_key?(receipt.invocation, :context)

    assert Exec.run(Probe, params, %{attempt: :replay},
             invocation: Host.config(store, self(), mode: :replay)
           ) == {:ok, %{value: 7}, [:one, :two]}

    assert_receive {:before_invoke, replayed, replay_worker}
    assert replayed.id == receipt.invocation.id
    refute replay_worker == fresh_worker
    refute_receive {:action_phase, _event, ^replay_worker}
    refute_receive {:after_invoke, _receipt, ^replay_worker}
  end

  test "success, envelopes, each error phase, and effects round-trip through receipts" do
    for mode <- [:success, :envelope, :input_error, :execution_error, :output_error] do
      store = start_supervised!({Agent, fn -> %{} end}, id: {Agent, mode})
      params = %{observer: self(), value: 11, mode: mode, effects: [:a, :b]}
      config = Host.config(store, self(), run_key: "outcome-#{mode}")

      fresh = Exec.run(Probe, params, %{attempt: :fresh}, invocation: config)
      receipt = only_receipt(store)
      flush_messages()

      replayed =
        Exec.run(Probe, params, %{attempt: :replay},
          invocation: Host.config(store, self(), mode: :replay, run_key: "outcome-#{mode}")
        )

      assert replayed == fresh
      assert_receive {:before_invoke, _descriptor, replay_worker}
      refute_receive {:action_phase, _phase, ^replay_worker}
      refute_receive {:after_invoke, _receipt, ^replay_worker}

      case mode do
        :success ->
          assert receipt.outcome == %{kind: :ok, output: %{value: 11}, effects: [:a, :b]}

        :envelope ->
          assert %{kind: :ok, output: %Output{value: 11}, effects: [:a, :b]} = receipt.outcome

        phase_mode ->
          expected_phase =
            %{input_error: :input, execution_error: :execution, output_error: :output}
            |> Map.fetch!(phase_mode)

          assert %{kind: :error, phase: ^expected_phase, error: error} = receipt.outcome
          assert is_exception(error)
      end
    end
  end

  test "an Instruction uses the root identity and Action evidence" do
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{observer: self(), value: 3}
    instruction = Instruction.new!(target: Probe, params: params, context: %{attempt: :fresh})

    assert Exec.run(instruction, %{}, %{}, invocation: Host.config(store, self())) ==
             {:ok, %{value: 3}}

    descriptor = only_receipt(store).invocation
    assert descriptor.id.component_path == []
    assert descriptor.id.role == :root_action
    assert descriptor.id.selector == nil

    assert descriptor.evidence == %{
             executable: %{kind: :action, form: :module, module: Probe},
             flow_semantic_digest: nil,
             compilation_digest: nil
           }
  end

  test "the host owns compatibility decisions for changed descriptor fields" do
    store = start_supervised!({Agent, fn -> %{} end})

    assert Exec.run(Probe, %{value: 4}, %{},
             invocation: Host.config(store, self(), run_key: "compat", compatibility: :historical)
           ) == {:ok, %{value: 4}}

    flush_messages()

    assert Exec.run(Changed, %{different: true}, %{observer: self()},
             invocation:
               Host.config(store, self(),
                 mode: :replay,
                 run_key: "compat",
                 compatibility: :current
               )
           ) == {:ok, %{value: 4}}

    refute_receive {:changed_action_ran, _worker}
    assert_receive {:before_invoke, current, _worker}
    assert current.action == Changed
    assert current.params == %{different: true}
    assert current.compatibility == :current
    assert current.evidence.executable.module == Changed

    assert Exec.run(Changed, %{different: true}, %{observer: self()},
             invocation: Host.config(store, self(), run_key: "compat")
           ) == {:ok, %{changed: true, different: true}}

    assert_receive {:changed_action_ran, _worker}
  end

  test "continuation replay increments the chain and rebuilds current context" do
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{mode: :continue, observer: self(), target: Final, value: 5}
    config = Host.config(store, self(), run_key: "continuation")

    assert Exec.run(Probe, params, %{attempt: :old}, invocation: config) == {:ok, %{value: 5}}

    receipts = Host.receipts(store)
    assert Enum.sort(Enum.map(Map.keys(receipts), & &1.chain_index)) == [0, 1]
    root_id = Enum.find(Map.keys(receipts), &(&1.chain_index == 0))
    Agent.update(store, &Map.take(&1, [root_id]))
    flush_messages()

    assert Exec.run(Probe, params, %{attempt: :new},
             timeout: 5_000,
             invocation: Host.config(store, self(), mode: :replay, run_key: "continuation")
           ) == {:ok, %{value: 5}}

    assert_receive {:final_action, context, _worker}
    assert context.attempt == :new
    assert is_integer(Exec.remaining_time(context))

    ids = store |> Host.receipts() |> Map.keys()
    assert Enum.sort(Enum.map(ids, & &1.chain_index)) == [0, 1]
  end

  test "replayed continuations keep invalid target and Flow position rules" do
    for {name, target, run} <- [
          {"invalid-target", :not_an_executable,
           fn config ->
             Exec.run(Probe, %{mode: :continue, target: :not_an_executable, value: 1}, %{},
               invocation: config
             )
           end},
          {"invalid-flow", InvalidFlow,
           fn config ->
             Exec.run(Probe, %{mode: :continue, target: InvalidFlow, value: 1}, %{},
               invocation: config
             )
           end},
          {"step-position", Final,
           fn config ->
             flow =
               Flow.new!(
                 name: "disallowed_step_continuation",
                 components: [
                   Step.new!(
                     name: "work",
                     action: Probe,
                     params: %{mode: :continue, target: Final, value: 1}
                   )
                 ],
                 output: Ref.result("work")
               )

             Exec.run(flow, %{}, %{}, invocation: config)
           end}
        ] do
      store = start_supervised!({Agent, fn -> %{} end}, id: {Agent, name})
      fresh = run.(Host.config(store, self(), run_key: name))
      assert {:error, fresh_error} = fresh

      expected_message =
        cond do
          target == Final -> "not allowed"
          target == InvalidFlow -> "must return"
          true -> "invalid"
        end

      assert Exception.message(fresh_error) =~ expected_message

      flush_messages()

      replayed = run.(Host.config(store, self(), mode: :replay, run_key: name))
      assert {:error, replay_error} = replayed
      assert Exception.message(replay_error) == Exception.message(fresh_error)
    end
  end

  test "an Action-to-Flow continuation uses the next chain index" do
    counter = start_supervised!({Agent, fn -> 0 end}, id: CountedFlow)
    Process.register(counter, CountedFlow)
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{mode: :continue, observer: self(), target: CountedFlow, value: 6}

    assert Exec.run(Probe, params, %{observer: self()},
             invocation: Host.config(store, self(), run_key: "action-flow")
           ) == {:ok, %{value: 6}}

    ids = store |> Host.receipts() |> Map.keys()

    assert Enum.sort(Enum.map(ids, &{&1.chain_index, &1.component_path, &1.role})) == [
             {0, [], :root_action},
             {1, ["work"], :step}
           ]

    assert Agent.get(counter, & &1) == 1
  end

  test "Flow identities cover every Action position and structural Subflows" do
    assert ids_for(step_flow(), "step") == [
             {0, ["work"], :step, nil}
           ]

    assert ids_for(choice_flow(), "choice") == [
             {0, ["route"], :choice, %{kind: :option, name: "selected"}}
           ]

    assert ids_for(fallback_flow(), "fallback") == [
             {0, ["route"], :choice, %{kind: :fallback}}
           ]

    assert ids_for(map_flow(), "map") == [
             {0, ["items"], :map, %{index: 0}},
             {0, ["items"], :map, %{index: 1}}
           ]

    assert ids_for(reduce_flow(), "reduce") == [
             {0, ["items"], :reduce, %{index: 0}},
             {0, ["items"], :reduce, %{index: 1}}
           ]

    assert ids_for(iterate_flow(), "iterate") == [
             {0, ["loop"], :iterate, %{index: 0}},
             {0, ["loop"], :iterate, %{index: 1}}
           ]

    assert ids_for(subflow(), "subflow") == [
             {0, ["child", "inside"], :step, nil}
           ]

    assert ids_for(dispatch_flow(), "dispatch") == [
             {0, ["dispatch"], :dispatch, %{phase: :decision}},
             {0, ["dispatch"], :dispatch, %{phase: :expander}}
           ]
  end

  test "Flow evidence uses the prepared compilation and flow/0 runs once" do
    counter = start_supervised!({Agent, fn -> 0 end}, id: CountedFlow)
    Process.register(counter, CountedFlow)
    store = start_supervised!({Agent, fn -> %{} end})

    assert Exec.run(CountedFlow, %{value: 8}, %{observer: self()},
             invocation: Host.config(store, self(), run_key: "counted")
           ) == {:ok, %{value: 8}}

    assert Agent.get(counter, & &1) == 1
    evidence = only_receipt(store).invocation.evidence
    assert evidence.executable == %{kind: :flow, form: :module, module: CountedFlow}
    assert is_binary(evidence.flow_semantic_digest)
    assert is_binary(evidence.compilation_digest)
  end

  test "the host can accept changed Flow evidence at the same occurrence key" do
    store = start_supervised!({Agent, fn -> %{} end})

    historical =
      Flow.new!(
        name: "historical_flow_evidence",
        components: [Step.new!(name: "work", action: Probe, params: %{value: 1})],
        output: Ref.result("work")
      )

    current =
      Flow.new!(
        name: "current_flow_evidence",
        components: [Step.new!(name: "work", action: Changed, params: %{different: true})],
        output: Ref.result("work")
      )

    config = Host.config(store, self(), run_key: "flow-evidence")
    assert Exec.run(historical, %{}, %{}, invocation: config) == {:ok, %{value: 1}}
    old = only_receipt(store).invocation
    flush_messages()

    assert Exec.run(current, %{}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: "flow-evidence")
           ) == {:ok, %{value: 1}}

    assert_receive {:before_invoke, descriptor, _worker}
    assert descriptor.action == Changed
    assert descriptor.params == %{different: true}
    assert descriptor.evidence.executable == %{kind: :flow, form: :value, module: nil}
    refute descriptor.evidence == old.evidence
    refute_receive {:changed_action_ran, _worker}
  end

  test "an empty Flow has no invocation callbacks" do
    store = start_supervised!({Agent, fn -> %{} end})

    flow =
      Flow.new!(
        name: "empty_invocation_flow",
        components: [
          FlowMap.new!(name: "empty", collection: [], action: Probe, params: %{})
        ],
        output: %{items: Ref.result("empty"), value: Ref.input(:value)}
      )

    assert Exec.run(flow, %{value: 2}, %{}, invocation: Host.config(store, self())) ==
             {:ok, %{items: [], value: 2}}

    assert Host.receipts(store) == %{}
    refute_receive {:before_invoke, _descriptor, _worker}
    refute_receive {:after_invoke, _receipt, _worker}
  end

  test "a fresh result waits for host receipt acceptance" do
    store = start_supervised!({Agent, fn -> %{} end})

    handle =
      Exec.run_async(Probe, %{observer: self(), value: 9}, %{},
        invocation: Host.config(store, self(), gate_after: true)
      )

    assert_receive {:after_invoke, receipt, worker}
    refute_receive {:jido_exec_async_result, _, _, _}
    send(worker, {:accept_receipt, receipt.invocation.id})
    assert Exec.await(handle) == {:ok, %{value: 9}}
  end

  defp only_receipt(store) do
    assert [receipt] = store |> Host.receipts() |> Map.values()
    receipt
  end

  defp ids_for(flow, run_key) do
    store = start_supervised!({Agent, fn -> %{} end}, id: {Agent, run_key})

    assert {:ok, output} =
             Exec.run(flow, %{}, %{observer: self()},
               invocation: Host.config(store, self(), run_key: run_key)
             )

    flush_messages()

    assert Exec.run(flow, %{}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: run_key)
           ) == {:ok, output}

    flush_messages()

    store
    |> Host.receipts()
    |> Map.keys()
    |> Enum.map(&{&1.chain_index, &1.component_path, &1.role, &1.selector})
    |> Enum.sort()
  end

  defp step_flow do
    Flow.new!(
      name: "invocation_step",
      components: [
        Step.new!(
          name: "work",
          action: Probe,
          params: %{observer: Ref.context(:observer), value: 1}
        )
      ],
      output: Ref.result("work")
    )
  end

  defp choice_flow do
    Flow.new!(
      name: "invocation_choice",
      components: [
        Choice.new!(
          name: "route",
          options: [
            [name: "selected", condition: true, action: Probe, params: %{value: 1}]
          ],
          fallback: [action: Probe, params: %{value: 2}]
        )
      ],
      output: Ref.result("route")
    )
  end

  defp fallback_flow do
    Flow.new!(
      name: "invocation_fallback",
      components: [
        Choice.new!(
          name: "route",
          options: [
            [name: "not-selected", condition: false, action: Probe, params: %{value: 1}]
          ],
          fallback: [action: Probe, params: %{value: 2}]
        )
      ],
      output: Ref.result("route")
    )
  end

  defp map_flow do
    Flow.new!(
      name: "invocation_map",
      components: [
        FlowMap.new!(
          name: "items",
          collection: [1, 2],
          action: Probe,
          params: %{value: Ref.item()}
        )
      ],
      output: %{items: Ref.result("items")}
    )
  end

  defp reduce_flow do
    Flow.new!(
      name: "invocation_reduce",
      components: [
        Reduce.new!(
          name: "items",
          collection: [1, 2],
          initial: %{},
          action: Probe,
          params: %{value: Ref.item()}
        )
      ],
      output: %{result: Ref.result("items")}
    )
  end

  defp iterate_flow do
    Flow.new!(
      name: "invocation_iterate",
      components: [
        Iterate.new!(
          name: "loop",
          action: Probe,
          params: %{value: Ref.iteration_index()},
          state: Iterate.State.new!(initial: %{}, update: %{}),
          completion: Jido.Expr.new!(:gte, [Ref.iteration_index(), 2]),
          max_iterations: 2
        )
      ],
      output: Ref.result("loop")
    )
  end

  defp subflow do
    Flow.new!(
      name: "invocation_parent",
      components: [Subflow.new!(name: "child", flow: ChildFlow, params: %{})],
      output: Ref.result("child")
    )
  end

  defp dispatch_flow do
    Flow.new!(
      name: "invocation_dispatch",
      components: [
        Dispatch.new!(
          name: "dispatch",
          decision: Probe,
          expander: Probe,
          params: %{value: 1}
        )
      ],
      output: Ref.result("dispatch")
    )
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end
