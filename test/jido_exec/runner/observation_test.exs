defmodule Jido.Exec.Runner.ObservationTest do
  use ExUnit.Case, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Runic.Workflow.Execution

  defmodule Controlled do
    use Jido.Action, name: "managed_observation"

    @impl true
    def run(params, %{observer: observer}) do
      send(Process.whereis(observer), {:started, params.label, self()})

      receive do
        :release ->
          if params.fail, do: {:error, params.label}, else: {:ok, params, [:saved]}
      end
    end
  end

  setup do
    runner = __MODULE__.Runner
    observer = __MODULE__.Observer
    Process.register(self(), observer)
    start_supervised!({Runic.Runner, name: runner})
    owner = self()

    hooks = [
      on_dispatch: fn _units, state -> send(owner, {:scope, state.current_execution_id}) end,
      on_failed: fn runnable, _reason, _state -> send(owner, {:failed, runnable.node.name}) end,
      on_idle: fn _state -> send(owner, :idle) end
    ]

    %{runner: runner, context: %{observer: observer}, opts: [hooks: hooks]}
  end

  test "managed results use a Runic input occurrence and reject active work", ctx do
    id = {:observed, System.unique_integer([:positive])}
    params = %{label: :one, fail: false}
    assert {:ok, _worker} = Exec.start(ctx.runner, id, Controlled, params, ctx.context, ctx.opts)
    assert_receive {:scope, scope_id}
    assert_receive {:started, :one, task}

    assert {:ok, %Execution{quiescent?: false}} =
             Runic.Runner.execution(ctx.runner, id, scope_id)

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
             Exec.result(ctx.runner, id)

    assert details.reason == :execution_active
    send(task, :release)
    assert_receive :idle

    assert {:ok, observation} = Runic.Runner.execution(ctx.runner, id, scope_id)
    assert observation.quiescent?
    assert observation.id.domain == :execution
    assert observation.input_id.domain == :input_command
    assert observation.input_fact_id.domain == :fact_occurrence
    assert observation.persistence.status == :saved
    assert observation.persistence.pending_events == 0
    assert Exec.result(ctx.runner, id) == {:ok, params, [:saved]}
  end

  test "later inputs keep distinct identities and do not replace the managed result", ctx do
    id = {:repeated, System.unique_integer([:positive])}
    params = %{label: :first, fail: false}
    assert {:ok, _worker} = Exec.start(ctx.runner, id, Controlled, params, ctx.context, ctx.opts)
    assert_receive {:scope, first_id}
    assert_receive {:started, :first, task}
    send(task, :release)
    assert_receive :idle
    assert {:ok, first} = Runic.Runner.execution(ctx.runner, id, first_id)

    [second, third] =
      for _repeat <- 1..2 do
        next = %{params | label: :second}
        assert {:ok, next_id} = Runic.Runner.start_execution(ctx.runner, id, next)
        assert_receive {:started, :second, task}
        assert Exec.result(ctx.runner, id) == {:ok, params, [:saved]}
        send(task, :release)
        assert_receive :idle
        assert {:ok, observation} = Runic.Runner.execution(ctx.runner, id, next_id)
        assert observation.id != first.id
        assert observation.input_fact_id != first.input_fact_id
        assert {:ok, workflow} = Runic.Runner.get_workflow(ctx.runner, id)
        assert Exec.result(workflow, observation) == {:ok, next, [:saved]}
        assert Exec.result(ctx.runner, id) == {:ok, params, [:saved]}
        observation
      end

    assert second.id != third.id
    assert second.input_fact_id != third.input_fact_id
  end

  test "managed failure selection follows component order after active work drains", ctx do
    id = {:failure, System.unique_integer([:positive])}

    assert {:ok, _worker} =
             Exec.start(
               ctx.runner,
               id,
               failure_flow(),
               %{},
               ctx.context,
               ctx.opts ++ [max_concurrency: 2]
             )

    assert_receive {:started, :a, a}
    assert_receive {:started, :b, b}
    send(b, :release)
    assert_receive {:failed, "b"}

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
             Exec.result(ctx.runner, id)

    assert details.reason == :execution_active
    send(a, :release)
    assert_receive :idle

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "a"}} =
             Exec.result(ctx.runner, id)
  end

  test "serial managed admission selects the same first failure as concurrent admission", ctx do
    id = {:serial_failure, System.unique_integer([:positive])}

    assert {:ok, _worker} =
             Exec.start(
               ctx.runner,
               id,
               failure_flow(),
               %{},
               ctx.context,
               ctx.opts ++ [max_concurrency: 1]
             )

    assert_receive {:started, :a, task}
    send(task, :release)
    assert_receive :idle
    refute_received {:started, :b, _task}

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "a"}} =
             Exec.result(ctx.runner, id)
  end

  for order <- [[:a, :b], [:b, :a]] do
    @tag completion_order: order
    test "failure selection survives resume after completion order #{inspect(order)}", ctx do
      id = {:failure_resume, System.unique_integer([:positive])}
      opts = ctx.opts ++ [max_concurrency: 2]

      assert {:ok, _worker} =
               Exec.start(ctx.runner, id, failure_flow(), %{}, ctx.context, opts)

      assert_receive {:started, :a, a}
      assert_receive {:started, :b, b}
      tasks = %{a: a, b: b}

      for label <- ctx.completion_order do
        name = Atom.to_string(label)
        send(tasks[label], :release)
        assert_receive {:failed, ^name}
      end

      assert_receive :idle
      assert {:error, %{message: "a", details: details}} = Exec.result(ctx.runner, id)
      assert :ok = Runic.Runner.checkpoint(ctx.runner, id)
      assert :ok = Runic.Runner.stop(ctx.runner, id, persist: true)
      assert {:ok, _worker} = Exec.resume(ctx.runner, id, ctx.context, opts)

      assert {:error, %{message: "a", details: ^details}} = Exec.result(ctx.runner, id)
      assert {:ok, workflow} = Runic.Runner.get_workflow(ctx.runner, id)
      assert {:error, %{message: "a", details: ^details}} = Exec.result(workflow)
    end
  end

  test "resumed execution keeps snapshot results and rejects active recovery", ctx do
    id = {:resumed, System.unique_integer([:positive])}
    params = %{label: :restored, fail: false}
    assert {:ok, _worker} = Exec.start(ctx.runner, id, Controlled, params, ctx.context, ctx.opts)
    assert_receive {:scope, scope_id}
    assert_receive {:started, :restored, _task}
    assert :ok = Runic.Runner.checkpoint(ctx.runner, id)
    assert :ok = Runic.Runner.stop(ctx.runner, id, persist: true)

    assert {:ok, _worker} =
             Exec.resume(ctx.runner, id, ctx.context, ctx.opts ++ [dispatch_mode: :manual])

    assert Runic.Runner.execution(ctx.runner, id, scope_id) == {:error, :not_found}

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
             Exec.result(ctx.runner, id)

    assert details.reason == :execution_active
    assert {:ok, _workflow} = Exec.step(ctx.runner, id)
    assert_receive {:started, :restored, task}

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{details: %{reason: :execution_active}}} =
             Exec.result(ctx.runner, id)

    send(task, :release)
    assert_receive :idle
    assert Exec.result(ctx.runner, id) == {:ok, params, [:saved]}
  end

  test "missing managed executions keep the Runner lookup error", ctx do
    assert Exec.result(ctx.runner, :missing) == {:error, :not_found}
  end

  defp failure_flow do
    Flow.new!(%{
      name: "managed_failure_order",
      components: [
        %{kind: :step, name: "a", action: Controlled, params: %{label: :a, fail: true}},
        %{kind: :step, name: "b", action: Controlled, params: %{label: :b, fail: true}}
      ],
      output: %{a: Ref.result("a"), b: Ref.result("b")}
    })
  end
end
