defmodule JidoActionTest.Exec.FlowActionContractTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Jido.Exec
  alias Jido.Action.{Error, Output}

  defmodule InputError do
    defexception [:message, :details, :stacktrace]
  end

  defmodule RejectedInputAction do
    def __jido_executable__ do
      Jido.Executable.action(__MODULE__)
    end

    def validate_params(%{error: error}) do
      {:error, error}
    end

    def validate_output(value) do
      {:ok, value}
    end

    def run(_params, _context) do
      raise "invalid input reached the Action"
    end
  end

  test "Step validation preserves input errors with any details shape" do
    {:ok, flow} =
      Jido.Flow.new(%{
        output: Jido.Flow.Ref.result("reject"),
        components: [
          %{
            kind: :step,
            name: "reject",
            action: RejectedInputAction,
            params: Jido.Flow.Ref.input([])
          }
        ],
        name: "rejected_input"
      })

    stacktrace = [{__MODULE__, :validate_input, 1, file: ~c"input.ex", line: 1}]

    errors = [
      RuntimeError.exception("input rejected"),
      %InputError{message: "input rejected", details: nil, stacktrace: stacktrace},
      %InputError{message: "input rejected", details: [:invalid], stacktrace: stacktrace},
      %InputError{
        message: "input rejected",
        details: %{field: :value, phase: :custom},
        stacktrace: stacktrace
      }
    ]

    for original <- errors do
      assert Exec.run(RejectedInputAction, %{error: original}) == {:error, original}
      assert {:error, %Error.InvalidInputError{} = error} = Exec.run(flow, %{error: original})
      assert error.message == "input rejected"
      assert error.details.node == "reject"
      assert error.details.node_path == ["reject"]
      assert error.details.action == RejectedInputAction
      assert error.details.phase == :step_input

      if is_map(Map.get(original, :details)) do
        assert error.details.field == :value
      end

      if Map.has_key?(original, :stacktrace) do
        assert error.stacktrace == stacktrace
      end
    end
  end

  defmodule Results do
    def run(%{mode: mode, value: value}) do
      case mode do
        :map -> {:ok, %{value: value}}
        :output -> {:ok, Output.raw(value)}
        :extras -> {:ok, %{value: value}, [:request]}
        :error_extras -> {:error, Error.execution_error("body error"), %{effect: :done}}
        :raise -> raise "body failed"
        :throw -> throw({:body_throw, value})
        :exit -> exit({:body_exit, value})
        :invalid_callback -> :not_a_result
        :invalid_output -> {:ok, value}
      end
    end
  end

  defmodule MappedResultAction do
    use Jido.Action, name: "mapped_result_action"
    @impl true
    def run(params, _context) do
      Results.run(params)
    end
  end

  defmodule IdentityDecision do
    use Jido.Action, name: "identity_decision"
    @impl true
    def run(params, _context) do
      {:ok, params}
    end
  end

  defmodule CallbackResultAction do
    use Jido.Action, name: "callback_result_action"
    @impl true
    def run(params, _context) do
      Results.run(params)
    end
  end

  defmodule MappedResults do
    use Jido.Flow, name: "mapped_results"

    flow do
      map("mapped") do
        collection([input()])
        action(MappedResultAction)
        params(item())
      end

      output(result("mapped", 0))
    end
  end

  defmodule CallbackResults do
    use Jido.Flow, name: "callback_results"

    flow do
      dispatch("next") do
        decision(IdentityDecision)
        params(input())
        expander(CallbackResultAction)
      end

      output(result("next"))
    end
  end

  defmodule ControlledMapAction do
    use Jido.Action, name: "controlled_map_action"
    @impl true
    def run(%{value: value}, ctx) do
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

  defmodule ControlledMap do
    use Jido.Flow, name: "controlled_map"

    flow do
      map("mapped") do
        collection(input(:items))
        action(ControlledMapAction)
        params(%{value: item()})
      end

      output(%{items: result("mapped")})
    end
  end

  test "mapped and callback Actions keep failures, Output envelopes, and extras" do
    for {owner, target, node} <- [
          {MappedResults, MappedResultAction, "mapped"},
          {CallbackResults, CallbackResultAction, "next"}
        ] do
      for {mode, expected} <- [map: %{value: 42}, output: Output.raw(42)] do
        assert Exec.run(target, %{mode: mode, value: 42}) == {:ok, expected}
        assert Exec.run(owner, %{mode: mode, value: 42}) == {:ok, expected}
      end

      assert Exec.run(target, %{mode: :extras, value: 42}) == {:ok, %{value: 42}, [:request]}
      assert Exec.run(owner, %{mode: :extras, value: 42}) == {:ok, %{value: 42}, [:request]}

      assert {:error, %{message: "body error"}} =
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

        if executable == owner do
          assert error.details.node == node
        end

        if mode in [:raise, :throw, :exit] do
          assert %Splode.Stacktrace{} = error.stacktrace
        end
      end
    end
  end

  test "Map work is bounded, ordered, and runs once in full and step-wise execution" do
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
                assert_receive {^ref, :ready, value, worker}, 1000
                {value, worker, Process.monitor(worker)}
              end

            # The Agent call is a barrier after every admitted body has recorded its start.
            assert Agent.get(probe, & &1.max) == limit

            for {_value, worker, _monitor} <- Enum.reverse(ready) do
              send(worker, {:release, ref})
            end

            ready
          end)

        assert Task.await(task) ==
                 {:ok, %{items: [%{value: 1}, %{value: 2}, %{value: 3}, %{value: 4}]}}

        assert Agent.get(probe, & &1.running) == 0
        assert Agent.get(probe, &Enum.sort(&1.started)) == [1, 2, 3, 4]

        for {value, worker, monitor} <- workers do
          assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
          assert_received {^ref, :finished, ^value}
        end

        refute_received {^ref, :ready, _, _}
        refute_received {^ref, :finished, _}
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "cancelling Map work stops all workers and releases the routed supervisor" do
    instance = JidoActionTest.FlowMapCancellation
    supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: supervisor})
    probe = start_supervised!({Agent, fn -> %{running: 0, max: 0, started: []} end})
    ref = make_ref()
    context = %{probe: probe, test_pid: self(), ref: ref}

    handle =
      Exec.run_async(ControlledMap, %{items: [1, 2, 3, 4]}, context,
        max_concurrency: 2,
        task_supervisor: supervisor
      )

    try do
      workers =
        for _ <- 1..2 do
          assert_receive {^ref, :ready, _value, worker}, 1000
          worker
        end

      children = Task.Supervisor.children(supervisor)
      assert handle.pid in children
      assert children == [handle.pid]
      assert Enum.all?(workers, &(&1 != handle.pid))

      monitors =
        for child <- children ++ workers do
          {child, Process.monitor(child)}
        end

      assert Agent.get(probe, & &1.max) == 2
      assert :ok = Exec.cancel(handle)

      for {child, monitor} <- monitors do
        assert_receive {:DOWN, ^monitor, :process, ^child, _}, 1000
      end

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
