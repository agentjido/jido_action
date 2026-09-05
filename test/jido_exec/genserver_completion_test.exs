defmodule JidoActionTest.Exec.GenServerCompletionTest do
  use ExUnit.Case, async: false

  alias Jido.Exec.Error.AsyncExecutionError
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  # Compile the exact guide example so the public callback pattern stays usable.
  @guide Path.expand("../../guides/execution.md", __DIR__)
  @external_resource @guide
  [_, source] =
    Regex.run(~r/```elixir\n(defmodule MyApp.ReportServer.*?\nend)\n/s, File.read!(@guide))

  Code.compile_string(source, @guide)

  test "the documented server handles calls while work runs and consumes completion" do
    supervisor = start_supervised!(Task.Supervisor)

    server =
      start_supervised!({MyApp.ReportServer, target: BlockingAction, task_supervisor: supervisor})

    :erlang.trace(server, true, [:receive])

    assert :ok = GenServer.call(server, {:run, %{value: :report}, %{test_pid: self()}})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert GenServer.call(server, :status) == %{running?: true, result: nil}
    assert GenServer.call(server, {:run, %{}, %{}}) == {:error, :busy}
    send(server, :unrelated)
    assert GenServer.call(server, :status) == %{running?: true, result: nil}

    send(worker, :finish)
    # The receive trace is a barrier: the server has selected its completion
    # before the next status call. No timing or polling is needed.
    assert_receive {:trace, ^server, :receive, {:jido_exec_async_result, _, _, _}}, 1_000
    assert GenServer.call(server, :status) == %{running?: false, result: {:ok, %{value: :report}}}
    send(server, :stale)
    assert GenServer.call(server, :status).running? == false
    :erlang.trace(server, false, [:receive])
  end

  test "the documented server contains a control-task capacity failure" do
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})

    server =
      start_supervised!({MyApp.ReportServer, target: BlockingAction, task_supervisor: supervisor})

    assert {:error, %AsyncExecutionError{details: %{reason: :max_children}}} =
             GenServer.call(server, {:run, %{}, %{}})

    assert GenServer.call(server, :status) == %{running?: false, result: nil}
  end
end
