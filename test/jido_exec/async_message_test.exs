defmodule JidoActionTest.Exec.AsyncMessageTest do
  use JidoActionTest.Case, async: false

  alias Jido.Exec
  alias Jido.Exec.Error
  alias Jido.Flow
  alias Jido.Flow.{Dispatch, Ref}
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.Execution.BlockingAction
  alias JidoActionTest.Fixtures.MathFlow

  defmodule ContinueToAdd do
    use Jido.Action, name: "async_message_continue_to_add"

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value, amount: 2}, Add}
  end

  defmodule ContinueToFlow do
    use Jido.Action, name: "async_message_continue_to_flow"

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value}, MathFlow}
  end

  defmodule DispatchDecision do
    use Jido.Action, name: "async_message_dispatch_decision"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule DispatchExpander do
    use Jido.Action, name: "async_message_dispatch_expander"

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value, amount: 1}, Add}
  end

  test "classifies unrelated messages and consumes the exact result" do
    handle = Exec.run_async(BlockingAction, %{value: 3}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000

    assert :ignore = Exec.handle_message(handle, {:application_event, :ready})

    send(worker, :finish)
    message = receive_message()

    assert {:done, {:ok, %{value: 3}}} = Exec.handle_message(handle, message)

    assert {:error, %Error.InvalidHandleError{details: %{operation: :await}}} =
             Exec.await(handle, 0)
  end

  test "does not claim a handle for a different execution message" do
    first = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, first_worker}, 1_000

    second = Exec.run_async(BlockingAction, %{value: 2}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, second_worker}, 1_000

    send(first_worker, :finish)
    first_message = receive_message()

    assert :ignore = Exec.handle_message(second, first_message)
    assert {:done, {:ok, %{value: 1}}} = Exec.handle_message(first, first_message)

    send(second_worker, :finish)
    second_message = receive_message()
    assert {:done, {:ok, %{value: 2}}} = Exec.handle_message(second, second_message)
  end

  test "rejects invalid handles and non-owner calls without claiming the handle" do
    assert {:error, %Error.InvalidHandleError{}} = Exec.handle_message(%{}, :message)

    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    invalid_state_handle = %{handle | state: make_ref()}

    assert {:error, %Error.InvalidHandleError{}} =
             Exec.handle_message(invalid_state_handle, :message)

    forged_state_handle = %{handle | state: {:jido_exec_async_state, make_ref()}}

    assert {:error, %Error.InvalidHandleError{}} =
             Exec.handle_message(forged_state_handle, :message)

    send(worker, :finish)
    message = receive_message()
    owner = self()

    spawn(fn -> send(owner, {:non_owner, Exec.handle_message(handle, message)}) end)

    assert_receive {:non_owner,
                    {:error, %Error.InvalidHandleError{details: %{operation: :handle_message}}}},
                   1_000

    assert {:done, {:ok, %{value: 1}}} = Exec.handle_message(handle, message)
  end

  test "an invalid await timeout does not claim the handle" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000

    assert {:error, %Error.InvalidHandleError{}} = Exec.await(handle, :soon)

    send(worker, :finish)
    message = receive_message()
    assert {:done, {:ok, %{value: 1}}} = Exec.handle_message(handle, message)
  end

  test "returns continuation-capable Action and Flow results" do
    for {target, expected} <- [
          {ContinueToAdd, {:ok, %{value: 5}}},
          {ContinueToFlow, {:ok, %{value: 8}}},
          {continuation_flow(), {:ok, %{value: 4}}}
        ] do
      handle = Exec.run_async(target, %{value: 3})
      message = receive_message()
      assert {:done, ^expected} = Exec.handle_message(handle, message)
    end
  end

  defp continuation_flow do
    Flow.new!(
      name: "async_message_dispatch_flow",
      components: [
        Dispatch.new!(
          name: "next",
          decision: DispatchDecision,
          expander: DispatchExpander,
          params: %{value: Ref.input(:value)}
        )
      ],
      output: Ref.result("next")
    )
  end

  defp receive_message do
    receive do
      message -> message
    after
      1_000 -> flunk("expected an asynchronous execution message")
    end
  end
end
