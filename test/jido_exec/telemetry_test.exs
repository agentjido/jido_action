defmodule Jido.Exec.TelemetryTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref}
  alias Jido.Instruction

  alias JidoTest.TestActions.{
    Add,
    Divide,
    ErrorAction,
    ErrorWithExtrasAction,
    InvalidValidationResultAction,
    Multiply
  }

  @exec_stop [:jido, :exec, :run, :stop]
  @exec_start [:jido, :exec, :run, :start]
  @node_stop [:jido, :flow, :node, :stop]
  @node_start [:jido, :flow, :node, :start]

  test "emits an exec span for successful action execution" do
    attach_telemetry([@exec_stop])

    assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5}, %{})

    assert_receive {:telemetry_event, @exec_stop, measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.kind == :action
    assert metadata.name == "add_one"
    assert metadata.status == :ok
  end

  test "emits an exec span for instruction execution" do
    attach_telemetry([@exec_stop])

    instruction = Instruction.new!(action: Add, params: %{value: 5})

    assert {:ok, %{value: 6}} = Exec.run(instruction)

    assert_receive {:telemetry_event, @exec_stop, _measurements, metadata}
    assert metadata.kind == :instruction
    assert metadata.name == "add_one"
    assert metadata.status == :ok
  end

  test "marks exec span errors with normalized error type" do
    attach_telemetry([@exec_stop])

    assert {:error, %ExecutionFailureError{}} =
             Exec.run(ErrorAction, %{error_type: :validation}, %{})

    assert_receive {:telemetry_event, @exec_stop, _measurements, metadata}
    assert metadata.kind == :action
    assert metadata.status == :error
    assert metadata.error_type == :execution_error
  end

  test "marks invalid validator results as execution errors" do
    attach_telemetry([@exec_stop])

    assert {:error, %ExecutionFailureError{}} = Exec.run(InvalidValidationResultAction)

    assert_receive {:telemetry_event, @exec_stop, _measurements, metadata}
    assert metadata.status == :error
    assert metadata.error_type == :execution_error
  end

  test "marks action errors with extras as execution errors" do
    attach_telemetry([@exec_stop])

    assert {:error, %ExecutionFailureError{}, %{ignored: true}} =
             Exec.run(ErrorWithExtrasAction)

    assert_receive {:telemetry_event, @exec_stop, _measurements, metadata}
    assert metadata.status == :error
    assert metadata.error_type == :execution_error
  end

  test "emits exec and node spans for flow execution" do
    attach_telemetry([@exec_stop, @node_stop])
    flow = three_node_flow()

    assert {:ok, %{value: 9}} = Exec.run(flow, %{value: 2}, %{})

    node_metadata = receive_metadata(@node_stop, 3)

    assert MapSet.new(Enum.map(node_metadata, & &1.node)) ==
             MapSet.new(["add_one", "multiply", "add_three"])

    assert Enum.all?(node_metadata, &(&1.flow == "telemetry_flow"))
    assert Enum.all?(node_metadata, &(&1.status == :ok))

    assert_receive {:telemetry_event, @exec_stop, _measurements, metadata}
    assert metadata.kind == :flow
    assert metadata.name == "telemetry_flow"
    assert metadata.status == :ok
  end

  test "emits node spans from async flow execution" do
    attach_telemetry([@node_stop])

    assert {:ok, %{value: 9}} = Exec.run(three_node_flow(), %{value: 2}, %{}, async: true)

    node_metadata = receive_metadata(@node_stop, 3)

    assert MapSet.new(Enum.map(node_metadata, & &1.node)) ==
             MapSet.new(["add_one", "multiply", "add_three"])

    assert Enum.all?(node_metadata, &(&1.status == :ok))
  end

  test "emits failed node spans without observing skipped downstream nodes" do
    attach_telemetry([@node_stop])

    assert {:error, %ExecutionFailureError{}} = Exec.run(failing_flow(), %{}, %{})

    assert_receive {:telemetry_event, @node_stop, _measurements, metadata}
    assert metadata.node == "divide"
    assert metadata.status == :error
    assert metadata.error_type == :execution_error

    refute_receive {:telemetry_event, @node_stop, _measurements, %{node: "skipped"}}, 50
  end

  test "emits one Choice node span with selected target metadata" do
    assert {:ok, %{value: 2}} = Exec.run(Add, %{value: 1}, %{})
    attach_telemetry([@node_start, @node_stop])

    flow =
      Flow.new!(
        name: "choice_telemetry_flow",
        nodes: [
          Choice.new!(
            name: :route,
            options: [
              [
                name: :selected,
                condition: Condition.eq(Ref.value(true), Ref.value(true)),
                action: Add,
                input: %{value: Ref.value(3), amount: Ref.value(1)}
              ],
              [
                name: :unselected,
                condition: Condition.eq(Ref.value(false), Ref.value(true)),
                action: Multiply,
                input: %{value: Ref.value(3), amount: Ref.value(2)}
              ]
            ],
            fallback: [action: Add, input: %{value: Ref.value(0), amount: Ref.value(0)}]
          )
        ],
        return: Ref.result(:route)
      )

    assert {:ok, %{value: 4}} = Exec.run(flow, %{}, %{})

    assert_receive {:telemetry_event, @node_start, %{}, start_metadata}

    assert Map.take(start_metadata, [:flow, :node, :kind]) == %{
             flow: "choice_telemetry_flow",
             node: "route",
             kind: :choice
           }

    refute Map.has_key?(start_metadata, :option)
    refute Map.has_key?(start_metadata, :target)

    assert_receive {:telemetry_event, @node_stop, measurements, stop_metadata}
    assert is_integer(measurements.duration)

    assert Map.take(stop_metadata, [:flow, :node, :kind, :option, :target, :status]) == %{
             flow: "choice_telemetry_flow",
             node: "route",
             kind: :choice,
             option: "selected",
             target: Add,
             status: :ok
           }

    refute_receive {:telemetry_event, @node_start, _measurements, _metadata}, 50
    refute_receive {:telemetry_event, @node_stop, _measurements, _metadata}, 50
  end

  test "emits selected nested Flow spans inside the outer Choice span" do
    assert {:ok, %{value: 2}} = Exec.run(Add, %{value: 1}, %{})

    target = Module.concat(__MODULE__, "ChoiceNestedFlow#{System.unique_integer([:positive])}")

    assert {:module, ^target, _bytecode, _term} =
             Module.create(
               target,
               quote do
                 use Jido.Flow, name: "choice_nested_telemetry_flow"

                 flow do
                   step(:add, unquote(Add), %{value: input(:value), amount: value(1)})
                   return(result(:add))
                 end
               end,
               Macro.Env.location(__ENV__)
             )

    attach_telemetry([@exec_start, @exec_stop, @node_start, @node_stop])

    flow =
      Flow.new!(
        name: "outer_choice_telemetry_flow",
        nodes: [
          Choice.new!(
            name: :route,
            options: [
              [
                name: :nested,
                condition: Condition.eq(Ref.value(true), Ref.value(true)),
                action: target,
                input: %{value: Ref.value(3)}
              ]
            ],
            fallback: [action: Add, input: %{value: Ref.value(0), amount: Ref.value(0)}]
          )
        ],
        return: Ref.result(:route)
      )

    assert {:ok, %{value: 4}} = Exec.run(flow, %{}, %{})

    assert_receive {:telemetry_event, @exec_start, %{},
                    %{kind: :flow, name: "outer_choice_telemetry_flow"}}

    assert_receive {:telemetry_event, @node_start, %{},
                    %{flow: "outer_choice_telemetry_flow", node: "route", kind: :choice}}

    assert_receive {:telemetry_event, @exec_start, %{},
                    %{kind: :flow, name: "choice_nested_telemetry_flow"}}

    assert_receive {:telemetry_event, @node_start, %{},
                    %{flow: "choice_nested_telemetry_flow", node: "add"}}

    assert_receive {:telemetry_event, @node_stop, _measurements,
                    %{flow: "choice_nested_telemetry_flow", node: "add", status: :ok}}

    assert_receive {:telemetry_event, @exec_stop, _measurements,
                    %{kind: :flow, name: "choice_nested_telemetry_flow", status: :ok}}

    assert_receive {:telemetry_event, @node_stop, _measurements,
                    %{
                      flow: "outer_choice_telemetry_flow",
                      node: "route",
                      option: "nested",
                      target: ^target,
                      status: :ok
                    }}

    assert_receive {:telemetry_event, @exec_stop, _measurements,
                    %{kind: :flow, name: "outer_choice_telemetry_flow", status: :ok}}
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, make_ref()}

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.handle_telemetry_event/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp receive_metadata(event, count) do
    for _index <- 1..count do
      assert_receive {:telemetry_event, ^event, measurements, metadata}
      assert is_integer(measurements.duration)
      metadata
    end
  end

  defp three_node_flow do
    Flow.new!(
      name: "telemetry_flow",
      nodes: [
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        ),
        Node.new!(
          name: :multiply,
          action: Multiply,
          input: %{value: Ref.result(:add_one, :value), amount: Ref.value(2)}
        ),
        Node.new!(
          name: :add_three,
          action: Add,
          input: %{value: Ref.result(:multiply, :value), amount: Ref.value(3)}
        )
      ],
      return: Ref.result(:add_three)
    )
  end

  defp failing_flow do
    Flow.new!(
      name: "failing_telemetry_flow",
      nodes: [
        Node.new!(
          name: :divide,
          action: Divide,
          input: %{value: Ref.value(1.0), amount: Ref.value(0.0)}
        ),
        Node.new!(
          name: :skipped,
          action: Add,
          input: %{value: Ref.result(:divide, :value), amount: Ref.value(1)}
        )
      ],
      return: Ref.result(:skipped, :value)
    )
  end
end
