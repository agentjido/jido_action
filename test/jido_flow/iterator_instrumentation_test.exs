defmodule Jido.Flow.IteratorInstrumentationTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Flow.Compiler.Iterator, as: IteratorCompiler
  alias Jido.Flow.Ref
  alias JidoTest.IteratorFixtures

  describe "Iterator instrumentation" do
    test "runs the State schema transform exactly once per candidate" do
      IteratorFixtures.register_state_schema_recorder(self())

      schema =
        Zoi.map()
        |> Zoi.transform({IteratorFixtures, :record_state_transform, []})

      flow =
        IteratorFixtures.iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 1, state: %{count: 201}, output: %{count: 101}}} =
               Exec.run(flow, %{}, %{})

      assert_receive {:state_schema_transform, %{count: 0}}
      assert_receive {:state_schema_transform, %{count: 101}}
      refute_received {:state_schema_transform, _candidate}
    end

    test "evaluates completion exactly once at the head and after each commit" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.gte(Ref.state(:count), Ref.value(3)),
          max_iterations: 3
        )

      target = {IteratorCompiler, :evaluate_iterator_completion, 3}

      :erlang.trace_pattern(target, true, [:local, :call_count])

      result =
        try do
          result = Exec.run(flow, %{}, %{})
          assert {:call_count, 4} = :erlang.trace_info(target, :call_count)
          result
        after
          :erlang.trace_pattern(target, false, [:local, :call_count])
        end

      assert {:ok, %{iterations: 3}} = result
    end
  end
end
