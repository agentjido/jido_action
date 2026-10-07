defmodule JidoActionTest.Exec.InvocationReplayTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow.{Ref}
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Execution.InvocationChildFlow, as: ChildFlow
  alias JidoActionTest.Fixtures.Execution.InvocationChanged, as: Changed
  alias JidoActionTest.Fixtures.Execution.InvocationCountedFlow, as: CountedFlow
  alias JidoActionTest.Fixtures.Execution.InvocationDispatchDecision, as: DispatchDecision
  alias JidoActionTest.Fixtures.Execution.InvocationDispatchExpander, as: DispatchExpander
  alias JidoActionTest.Fixtures.Execution.InvocationFinal, as: Final
  alias JidoActionTest.Fixtures.Execution.InvocationFold, as: Fold
  alias JidoActionTest.Fixtures.Execution.InvocationHost, as: Host
  alias JidoActionTest.Fixtures.Execution.InvocationInvalidFlow, as: InvalidFlow
  alias JidoActionTest.Fixtures.Execution.InvocationLazyOutput, as: LazyOutput
  alias JidoActionTest.Fixtures.Execution.InvocationLoop, as: Loop
  alias JidoActionTest.Fixtures.Execution.InvocationProbe, as: Probe

  defmodule RepeatedCollectionChild do
    @behaviour Jido.Flow

    def flow do
      JidoActionTest.FlowBuilder.new!(
        name: "repeated_collection_child",
        components: [
          JidoActionTest.FlowComponent.map!(
            name: "items",
            collection: [1],
            action: Probe,
            params: %{value: Ref.item()}
          )
        ],
        output: %{items: Ref.result("items")}
      )
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Exec.run(__MODULE__, params, context)
  end

  defmodule ValidatedIterateFlow do
    @behaviour Jido.Flow

    def flow do
      schema = Zoi.map() |> Zoi.transform({Loop, :state_transform, []})

      JidoActionTest.FlowBuilder.new!(
        name: "validated_invocation_iterate",
        components: [
          JidoActionTest.FlowComponent.iterate!(
            name: "loop",
            action: Loop,
            params: %{
              observer: Ref.context(:observer),
              index: Ref.iteration_index(),
              state: Ref.state()
            },
            state:
              JidoActionTest.FlowComponent.state!(
                schema: schema,
                initial: %{count: 0},
                update: %{count: Ref.body_result(:count)}
              ),
            completion: Jido.Expr.new!(:>=, [Ref.state(:count), 3]),
            max_iterations: 3
          )
        ],
        output: Ref.result("loop")
      )
    end

    def validate_params(params) do
      Loop.record({:flow_validate_params, params})
      {:ok, params}
    end

    def validate_output(output) do
      Loop.record({:flow_validate_output, output})
      {:ok, output}
    end

    def run(params, context), do: Exec.run(__MODULE__, params, context)
  end

  defmodule FailingAction do
    use Jido.Action, name: "invocation_later_failure"

    @impl true
    def run(_params, _context), do: {:error, Jido.Action.Error.execution_error("later failure")}
  end

  defmodule UnselectedAction do
    use Jido.Action, name: "invocation_unselected"

    @impl true
    def run(_params, context) do
      send(context.observer, {:unselected_action_ran, self()})
      {:ok, %{value: :wrong}}
    end
  end

  defmodule InlineReplayFlow do
    use Jido.Flow, name: "invocation_inline_replay"

    flow do
      step "inline", [owner <- context(:observer), value <- input(:value)] do
        send(owner, {:inline_body, value, self()})
        {:ok, %{value: value}}
      end

      output result("inline")
    end
  end

  defmodule ListParamsProbe do
    @behaviour Jido.Action

    @impl true
    def validate_params([observer, value]) do
      send(observer, {:list_params_phase, :input, self()})
      {:ok, %{observer: observer, value: value}}
    end

    @impl true
    def run(%{observer: observer, value: value}, _context) do
      send(observer, {:list_params_phase, :execution, self()})
      {:ok, %{observer: observer, value: value}}
    end

    @impl true
    def validate_output(%{observer: observer} = output) do
      send(observer, {:list_params_phase, :output, self()})
      {:ok, Map.delete(output, :observer)}
    end
  end

  defmodule ValidatedEmptyFlow do
    @behaviour Jido.Flow

    def flow do
      JidoActionTest.FlowBuilder.new!(
        name: "validated_empty_invocation_flow",
        components: [
          JidoActionTest.FlowComponent.map!(
            name: "empty",
            collection: [],
            action: Probe,
            params: %{}
          )
        ],
        output: %{items: Ref.result("empty"), value: Ref.input(:value)}
      )
    end

    def validate_params(params) do
      Loop.record({:empty_flow_validate_params, params})
      {:ok, params}
    end

    def validate_output(output) do
      Loop.record({:empty_flow_validate_output, output})
      {:ok, output}
    end

    def run(params, context), do: Exec.run(__MODULE__, params, context)
  end

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

  test "P4 reuses an accepted receipt after the first caller loses its result" do
    store = start_supervised!({Agent, fn -> %{} end})
    owner = self()
    token = make_ref()
    params = %{observer: owner, value: 13}

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        {:ok, %{value: 13}} =
          Exec.run(Probe, params, %{attempt: :lost},
            invocation: Host.config(store, owner, run_key: "lost-result")
          )

        send(owner, {token, :result_ready, self()})

        receive do
          {^token, :discard_result} -> :ok
        end
      end)

    assert_receive {^token, :result_ready, ^caller}
    assert map_size(Host.receipts(store)) == 1

    assert_receive {:before_invoke, _descriptor, fresh_worker}
    assert_receive {:action_phase, :input, ^fresh_worker}
    assert_receive {:action_phase, {:execution, :lost}, ^fresh_worker}
    assert_receive {:action_phase, :output, ^fresh_worker}
    assert_receive {:after_invoke, receipt, ^fresh_worker}

    send(caller, {token, :discard_result})
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}

    assert Exec.run(Probe, params, %{attempt: :replay},
             invocation: Host.config(store, self(), mode: :replay, run_key: "lost-result")
           ) == {:ok, %{value: 13}}

    assert_receive {:before_invoke, replayed, replay_worker}
    assert replayed.id == receipt.invocation.id
    refute_receive {:action_phase, _phase, ^replay_worker}
    refute_receive {:after_invoke, _receipt, ^replay_worker}
  end

  test "a Flow replays an Action receipt with resolved list parameters" do
    store = start_supervised!({Agent, fn -> %{} end})

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "list_params_replay",
        components: [
          JidoActionTest.FlowComponent.step!(
            name: "list",
            action: ListParamsProbe,
            params: [Ref.context(:observer), Ref.input(:value)]
          )
        ],
        output: Ref.result("list")
      )

    config = Host.config(store, self(), run_key: "list-params")

    assert Exec.run(flow, %{value: 7}, %{observer: self()}, invocation: config) ==
             {:ok, %{value: 7}}

    assert_receive {:before_invoke, _fresh_invocation, fresh_worker}
    assert_receive {:list_params_phase, :input, ^fresh_worker}
    assert_receive {:list_params_phase, :execution, ^fresh_worker}
    assert_receive {:list_params_phase, :output, ^fresh_worker}
    assert_receive {:after_invoke, receipt, ^fresh_worker}
    assert receipt.invocation.params == [self(), 7]

    assert Exec.run(flow, %{value: 7}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: "list-params")
           ) == {:ok, %{value: 7}}

    assert_receive {:before_invoke, _replayed_invocation, replay_worker}
    refute replay_worker == fresh_worker
    refute_receive {:list_params_phase, _phase, ^replay_worker}
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

  test "P6 replays an Instruction without repeating its Action boundary" do
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{observer: self(), value: 21, effects: [:instruction_effect]}
    instruction = Instruction.new!(target: Probe, params: params, context: %{attempt: :fresh})
    config = Host.config(store, self(), run_key: "instruction-replay")
    expected = {:ok, %{value: 21}, [:instruction_effect]}

    assert Exec.run(instruction, %{}, %{}, invocation: config) == expected

    assert_receive {:before_invoke, %{id: %{role: :root_action}}, fresh_worker}
    assert_receive {:action_phase, :input, ^fresh_worker}
    assert_receive {:action_phase, {:execution, :fresh}, ^fresh_worker}
    assert_receive {:action_phase, :output, ^fresh_worker}
    assert_receive {:after_invoke, _receipt, ^fresh_worker}

    assert Exec.run(instruction, %{}, %{},
             invocation: Host.config(store, self(), mode: :replay, run_key: "instruction-replay")
           ) == expected

    assert_receive {:before_invoke, %{id: %{role: :root_action}}, replay_worker}
    refute replay_worker == fresh_worker
    refute_receive {:action_phase, _phase, ^replay_worker}
    refute_receive {:after_invoke, _receipt, ^replay_worker}
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

  test "P15 replays a root continuation into a nonempty Flow at chain index one" do
    store = start_supervised!({Agent, fn -> %{} end})
    params = %{mode: :continue, observer: self(), target: CountedFlow, value: 34}
    run_key = "replayed-flow-continuation"

    assert Exec.run(Probe, params, %{observer: self()},
             max_continuations: 1,
             invocation: Host.config(store, self(), run_key: run_key)
           ) == {:ok, %{value: 34}}

    receipts = Host.receipts(store)
    root_id = Enum.find(Map.keys(receipts), &(&1.chain_index == 0))
    root_receipt = Map.fetch!(receipts, root_id)
    Agent.update(store, fn _receipts -> %{root_id => root_receipt} end)
    flush_messages()

    assert Exec.run(Probe, params, %{observer: self()},
             max_continuations: 1,
             invocation: Host.config(store, self(), mode: :replay, run_key: run_key)
           ) == {:ok, %{value: 34}}

    assert_receive {:before_invoke, %{id: %{chain_index: 0}}, root_worker}
    refute_receive {:action_phase, _phase, ^root_worker}

    assert_receive {:before_invoke, %{id: %{chain_index: 1, component_path: ["work"]}},
                    flow_worker}

    assert_receive {:action_phase, :input, ^flow_worker}
    assert_receive {:action_phase, {:execution, nil}, ^flow_worker}
    assert_receive {:action_phase, :output, ^flow_worker}
    assert_receive {:after_invoke, %{invocation: %{id: %{chain_index: 1}}}, ^flow_worker}

    Agent.update(store, fn _receipts -> %{root_id => root_receipt} end)
    flush_messages()

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{
              message: "continuation limit exceeded",
              details: %{count: 1, max_continuations: 0}
            }} =
             Exec.run(Probe, params, %{observer: self()},
               max_continuations: 0,
               invocation: Host.config(store, self(), mode: :replay, run_key: run_key)
             )

    assert_receive {:before_invoke, %{id: %{chain_index: 0}}, limited_worker}
    refute_receive {:before_invoke, %{id: %{chain_index: 1}}, _worker}
    refute_receive {:action_phase, _phase, ^limited_worker}
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
               JidoActionTest.FlowBuilder.new!(
                 name: "disallowed_step_continuation",
                 components: [
                   JidoActionTest.FlowComponent.step!(
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
      JidoActionTest.FlowBuilder.new!(
        name: "historical_flow_evidence",
        components: [
          JidoActionTest.FlowComponent.step!(name: "work", action: Probe, params: %{value: 1})
        ],
        output: Ref.result("work")
      )

    current =
      JidoActionTest.FlowBuilder.new!(
        name: "current_flow_evidence",
        components: [
          JidoActionTest.FlowComponent.step!(
            name: "work",
            action: Changed,
            params: %{different: true}
          )
        ],
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
      JidoActionTest.FlowBuilder.new!(
        name: "empty_invocation_flow",
        components: [
          JidoActionTest.FlowComponent.map!(
            name: "empty",
            collection: [],
            action: Probe,
            params: %{}
          )
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

  test "Step and inline Step receipts suppress their Action bodies" do
    explicit = step_flow()

    for {name, flow, body_message} <- [
          {"explicit-step", explicit, :action_phase},
          {"inline-step", InlineReplayFlow, :inline_body}
        ] do
      store = start_supervised!({Agent, fn -> %{} end}, id: {Agent, name})
      input = if name == "inline-step", do: %{value: 12}, else: %{}
      context = %{observer: self()}
      config = Host.config(store, self(), run_key: name)

      assert {:ok, output} = Exec.run(flow, input, context, invocation: config)
      assert map_size(Host.receipts(store)) == 1
      flush_messages()

      assert Exec.run(flow, input, context,
               invocation: Host.config(store, self(), mode: :replay, run_key: name)
             ) == {:ok, output}

      assert_receive {:before_invoke, %{id: %{role: :step}}, replay_worker}

      case body_message do
        :action_phase -> refute_receive {:action_phase, _phase, ^replay_worker}
        :inline_body -> refute_receive {:inline_body, _value, ^replay_worker}
      end

      refute_receive {:after_invoke, _receipt, ^replay_worker}
    end
  end

  test "Choice branch and fallback receipts never run unselected Actions" do
    for {name, option_condition, expected_selector, expected_value} <- [
          {"choice-branch", true, %{kind: :option, name: "selected"}, 1},
          {"choice-fallback", false, %{kind: :fallback}, 2}
        ] do
      store = start_supervised!({Agent, fn -> %{} end}, id: {Agent, name})

      flow =
        JidoActionTest.FlowBuilder.new!(
          name: name,
          components: [
            JidoActionTest.FlowComponent.choice!(
              name: "route",
              options: [
                [
                  name: "selected",
                  condition: option_condition,
                  action: if(option_condition, do: Probe, else: UnselectedAction),
                  params: %{observer: Ref.context(:observer), value: 1}
                ]
              ],
              fallback: [
                action: if(option_condition, do: UnselectedAction, else: Probe),
                params: %{observer: Ref.context(:observer), value: 2}
              ]
            )
          ],
          output: Ref.result("route")
        )

      config = Host.config(store, self(), run_key: name)

      assert Exec.run(flow, %{}, %{observer: self()}, invocation: config) ==
               {:ok, %{value: expected_value}}

      assert only_receipt(store).invocation.id.selector == expected_selector
      flush_messages()

      assert Exec.run(flow, %{}, %{observer: self()},
               invocation: Host.config(store, self(), mode: :replay, run_key: name)
             ) == {:ok, %{value: expected_value}}

      assert_receive {:before_invoke, %{id: %{selector: ^expected_selector}}, replay_worker}
      refute_receive {:unselected_action_ran, _worker}
      refute_receive {:action_phase, _phase, ^replay_worker}
      refute_receive {:after_invoke, _receipt, ^replay_worker}
    end
  end

  test "P10 replays a collected Map business error without repeated Action work" do
    store = start_supervised!({Agent, fn -> %{} end})

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "invocation_map_business_error",
        components: [
          JidoActionTest.FlowComponent.map!(
            name: "items",
            collection: [8],
            action: Probe,
            params: %{
              observer: Ref.context(:observer),
              value: Ref.item(),
              mode: :execution_error
            },
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("items")}
      )

    config = Host.config(store, self(), run_key: "map-business-error")

    assert {:ok, %{items: [%{status: :error, error: first_error}]} = first_output} =
             Exec.run(flow, %{}, %{observer: self()}, invocation: config)

    assert %{message: "execution rejected"} = first_error
    assert_receive {:before_invoke, %{id: %{role: :map}}, fresh_worker}
    assert_receive {:action_phase, :input, ^fresh_worker}
    assert_receive {:action_phase, {:execution, nil}, ^fresh_worker}
    assert_receive {:after_invoke, %{outcome: %{kind: :error}}, ^fresh_worker}

    assert Exec.run(flow, %{}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: "map-business-error")
           ) == {:ok, first_output}

    assert_receive {:before_invoke, %{id: %{role: :map}}, replay_worker}
    refute replay_worker == fresh_worker
    refute_receive {:action_phase, _phase, ^replay_worker}
    refute_receive {:after_invoke, _receipt, ^replay_worker}
  end

  test "Reduce rebuilds its accumulator from a prefix of keyed receipts" do
    store = start_supervised!({Agent, fn -> %{} end})
    flow = replay_reduce_flow()
    config = Host.config(store, self(), run_key: "reduce-prefix")

    expected =
      {:ok, %{result: %{values: [:a, :b, :c, :d]}},
       [{:fold_effect, 0}, {:fold_effect, 1}, {:fold_effect, 2}, {:fold_effect, 3}]}

    assert Exec.run(flow, %{}, %{observer: self()}, invocation: config) == expected
    receipts = Host.receipts(store)

    prefix =
      receipts
      |> Enum.filter(fn {id, _receipt} -> id.selector.index < 2 end)
      |> Map.new()

    Agent.update(store, fn _receipts -> prefix end)
    flush_messages()

    assert Exec.run(flow, %{}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: "reduce-prefix")
           ) == expected

    refute_receive {:fold_body, 0, _values, _worker}
    refute_receive {:fold_body, 1, _values, _worker}
    assert_receive {:fold_body, 2, [:a, :b], _worker}
    assert_receive {:fold_body, 3, [:a, :b, :c], _worker}
  end

  test "Iterate rebuilds state, count, completion, effects, and Flow validation" do
    recorder = start_supervised!({Agent, fn -> [] end}, id: :iterate_recorder)
    Process.register(recorder, Loop)
    store = start_supervised!({Agent, fn -> %{} end}, id: :iterate_store)
    config = Host.config(store, self(), run_key: "iterate-prefix")

    expected =
      {:ok,
       %{
         kind: :jido_flow_iterate_result,
         iterations: 3,
         state: %{count: 3},
         output: %{count: 3, index: 2}
       }, [{:loop_effect, 0}, {:loop_effect, 1}, {:loop_effect, 2}]}

    assert Exec.run(ValidatedIterateFlow, %{}, %{observer: self()}, invocation: config) ==
             expected

    receipts = Host.receipts(store)

    prefix =
      receipts
      |> Enum.filter(fn {id, _receipt} -> id.selector.index < 2 end)
      |> Map.new()

    Agent.update(store, fn _receipts -> prefix end)
    Agent.update(recorder, fn _events -> [] end)
    flush_messages()

    assert Exec.run(ValidatedIterateFlow, %{}, %{observer: self()},
             invocation: Host.config(store, self(), mode: :replay, run_key: "iterate-prefix")
           ) == expected

    for index <- [0, 1] do
      refute_receive {:loop_action, _phase, ^index, _worker}
    end

    assert_receive {:loop_action, :input, 2, iteration_worker}
    assert_receive {:loop_action, :execution, 2, ^iteration_worker}
    assert_receive {:loop_action, :output, 2, ^iteration_worker}

    events = recorder |> Agent.get(&Enum.reverse/1)

    assert Enum.count(events, &match?({:loop_state_transform, _value}, &1)) == 4
    assert Enum.count(events, &match?({:flow_validate_params, %{}}, &1)) == 1

    assert Enum.count(
             events,
             &match?({:flow_validate_output, %{iterations: 3, state: %{count: 3}}}, &1)
           ) == 1
  end

  test "the same child Flow at two paths has distinct invocation keys" do
    store = start_supervised!({Agent, fn -> %{} end})

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "repeated_child_parent",
        components: [
          JidoActionTest.FlowComponent.subflow!(
            name: "left",
            flow: RepeatedCollectionChild,
            params: %{}
          ),
          JidoActionTest.FlowComponent.subflow!(
            name: "right",
            flow: RepeatedCollectionChild,
            params: %{}
          )
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    expected =
      {:ok, %{left: %{items: [%{value: 1}]}, right: %{items: [%{value: 1}]}}}

    config = Host.config(store, self(), run_key: "repeated-child")
    assert Exec.run(flow, %{}, %{}, invocation: config) == expected

    ids = store |> Host.receipts() |> Map.keys()
    assert Enum.map(ids, & &1.selector) |> Enum.uniq() == [%{index: 0}]

    assert Enum.map(ids, & &1.component_path) |> Enum.sort() == [
             ["left", "items"],
             ["right", "items"]
           ]

    flush_messages()

    assert Exec.run(flow, %{}, %{},
             invocation: Host.config(store, self(), mode: :replay, run_key: "repeated-child")
           ) == expected

    refute_receive {:action_phase, _phase, _worker}
  end

  test "Dispatch decision and expander receipts replay independently" do
    original_store = start_supervised!({Agent, fn -> %{} end}, id: :dispatch_original)
    flow = replay_dispatch_flow(false)
    expected = {:ok, %{value: 4}, [:decision_effect, :expander_effect]}

    assert Exec.run(flow, %{}, %{observer: self()},
             invocation: Host.config(original_store, self(), run_key: "dispatch-independent")
           ) == expected

    receipts = Host.receipts(original_store)
    decision = receipt_for_phase(receipts, :decision)
    expander = receipt_for_phase(receipts, :expander)

    for {phase, kept, expected_body} <- [
          {:decision, decision, :expander},
          {:expander, expander, :decision}
        ] do
      store = start_supervised!({Agent, fn -> %{kept.invocation.id => kept} end}, id: phase)
      flush_messages()

      assert Exec.run(flow, %{}, %{observer: self()},
               invocation:
                 Host.config(store, self(), mode: :replay, run_key: "dispatch-independent")
             ) == expected

      assert_receive {:dispatch_body, ^expected_body, _worker}
      refute_receive {:dispatch_body, ^phase, _worker}
    end

    continuation_store = start_supervised!({Agent, fn -> %{} end}, id: :dispatch_continuation)
    continuation = replay_dispatch_flow(true)

    assert Exec.run(continuation, %{}, %{observer: self()},
             invocation: Host.config(continuation_store, self(), run_key: "dispatch-terminal")
           ) == {:ok, %{value: 4}, [:decision_effect]}

    flush_messages()

    assert Exec.run(continuation, %{}, %{observer: self()},
             invocation:
               Host.config(continuation_store, self(),
                 mode: :replay,
                 run_key: "dispatch-terminal"
               )
           ) == {:ok, %{value: 4}, [:decision_effect]}

    refute_receive {:dispatch_body, _phase, _worker}
  end

  test "a replayed Action continuation can rebuild an empty Flow" do
    recorder = start_supervised!({Agent, fn -> [] end}, id: :empty_continuation_recorder)
    Process.register(recorder, Loop)
    store = start_supervised!({Agent, fn -> %{} end}, id: :empty_continuation_store)
    params = %{mode: :continue, observer: self(), target: ValidatedEmptyFlow, value: 15}
    config = Host.config(store, self(), run_key: "empty-continuation")

    assert Exec.run(Probe, params, %{attempt: :first}, invocation: config) ==
             {:ok, %{items: [], value: 15}}

    assert map_size(Host.receipts(store)) == 1
    Agent.update(recorder, fn _events -> [] end)
    flush_messages()

    assert Exec.run(Probe, params, %{attempt: :second},
             invocation: Host.config(store, self(), mode: :replay, run_key: "empty-continuation")
           ) == {:ok, %{items: [], value: 15}}

    assert_receive {:before_invoke, %{id: %{chain_index: 0}}, replay_worker}
    refute_receive {:action_phase, _phase, ^replay_worker}

    events = recorder |> Agent.get(&Enum.reverse/1)

    assert [{:empty_flow_validate_params, %{value: 15}}, {:empty_flow_validate_output, output}] =
             events

    assert output == %{items: [], value: 15}
  end

  test "the host may reject changed compatibility evidence" do
    store = start_supervised!({Agent, fn -> %{} end})

    assert Exec.run(Probe, %{value: 4}, %{},
             invocation: Host.config(store, self(), run_key: "compat-reject")
           ) == {:ok, %{value: 4}}

    flush_messages()

    assert {:error,
            %Jido.Exec.Error.InterruptedError{
              details: %{stage: :before_invoke, reason: :compatibility_rejected}
            }} =
             Exec.run(Changed, %{different: true}, %{observer: self()},
               invocation:
                 Host.config(store, self(),
                   mode: :reject_existing,
                   run_key: "compat-reject",
                   compatibility: :changed
                 )
             )

    refute_receive {:changed_action_ran, _worker}
  end

  test "a replayed success effect batch does not escape after a later failure" do
    store = start_supervised!({Agent, fn -> %{} end})
    flow = effect_then_failure_flow()
    config = Host.config(store, self(), run_key: "effect-then-failure")

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "later failure"}} =
             Exec.run(flow, %{}, %{observer: self()}, invocation: config)

    first_id =
      store
      |> Host.receipts()
      |> Map.keys()
      |> Enum.find(&(&1.component_path == ["first"]))

    Agent.update(store, &Map.take(&1, [first_id]))
    flush_messages()

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "later failure"}} =
             Exec.run(flow, %{}, %{observer: self()},
               invocation:
                 Host.config(store, self(), mode: :replay, run_key: "effect-then-failure")
             )

    assert_receive {:before_invoke, %{id: %{component_path: ["first"]}}, first_worker}
    refute_receive {:action_phase, _phase, ^first_worker}
  end

  test "receipt creation does not consume a lazy output before host rejection" do
    store = start_supervised!({Agent, fn -> %{} end})

    handle =
      Exec.run_async(LazyOutput, %{observer: self()}, %{},
        invocation: Host.config(store, self(), gate_after: true)
      )

    assert_receive {:after_invoke, receipt, worker}
    assert %Output{kind: :stream} = receipt.outcome.output
    refute_receive {:lazy_value, _value}
    send(worker, {:reject_receipt, receipt.invocation.id, :receipt_rejected})

    assert {:error,
            %Jido.Exec.Error.InterruptedError{
              details: %{stage: :after_invoke, reason: :receipt_rejected}
            }} = Exec.await(handle)

    refute_receive {:lazy_value, _value}
  end

  test "context-bound parameters are reported unchanged and compared only by the host" do
    store = start_supervised!({Agent, fn -> %{} end})
    first = make_ref()
    second = make_ref()
    flow = context_bound_flow()

    assert Exec.run(flow, %{}, %{temporary: first},
             invocation: Host.config(store, self(), run_key: "context-params")
           ) == {:ok, %{value: 1}}

    assert only_receipt(store).invocation.params == %{temporary: first, value: 1}
    flush_messages()

    assert Exec.run(flow, %{}, %{temporary: second},
             invocation: Host.config(store, self(), mode: :replay, run_key: "context-params")
           ) == {:ok, %{value: 1}}

    assert_receive {:before_invoke, current, replay_worker}
    assert current.params == %{temporary: second, value: 1}
    refute Map.has_key?(current, :context)
    refute_receive {:action_phase, _phase, ^replay_worker}
  end

  test "a validated Flow with no Action calls repeats validation without host callbacks" do
    recorder = start_supervised!({Agent, fn -> [] end}, id: :empty_flow_recorder)
    Process.register(recorder, Loop)
    store = start_supervised!({Agent, fn -> %{} end}, id: :empty_flow_store)
    config = Host.config(store, self(), run_key: "validated-empty")

    assert Exec.run(ValidatedEmptyFlow, %{value: 3}, %{}, invocation: config) ==
             {:ok, %{items: [], value: 3}}

    assert Exec.run(ValidatedEmptyFlow, %{value: 3}, %{},
             invocation: Host.config(store, self(), mode: :replay, run_key: "validated-empty")
           ) == {:ok, %{items: [], value: 3}}

    assert Host.receipts(store) == %{}
    refute_receive {:before_invoke, _descriptor, _worker}
    refute_receive {:after_invoke, _receipt, _worker}

    events = recorder |> Agent.get(&Enum.reverse/1)
    assert Enum.count(events, &match?({:empty_flow_validate_params, %{value: 3}}, &1)) == 2
    assert Enum.count(events, &match?({:empty_flow_validate_output, _output}, &1)) == 2
  end

  defp only_receipt(store) do
    assert [receipt] = store |> Host.receipts() |> Map.values()
    receipt
  end

  defp receipt_for_phase(receipts, phase) do
    receipts
    |> Map.values()
    |> Enum.find(fn receipt -> receipt.invocation.id.selector == %{phase: phase} end)
  end

  defp replay_reduce_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_reduce_prefix",
      components: [
        JidoActionTest.FlowComponent.reduce!(
          name: "items",
          collection: [:a, :b, :c, :d],
          initial: %{values: []},
          action: Fold,
          params: %{
            accumulator: Ref.accumulator(),
            index: Ref.item_index(),
            item: Ref.item(),
            observer: Ref.context(:observer)
          }
        )
      ],
      output: %{result: Ref.result("items")}
    )
  end

  defp replay_dispatch_flow(continue?) do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_dispatch_replay",
      components: [
        JidoActionTest.FlowComponent.dispatch!(
          name: "dispatch",
          decision: DispatchDecision,
          expander: DispatchExpander,
          params: %{continue?: continue?, value: 4}
        )
      ],
      output: Ref.result("dispatch")
    )
  end

  defp effect_then_failure_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_effect_then_failure",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "first",
          action: Probe,
          params: %{observer: Ref.context(:observer), value: 1, effects: [:first_effect]}
        ),
        JidoActionTest.FlowComponent.step!(
          name: "later",
          action: FailingAction,
          params: %{},
          needs: ["first"]
        )
      ],
      output: Ref.result("later")
    )
  end

  defp context_bound_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_context_bound",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "work",
          action: Probe,
          params: %{temporary: Ref.context(:temporary), value: 1}
        )
      ],
      output: Ref.result("work")
    )
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
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_step",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "work",
          action: Probe,
          params: %{observer: Ref.context(:observer), value: 1}
        )
      ],
      output: Ref.result("work")
    )
  end

  defp choice_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_choice",
      components: [
        JidoActionTest.FlowComponent.choice!(
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
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_fallback",
      components: [
        JidoActionTest.FlowComponent.choice!(
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
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_map",
      components: [
        JidoActionTest.FlowComponent.map!(
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
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_reduce",
      components: [
        JidoActionTest.FlowComponent.reduce!(
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
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_iterate",
      components: [
        JidoActionTest.FlowComponent.iterate!(
          name: "loop",
          action: Probe,
          params: %{value: Ref.iteration_index()},
          state: JidoActionTest.FlowComponent.state!(initial: %{}, update: %{}),
          completion: Jido.Expr.new!(:>=, [Ref.iteration_index(), 2]),
          max_iterations: 2
        )
      ],
      output: Ref.result("loop")
    )
  end

  defp subflow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_parent",
      components: [
        JidoActionTest.FlowComponent.subflow!(name: "child", flow: ChildFlow, params: %{})
      ],
      output: Ref.result("child")
    )
  end

  defp dispatch_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_dispatch",
      components: [
        JidoActionTest.FlowComponent.dispatch!(
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
