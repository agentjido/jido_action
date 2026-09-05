defmodule JidoActionBench.Accumulate do
  @moduledoc false
  use Jido.Action, name: "benchmark_accumulate"

  @impl true
  def run(%{value: value, amount: amount}, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:ok, %{value: value + amount}}
  end
end

defmodule JidoActionBench.Continue do
  @moduledoc false
  use Jido.Action, name: "benchmark_continue"

  @impl true
  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:continue, params, JidoActionBench.Child}
  end
end

defmodule JidoActionBench.ComponentCases do
  @moduledoc false
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Choice, Dispatch, Iterate, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionBench.{Accumulate, Continue, Echo, Fixtures}

  @opts [task_supervisor: JidoActionBench.TaskSupervisor, max_concurrency: 4]

  def workloads do
    collections =
      for kind <- [:map, :reduce, :iterate],
          count <- [0, 1, 16],
          workload <-
            cases(
              "component/#{kind}/#{count}",
              graph(kind, count),
              input(count),
              expected(kind, count)
            ),
          do: workload

    choices =
      for selected <- [1, 16, 0],
          workload <-
            cases(
              "component/choice/#{selected}",
              graph(:choice, 16),
              %{selected: selected},
              {:ok, %{value: selected}}
            ),
          do: workload

    metadata =
      for kind <- [:map, :reduce, :iterate, :choice, :dispatch],
          payload <- [:small, :list, :binary] do
        flow = graph(kind, 1)

        meta =
          case payload do
            :small -> %{}
            :list -> %{notes: Enum.to_list(1..5_000)}
            :binary -> %{notes: :binary.copy(<<42>>, 1_048_576)}
          end

        flow = %{flow | components: Enum.map(flow.components, &%{&1 | meta: meta})}
        modes = if kind == :dispatch, do: [:compile, :run], else: [:compile, :continue]

        cases(
          "captures/#{kind}/#{payload}",
          flow,
          Map.put(input(1), :selected, 1),
          expected(kind, 1),
          modes
        )
      end
      |> List.flatten()

    collections ++
      choices ++
      metadata ++
      dependency_cases() ++
      reduce_payload_cases() ++
      output_cases() ++
      cases("component/dispatch", graph(:dispatch, 1), %{value: 42}, {:ok, %{value: 42}}, [
        :compile,
        :run
      ]) ++
      execution_modes()
  end

  def graph(:map, _count) do
    component =
      FlowMap.new!(
        name: "work",
        collection: Ref.input(:items),
        action: Echo,
        params: %{value: Ref.item()}
      )

    flow(component, %{items: Ref.result("work")})
  end

  def graph(:reduce, _count) do
    component =
      Reduce.new!(
        name: "work",
        collection: Ref.input(:items),
        initial: %{value: 0},
        action: Accumulate,
        params: %{value: Ref.accumulator(:value), amount: Ref.item()}
      )

    flow(component, Ref.result("work"))
  end

  def graph(:iterate, count) do
    component =
      Iterate.new!(
        name: "work",
        action: Accumulate,
        params: %{value: Ref.state(:value), amount: 1},
        state: Iterate.State.new!(initial: %{value: 0}, update: Ref.body_result()),
        completion: Expr.new!(:eq, [Ref.state(:value), count]),
        max_iterations: max(count, 1)
      )

    flow(component, %{value: Ref.result("work", [:state, :value])})
  end

  def graph(:choice, count) do
    component =
      Choice.new!(
        name: "work",
        options:
          for(
            index <- 1..count,
            do: [
              name: "o#{index}",
              condition: Expr.new!(:eq, [Ref.input(:selected), index]),
              action: Echo,
              params: %{value: index}
            ]
          ),
        fallback: [action: Echo, params: %{value: 0}]
      )

    flow(component, Ref.result("work"))
  end

  def graph(:dispatch, _count) do
    component =
      Dispatch.new!(
        name: "work",
        decision: Echo,
        expander: Continue,
        params: %{value: Ref.input(:value)}
      )

    flow(component, Ref.result("work"))
  end

  def cases(id, flow, input, expected, modes \\ [:compile, :start, :continue, :run]) do
    {:ok, compiled} = Flow.compile(flow)

    Enum.map(modes, fn mode ->
      setup = fn context ->
        if mode == :continue do
          {:ok, execution} = Exec.start(flow, input, context, @opts)
          Fixtures.barrier(context)
          execution
        else
          context
        end
      end

      run =
        case mode do
          :compile -> fn _ -> Flow.compile(flow) end
          :start -> fn context -> Exec.start(flow, input, context, @opts) end
          :continue -> fn execution -> Exec.continue(execution) end
          :run -> fn context -> Exec.run(flow, input, context, @opts) end
        end

      check =
        case mode do
          :compile ->
            fn {:ok, value} -> expect!(value.compilation_digest, compiled.compilation_digest) end

          :start ->
            fn {:ok, execution} ->
              {:ok, finished} = Exec.continue(execution)
              expect!(Exec.result(finished), expected)
            end

          :continue ->
            fn {:ok, execution} -> expect!(Exec.result(execution), expected) end

          :run ->
            fn value -> expect!(value, expected) end
        end

      retained =
        case mode do
          :compile ->
            fn _, {:ok, value} ->
              %{compiled: value, workflow: value.workflow, index: value.component_index}
            end

          :start ->
            fn _, {:ok, execution} -> %{started_execution: execution} end

          :continue ->
            fn paused, {:ok, finished} ->
              %{
                paused_execution: paused,
                finished_execution: finished,
                result: Exec.result(finished)
              }
            end

          :run ->
            fn _, result -> %{result: result} end
        end

      %{id: "#{id}/#{mode}", setup: setup, run: run, check: check, retained: retained}
    end)
  end

  defp dependency_cases do
    for size <- [0, 1_000], mode <- [:fail_fast, :collect_errors] do
      producer = Step.new!(name: "producer", action: Echo, params: %{unused: Ref.input(:unused)})

      mapped =
        FlowMap.new!(
          name: "work",
          collection: Ref.input(:items),
          action: Echo,
          on_error: mode,
          params: %{value: Ref.item(), ignored: Ref.result("producer", :unused)}
        )

      # The Action consumes a reference but emits a small result.
      mapped = %{
        mapped
        | action: JidoActionBench.SmallResult,
          params: Map.put(mapped.params, :fail, false)
      }

      flow =
        Flow.new!(
          name: "map_dependencies",
          components: [producer, mapped],
          output: %{items: Ref.result("work")}
        )

      input = %{items: Enum.to_list(1..16), unused: List.duplicate(7, size)}

      item =
        if mode == :collect_errors, do: %{status: :ok, value: %{value: 42}}, else: %{value: 42}

      expected = {:ok, %{items: List.duplicate(item, 16)}}
      cases("map_dependencies/#{mode}/#{size}", flow, input, expected, [:continue])
    end
    |> List.flatten()
  end

  defp output_cases do
    for count <- [4, 16], output <- [:terminal, :all] do
      flow = Fixtures.graph(:serial, count)
      flow = if output == :terminal, do: %{flow | output: Ref.result("s#{count}")}, else: flow

      expected =
        if output == :terminal,
          do: {:ok, %{value: 42}},
          else: {:ok, Map.new(1..count, &{"s#{&1}", %{value: 42}})}

      cases("outputs/#{output}/#{count}", flow, %{value: 42}, expected, [:continue])
    end
    |> List.flatten()
  end

  defp reduce_payload_cases do
    for count <- [0, 16], size <- [0, 1_000] do
      flow = graph(:reduce, count)
      [component] = flow.components
      component = %{component | initial: Ref.input(:initial)}
      flow = %{flow | components: [component]}
      initial = %{value: 0, unused: List.duplicate(7, size)}
      input = Map.put(input(count), :initial, initial)
      expected = if count == 0, do: {:ok, initial}, else: expected(:reduce, count)
      cases("reduce_initial/#{count}/#{size}", flow, input, expected, [:continue])
    end
    |> List.flatten()
  end

  defp execution_modes do
    flow = Fixtures.graph(:parallel, 8)
    expected = {:ok, Map.new(1..8, &{"s#{&1}", %{value: 42}})}

    for mode <- [:step, :wave, :continue] do
      %{
        id: "scheduling/#{mode}/8",
        setup: fn context ->
          {:ok, execution} = Exec.start(flow, %{value: 42}, context, @opts)
          execution
        end,
        run: &finish(&1, mode),
        check: fn finished -> expect!(Exec.result(finished), expected) end,
        retained: fn _, finished -> %{finished_execution: finished} end
      }
    end
  end

  defp finish(%{status: status} = execution, _) when status != :running, do: execution

  defp finish(execution, :continue) do
    {:ok, finished} = Exec.continue(execution)
    finished
  end

  defp finish(execution, mode) do
    {:ok, _, next} = apply(Exec, mode, [execution])
    finish(next, mode)
  end

  defp flow(component, output),
    do: Flow.new!(name: "bench_component", components: [component], output: output)

  defp input(0), do: %{items: [], value: 42}
  defp input(count), do: %{items: Enum.to_list(1..count), value: 42}
  defp expected(:map, count), do: {:ok, %{items: Enum.map(input(count).items, &%{value: &1})}}
  defp expected(:reduce, count), do: {:ok, %{value: div(count * (count + 1), 2)}}
  defp expected(:iterate, count), do: {:ok, %{value: count}}
  defp expected(:choice, count), do: {:ok, %{value: count}}
  defp expected(:dispatch, _), do: {:ok, %{value: 42}}

  def expect!(actual, expected) do
    if actual != expected,
      do: raise("component benchmark returned an incorrect result: #{inspect(actual, limit: 5)}")

    :ok
  end
end
