defmodule JidoActionTest.Exec.GenServerCompletionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Error.AsyncExecutionError
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  defmodule ReportServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{supervisor: opts[:supervisor], owner: opts[:owner], handle: nil, result: nil}}
    end

    @impl true
    def handle_call({:run, value}, _from, %{handle: nil} = state) do
      handle =
        Jido.Exec.run_async(BlockingAction, %{value: value}, %{test_pid: state.owner},
          task_supervisor: state.supervisor
        )

      {:reply, :ok, %{state | handle: handle}}
    rescue
      error in AsyncExecutionError -> {:reply, {:error, error}, state}
    end

    def handle_call({:run, _value}, _from, state), do: {:reply, {:error, :busy}, state}

    def handle_call(:status, _from, state),
      do: {:reply, %{running?: state.handle != nil, result: state.result}, state}

    @impl true
    def handle_info(_message, %{handle: nil} = state), do: {:noreply, state}

    def handle_info(message, state) do
      case Jido.Exec.handle_message(state.handle, message) do
        :ignore ->
          {:noreply, state}

        {:done, result} ->
          send(state.owner, {:completed, self(), result})
          {:noreply, %{state | handle: nil, result: result}}
      end
    end
  end

  test "a GenServer remains responsive and consumes completion in its owner" do
    supervisor = start_supervised!(Task.Supervisor)

    server = start_supervised!({ReportServer, supervisor: supervisor, owner: self()})

    assert :ok = GenServer.call(server, {:run, :report})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert GenServer.call(server, :status) == %{running?: true, result: nil}
    assert GenServer.call(server, {:run, :other}) == {:error, :busy}
    send(server, :unrelated)
    assert GenServer.call(server, :status) == %{running?: true, result: nil}

    send(worker, :finish)
    assert_receive {:completed, ^server, {:ok, %{value: :report}}}, 1_000
    assert GenServer.call(server, :status) == %{running?: false, result: {:ok, %{value: :report}}}
    send(server, :stale)
    assert GenServer.call(server, :status).running? == false
  end

  test "a GenServer contains a control-task capacity failure" do
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})

    server = start_supervised!({ReportServer, supervisor: supervisor, owner: self()})

    assert {:error, %AsyncExecutionError{details: %{reason: :max_children}}} =
             GenServer.call(server, {:run, :report})

    assert GenServer.call(server, :status) == %{running?: false, result: nil}
  end
end
