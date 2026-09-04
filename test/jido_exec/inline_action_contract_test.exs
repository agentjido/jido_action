defmodule JidoActionTest.Exec.InlineActionContractTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.{Exec, Flow}
  alias Jido.Action.{Error, Output}

  defmodule Results do
    def run(%{mode: mode, value: value}) do
      case mode do
        :map -> {:ok, %{value: value}}
        :output -> {:ok, Output.raw(value)}
        :extras -> {:ok, %{value: value}, %{effect: :done}}
        :error_extras -> {:error, Error.execution_error("body error"), %{effect: :done}}
        :raise -> raise "body failed"
        :throw -> throw({:body_throw, value})
        :exit -> exit({:body_exit, value})
        :invalid_callback -> :not_a_result
        :invalid_output -> {:ok, value}
      end
    end
  end

  defmodule MappedResults do
    use Jido.Flow, name: "mapped_results"

    flow do
      map "mapped" do
        collection [input()]

        action %{mode: mode, value: value} <- item() do
          Results.run(%{mode: mode, value: value})
        end
      end

      output result("mapped", 0)
    end
  end

  defmodule CallbackResults do
    use Jido.Flow, name: "callback_results"

    flow do
      dispatch "next" do
        decision params <- input(), do: {:ok, params}
        expander params, do: Results.run(params)
      end

      output result("next")
    end
  end

  defmodule MappedExpression do
    use Jido.Flow, name: "mapped_expression"

    flow do
      map "mapped" do
        collection input(:items)

        action value <- item() / input(:divisor), context: ctx do
          send(ctx.test_pid, {ctx.ref, :body})
          {:ok, %{value: value}}
        end
      end

      output %{items: result("mapped")}
    end
  end

  defmodule DecisionExpression do
    use Jido.Flow, name: "decision_expression"

    flow do
      dispatch "next" do
        decision value <- input(:value) <> context(:suffix), context: ctx do
          send(ctx.test_pid, {ctx.ref, :decision})
          {:ok, %{value: value}}
        end

        expander params, context: ctx do
          send(ctx.test_pid, {ctx.ref, :expander})
          {:ok, params}
        end
      end

      output result("next")
    end
  end

  defmodule ControlledMap do
    use Jido.Flow, name: "controlled_inline_map"

    flow do
      map "mapped" do
        collection input(:items)

        action value <- item(), context: ctx do
          Agent.update(ctx.probe, fn state ->
            running = state.running + 1

            %{
              state
              | running: running,
                max: max(state.max, running),
                started: [value | state.started]
            }
          end)

          send(ctx.test_pid, {ctx.ref, :ready, value, self()})

          receive do
            {:release, ref} when ref == ctx.ref -> :ok
          end

          Agent.update(ctx.probe, &%{&1 | running: &1.running - 1})
          send(ctx.test_pid, {ctx.ref, :finished, value})
          {:ok, %{value: value}}
        end
      end

      output %{items: result("mapped")}
    end
  end

  test "mapped and callback targets keep Action failures, Output envelopes, and extras" do
    for {owner, path, node} <- [
          {MappedResults, [map: "mapped", role: :action], "mapped"},
          {CallbackResults, [dispatch: "next", role: :expander], "next"}
        ] do
      target = Jido.Action.Inline.target!(owner, [host: Jido.Flow] ++ path)

      for {mode, expected} <- [map: %{value: 42}, output: Output.raw(42)] do
        assert Exec.run(target, %{mode: mode, value: 42}) == {:ok, expected}
        assert Exec.run(owner, %{mode: mode, value: 42}) == {:ok, expected}
      end

      assert Exec.run(target, %{mode: :extras, value: 42}) ==
               {:ok, %{value: 42}, %{effect: :done}}

      assert Exec.run(owner, %{mode: :extras, value: 42}) == {:ok, %{value: 42}}

      assert {:error, %{message: "body error"}, %{effect: :done}} =
               Exec.run(target, %{mode: :error_extras, value: 42})

      assert {:error, %{message: "body error"}} =
               Exec.run(owner, %{mode: :error_extras, value: 42})

      for {mode, message, details} <- [
            {:raise, "body failed", %{exception: RuntimeError}},
            {:throw, "action throw", %{reason: {:body_throw, 42}}},
            {:exit, "action exit", %{reason: {:body_exit, 42}}},
            {:invalid_callback, "action returned an unsupported result",
             %{result: :not_a_result}},
            {:invalid_output, "action returned a value that requires an output envelope",
             %{callback: :run, output: 42}}
          ],
          executable <- [target, owner] do
        assert {:error, %Error.ExecutionFailureError{} = error} =
                 Exec.run(executable, %{mode: mode, value: 42})

        assert error.message == message
        assert error.details.action == target
        assert Map.take(error.details, Map.keys(details)) == details
        refute Error.retryable?(error)
        if executable == owner, do: assert(error.details.node == node)
        if mode in [:raise, :throw, :exit], do: assert(%Splode.Stacktrace{} = error.stacktrace)
      end
    end
  end

  test "inline binding errors retain Expr locations and stop before body work" do
    ref = make_ref()
    context = %{test_pid: self(), ref: ref, secret: "private-context"}

    for {item, divisor, reason} <- [
          {4, 0, :division_by_zero},
          {"private-operand", 2, :invalid_numeric_operands}
        ] do
      assert {:error, error} =
               Exec.run(MappedExpression, %{items: [item], divisor: divisor}, context)

      assert error.details.operator == :divide
      assert error.details.reason == reason
      assert error.details.expression_path == [:value]
      assert error.details.retry == false
      refute inspect(error, limit: :infinity) =~ "private-operand"
      refute inspect(Flow.Error.to_map(error), limit: :infinity) =~ "private-context"
      refute_received {^ref, :body}
    end

    private = String.duplicate("private-data", 40_000)

    assert {:error, error} =
             Exec.run(DecisionExpression, %{value: private}, Map.put(context, :suffix, private))

    assert error.details.operator == :concat
    assert error.details.reason == :max_binary_bytes
    assert error.details.expression_path == [:value]
    refute inspect(error, limit: :infinity) =~ "private-data"
    refute inspect(Flow.Error.to_map(error), limit: :infinity) =~ "private-context"
    refute_received {^ref, :decision}
    refute_received {^ref, :expander}
  end

  test "inline Map work is bounded, ordered, and runs once in full and step-wise execution" do
    for limit <- [1, 2], mode <- [:run, :stepwise] do
      probe =
        start_supervised!(
          Supervisor.child_spec({Agent, fn -> %{running: 0, max: 0, started: []} end},
            id: {limit, mode}
          )
        )

      ref = make_ref()
      context = %{probe: probe, test_pid: self(), ref: ref}

      task =
        Task.async(fn ->
          case mode do
            :run ->
              Exec.run(ControlledMap, %{items: [1, 2, 3, 4]}, context, max_concurrency: limit)

            :stepwise ->
              {:ok, initial} =
                Exec.start(ControlledMap, %{items: [1, 2, 3, 4]}, context, max_concurrency: limit)

              {:ok, final} = Exec.continue(initial)
              # Reuse must fail without a second body call.
              {:error, _} = Exec.continue(initial)
              Exec.result(final)
          end
        end)

      try do
        workers =
          Enum.flat_map(Enum.chunk_every(1..4, limit), fn batch ->
            ready =
              for _ <- batch do
                assert_receive {^ref, :ready, value, worker}, 1_000
                {value, worker, Process.monitor(worker)}
              end

            # The Agent call is a barrier after every admitted body has recorded its start.
            assert Agent.get(probe, & &1.max) == limit

            for {_value, worker, _monitor} <- Enum.reverse(ready),
                do: send(worker, {:release, ref})

            ready
          end)

        assert Task.await(task) ==
                 {:ok, %{items: [%{value: 1}, %{value: 2}, %{value: 3}, %{value: 4}]}}

        assert Agent.get(probe, & &1.running) == 0
        assert Agent.get(probe, &Enum.sort(&1.started)) == [1, 2, 3, 4]

        for {value, worker, monitor} <- workers do
          assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
          assert_received {^ref, :finished, ^value}
        end

        refute_received {^ref, :ready, _, _}
        refute_received {^ref, :finished, _}
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "cancelling inline Map work stops all workers and releases the routed supervisor" do
    instance = JidoActionTest.InlineMapCancellation
    supervisor = Exec.task_supervisor_name(instance)
    start_supervised!({Task.Supervisor, name: supervisor})
    probe = start_supervised!({Agent, fn -> %{running: 0, max: 0, started: []} end})
    ref = make_ref()
    context = %{probe: probe, test_pid: self(), ref: ref}

    handle =
      Exec.run_async(ControlledMap, %{items: [1, 2, 3, 4]}, context,
        max_concurrency: 2,
        jido: instance
      )

    try do
      workers =
        for _ <- 1..2 do
          assert_receive {^ref, :ready, _value, worker}, 1_000
          worker
        end

      children = Task.Supervisor.children(supervisor)
      assert handle.pid in children
      assert Enum.all?(workers, &(&1 in children))
      monitors = for child <- children, do: {child, Process.monitor(child)}
      assert Agent.get(probe, & &1.max) == 2
      assert :ok = Exec.cancel(handle)

      for {child, monitor} <- monitors,
          do: assert_receive({:DOWN, ^monitor, :process, ^child, _}, 1_000)

      assert Task.Supervisor.children(supervisor) == []
      assert length(Agent.get(probe, & &1.started)) == 2
      refute_received {^ref, :ready, _, _}
      refute_received {^ref, :finished, _}
      handle_ref = handle.ref
      handle_monitor = handle.monitor_ref
      refute_received {:jido_exec_async_result, ^handle_ref, _, _}
      refute_received {:DOWN, ^handle_monitor, :process, _, _}
      assert {:error, %Jido.Exec.Error.InvalidHandleError{}} = Exec.await(handle)
    after
      Exec.cancel(handle)
    end
  end
end
