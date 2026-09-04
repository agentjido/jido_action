defmodule JidoActionTest.Flow.Compiler.IteratorTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Flow.Condition
  alias Jido.Flow.Compiler.Iterator, as: IteratorCompiler
  alias Jido.Flow.Iterate
  alias JidoActionTest.Fixtures.Actions.Add

  describe "Iterator adapter containment" do
    test "contains failures before the iteration starts" do
      state = runtime_state(fn _action, _params, _context, _execution_id, _owner -> :unused end)

      assert {:error, %Jido.Flow.Error.InternalError{details: details}, ^state} =
               IteratorCompiler.run(%{name: "broken"}, state)

      assert details.phase == :iterate_internal
      assert details.node == "broken"
      assert details.error_type == KeyError

      for {observer, error_type} <- [
            {fn _event -> raise "observer failed" end, RuntimeError},
            {fn _event -> throw(:observer_failed) end, :throw}
          ] do
        state = %{state | observer: observer}

        assert {:error, %Jido.Flow.Error.InternalError{details: details}, ^state} =
                 IteratorCompiler.run(iterator(), state)

        assert details.error_type == error_type
        assert details.iteration_index == nil
      end
    end

    test "contains raised and thrown target runner failures inside an iteration" do
      failures = [
        {fn _action, _params, _context, _execution_id, _owner ->
           raise "target runner failed"
         end, RuntimeError},
        {fn _action, _params, _context, _execution_id, _owner ->
           throw(:target_runner_failed)
         end, :throw}
      ]

      for {target_runner, error_type} <- failures do
        state = runtime_state(target_runner)

        assert {:error, %Jido.Flow.Error.InternalError{details: details}, ^state} =
                 IteratorCompiler.run(iterator(), state)

        assert details.phase == :iterate_internal
        assert details.error_type == error_type
        assert details.iteration_index == 0
        assert details.state_revision == 0
      end
    end
  end

  defp iterator do
    Iterate.new!(
      name: "contained_iterator",
      action: Add,
      params: %{},
      state: Iterate.State.new!(schema: [], initial: %{}, update: %{}),
      completion: Condition.eq(false, true),
      max_iterations: 1
    )
  end

  defp runtime_state(target_runner) do
    %{
      namespace: [],
      input: %{},
      context: %{},
      results: %{},
      flow_digest: "iterator-containment-digest",
      observer: fn
        {:start, _kind, _metadata} -> :span
        _event -> :ok
      end,
      execution_id: "iterator-containment",
      target_runner: target_runner
    }
  end
end
