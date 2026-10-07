defmodule JidoActionTest.Exec.InvocationInterruptionTest do
  use ExUnit.Case, async: true

  import JidoActionTest.ProcessCleanup

  alias Jido.Exec
  alias Jido.Exec.Error.InterruptedError
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Map, as: FlowMap

  defmodule Host do
    @behaviour Jido.Exec.Invocation

    @impl true
    def before_invoke(invocation, ref) do
      send(ref.owner, {ref.token, :before, invocation, self()})

      case ref.before do
        :execute ->
          :execute

        :gate ->
          await_result(ref.token, :before_result)

        {:interrupt_index, index, reason} ->
          interrupt_index(invocation, index, reason)

        {:interrupt_chain, chain_index, reason} ->
          if invocation.id.chain_index == chain_index, do: {:interrupt, reason}, else: :execute

        result ->
          result
      end
    end

    @impl true
    def after_invoke(receipt, ref) do
      send(ref.owner, {ref.token, :after, receipt, self()})
      if ref.after == :gate, do: await_result(ref.token, :after_result), else: ref.after
    end

    defp await_result(token, tag) do
      receive do
        {^token, ^tag, result} -> result
      end
    end

    defp interrupt_index(%{id: %{selector: %{index: index}}}, index, reason),
      do: {:interrupt, reason}

    defp interrupt_index(_invocation, _index, _reason), do: :execute
  end

  defmodule Probe do
    use Jido.Action, name: "invocation_interruption_probe"

    @impl true
    def run(%{mode: :kill}, _context), do: Process.exit(self(), :kill)

    def run(%{mode: :business_error}, _context) do
      {:error, Jido.Action.Error.execution_error("business failure")}
    end

    def run(%{owner: owner, token: token} = params, _context) do
      send(owner, {token, :phase, :execution, self()})
      {:ok, Map.take(params, [:value]), params[:effects] || []}
    end
  end

  defmodule Continue do
    use Jido.Action, name: "invocation_interruption_continue"

    @impl true
    def run(%{owner: owner, token: token, value: value}, _context) do
      send(owner, {token, :continued, self()})

      {:continue, %{owner: owner, token: token, value: value},
       JidoActionTest.Exec.InvocationInterruptionTest.Final}
    end
  end

  defmodule Final do
    use Jido.Action, name: "invocation_interruption_final"

    @impl true
    def run(%{owner: owner, token: token, value: value}, _context) do
      send(owner, {token, :final_started, self()})
      {:ok, %{value: value}}
    end
  end

  test "host refusal before permission starts no Action phase and kills the detecting worker" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()

    handle =
      Exec.run_async(Probe, %{owner: self(), token: token, value: 1}, %{},
        task_supervisor: supervisor,
        invocation: config(token, before: :gate)
      )

    assert_receive {^token, :before, _invocation, worker}, 1_000
    monitor = Process.monitor(worker)
    send(worker, {token, :before_result, {:interrupt, :intent_without_receipt}})

    result = Exec.await(handle, 1_000)

    assert {:error,
            %InterruptedError{
              details: %{stage: :before_invoke, reason: :intent_without_receipt}
            }} = result

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    refute_received {^token, :phase, :execution, _worker}
    assert_supervisor_quiescent(supervisor)
  end

  test "receipt rejection releases no Action result or effects" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()

    handle =
      Exec.run_async(
        Probe,
        %{owner: self(), token: token, value: 2, effects: [:must_not_escape]},
        %{},
        task_supervisor: supervisor,
        invocation: config(token, after: :gate)
      )

    assert_receive {^token, :after, receipt, worker}, 1_000
    assert receipt.outcome.effects == [:must_not_escape]
    monitor = Process.monitor(worker)
    send(worker, {token, :after_result, {:error, :receipt_rejected}})

    assert {:error,
            %InterruptedError{details: %{stage: :after_invoke, reason: :receipt_rejected}}} =
             Exec.await(handle, 1_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert_supervisor_quiescent(supervisor)
  end

  test "the controller notification survives detector death with an infinite timeout" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()

    handle =
      Exec.run_async(Probe, %{owner: self(), token: token, value: 2}, %{},
        task_supervisor: supervisor,
        timeout: :infinity,
        invocation: config(token, after: :gate)
      )

    assert_receive {^token, :after, _receipt, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    :erlang.trace(worker, true, [:send, {:tracer, self()}])
    :erlang.suspend_process(handle.pid)

    try do
      send(worker, {token, :after_result, {:interrupt, :detector_stopped}})

      assert_receive {:trace, ^worker, :send,
                      {Jido.Exec.Controller, _call_token,
                       {:invocation_interrupt,
                        %InterruptedError{details: %{reason: :detector_stopped}}}}, controller},
                     1_000

      assert controller == handle.pid
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    after
      :erlang.resume_process(handle.pid)
    end

    assert {:error,
            %InterruptedError{details: %{stage: :after_invoke, reason: :detector_stopped}}} =
             Exec.await(handle, 1_000)

    assert_supervisor_quiescent(supervisor)
  end

  test "invalid replay interrupts before Action work" do
    token = make_ref()

    assert {:error, %InterruptedError{details: %{stage: :replay}}} =
             Exec.run(Probe, %{owner: self(), token: token, value: 1}, %{},
               invocation: config(token, before: {:replay, :invalid_receipt})
             )

    refute_received {^token, :phase, :execution, _worker}
    refute_received {^token, :after, _receipt, _worker}
  end

  test "the same interruption control covers a pending continuation" do
    token = make_ref()

    assert {:error,
            %InterruptedError{details: %{stage: :before_invoke, reason: :stop_continuation}}} =
             Exec.run(Continue, %{owner: self(), token: token, value: 3}, %{},
               invocation: config(token, before: {:interrupt_chain, 1, :stop_continuation})
             )

    assert_receive {^token, :continued, _worker}, 1_000
    assert_receive {^token, :after, %{invocation: %{id: %{chain_index: 0}}}, _worker}, 1_000
    assert_receive {^token, :before, %{id: %{chain_index: 1}}, _worker}, 1_000
    refute_received {^token, :final_started, _worker}
  end

  for terminal <- [:timeout, :cancel] do
    @tag terminal: terminal
    test "a hanging host callback is cleaned up on #{terminal}", %{terminal: terminal} do
      supervisor = start_supervised!(Task.Supervisor)
      token = make_ref()
      timeout = if terminal == :timeout, do: 50, else: :infinity

      handle =
        Exec.run_async(Probe, %{owner: self(), token: token, value: 1}, %{},
          task_supervisor: supervisor,
          timeout: timeout,
          invocation: config(token, before: :gate)
        )

      assert_receive {^token, :before, _invocation, worker}, 1_000
      monitor = Process.monitor(worker)

      if terminal == :timeout do
        assert {:error, %Jido.Action.Error.TimeoutError{}} = Exec.await(handle, 1_000)
      else
        assert :ok = Exec.cancel(handle)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      refute_received {^token, :phase, :execution, _worker}
      refute_received {^token, :after, _receipt, _worker}
      assert_supervisor_quiescent(supervisor)
    end
  end

  test "a deadline in the receipt window reports an interruption" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()

    handle =
      Exec.run_async(Probe, %{owner: self(), token: token, value: 1}, %{},
        task_supervisor: supervisor,
        timeout: 50,
        invocation: config(token, after: :gate)
      )

    assert_receive {^token, :after, _receipt, worker}, 1_000
    monitor = Process.monitor(worker)

    assert {:error,
            %InterruptedError{
              details: %{
                stage: :worker,
                reason: {:call_stopped, %Jido.Action.Error.TimeoutError{}}
              }
            }} = Exec.await(handle, 1_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert_supervisor_quiescent(supervisor)
  end

  for target <- [:action, :flow] do
    @tag target: target
    test "private supervisor exit interrupts an opted-in #{target} call", %{target: target} do
      supervisor = start_supervised!(Task.Supervisor)
      token = make_ref()
      params = %{owner: self(), token: token, value: 1}

      executable =
        case target do
          :action ->
            Probe

          :flow ->
            Flow.new!(
              name: "invocation_supervisor_exit",
              components: [Step.new!(name: "probe", action: Probe, params: Ref.input([]))],
              output: Ref.result("probe")
            )
        end

      handle =
        Exec.run_async(executable, params, %{},
          task_supervisor: supervisor,
          invocation: config(token, after: :gate)
        )

      assert_receive {^token, :after, _receipt, worker}, 1_000
      {:dictionary, dictionary} = Process.info(worker, :dictionary)
      [private_supervisor | _] = Keyword.fetch!(dictionary, :"$ancestors")
      Process.exit(private_supervisor, :kill)

      assert {:error,
              %InterruptedError{
                details: %{stage: :worker, reason: {:supervisor_exit, :killed}}
              }} = Exec.await(handle, 1_000)

      assert_supervisor_quiescent(supervisor)
    end
  end

  test "owner death cleans up a hanging host callback" do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()
    test_pid = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        handle =
          Exec.run_async(Probe, %{owner: test_pid, token: token, value: 1}, %{},
            task_supervisor: supervisor,
            invocation: config(token, before: :gate, owner: test_pid)
          )

        send(test_pid, {token, :handle, handle})
        receive do: ({^token, :stop_owner} -> :ok)
      end)

    assert_receive {^token, :handle, handle}, 1_000
    assert_receive {^token, :before, _invocation, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    control_monitor = Process.monitor(handle.pid)
    send(owner, {token, :stop_owner})

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, _, :normal}, 1_000
    assert_supervisor_quiescent(supervisor)
  end

  test "Map collect_errors cannot consume a host interruption" do
    token = make_ref()

    assert {:error,
            %InterruptedError{
              details: %{stage: :before_invoke, reason: :host_refused_item}
            }} =
             Exec.run(map_flow(:ok), %{}, %{owner: self(), token: token},
               max_concurrency: 1,
               invocation: config(token, before: {:interrupt_index, 0, :host_refused_item})
             )

    refute_received {^token, :phase, :execution, _worker}
  end

  test "Map collect_errors cannot consume an opted-in worker exit" do
    token = make_ref()

    assert {:error,
            %InterruptedError{
              details: %{stage: :worker, invocation_id: nil}
            }} =
             Exec.run(map_flow(:kill), %{}, %{owner: self(), token: token},
               max_concurrency: 2,
               invocation: config(token)
             )
  end

  test "a root Action worker exit is an invocation interruption" do
    token = make_ref()

    assert {:error,
            %InterruptedError{
              details: %{stage: :worker, invocation_id: nil}
            }} =
             Exec.run(Probe, %{owner: self(), token: token, mode: :kill}, %{},
               invocation: config(token)
             )
  end

  test "a nested Action worker exit is an invocation interruption" do
    token = make_ref()

    flow =
      Flow.new!(
        name: "nested_invocation_worker_exit",
        components: [
          Step.new!(
            name: "work",
            action: Probe,
            params: %{
              owner: Ref.context(:owner),
              token: Ref.context(:token),
              mode: :kill
            }
          )
        ],
        output: Ref.result("work")
      )

    assert {:error, %InterruptedError{details: %{stage: :worker, invocation_id: nil}}} =
             Exec.run(flow, %{}, %{owner: self(), token: token}, invocation: config(token))
  end

  test "a recorded Action error remains collectable" do
    token = make_ref()

    assert {:ok, %{items: [item]}} =
             Exec.run(map_flow(:business_error), %{}, %{owner: self(), token: token},
               max_concurrency: 1,
               invocation: config(token)
             )

    assert %{status: :error, error: %{message: "business failure"}} = item
    assert_receive {^token, :after, %{outcome: %{kind: :error}}, _worker}, 1_000
  end

  defp map_flow(mode) do
    Flow.new!(
      name: "invocation_interruption_map",
      components: [
        FlowMap.new!(
          name: "items",
          collection: [1],
          action: Probe,
          params: %{
            owner: Ref.context(:owner),
            token: Ref.context(:token),
            mode: mode,
            value: Ref.item()
          },
          on_error: :collect_errors
        )
      ],
      output: %{items: Ref.result("items")}
    )
  end

  defp config(token, opts \\ []) do
    %{
      host: Host,
      ref: %{
        owner: Keyword.get(opts, :owner, self()),
        token: token,
        before: Keyword.get(opts, :before, :execute),
        after: Keyword.get(opts, :after, :ok)
      },
      run_key: "interruption-#{inspect(token)}",
      compatibility: :current
    }
  end
end
