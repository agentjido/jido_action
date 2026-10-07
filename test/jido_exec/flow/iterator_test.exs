defmodule JidoActionTest.Exec.Flow.Compiler.IteratorTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  alias Jido.Exec.Flow.Iterator, as: IteratorCompiler
  alias Jido.Flow.Iterate
  alias JidoActionTest.Fixtures.Actions.Add

  describe "Iterator adapter containment" do
    test "contains failures before the iteration starts" do
      state = runtime_state(fn _instruction, _execution_id -> :unused end)

      assert {:error, %Jido.Flow.Error.InternalError{details: details}} =
               IteratorCompiler.run(%{name: "broken"}, state)

      assert details.phase == :iterate_internal
      assert details.node == "broken"
      assert details.error_type == KeyError

      for {observer, error_type} <- [
            {fn _event -> raise "observer failed" end, RuntimeError},
            {fn _event -> throw(:observer_failed) end, :throw}
          ] do
        state = %{state | observer: observer}

        assert {:error, %Jido.Flow.Error.InternalError{details: details}} =
                 IteratorCompiler.run(iterator(), state)

        assert details.error_type == error_type
        assert details.iteration_index == nil
      end
    end

    test "completion failure sees updated state and reports the iteration" do
      test_pid = self()

      state =
        runtime_state(fn _instruction, _execution_id -> {:ok, %{}} end)

      state = %{
        state
        | observer: fn
            {:start, :iterate_iteration, metadata} ->
              send(test_pid, {:iteration_started, metadata})
              :span

            {:error, :span, error} ->
              send(test_pid, {:iteration_failed, error})
          end
      }

      iterator = %{
        iterator()
        | state: Iterate.State.new!(schema: [], initial: %{guard: -1}, update: %{guard: %{}}),
          completion:
            Jido.Expr.new!(:>=, [Jido.Expr.new!(:+, [Jido.Flow.Ref.state(:guard), 0]), 0])
      }

      assert {:error, %Jido.Flow.Error.ExecutionFailureError{} = error} =
               IteratorCompiler.run(iterator, state)

      assert error.message == "invalid iterator completion condition operands"
      assert error.details.iterations == 1
      assert error.details.phase == :iterate_completion
      assert error.details.reason == :invalid_numeric_operands
      assert_received {:iteration_started, %{iteration_index: 0, state_revision: 0}}
      assert_received {:iteration_failed, ^error}
      refute_received {:iteration_started, _}
    end

    test "contains raised and thrown target runner failures inside an iteration" do
      failures = [
        {fn _instruction, _execution_id ->
           raise "target runner failed"
         end, RuntimeError},
        {fn _instruction, _execution_id ->
           throw(:target_runner_failed)
         end, :throw}
      ]

      for {target_runner, error_type} <- failures do
        state = runtime_state(target_runner)

        assert {:error, %Jido.Flow.Error.InternalError{details: details}} =
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
      completion: Jido.Expr.new!(:==, [false, true]),
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
