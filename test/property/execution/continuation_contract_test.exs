Code.require_file("../support/fuzz.exs", __DIR__)
Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.ContinuationContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias JidoActionTest.Property.Fuzz
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step, Subflow}
  alias JidoActionTest.Property.Runtime

  defmodule Decision do
    use Jido.Action, name: "property_decision"
    @impl true
    def run(params, _), do: {:ok, params}
  end

  defmodule Next do
    use Jido.Action, name: "property_next"
    @impl true
    def run(%{count: count, value: value}, context) do
      send(
        context.observer,
        {context.token, :call, {count, Exec.remaining_time(context)}, self()}
      )

      if count == 0,
        do: {:continue, %{value: value}, context.final},
        else: {:continue, %{count: count - 1, value: value}, context.next}
    end
  end

  defmodule DispatchFlow do
    use Jido.Flow, name: "property_dispatch"

    flow do
      dispatch "next",
        decision: JidoActionTest.Property.Execution.ContinuationContractTest.Decision,
        expander: JidoActionTest.Property.Execution.ContinuationContractTest.Next,
        params: input()

      output result("next")
    end
  end

  defmodule Chain do
    use Jido.Action, name: "fuzz_chain"
    @impl true
    def run(%{path: path, value: value}, context) do
      send(
        context.observer,
        {context.token, :call, {length(path), context.__jido_exec__.deadline}, self()}
      )

      case path do
        [] ->
          {:continue, %{value: value}, context.final}

        [kind | rest] ->
          target =
            if kind == "action",
              do: __MODULE__,
              else: JidoActionTest.Property.Execution.ContinuationContractTest.ChainFlow

          {:continue, %{path: rest, value: value}, target}
      end
    end
  end

  defmodule ChainDecision do
    use Jido.Action, name: "fuzz_chain_decision"
    @impl true
    def run(params, _), do: {:ok, params, [{:decision, length(params.path)}]}
  end

  defmodule ChainFlow do
    use Jido.Flow, name: "fuzz_chain_flow"

    flow do
      dispatch "next",
        decision: JidoActionTest.Property.Execution.ContinuationContractTest.ChainDecision,
        expander: JidoActionTest.Property.Execution.ContinuationContractTest.Chain,
        params: input()

      output result("next")
    end
  end

  defmodule Finish do
    use Jido.Action, name: "fuzz_chain_finish"
    @impl true
    def run(%{value: value}, context) do
      send(
        context.observer,
        {context.token, :call, {:final, context.__jido_exec__.deadline}, self()}
      )

      if context.outcome == "failure",
        do: {:error, {:final_failed, value}, [:discard]},
        else: {:ok, %{value: value}, [value]}
    end
  end

  @tag :fuzz
  @tag max_runs: 250, max_run_time: 300_000, timeout: 900_000, max_links: 12
  @tag contracts: ["EXEC-007", "EXEC-008", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-007/fuzz-absolute-deadline",
         "EXEC-007/fuzz-terminal-timeout",
         "EXEC-008/fuzz-chain-bound",
         "EXEC-008/fuzz-invalid-position",
         "EFFECT-002/fuzz-chain-failure"
       ]
  test "fuzz: mixed continuation chains preserve the supplied deadline and one transition bound",
       context do
    generator =
      fixed_map(%{
        "path" => list_of(member_of(~w(action dispatch)), max_length: context.max_links),
        "root" => member_of(~w(action dispatch)),
        "outcome" => member_of(~w(success failure bound)),
        "value" => integer(),
        "limit" => integer(1..context.max_links)
      })

    examples =
      for root <- ~w(action dispatch), outcome <- ~w(success failure bound timeout) do
        %{
          "path" => ["dispatch", "action", "dispatch"],
          "root" => root,
          "outcome" => outcome,
          "value" => 1,
          "limit" => 1
        }
      end

    Fuzz.check(
      "continuation_chains",
      generator,
      Map.to_list(context) ++ [examples: examples],
      &check_chain/1
    )
  end

  defp check_chain(sample) do
    Runtime.with_context(fn runtime ->
      path = sample["path"]
      target = if sample["root"] == "action", do: Chain, else: ChainFlow
      timed? = sample["outcome"] == "timeout"
      # The supplied deadline is earlier than the local 60-second limit.
      # Equality detects resets even when successive calls use the same clock tick.
      deadline = System.monotonic_time(:millisecond) + 30_000
      final = if timed?, do: Runtime.Gate, else: Finish

      runtime =
        Map.merge(runtime, %{
          final: final,
          outcome: sample["outcome"],
          __jido_exec__: %{deadline: deadline}
        })

      bounded? = sample["outcome"] == "bound" and path != []
      bound = if bounded?, do: min(sample["limit"], length(path)), else: length(path) + 2

      options =
        Runtime.options(runtime, 3) ++
          [timeout: if(timed?, do: 300, else: 60_000), max_continuations: bound]

      input = %{path: path, value: sample["value"]}

      result =
        if timed? do
          handle = Exec.run_async(target, input, runtime, options)

          try do
            token = runtime.token
            assert_receive {^token, :ready, _, worker}, 5_000
            result = Exec.await(handle, 5_000)
            Runtime.assert_workers_stopped([worker, handle.pid])
            result
          after
            Exec.cancel(handle)
          end
        else
          Exec.run(target, input, runtime, options)
        end

      calls = Runtime.calls(runtime)
      effective_deadline = if timed?, do: calls |> hd() |> elem(0) |> elem(1), else: deadline
      assert is_integer(effective_deadline) and effective_deadline <= deadline

      expected_frames =
        if bounded?,
          do: Enum.to_list(length(path)..(length(path) - bound)//-1),
          else: Enum.to_list(length(path)..0//-1)

      expected_calls =
        Enum.map(expected_frames, &{&1, effective_deadline}) ++
          if(bounded? or timed?, do: [], else: [{:final, effective_deadline}])

      assert Enum.map(calls, &elem(&1, 0)) == expected_calls
      Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))

      cond do
        timed? ->
          assert {:error, error} = result
          assert error.__struct__ in [Jido.Action.Error.TimeoutError, Flow.Error.TimeoutError]

        bounded? ->
          assert {:error, error} = result
          assert is_exception(error)

        sample["outcome"] == "failure" ->
          assert {:error, %Jido.Action.Error.ExecutionFailureError{details: %{reason: reason}}} =
                   result

          assert reason == {:final_failed, sample["value"]}

        true ->
          effects =
            [sample["root"] | path]
            |> Enum.with_index()
            |> Enum.flat_map(fn {kind, index} ->
              if kind == "dispatch", do: [{:decision, length(path) - index}], else: []
            end)

          assert result == {:ok, %{value: sample["value"]}, effects ++ [sample["value"]]}
      end

      # Unauthorized positions must not follow the requested target.
      invalid =
        Flow.new!(
          name: "invalid_chain",
          components: [Step.new!(name: "work", action: Chain, params: input)],
          output: Ref.result("work")
        )

      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Exec.run(invalid, %{}, runtime)

      Runtime.assert_calls(runtime, [{length(path), deadline}])
      assert {:error, _} = Exec.start(ChainFlow, input, runtime)
      Runtime.assert_calls(runtime, [])
    end)

    [sample["root"], sample["outcome"], "links:#{length(sample["path"])}"]
  end

  @tag contracts: ["EXEC-007", "EXEC-008"]
  @tag contract_cases: [
         "EXEC-008/action-chain",
         "EXEC-008/dispatch-chain",
         "EXEC-008/shared-limit",
         "EXEC-007/shared-budget"
       ]
  property "Action and Dispatch chains share the continuation limit and one finite budget" do
    check all(count <- integer(2..5), value <- integer(-50..50), max_runs: 20) do
      for target <- [Next, DispatchFlow] do
        Runtime.with_context(fn context ->
          context = Map.merge(context, %{next: DispatchFlow, final: Runtime.Emit})
          opts = Runtime.options(context) ++ [max_continuations: count + 2, timeout: 2_000]

          assert Exec.run(target, %{count: count, value: value}, context, opts) ==
                   {:ok, %{value: value}, [value]}

          observed = Runtime.calls(context)

          assert Enum.map(Enum.drop(observed, -1), fn {{index, _budget}, _pid} -> index end) ==
                   Enum.to_list(count..0//-1)

          budgets = Enum.map(Enum.drop(observed, -1), fn {{_, budget}, _} -> budget end)
          assert Enum.all?(budgets, &(is_integer(&1) and &1 >= 0 and &1 <= 2_000))
          assert budgets == Enum.sort(budgets, :desc)
          assert List.last(observed) |> elem(0) == value
          Runtime.assert_workers_stopped(Enum.map(observed, &elem(&1, 1)))

          assert {:error, error} =
                   Exec.run(
                     target,
                     %{count: count, value: value},
                     context,
                     Runtime.options(context) ++ [max_continuations: 1]
                   )

          assert is_exception(error)
          calls = Runtime.calls(context)
          assert Enum.map(calls, fn {{index, _}, _} -> index end) == [count, count - 1]
        end)
      end
    end
  end

  @tag contracts: ["EXEC-007", "EFFECT-002"]
  @tag contract_cases: ["EXEC-007/continuation-timeout", "EXEC-007/zero-timeout"]
  property "complete-call timeout stops the final continuation worker and zero timeout starts no work" do
    check all(
            count <- integer(1..3),
            value <- integer(-20..20),
            max_runs: 4
          ) do
      for target <- [Next, DispatchFlow] do
        Runtime.with_context(fn context ->
          token = context.token
          context = Map.merge(context, %{next: DispatchFlow, final: Runtime.Gate})

          task =
            Task.async(fn ->
              Exec.run(
                target,
                %{count: count, value: value},
                context,
                Runtime.options(context) ++ [timeout: 200]
              )
            end)

          try do
            assert_receive {^token, :ready, ^value, worker}, 1_000
            assert {:error, error} = Task.await(task, 2_000)
            assert error.__struct__ in [Jido.Action.Error.TimeoutError, Flow.Error.TimeoutError]
            Runtime.assert_workers_stopped([worker])
            calls = Runtime.calls(context)
            assert length(calls) == count + 1
            Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
          after
            Task.shutdown(task, :brutal_kill)
          end

          assert {:error, _} =
                   Exec.run(
                     target,
                     %{count: count, value: value},
                     context,
                     Runtime.options(context) ++ [timeout: 0]
                   )

          Runtime.assert_calls(context, [])
          refute_received {^token, :ready, _, _}
        end)
      end
    end
  end

  @tag contracts: ["EXEC-008", "FLOW-004"]
  @tag contract_cases: [
         "EXEC-008/step-wise-rejection",
         "EXEC-008/subflow-rejection",
         "EXEC-008/ordinary-step-rejection"
       ]
  property "Dispatch rejects step-wise and Subflow use and ordinary Steps reject continuations" do
    check all(count <- integer(1..5), value <- integer(), max_runs: 25) do
      Runtime.with_context(fn context ->
        context = Map.merge(context, %{next: DispatchFlow, final: Runtime.Emit})
        input = %{count: count, value: value}
        assert {:error, _} = Exec.start(DispatchFlow, input, context)

        parent =
          Flow.new!(
            name: "dispatch_parent",
            components: [Subflow.new!(name: "child", flow: DispatchFlow, params: input)],
            output: Ref.result("child")
          )

        assert {:error, _} = Exec.run(parent, %{}, context)
        Runtime.assert_calls(context, [])

        step_flow =
          Flow.new!(
            name: "ordinary",
            components: [Step.new!(name: "work", action: Next, params: input)],
            output: Ref.result("work")
          )

        assert {:error, %Jido.Action.Error.ExecutionFailureError{message: message}} =
                 Exec.run(step_flow, %{}, context)

        assert message == "action continuation is not allowed from this Flow position"
        Runtime.assert_calls(context, [{count, :infinity}])
      end)
    end
  end
end
