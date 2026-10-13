defmodule Jido.Exec.Node.ActionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Node.Action
  alias Jido.Instruction

  alias JidoActionTest.Fixtures.Actions.{
    Add,
    BasicAction,
    EchoParamsAction,
    ErrorAction,
    ExtrasAction,
    UnsupportedResult
  }

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Invokable}

  test "an Action Instruction becomes a stable Action" do
    instruction = Instruction.new!(target: Add, params: %{amount: 2})

    first = Runic.Transmutable.to_component(instruction)
    second = Runic.Transmutable.to_component(instruction)

    assert %Action{instruction: ^instruction} = first
    assert first.hash == second.hash
    assert Runic.Component.hash(first) == first.hash
  end

  test "Action schemas are available through the Runic Component ports" do
    node = Add |> then(&Instruction.new!(target: &1)) |> Runic.Transmutable.to_component()

    assert Runic.Component.inputs(node)[:in][:schema] == Add.to_json()["input_schema"]
    assert Runic.Component.outputs(node)[:out][:schema] == Add.to_json()["output_schema"]
  end

  test "Runic prepares, executes, and applies an Action" do
    node = Action.new(Instruction.new!(target: Add, params: %{amount: 2}), name: "add")
    workflow = Workflow.new(name: "one_action") |> Workflow.add(node)
    fact = Fact.new(value: %{value: 3})

    assert {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    assert runnable.status == :pending

    executed = Invokable.execute(node, runnable)
    assert executed.status == :completed
    assert %Fact{value: %{value: 5}} = executed.result

    applied = Workflow.apply_runnable(workflow, executed)
    assert Workflow.raw_productions(applied, "add") == [%{value: 5}]
  end

  test "an Action participates in a native SingleOutput batch" do
    node = Action.new(Instruction.new!(target: Add, params: %{amount: 2}), name: "item")
    batch = Runic.batch(node, name: "batch")
    definition = Workflow.new() |> Workflow.add(batch)
    rebuilt = definition |> Workflow.build_log() |> Workflow.from_log()
    {completed, observation} = Workflow.execute(rebuilt, [%{value: 1}, %{value: 3}])

    assert observation.quiescent?

    assert [id] = Runic.Workflow.Batch.invocations(completed, batch)
    assert {:ok, outcomes} = Runic.Workflow.Batch.outcomes(completed, batch, id)

    assert Enum.map(outcomes, & &1.value) == [%{value: 3}, %{value: 5}]
    assert Enum.all?(outcomes, &(&1.status == :completed))
  end

  test "successful output keeps application metadata and effects through the native lifecycle" do
    node = Action.new(Instruction.new!(target: ExtrasAction), name: "effects")

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.put_run_context(%{_global: %{trace_id: "current"}})

    metadata = %{domain: :input, jido: %{effects: [:prior]}, runic: %{internal: :input}}
    fact = Fact.new(value: %{value: 3}, meta: metadata)
    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    executed = Invokable.execute(node, runnable)

    assert executed.status == :completed
    assert executed.result.value == %{value: 3}

    assert executed.result.meta == %{
             domain: :input,
             jido: %{effects: [:prior, %{trace_id: "current"}]}
           }

    assert executed.result.ancestry == {node.hash, fact.hash}
  end

  test "native completion preserves local values from marked and wrapped input Facts" do
    node = Action.new(Instruction.new!(target: EchoParamsAction), name: "local")
    workflow = Workflow.new() |> Workflow.add(node)
    params = %{owner: self(), reference: make_ref(), uri: URI.parse("/local")}

    for fact <- [
          Jido.Exec.Fact.local_root(params),
          Fact.new(value: Jido.Exec.Fact.local_value(params))
        ] do
      {:ok, runnable} = Invokable.prepare(node, workflow, fact)
      executed = Invokable.execute(node, runnable)

      assert executed.status == :completed
      assert Jido.Exec.Fact.value(executed.result) == params
      assert executed.result.meta.jido.identity_mode == :local
    end
  end

  test "native hooks defer graph changes until successful application" do
    node = Action.new(Instruction.new!(target: Add, params: %{amount: 2}), name: "hooks")
    owner = self()

    hook = fn event, _context ->
      send(owner, {:hook, event.timing})

      {:apply,
       fn workflow ->
         send(owner, {:applied, event.timing})
         workflow
       end}
    end

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Map.put(:before_hooks, %{node.hash => [hook]})
      |> Map.put(:after_hooks, %{node.hash => [hook]})

    {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: %{value: 3}))
    executed = Invokable.execute(node, runnable)
    assert executed.status == :completed
    assert_receive {:hook, :before}
    assert_receive {:hook, :after}
    refute_received {:applied, _timing}

    Workflow.apply_runnable(workflow, executed)
    assert_receive {:applied, :before}
    assert_receive {:applied, :after}
  end

  test "hook failures publish no Fact and discard deferred changes" do
    node = Action.new(Instruction.new!(target: ExtrasAction), name: "failed_hooks")
    owner = self()

    before_hook = fn _event, _context ->
      {:apply,
       fn workflow ->
         send(owner, :applied)
         workflow
       end}
    end

    for timing <- [:before_hooks, :after_hooks] do
      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Map.put(:before_hooks, %{node.hash => [before_hook]})
        |> Map.put(timing, %{node.hash => [fn _event, _context -> {:error, :rejected} end]})

      {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: %{value: 3}))
      executed = Invokable.execute(node, runnable)
      assert executed.status == :failed
      assert executed.result == nil
      assert executed.events == nil
      assert executed.hook_apply_fns == nil
      refute_received :applied
    end
  end

  test "input validation fails the Runnable" do
    node = Action.new(Instruction.new!(target: BasicAction), name: "basic")
    workflow = Workflow.new() |> Workflow.add(node)
    fact = Fact.new(value: %{value: "bad"})

    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    executed = Invokable.execute(node, runnable)

    assert executed.status == :failed
    assert %Jido.Action.Error.InvalidInputError{} = executed.error
  end

  test "an Action exception fails the Runnable with a structured error" do
    node = Action.new(Instruction.new!(target: ErrorAction), name: "error")
    workflow = Workflow.new() |> Workflow.add(node)
    fact = Fact.new(value: %{error_type: :runtime})

    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    executed = Invokable.execute(node, runnable)

    assert executed.status == :failed
    assert %Jido.Action.Error.ExecutionFailureError{details: %{phase: :run}} = executed.error
  end

  test "an invalid Action return fails the Runnable" do
    node = Action.new(Instruction.new!(target: UnsupportedResult), name: "unsupported")
    workflow = Workflow.new() |> Workflow.add(node)
    fact = Fact.new(value: %{})

    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    executed = Invokable.execute(node, runnable)

    assert executed.status == :failed

    assert %Jido.Action.Error.ExecutionFailureError{details: %{reason: :invalid_return}} =
             executed.error
  end

  test "normal atoms keep Runic's normal Transmutable behavior" do
    refute match?(%Action{}, Runic.Transmutable.to_component(:ordinary_value))
  end
end
