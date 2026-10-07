defmodule Jido.Exec.Node.ActionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Node.Action
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Actions.{Add, BasicAction, ErrorAction, UnsupportedResult}
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
