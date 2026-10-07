defmodule JidoActionTest.Exec.InvocationConcurrencyTest do
  use ExUnit.Case, async: true

  import JidoActionTest.ProcessCleanup

  alias Jido.Exec
  alias Jido.Exec.Error.InterruptedError
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Map, as: FlowMap

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
    Flow.new!(
      name: "invocation_concurrency",
      components: [
        FlowMap.new!(
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
end
