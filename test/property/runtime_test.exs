Code.require_file("support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.RuntimeTest do
  use ExUnit.Case, async: true
  @moduletag :property
  alias JidoActionTest.Property.Runtime

  test "execution uses the sample supervisor and exits before cleanup" do
    Runtime.with_context(fn context ->
      caller =
        Task.async(fn ->
          Jido.Exec.run(Runtime.Gate, %{value: 7}, context, Runtime.options(context))
        end)

      token = context.token

      try do
        assert_receive {^token, :ready, 7, worker}, 1_000
        assert worker in Task.Supervisor.children(context.supervisor)
        send(worker, {token, :release})
        assert Task.await(caller) == {:ok, %{value: 7}, [7]}
        Runtime.assert_supervisor_idle(context.supervisor)
      after
        Task.shutdown(caller, :brutal_kill)
      end
    end)
  end
end
