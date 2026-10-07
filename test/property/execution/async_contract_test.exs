Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.AsyncContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.Runtime
  @ready_timeout 5_000

  @tag contracts: ["EXEC-006", "EFFECT-002"]
  @tag contract_cases: ["EXEC-006/foreign-consumers", "EXEC-006/cancel", "EXEC-006/handle-reuse"]
  property "foreign consumers cannot claim a handle and the owner can cancel its workers" do
    check all(count <- integer(1..4), max_runs: 20) do
      Runtime.with_context(fn context ->
        token = context.token
        handle = Exec.run_async(blocked(count), %{}, context, Runtime.options(context, count))

        try do
          workers =
            for index <- 1..count do
              assert_receive {^token, :ready, ^index, worker}, @ready_timeout
              worker
            end

          caller =
            Task.async(fn ->
              {Exec.await(handle, 0), Exec.cancel(handle),
               Exec.handle_message(handle, :unrelated)}
            end)

          assert {{:error, await_error}, {:error, cancel_error}, {:error, message_error}} =
                   Task.await(caller)

          for error <- [await_error, cancel_error, message_error], do: assert(is_exception(error))
          assert Enum.all?(workers, &Process.alive?/1)
          assert Exec.handle_message(handle, :unrelated) == :ignore
          assert :ok = Exec.cancel(handle)
          Runtime.assert_workers_stopped(workers ++ [handle.pid])
          assert {:error, _} = Exec.await(handle, 0)
          refute_received {:jido_exec_async_result, _, _, {:ok, _, _}}
        after
          Exec.cancel(handle)
        end
      end)
    end
  end

  @tag contracts: ["EXEC-006", "EFFECT-002"]
  @tag contract_cases: ["EXEC-006/owner-death"]
  property "owner death cancels active concurrent callbacks under a living controller" do
    check all(count <- integer(1..4), max_runs: 15) do
      Runtime.with_context(fn context ->
        token = context.token

        owner =
          spawn(fn ->
            handle = Exec.run_async(blocked(count), %{}, context, Runtime.options(context, count))
            send(context.observer, {token, :handle, handle})

            receive do
              {^token, :stop} -> :ok
            end
          end)

        monitor = Process.monitor(owner)

        try do
          assert_receive {^token, :handle, handle}, @ready_timeout

          workers =
            for index <- 1..count do
              assert_receive {^token, :ready, ^index, worker}, @ready_timeout
              worker
            end

          send(owner, {token, :stop})
          assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
          Runtime.assert_workers_stopped(workers ++ [handle.pid])
          refute_received {^token, :ready, _, _}
        after
          if Process.alive?(owner), do: Process.exit(owner, :kill)
          Process.demonitor(monitor, [:flush])
        end
      end)
    end
  end

  @tag contracts: ["EXEC-006", "EFFECT-002"]
  @tag contract_cases: ["EXEC-006/await-timeout", "EFFECT-002/await-timeout"]
  property "an await timeout cancels work and yields no partial effect batch" do
    check all(value <- integer(), max_runs: 20) do
      Runtime.with_context(fn context ->
        token = context.token
        flow = with_prior_effect(value)
        handle = Exec.run_async(flow, %{}, context, Runtime.options(context))

        try do
          assert_receive {^token, :ready, ^value, worker}, @ready_timeout
          assert {:error, %Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
          Runtime.assert_workers_stopped([worker, handle.pid])
          Runtime.assert_calls(context, [value])
          refute_received {:jido_exec_async_result, _, _, _}
        after
          Exec.cancel(handle)
        end
      end)
    end
  end

  @tag contracts: ["EXEC-006"]
  @tag contract_cases: ["EXEC-006/handle-message", "EXEC-006/mailbox"]
  property "message consumption preserves success once and drains the handle mailbox" do
    check all(value <- integer(), max_runs: 30) do
      Runtime.with_context(fn context ->
        token = context.token
        handle = Exec.run_async(Runtime.Emit, %{value: value}, context, Runtime.options(context))

        try do
          ref = handle.ref
          pid = handle.pid
          assert_receive {:jido_exec_async_result, ^ref, ^pid, _} = message, @ready_timeout
          assert {:done, {:ok, %{value: ^value}, [^value]}} = Exec.handle_message(handle, message)
          assert {:error, _} = Exec.await(handle, 0)
          Runtime.assert_workers_stopped([pid])
          Runtime.assert_calls(context, [value])
          refute_received {:jido_exec_async_result, ^ref, ^pid, _}
          refute_received {^token, :call, _, _}
        after
          Exec.cancel(handle)
        end
      end)
    end
  end

  defp blocked(count) do
    components =
      for index <- 1..count,
          do:
            JidoActionTest.FlowComponent.step!(
              name: "n#{index}",
              action: Runtime.Gate,
              params: %{value: index}
            )

    JidoActionTest.FlowBuilder.new!(name: "async", components: components, output: %{done: true})
  end

  defp with_prior_effect(value) do
    JidoActionTest.FlowBuilder.new!(
      name: "partial_effects",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "first",
          action: Runtime.Emit,
          params: %{value: value}
        ),
        JidoActionTest.FlowComponent.step!(
          name: "blocked",
          action: Runtime.Gate,
          params: %{value: value},
          needs: ["first"]
        )
      ],
      output: Ref.result("blocked")
    )
  end
end
