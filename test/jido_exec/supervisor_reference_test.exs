defmodule JidoActionTest.Exec.SupervisorReferenceTest do
  use JidoActionTest.Case, async: false

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Exec.Error.AsyncExecutionError
  alias Jido.Flow
  alias Jido.Flow.{Condition, Dispatch, Iterate, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.BlockingFlow
  alias JidoActionTest.Fixtures.Execution, as: Fixtures
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  defmodule Continue do
    use Jido.Action, name: "supervisor_route_continue"

    @impl true
    def run(params, context) do
      send(context.test_pid, {:blocking_flow_node_started, self()})

      receive do
        :finish -> {:continue, params, context.next}
      end
    end
  end

  defmodule BarrierVia do
    def whereis_name({owner, token}) do
      ref = make_ref()
      send(owner, {:lookup, token, self(), ref})

      receive do
        {^ref, :raise} -> raise ArgumentError, "via registry stopped"
        {^ref, pid} -> pid
      end
    end
  end

  for route_kind <- [:pid, :name, :registry, :partition] do
    @route_kind route_kind
    test "routes all run and async target forms through #{@route_kind}" do
      route = start_route(@route_kind)
      expected_supervisor = GenServer.whereis(route)
      owner = self()

      for {form, {target, input, context}} <-
            Fixtures.blocking_execution_forms(BlockingFlow, owner),
          mode <- [:run, :finite, :async] do
        opts = [task_supervisor: route]

        caller =
          start_caller(fn ->
            case mode do
              :run ->
                Exec.run(target, input, context, opts)

              :finite ->
                Exec.run(target, input, context, opts ++ [timeout: 10_000])

              :async ->
                handle = Exec.run_async(target, input, context, opts)
                send(owner, {:async_handle, handle})
                Exec.await(handle)
            end
          end)

        if mode == :async do
          assert_receive {:async_handle, handle}
          assert handle.pid in Task.Supervisor.children(expected_supervisor)
        end

        assert_receive {:blocking_flow_node_started, worker}, 1_000, inspect({form, mode})
        assert worker in Task.Supervisor.children(expected_supervisor)
        refute worker in Task.Supervisor.children(Jido.Exec.TaskSupervisor)
        monitor = Process.monitor(worker)
        send(worker, :finish)
        assert {:ok, %{value: _}} = caller_result(caller)
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
      end
    end

    test "retains #{@route_kind} through step, wave, and continue" do
      route = start_route(@route_kind)
      owner = self()

      for operation <- [:step, :wave, :continue] do
        {:ok, execution} =
          Exec.start(BlockingFlow, %{value: operation}, %{test_pid: owner},
            task_supervisor: route
          )

        caller = start_caller(fn -> finish_execution(execution, operation) end)
        assert_receive {:blocking_flow_node_started, worker}, 1_000
        assert worker in Task.Supervisor.children(route)
        send(worker, :finish)
        assert {:ok, %{value: ^operation}} = caller_result(caller)
      end
    end
  end

  test "keeps the caller partition key through Action, Flow, and Dispatch continuations" do
    route = start_route(:partition)
    owner = self()

    dispatch =
      Flow.new!(
        name: "route_dispatch",
        components: [
          Dispatch.new!(
            name: :dispatch,
            decision: BlockingAction,
            expander: Continue,
            params: %{value: :continued}
          )
        ],
        output: Ref.result(:dispatch)
      )

    for {target, next, count} <- [
          {Continue, BlockingFlow, 2},
          {Continue, BlockingAction, 2},
          {dispatch, BlockingAction, 3}
        ],
        mode <- [:run, :finite, :async] do
      caller =
        start_caller(fn ->
          opts = [task_supervisor: route]
          context = %{test_pid: owner, next: next}

          case mode do
            :run ->
              Exec.run(target, %{value: :continued}, context, opts)

            :finite ->
              Exec.run(target, %{value: :continued}, context, opts ++ [timeout: 10_000])

            :async ->
              target |> Exec.run_async(%{value: :continued}, context, opts) |> Exec.await()
          end
        end)

      for _ <- 1..count do
        assert_receive {:blocking_flow_node_started, worker}, 1_000
        assert worker in Task.Supervisor.children(route)
        send(worker, :finish)
      end

      assert {:ok, %{value: :continued}} = caller_result(caller)
    end
  end

  test "keeps a partition route through Map, Reduce, and Iterate work" do
    route = start_route(:partition)
    owner = self()

    flow =
      Flow.new!(
        name: "route_collections",
        components: [
          FlowMap.new!(
            name: :mapped,
            collection: [:a, :b],
            action: BlockingAction,
            params: %{value: Ref.item()}
          ),
          Reduce.new!(
            name: :reduced,
            collection: Ref.result(:mapped),
            initial: %{},
            action: BlockingAction,
            params: %{value: Ref.item(:value)}
          ),
          Iterate.new!(
            name: :loop,
            after: [:reduced],
            action: BlockingAction,
            params: %{value: :iteration},
            state: Iterate.State.new!(initial: %{}, update: Ref.body_result()),
            completion: Condition.gte(Ref.iteration_index(), 1),
            max_iterations: 1
          )
        ],
        output: Ref.result(:loop)
      )

    caller =
      start_caller(fn ->
        Exec.run(flow, %{}, %{test_pid: owner}, task_supervisor: route, max_concurrency: 2)
      end)

    workers =
      for _ <- 1..2 do
        assert_receive {:blocking_flow_node_started, worker}, 1_000
        assert worker in Task.Supervisor.children(route)
        worker
      end

    Enum.each(workers, &send(&1, :finish))

    for _ <- 1..3 do
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      assert worker in Task.Supervisor.children(route)
      send(worker, :finish)
    end

    assert {:ok, %{iterations: 1, output: %{value: :iteration}}} = caller_result(caller)
  end

  test "uses effective Instruction options for both async control and Action workers" do
    stored = start_route(:pid)
    override = start_route(:registry)

    instruction = %Instruction{
      target: BlockingAction,
      opts: [task_supervisor: stored],
      context: %{test_pid: self()}
    }

    for opts <- [[], [task_supervisor: override]] do
      route = Keyword.get(opts, :task_supervisor, stored)
      handle = Exec.run_async(instruction, %{}, %{}, opts)
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      children = Task.Supervisor.children(route)
      assert worker in children
      assert handle.pid in children
      send(worker, :finish)
      assert {:ok, %{}} = Exec.await(handle)
    end
  end

  test "keeps Exec tasks temporary when the host has a legacy restart default" do
    name = __MODULE__.Restarting

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      start_supervised!({Task.Supervisor, name: name, restart: :permanent})
    end)

    supervisor = Process.whereis(name)
    owner = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        result = Exec.run(BlockingAction, %{}, %{test_pid: owner}, task_supervisor: name)
        send(owner, {:held_result, result})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    :erlang.trace(supervisor, true, [:receive])
    Process.exit(worker, :kill)
    assert_receive {:trace, ^supervisor, :receive, {:EXIT, ^worker, :killed}}, 1_000

    assert_receive {:held_result, {:error, %ExecutionFailureError{details: %{reason: :killed}}}},
                   1_000

    # The supervisor has received the exit before this call, so a restart
    # would already be visible. The caller stays alive until this assertion.
    assert Task.Supervisor.children(supervisor) == []
    :erlang.trace(supervisor, false, [:receive])
    send(caller, :stop)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "keeps two host supervision trees independent during shutdown" do
    first = start_route(:pid)
    second = start_route(:registry)

    first_handle =
      Exec.run_async(BlockingAction, %{}, %{test_pid: self()}, task_supervisor: first)

    assert_receive {:blocking_flow_node_started, first_worker}
    first_monitor = Process.monitor(first_worker)

    second_handle =
      Exec.run_async(BlockingAction, %{}, %{test_pid: self()}, task_supervisor: second)

    assert_receive {:blocking_flow_node_started, second_worker}
    assert first_worker in Task.Supervisor.children(first)
    assert second_worker in Task.Supervisor.children(second)

    Supervisor.stop(first)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :shutdown}
    assert {:error, %AsyncExecutionError{}} = Exec.await(first_handle)
    assert Process.alive?(second_worker)
    send(second_worker, :finish)
    assert {:ok, %{}} = Exec.await(second_handle)
  end

  test "named paused work uses a replacement while a PID route stays with its original process" do
    name = __MODULE__.Replacement
    original = start_supervised!({Task.Supervisor, name: name})
    context = %{test_pid: self()}
    {:ok, named} = Exec.start(BlockingFlow, %{value: :new}, context, task_supervisor: name)
    {:ok, pinned} = Exec.start(BlockingFlow, %{value: :old}, context, task_supervisor: original)
    stop_supervised!(name)
    replacement = start_supervised!({Task.Supervisor, name: name})
    refute original == replacement

    assert {:ok, failed} = Exec.continue(pinned)

    assert {:error, %ExecutionFailureError{details: %{task_supervisor: ^original}}} =
             Exec.result(failed)

    refute_received {:blocking_flow_node_started, _}

    caller = start_caller(fn -> finish_execution(named, :continue) end)
    assert_receive {:blocking_flow_node_started, worker}
    assert worker in Task.Supervisor.children(replacement)
    send(worker, :finish)
    assert {:ok, %{value: :new}} = caller_result(caller)
    assert Task.Supervisor.children(replacement) == []
  end

  test "contains supervisor shutdown during a synchronous Action or Flow call" do
    owner = self()

    for target <- [BlockingAction, BlockingFlow], timeout <- [:infinity, 10_000] do
      supervisor = start_route(:pid)

      caller =
        start_caller(fn ->
          Exec.run(target, %{value: 1}, %{test_pid: owner},
            task_supervisor: supervisor,
            timeout: timeout
          )
        end)

      assert_receive {:blocking_flow_node_started, worker}
      monitor = Process.monitor(worker)
      Supervisor.stop(supervisor)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}

      assert {:error, %ExecutionFailureError{details: %{reason: :shutdown}}} =
               caller_result(caller)
    end
  end

  test "contains a task-start race after successful via lookup without fallback" do
    owner = self()

    for mode <- [:run, :async], failure <- [:dead_pid, :raise] do
      supervisor = start_route(:pid)
      token = make_ref()
      route = {:via, BarrierVia, {owner, token}}

      caller =
        start_caller(fn ->
          try do
            case mode do
              :run ->
                Exec.run(BlockingAction, %{}, %{test_pid: owner}, task_supervisor: route)

              :async ->
                Exec.run_async(BlockingAction, %{}, %{test_pid: owner}, task_supervisor: route)
            end
          rescue
            error -> {:error, error}
          end
        end)

      assert_receive {:lookup, ^token, lookup_caller, ref}
      send(lookup_caller, {ref, supervisor})
      assert_receive {:lookup, ^token, lookup_caller, ref}
      Supervisor.stop(supervisor)
      send(lookup_caller, {ref, if(failure == :raise, do: :raise, else: supervisor)})
      assert {:error, error} = caller_result(caller)

      assert error.__struct__ ==
               if(mode == :run, do: ExecutionFailureError, else: AsyncExecutionError)

      assert error.details.task_supervisor == route

      if failure == :raise do
        assert {:error, %ArgumentError{}} = error.details.reason
      else
        assert {:exit, _} = error.details.reason
      end

      assert error.details.retry == false
      refute_received {:blocking_flow_node_started, _}
    end
  end

  test "returns capacity refusal for Action, Flow, and async control or target work" do
    full = start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 0}, id: :full))
    one = start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: :one))

    for target <- [BlockingAction, BlockingFlow], timeout <- [:infinity, 10_000] do
      assert {:error,
              %ExecutionFailureError{details: %{reason: :max_children, task_supervisor: ^full}}} =
               Exec.run(target, %{value: 1}, %{test_pid: self()},
                 task_supervisor: full,
                 timeout: timeout
               )
    end

    assert_raise AsyncExecutionError, fn ->
      Exec.run_async(BlockingAction, %{}, %{}, task_supervisor: full)
    end

    handle = Exec.run_async(BlockingAction, %{}, %{}, task_supervisor: one)

    assert {:error, %ExecutionFailureError{details: %{reason: :max_children}}} =
             Exec.await(handle)

    refute_received {:blocking_flow_node_started, _}
  end

  test "rejects removed, duplicate, invalid, and absent routes before Action work" do
    supervisor = start_route(:pid)

    for target <- [BlockingAction, BlockingFlow],
        opts <- [
          [jido: nil],
          [jido: __MODULE__, task_supervisor: supervisor],
          [task_supervisor: supervisor, task_supervisor: supervisor],
          [task_supervisor: nil],
          [task_supervisor: "bad"],
          [task_supervisor: {:global, :unsupported}],
          [task_supervisor: {:name, :remote}],
          [task_supervisor: {:via, nil, :bad}],
          [task_supervisor: {:via, __MODULE__, :bad}],
          [task_supervisor: __MODULE__.Absent]
        ] do
      assert {:error, error} = Exec.run(target, %{value: 1}, %{test_pid: self()}, opts)
      assert is_exception(error)
      assert error.details.option in [:jido, :task_supervisor]

      if Keyword.has_key?(opts, :jido) do
        assert error.message =~ "jido option was removed"
        assert error.message =~ "task_supervisor:"
      end

      refute_received {:blocking_flow_node_started, _}
    end

    for opts <- [
          [jido: nil],
          [task_supervisor: "bad"],
          [task_supervisor: supervisor, task_supervisor: supervisor]
        ] do
      assert_raise InvalidInputError, fn -> Exec.run_async(BlockingAction, %{}, %{}, opts) end
    end
  end

  test "rejects legacy Instruction jido routing even with an explicit new route" do
    instruction = %Instruction{target: BlockingAction, opts: [jido: nil]}
    assert {:error, %InvalidInputError{message: message}} = Exec.run(instruction)
    assert message =~ "jido option was removed"

    assert_raise InvalidInputError, ~r/jido option was removed/, fn ->
      Exec.run_async(instruction, %{}, %{}, task_supervisor: start_route(:pid))
    end
  end

  defp start_route(:pid),
    do: start_supervised!(Supervisor.child_spec(Task.Supervisor, id: make_ref()))

  defp start_route(:name) do
    name = __MODULE__.Named
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp start_route(:registry) do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.Registry})
    route = {:via, Registry, {__MODULE__.Registry, make_ref()}}
    start_supervised!({Task.Supervisor, name: route})
    route
  end

  defp start_route(:partition) do
    name = __MODULE__.Partitions

    start_supervised!(
      {PartitionSupervisor, child_spec: Task.Supervisor, name: name, partitions: 2}
    )

    {:via, PartitionSupervisor, {name, self()}}
  end

  defp start_caller(fun) do
    owner = self()
    {pid, monitor} = spawn_monitor(fn -> send(owner, {:caller_result, self(), fun.()}) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    {pid, monitor}
  end

  defp caller_result({pid, monitor}) do
    assert_receive {:caller_result, ^pid, result}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    result
  end

  defp finish_execution(execution, operation) do
    if Exec.status(execution) == :running do
      case apply(Exec, operation, [execution]) do
        {:ok, _work, next} -> finish_execution(next, operation)
        {:ok, next} -> Exec.result(next)
      end
    else
      Exec.result(execution)
    end
  end
end
