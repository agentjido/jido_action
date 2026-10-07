defmodule JidoActionTest.Exec.InvocationConcurrencyTest do
  use ExUnit.Case, async: true

  import JidoActionTest.ProcessCleanup

  alias Jido.Exec
  alias Jido.Exec.Error.InterruptedError
  alias Jido.Flow.Ref

  defmodule GateHost do
    @behaviour Jido.Exec.Invocation

    @impl true
    def before_invoke(invocation, ref) do
      send(ref.owner, {ref.token, :before, invocation, self()})
      token = ref.token

      receive do
        {^token, :before_result, result} -> result
      end
    end

    @impl true
    def after_invoke(receipt, ref) do
      send(ref.owner, {ref.token, :after, receipt, self()})
      token = ref.token

      receive do
        {^token, :after_result, result} -> result
      end
    end
  end

  defmodule ReplayGateHost do
    @behaviour Jido.Exec.Invocation

    @impl true
    def before_invoke(invocation, ref) do
      send(ref.owner, {ref.token, :before, invocation, self()})

      case {ref.mode, Agent.get(ref.store, &Map.get(&1, invocation.id))} do
        {:replay, receipt} when not is_nil(receipt) ->
          {:replay, receipt}

        _other ->
          token = ref.token

          receive do
            {^token, :before_result, result} -> result
          end
      end
    end

    @impl true
    def after_invoke(receipt, ref) do
      Agent.update(ref.store, &Map.put(&1, receipt.invocation.id, receipt))
      send(ref.owner, {ref.token, :after, receipt, self()})
      :ok
    end
  end

  defmodule ControlledAction do
    use Jido.Action, name: "invocation_concurrency_controlled"

    @impl true
    def run(%{owner: owner, token: token, value: value}, _context) do
      send(owner, {token, :action_started, value, self()})

      receive do
        {^token, :finish} -> {:ok, %{value: value}, [{:effect, value}]}
      end
    end
  end

  test "an admitted sibling may start, but host interruption stops the complete call" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()
    owner = self()

    call =
      Task.async(fn ->
        Exec.run(flow([0, 1]), %{}, %{owner: owner, token: token},
          task_supervisor: supervisor,
          max_concurrency: 2,
          timeout: :infinity,
          invocation: config(token, owner)
        )
      end)

    on_exit(fn -> Process.exit(call.pid, :kill) end)

    {workers, descriptors} = take_before_callbacks(token, 2)
    first = Map.fetch!(workers, 0)
    second = Map.fetch!(workers, 1)
    assert Map.fetch!(descriptors, 0).id.selector == %{index: 0}
    assert Map.fetch!(descriptors, 1).id.selector == %{index: 1}

    monitors = for worker <- Map.values(workers), do: {worker, Process.monitor(worker)}
    send(second, {token, :before_result, :execute})
    assert_receive {^token, :action_started, 1, action_worker}, 1_000
    assert action_worker == second

    send(first, {token, :before_result, {:interrupt, :stop_wave}})

    assert {:error, %InterruptedError{details: %{stage: :before_invoke, reason: :stop_wave}}} =
             Task.await(call, 1_000)

    for {worker, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    end

    refute_received {^token, :after, _receipt, _worker}
    assert_supervisor_quiescent(supervisor)
  end

  test "P18 reuses an accepted sibling receipt after another sibling interrupts" do
    store = start_supervised!({Agent, fn -> %{} end})
    owner = self()
    first_token = make_ref()

    first_call =
      Task.async(fn ->
        Exec.run(flow([0, 1]), %{}, %{owner: owner, token: first_token},
          max_concurrency: 2,
          timeout: :infinity,
          invocation: replay_config(first_token, store, :record, owner)
        )
      end)

    on_exit(fn -> Process.exit(first_call.pid, :kill) end)

    {first_workers, _descriptors} = take_before_callbacks(first_token, 2)
    accepted_worker = Map.fetch!(first_workers, 0)
    interrupted_worker = Map.fetch!(first_workers, 1)

    first_monitors =
      for worker <- Map.values(first_workers), into: %{} do
        {worker, Process.monitor(worker)}
      end

    send(accepted_worker, {first_token, :before_result, :execute})
    assert_receive {^first_token, :action_started, 0, ^accepted_worker}, 1_000
    send(accepted_worker, {first_token, :finish})

    assert_receive {^first_token, :after, accepted_receipt, ^accepted_worker}, 1_000
    assert accepted_receipt.invocation.id.selector == %{index: 0}
    assert Agent.get(store, &Map.keys/1) == [accepted_receipt.invocation.id]

    send(interrupted_worker, {first_token, :before_result, {:interrupt, :stop_after_accept}})

    assert {:error,
            %InterruptedError{
              details: %{stage: :before_invoke, reason: :stop_after_accept}
            }} = Task.await(first_call, 1_000)

    for {worker, monitor} <- first_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    end

    second_token = make_ref()

    second_call =
      Task.async(fn ->
        Exec.run(flow([0, 1]), %{}, %{owner: owner, token: second_token},
          max_concurrency: 2,
          timeout: :infinity,
          invocation: replay_config(second_token, store, :replay, owner)
        )
      end)

    on_exit(fn -> Process.exit(second_call.pid, :kill) end)

    {second_workers, _descriptors} = take_before_callbacks(second_token, 2)
    replayed_worker = Map.fetch!(second_workers, 0)
    missing_worker = Map.fetch!(second_workers, 1)
    missing_monitor = Process.monitor(missing_worker)

    send(missing_worker, {second_token, :before_result, :execute})
    assert_receive {^second_token, :action_started, 1, ^missing_worker}, 1_000
    send(missing_worker, {second_token, :finish})

    assert_receive {^second_token, :after, missing_receipt, ^missing_worker}, 1_000
    assert missing_receipt.invocation.id.selector == %{index: 1}

    assert Task.await(second_call, 1_000) ==
             {:ok,
              %{
                items: [
                  %{status: :ok, value: %{value: 0}},
                  %{status: :ok, value: %{value: 1}}
                ]
              }, [{:effect, 0}, {:effect, 1}]}

    assert_receive {:DOWN, ^missing_monitor, :process, ^missing_worker, :normal}, 1_000
    refute_received {^second_token, :action_started, 0, ^replayed_worker}
    refute_received {^second_token, :after, _receipt, ^replayed_worker}
    assert map_size(Agent.get(store, & &1)) == 2
  end

  test "callbacks may finish in reverse order while output and effects stay canonical" do
    token = make_ref()
    owner = self()

    call =
      Task.async(fn ->
        Exec.run(flow([0, 1]), %{}, %{owner: owner, token: token},
          max_concurrency: 2,
          invocation: config(token, owner)
        )
      end)

    on_exit(fn -> Process.exit(call.pid, :kill) end)

    {workers, _descriptors} = take_before_callbacks(token, 2)
    first = Map.fetch!(workers, 0)
    second = Map.fetch!(workers, 1)

    send(second, {token, :before_result, :execute})
    assert_receive {^token, :action_started, 1, ^second}, 1_000
    send(second, {token, :finish})
    assert_receive {^token, :after, second_receipt, ^second}, 1_000
    send(second, {token, :after_result, :ok})

    send(first, {token, :before_result, :execute})
    assert_receive {^token, :action_started, 0, ^first}, 1_000
    send(first, {token, :finish})
    assert_receive {^token, :after, first_receipt, ^first}, 1_000
    send(first, {token, :after_result, :ok})

    assert second_receipt.invocation.id.selector == %{index: 1}
    assert first_receipt.invocation.id.selector == %{index: 0}

    assert Task.await(call, 1_000) ==
             {:ok,
              %{
                items: [
                  %{status: :ok, value: %{value: 0}},
                  %{status: :ok, value: %{value: 1}}
                ]
              }, [{:effect, 0}, {:effect, 1}]}
  end

  test "partial Map receipts use source keys after reverse completion and a concurrency change" do
    store = start_supervised!({Agent, fn -> %{} end})
    token = make_ref()
    owner = self()

    first =
      Task.async(fn ->
        Exec.run(flow([:same, :same, :same]), %{}, %{owner: owner, token: token},
          max_concurrency: 3,
          invocation: replay_config(token, store, :record, owner)
        )
      end)

    on_exit(fn -> Process.exit(first.pid, :kill) end)
    {workers, descriptors} = take_before_callbacks(token, 3)

    for index <- [2, 1, 0] do
      worker = Map.fetch!(workers, index)
      send(worker, {token, :before_result, :execute})
      assert_receive {^token, :action_started, :same, ^worker}, 1_000
      send(worker, {token, :finish})
      assert_receive {^token, :after, receipt, ^worker}, 1_000
      assert receipt.invocation.id.selector == %{index: index}
    end

    expected =
      {:ok,
       %{
         items: [
           %{status: :ok, value: %{value: :same}},
           %{status: :ok, value: %{value: :same}},
           %{status: :ok, value: %{value: :same}}
         ]
       }, [{:effect, :same}, {:effect, :same}, {:effect, :same}]}

    assert Task.await(first, 1_000) == expected

    assert Enum.map(descriptors, fn {index, descriptor} -> {index, descriptor.id.selector} end)
           |> Enum.sort() ==
             [{0, %{index: 0}}, {1, %{index: 1}}, {2, %{index: 2}}]

    receipts = Agent.get(store, & &1)

    kept =
      receipts
      |> Enum.reject(fn {id, _receipt} -> id.selector == %{index: 1} end)
      |> Map.new()

    Agent.update(store, fn _receipts -> kept end)
    flush_messages()
    replay_token = make_ref()

    second =
      Task.async(fn ->
        Exec.run(flow([:same, :same, :same]), %{}, %{owner: owner, token: replay_token},
          max_concurrency: 1,
          invocation: replay_config(replay_token, store, :replay, owner)
        )
      end)

    on_exit(fn -> Process.exit(second.pid, :kill) end)

    assert_receive {^replay_token, :before, %{id: %{selector: %{index: 0}}}, first_replay},
                   1_000

    refute_received {^replay_token, :action_started, :same, ^first_replay}

    assert_receive {^replay_token, :before, %{id: %{selector: %{index: 1}}}, missing}, 1_000
    send(missing, {replay_token, :before_result, :execute})
    assert_receive {^replay_token, :action_started, :same, ^missing}, 1_000
    send(missing, {replay_token, :finish})

    assert_receive {^replay_token, :after, %{invocation: %{id: %{selector: %{index: 1}}}},
                    ^missing},
                   1_000

    assert_receive {^replay_token, :before, %{id: %{selector: %{index: 2}}}, last_replay},
                   1_000

    refute_received {^replay_token, :action_started, :same, ^last_replay}
    assert Task.await(second, 1_000) == expected
  end

  test "an unrelated invocation token cannot stop the call" do
    token = make_ref()

    handle =
      Exec.run_async(flow([0]), %{}, %{owner: self(), token: token},
        max_concurrency: 1,
        invocation: config(token)
      )

    on_exit(fn -> Process.exit(handle.pid, :kill) end)

    assert_receive {^token, :before, _descriptor, worker}, 1_000

    send(
      handle.pid,
      {Jido.Exec.Controller, make_ref(),
       {:invocation_interrupt, Jido.Exec.Error.interrupted_error(:before_invoke, :unrelated, nil)}}
    )

    send(worker, {token, :before_result, :execute})
    assert_receive {^token, :action_started, 0, ^worker}, 1_000
    send(worker, {token, :finish})
    assert_receive {^token, :after, _receipt, ^worker}, 1_000
    send(worker, {token, :after_result, :ok})

    assert Exec.await(handle, 1_000) ==
             {:ok, %{items: [%{status: :ok, value: %{value: 0}}]}, [{:effect, 0}]}
  end

  defp take_before_callbacks(token, count) do
    Enum.reduce(1..count, {%{}, %{}}, fn _, {workers, descriptors} ->
      assert_receive {^token, :before, descriptor, worker}, 1_000
      index = descriptor.id.selector.index
      {Map.put(workers, index, worker), Map.put(descriptors, index, descriptor)}
    end)
  end

  defp flow(values) do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_concurrency",
      components: [
        JidoActionTest.FlowComponent.map!(
          name: "items",
          collection: values,
          action: ControlledAction,
          params: %{
            owner: Ref.context(:owner),
            token: Ref.context(:token),
            value: Ref.item()
          },
          on_error: :collect_errors
        )
      ],
      output: %{items: Ref.result("items")}
    )
  end

  defp config(token, owner \\ self()) do
    %{
      host: GateHost,
      ref: %{owner: owner, token: token},
      run_key: "concurrency-#{inspect(token)}",
      compatibility: :current
    }
  end

  defp replay_config(token, store, mode, owner) do
    %{
      host: ReplayGateHost,
      ref: %{owner: owner, token: token, store: store, mode: mode},
      run_key: "replay-concurrency",
      compatibility: :current
    }
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end
