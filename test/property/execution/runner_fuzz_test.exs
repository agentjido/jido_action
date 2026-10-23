Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/managed.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.RunnerFuzzTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Jido.{Exec, Expr, Flow, Instruction}
  alias Jido.Action.Error
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.{Fuzz, Managed, Runtime}

  defmodule Record do
    use Jido.Action, name: "fuzz_managed_record"
    @impl true
    def run(params, context) do
      send(context.observer, {context.token, :call, params.label, self()})

      case Map.get(params, :fault, "none") do
        "error" ->
          {:error, {:record_failed, params.label}, [:discard]}

        "timeout" ->
          send(context.observer, {context.token, :blocked, self()})

          receive do
            :release -> {:ok, %{value: params.value}}
          end

        _ ->
          {:ok, %{value: params.value + params.amount, label: params.label}, [params.label]}
      end
    end
  end

  defmodule Controlled do
    use Jido.Action, name: "fuzz_managed_controlled"
    def controlled?, do: true
    @impl true
    def run(params, context) do
      send(context.observer, {context.token, :ready, params.index, self()})

      receive do
        :release ->
          if params.index >= params.fail_at do
            case params.fault do
              "error" -> {:error, {:item_failed, params.index}, [:discard]}
              "raise" -> raise "item_failed: #{params.index}"
              "throw" -> throw({:item_failed, params.index})
            end
          else
            {:ok, %{value: params.value * 2, index: params.index}, [params.index]}
          end
      end
    end
  end

  defmodule MappedChild do
    use Jido.Flow, name: "fuzz_managed_child"

    flow do
      map "items",
        collection: input(:items),
        action: Controlled,
        params: %{
          value: item(),
          index: item_index(),
          fail_at: input(:fail_at),
          fault: input(:fault)
        }

      output %{items: result("items")}
    end
  end

  defmodule RecordChild do
    use Jido.Flow, name: "fuzz_record_child"

    flow do
      map "items",
        collection: input(:items),
        action: Record,
        params: %{value: item(), label: item_index(), amount: input(:amount)}

      output %{items: result("items")}
    end
  end

  defmodule Decision do
    use Jido.Action, name: "fuzz_dispatch_decision"
    @impl true
    def run(params, context) do
      send(context.observer, {context.token, :call, params.label, self()})
      {:ok, params, [params.label]}
    end
  end

  defmodule Expander do
    use Jido.Action, name: "fuzz_dispatch_expander"
    @impl true
    def run(%{remaining: remaining} = params, _context) do
      if remaining > 0 do
        next = %{
          params
          | remaining: remaining - 1,
            label: params.label + 1,
            value: params.value + params.amount
        }

        {:continue, next, JidoActionTest.Property.Execution.RunnerFuzzTest.DispatchChild}
      else
        target =
          if params.terminal == "flow",
            do: JidoActionTest.Property.Execution.RunnerFuzzTest.TerminalChild,
            else: Record

        {:continue, %{params | label: params.label + 1}, target}
      end
    end
  end

  defmodule TerminalChild do
    use Jido.Flow, name: "fuzz_dispatch_terminal"

    flow do
      step "record", action: Record, params: input()
      output result("record")
    end
  end

  defmodule DispatchChild do
    use Jido.Flow, name: "fuzz_dispatch_child"

    flow do
      dispatch "route", decision: Decision, expander: Expander, params: input()
      output result("route")
    end
  end

  defmodule Retry do
    use Jido.Action, name: "fuzz_managed_retry"
    @impl true
    def run(params, context) do
      attempt = Agent.get_and_update(context.counter, fn count -> {count + 1, count + 1} end)

      if attempt < params.attempts or params.fail do
        {:error, Error.execution_error("retry", %{retry: true, attempt: attempt}), [:discard]}
      else
        {:ok, %{attempts: attempt}, [:saved]}
      end
    end
  end

  defmodule Unsafe do
    use Jido.Action, name: "fuzz_managed_unsafe"
    @impl true
    def run(%{field: "output"}, _context), do: {:ok, %{value: self()}}
    def run(%{field: "effects"}, _context), do: {:ok, %{}, [self()]}
  end

  setup do
    observer = __MODULE__.Observer
    Process.register(self(), observer)
    runner = __MODULE__.Runner
    start_supervised!({Runic.Runner, name: runner})
    supervisor = start_supervised!(Task.Supervisor)
    counter = __MODULE__.Counter
    start_supervised!(%{id: counter, start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}})
    %{runner: runner, observer: observer, supervisor: supervisor, counter: counter}
  end

  @tag :fuzz
  @tag fuzz_id: "runner_schedules"
  @tag max_runs: 100, max_run_time: 60_000, timeout: 900_000
  @tag contracts: ["EXEC-003", "EXEC-005", "EFFECT-001"]
  @tag contract_cases: [
         "EXEC-005/controlled-admission",
         "EFFECT-001/completion-order",
         "EXEC-005/cancel-and-stop"
       ]
  test "fuzz: managed Map completion order does not change results or effects", context do
    generator =
      fixed_map(%{
        "items" => list_of(integer(-20..20), min_length: 1, max_length: 8),
        "reverse" => boolean(),
        "concurrency" => integer(1..4)
      })

    examples =
      for reverse <- [false, true],
          do: %{"items" => [3, 3, -2, 1], "reverse" => reverse, "concurrency" => 3}

    Fuzz.check(
      "runner_schedules",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        items = sample["items"]
        n = length(items)

        expected =
          Enum.with_index(items, fn value, index -> %{value: value * 2, index: index} end)

        for concurrency <- Enum.uniq([1, sample["concurrency"]]) do
          Managed.with_execution(
            context,
            MappedChild,
            %{items: items, fail_at: n, fault: "error"},
            [max_concurrency: concurrency],
            fn id, runtime, _options ->
              {admitted, workers} =
                release_items(runtime.token, n, concurrency, sample["reverse"], n)

              assert Enum.sort(admitted) == Enum.to_list(0..(n - 1))

              assert Managed.complete(context.runner, id, runtime.token, :automatic) ==
                       {:ok, %{items: expected}, Enum.to_list(0..(n - 1))}

              Runtime.assert_workers_stopped(workers)
              token = runtime.token
              refute_received {^token, :ready, _, _}
            end
          )
        end

        for operation <- [:cancel, :stop] do
          Managed.with_execution(
            context,
            MappedChild,
            %{items: items, fail_at: n, fault: "error"},
            [max_concurrency: sample["concurrency"]],
            fn id, runtime, _options ->
              token = runtime.token

              workers =
                for _ <- 1..min(n, sample["concurrency"]) do
                  assert_receive {^token, :ready, _index, worker}, 5_000
                  worker
                end

              assert :ok = apply(Runic.Runner, operation, [context.runner, id])
              Runtime.assert_workers_stopped(workers)
              assert {:error, :not_found} = Exec.result(context.runner, id)
              refute_received {^token, :ready, _, _}
            end
          )
        end

        [
          "controlled-order",
          "cancel-and-stop",
          "items:#{n}",
          "concurrency:#{sample["concurrency"]}"
        ]
      end
    )
  end

  @tag :fuzz
  @tag fuzz_id: "nested_runner_failures"
  @tag max_runs: 100, max_run_time: 60_000, timeout: 900_000
  @tag contracts: ["ACT-002", "EXEC-004", "EXEC-005", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-004/nested-halt",
         "EXEC-005/nested-limit",
         "EFFECT-002/nested-error"
       ]
  test "fuzz: nested failures stop admission and discard effects", context do
    generator =
      fixed_map(%{
        "items" => list_of(integer(-20..20), min_length: 2, max_length: 8),
        "fault" => member_of(~w(error raise throw)),
        "reverse" => boolean(),
        "concurrency" => integer(1..3)
      })

    examples =
      for fault <- ~w(error raise throw),
          do: %{"items" => [1, 2, 3, 4], "fault" => fault, "reverse" => true, "concurrency" => 3}

    Fuzz.check(
      "nested_runner_failures",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        items = sample["items"]
        fail_at = div(length(items), 2)

        flow =
          Flow.new!(%{
            name: "nested_failure",
            components: [
              %{
                kind: :subflow,
                name: "child",
                flow: MappedChild,
                params: %{
                  items: items,
                  fail_at: fail_at,
                  fault: sample["fault"]
                }
              },
              %{
                kind: :step,
                name: "after",
                action: Record,
                needs: ["child"],
                params: %{label: -1, value: 0, amount: 1}
              }
            ],
            output: Ref.result("child")
          })

        for concurrency <- Enum.uniq([1, sample["concurrency"]]) do
          Managed.with_execution(context, flow, %{}, [max_concurrency: concurrency], fn id,
                                                                                        runtime,
                                                                                        _options ->
            {admitted, workers} =
              release_items(runtime.token, length(items), concurrency, sample["reverse"], fail_at)

            assert {:error, %Error.ExecutionFailureError{details: details}} =
                     Managed.complete(context.runner, id, runtime.token, :automatic)

            assert details.item_index == fail_at
            assert "child" in details.node_path
            assert length(admitted) <= min(length(items), fail_at + concurrency)
            Runtime.assert_workers_stopped(workers)
            token = runtime.token
            refute_received {^token, :ready, _, _}
            assert Managed.calls(token) == []
          end)
        end

        [sample["fault"], "nested-halt", "effects-discarded"]
      end
    )
  end

  @tag :fuzz
  @tag fuzz_id: "runner_histories"
  @tag max_runs: 80, max_run_time: 60_000, timeout: 900_000
  @tag contracts: [
         "EXEC-003",
         "EXEC-006",
         "DURABLE-002",
         "DURABLE-003",
         "DURABLE-004",
         "SECURITY-002"
       ]
  @tag contract_cases: [
         "EXEC-006/manual",
         "EXEC-006/continue",
         "DURABLE-002/no-replay",
         "DURABLE-003/map-iterate-nested-dispatch",
         "DURABLE-004/checkpoint",
         "SECURITY-002/portable-boundary"
       ]
  test "fuzz: manual Runner histories preserve completed work through resume", context do
    kinds = ~w(chain map iterate nested dispatch)

    generator =
      fixed_map(%{
        "kind" => member_of(kinds),
        "size" => integer(2..6),
        "seed" => integer(-20..20),
        "amount" => integer(-3..3),
        "cut" => integer(1..5),
        "automatic" => boolean(),
        "commands" => list_of(member_of(~w(read checkpoint resume)), max_length: 4)
      })

    examples =
      for kind <- kinds,
          automatic <- [false, true],
          do: %{
            "kind" => kind,
            "size" => 4,
            "seed" => 2,
            "amount" => 3,
            "cut" => 2,
            "automatic" => automatic,
            "commands" => ~w(read checkpoint resume read)
          }

    Fuzz.check(
      "runner_histories",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        {flow, params, expected, labels} = history_flow(sample)

        Managed.with_execution(
          context,
          flow,
          params,
          [dispatch_mode: :manual, max_concurrency: 1, checkpoint_strategy: :every_cycle],
          fn id, runtime, options ->
            cut = min(sample["cut"], length(labels) - 1)

            {prefix, first_workers} =
              Enum.reduce(1..cut, {[], []}, fn _, {prefix, workers} ->
                {label, pids} = advance_to_call(context.runner, id, runtime.token, 200)
                {prefix ++ [label], workers ++ pids}
              end)

            assert prefix == Enum.take(labels, cut)
            assert :ok = Runic.Runner.checkpoint(context.runner, id)
            assert :ok = Runic.Runner.stop(context.runner, id, persist: true)
            assert {:ok, _} = Exec.resume(context.runner, id, runtime, options)

            for command <- sample["commands"] do
              case command do
                "read" ->
                  assert {:ok, %Runic.Workflow{}} = Runic.Runner.get_workflow(context.runner, id)
                  assert {:error, _} = Exec.result(context.runner, id)

                "checkpoint" ->
                  assert :ok = Runic.Runner.checkpoint(context.runner, id)

                "resume" ->
                  assert :ok = Runic.Runner.stop(context.runner, id, persist: true)
                  assert {:ok, _} = Exec.resume(context.runner, id, runtime, options)
              end

              assert Managed.calls(runtime.token) == []
            end

            mode = if sample["automatic"], do: :automatic, else: :manual
            if mode == :automatic, do: assert(:ok = Runic.Runner.continue(context.runner, id))
            assert Managed.complete(context.runner, id, runtime.token, mode) == expected
            calls = Managed.calls(runtime.token)
            assert prefix ++ Enum.map(calls, &elem(&1, 0)) == labels
            Runtime.assert_workers_stopped(first_workers ++ Enum.map(calls, &elem(&1, 1)))
          end
        )

        assert_portable_boundaries(context, sample["seed"])

        [
          sample["kind"],
          "checkpoint-resume",
          if(sample["automatic"], do: "continue", else: "manual")
        ]
      end
    )
  end

  @tag :fuzz
  @tag fuzz_id: "dispatch_chains"
  @tag max_runs: 60, max_run_time: 60_000, timeout: 900_000
  @tag contracts: ["EXEC-003", "EXEC-004", "EFFECT-001", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-003/dispatch-action-flow",
         "EXEC-004/dispatch-timeout",
         "EFFECT-001/dispatch-order",
         "EFFECT-002/dispatch-failure"
       ]
  test "fuzz: Dispatch chains keep routing, terminal results and effects", context do
    generator =
      fixed_map(%{
        "links" => integer(0..6),
        "seed" => integer(-20..20),
        "amount" => integer(-3..3),
        "terminal" => member_of(~w(action flow)),
        "fault" => member_of(~w(none error timeout))
      })

    examples =
      for terminal <- ~w(action flow),
          fault <- ~w(none error timeout),
          do: %{
            "links" => 2,
            "seed" => 3,
            "amount" => 2,
            "terminal" => terminal,
            "fault" => fault
          }

    Fuzz.check(
      "dispatch_chains",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        params = %{
          remaining: sample["links"],
          value: sample["seed"],
          amount: sample["amount"],
          label: 0,
          terminal: sample["terminal"],
          fault: sample["fault"]
        }

        labels = Enum.to_list(0..(sample["links"] + 1))

        expected =
          {:ok,
           %{
             value: sample["seed"] + (sample["links"] + 1) * sample["amount"],
             label: List.last(labels)
           }, labels}

        timeout = if sample["fault"] == "timeout", do: 100, else: :infinity

        Runtime.with_context(fn runtime ->
          result =
            Exec.run(
              DispatchChild,
              params,
              runtime,
              Runtime.options(runtime) ++ [timeout: timeout]
            )

          assert_dispatch_result(result, expected, sample["fault"])
          Runtime.assert_calls(runtime, labels)
          assert_blocked_stopped(runtime.token, sample["fault"])
        end)

        for mode <- [:automatic, :manual] do
          Managed.with_execution(
            context,
            DispatchChild,
            params,
            [dispatch_mode: mode, max_concurrency: 1, timeout: timeout],
            fn id, runtime, _options ->
              result = Managed.complete(context.runner, id, runtime.token, mode)
              assert_dispatch_result(result, expected, sample["fault"])
              calls = Managed.calls(runtime.token)
              assert Enum.map(calls, &elem(&1, 0)) == labels
              Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
              assert_blocked_stopped(runtime.token, sample["fault"])
            end
          )
        end

        [sample["terminal"], sample["fault"], "links:#{sample["links"]}"]
      end
    )
  end

  @tag :fuzz
  @tag fuzz_id: "runner_telemetry"
  @tag max_runs: 60, max_run_time: 60_000, timeout: 900_000
  @tag contracts: ["EXEC-007", "DURABLE-005", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-007/attempt-spans",
         "EXEC-007/immediate-flow",
         "EXEC-007/managed-runtime",
         "DURABLE-005/retry-identity",
         "EFFECT-002/retry-effects"
       ]
  test "fuzz: retry telemetry has stable activations and bounded attempt metadata", context do
    generator = fixed_map(%{"attempts" => integer(1..4), "fail" => boolean()})
    examples = for fail <- [false, true], do: %{"attempts" => 3, "fail" => fail}

    Fuzz.check(
      "runner_telemetry",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        flow =
          Flow.new!(%{
            name: "fuzz_retry_flow",
            components: [
              %{
                kind: :step,
                name: "retry",
                action: Retry,
                params: %{attempts: sample["attempts"], fail: sample["fail"]}
              }
            ],
            output: Ref.result("retry")
          })

        for mode <- [:immediate, :automatic, :manual] do
          Agent.update(context.counter, fn _ -> 0 end)
          event_token = make_ref()
          handler = {__MODULE__, event_token}

          events =
            Jido.Exec.Telemetry.event_names() ++
              [
                [:runic, :runner, :runnable, :start],
                [:runic, :runner, :runnable, :stop],
                [:runic, :runner, :runnable, :exception]
              ]

          :ok =
            :telemetry.attach_many(
              handler,
              events,
              &__MODULE__.telemetry/4,
              {self(), event_token}
            )

          options = [
            max_attempts: sample["attempts"],
            backoff: :none,
            base_delay_ms: 0,
            max_delay_ms: 0
          ]

          try do
            result =
              case mode do
                :immediate ->
                  Exec.run(
                    flow,
                    %{},
                    %{counter: context.counter, secret: "do-not-emit"},
                    options ++ [task_supervisor: context.supervisor]
                  )

                _ ->
                  id = "telemetry-#{System.unique_integer([:positive])}"
                  token = Integer.to_string(System.unique_integer([:positive]))

                  assert {:ok, worker} =
                           Exec.start(
                             context.runner,
                             id,
                             flow,
                             %{},
                             %{counter: context.counter, secret: "do-not-emit"},
                             options ++
                               [dispatch_mode: mode, hooks: Managed.hooks(token)] ++
                               Managed.scheduler(token)
                           )

                  try do
                    Managed.complete(context.runner, id, token, mode)
                  after
                    assert :ok = Runic.Runner.stop(context.runner, id)
                    Runtime.assert_workers_stopped([worker])
                    Managed.drain(token)
                  end
              end

            if sample["fail"] do
              assert {:error, %Error.ExecutionFailureError{}} = result
            else
              assert result == {:ok, %{attempts: sample["attempts"]}, [:saved]}
            end

            assert Agent.get(context.counter, & &1) == sample["attempts"]
            assert_telemetry(event_token, sample, mode)
            Runtime.assert_supervisor_idle(context.supervisor)
          after
            :telemetry.detach(handler)
            Managed.drain(event_token)
          end
        end

        [
          if(sample["fail"], do: "error", else: "success"),
          "attempts:#{sample["attempts"]}",
          "all-current-modes"
        ]
      end
    )
  end

  def telemetry(event, measurements, metadata, {owner, token}),
    do: send(owner, {token, :telemetry, event, measurements, metadata})

  defp assert_telemetry(token, sample, mode) do
    events = telemetry_events(token, [])
    starts = for {[:jido, :action, :start], _, metadata} <- events, do: metadata
    stops = for {[:jido, :action, :stop], _, metadata} <- events, do: metadata
    assert length(starts) == sample["attempts"]
    assert length(stops) == sample["attempts"]
    assert Enum.map(starts, & &1.attempt) == Enum.to_list(0..(sample["attempts"] - 1))
    assert length(Enum.uniq_by(starts, & &1.activation_id)) == 1
    assert length(Enum.uniq_by(starts, & &1.attempt_id)) == sample["attempts"]
    assert Enum.map(starts, & &1.attempt_id) == Enum.map(stops, & &1.attempt_id)

    expected =
      List.duplicate(:error, sample["attempts"] - 1) ++
        [if(sample["fail"], do: :error, else: :ok)]

    assert Enum.map(stops, & &1.outcome) == expected

    for {event, measurements, metadata} <- events, hd(event) == :jido do
      refute List.last(event) == :exception

      refute Enum.any?(
               [:params, :context, :result, :effects, :error, :stacktrace],
               &Map.has_key?(metadata, &1)
             )

      refute inspect(metadata) =~ "do-not-emit"

      if List.last(event) == :stop,
        do: assert(is_integer(measurements.duration) and measurements.duration >= 0)
    end

    flow_events = for {[:jido, :flow, stage], _, _} <- events, do: stage

    if mode == :immediate do
      assert flow_events == [:start, :stop]
    else
      assert flow_events == []

      assert Enum.any?(events, fn {event, _, _} ->
               event == [:runic, :runner, :runnable, :start]
             end)

      terminal = if sample["fail"], do: :exception, else: :stop

      assert Enum.any?(events, fn {event, _, _} ->
               event == [:runic, :runner, :runnable, terminal]
             end)
    end
  end

  defp telemetry_events(token, acc) do
    receive do
      {^token, :telemetry, event, measurements, metadata} ->
        telemetry_events(token, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_dispatch_result(result, expected, "none"), do: assert(result == expected)

  defp assert_dispatch_result(result, _expected, "error"),
    do: assert({:error, %Error.ExecutionFailureError{}} = result)

  defp assert_dispatch_result(result, _expected, "timeout"),
    do: assert({:error, %Error.TimeoutError{}} = result)

  defp assert_blocked_stopped(token, "timeout") do
    assert_receive {^token, :blocked, worker}, 1_000
    Runtime.assert_workers_stopped([worker])
  end

  defp assert_blocked_stopped(_token, _fault), do: :ok

  defp release_items(token, size, concurrency, reverse, fail_at) do
    active =
      for _ <- 1..min(size, concurrency), into: %{} do
        assert_receive {^token, :ready, index, worker}, 5_000
        {index, worker}
      end

    assert Enum.sort(Map.keys(active)) == Enum.to_list(0..(min(size, concurrency) - 1))

    release_items(
      token,
      size,
      reverse,
      fail_at,
      active,
      map_size(active),
      false,
      Map.keys(active),
      Map.values(active)
    )
  end

  defp release_items(_token, _size, _reverse, _fail_at, active, _next, _failed, admitted, workers)
       when map_size(active) == 0, do: {admitted, workers}

  defp release_items(token, size, reverse, fail_at, active, next, failed, admitted, workers) do
    index = if reverse, do: Enum.max(Map.keys(active)), else: Enum.min(Map.keys(active))
    send(Map.fetch!(active, index), :release)
    assert_receive {^token, :controlled_done, status}, 5_000
    assert status == :failed == index >= fail_at
    active = Map.delete(active, index)
    failed = failed or status == :failed

    if next < size and not failed do
      assert_receive {^token, :ready, ^next, worker}, 5_000

      release_items(
        token,
        size,
        reverse,
        fail_at,
        Map.put(active, next, worker),
        next + 1,
        failed,
        admitted ++ [next],
        workers ++ [worker]
      )
    else
      release_items(token, size, reverse, fail_at, active, next, failed, admitted, workers)
    end
  end

  defp advance_to_call(_runner, _id, _token, 0),
    do: flunk("no Action reached within the unit bound")

  defp advance_to_call(runner, id, token, remaining) do
    assert {:ok, _workflow} = Managed.step(runner, id, token)

    case Managed.calls(token) do
      [] -> advance_to_call(runner, id, token, remaining - 1)
      [{label, worker}] -> {label, [worker]}
    end
  end

  defp history_flow(sample) do
    n = sample["size"]
    seed = sample["seed"]
    amount = sample["amount"]
    labels = Enum.to_list(0..(n - 1))

    case sample["kind"] do
      "chain" ->
        components =
          for index <- labels do
            value = if index == 0, do: seed, else: Ref.result("step_#{index - 1}", :value)

            %{
              kind: :step,
              name: "step_#{index}",
              action: Record,
              params: %{label: index, value: value, amount: amount}
            }
          end

        flow =
          Flow.new!(%{
            name: "history_chain",
            components: components,
            output: Ref.result("step_#{n - 1}")
          })

        {flow, %{}, {:ok, %{value: seed + n * amount, label: n - 1}, labels}, labels}

      kind when kind in ["map", "nested"] ->
        items = for index <- labels, do: seed + index

        expected =
          Enum.with_index(items, fn value, index -> %{value: value + amount, label: index} end)

        flow =
          if kind == "nested" do
            Flow.new!(%{
              name: "history_nested",
              components: [
                %{
                  kind: :subflow,
                  name: "child",
                  flow: RecordChild,
                  params: %{items: items, amount: amount}
                }
              ],
              output: Ref.result("child")
            })
          else
            RecordChild
          end

        {flow, %{items: items, amount: amount}, {:ok, %{items: expected}, labels}, labels}

      "iterate" ->
        flow =
          Flow.new!(%{
            name: "history_iterate",
            components: [
              %{
                kind: :iterate,
                name: "loop",
                action: Record,
                params: %{label: Ref.iteration_index(), value: Ref.state(:value), amount: amount},
                state: %{
                  schema: Zoi.map(),
                  initial: %{value: seed},
                  update: %{value: Ref.body_result(:value)}
                },
                completion: Expr.new!(:>=, [Ref.iteration_index(), n]),
                max_iterations: n
              }
            ],
            output: Ref.result("loop")
          })

        expected = %{
          kind: :jido_flow_iterate_result,
          iterations: n,
          state: %{value: seed + n * amount},
          output: %{value: seed + n * amount, label: n - 1}
        }

        {flow, %{}, {:ok, expected, labels}, labels}

      "dispatch" ->
        params = %{
          remaining: n - 2,
          value: seed,
          amount: amount,
          label: 0,
          terminal: "flow",
          fault: "none"
        }

        {DispatchChild, params, {:ok, %{value: seed + (n - 1) * amount, label: n - 1}, labels},
         labels}
    end
  end

  defp assert_portable_boundaries(context, value) do
    for field <- [:params, :context, :metadata] do
      attrs = %{
        target: Record,
        params: %{label: 0, value: value, amount: 1},
        context: %{},
        metadata: %{}
      }

      attrs = Map.put(attrs, field, %{bad: self()})
      id = "unsafe-#{System.unique_integer([:positive])}"
      assert {:error, _} = Exec.start(context.runner, id, Instruction.new!(attrs))
      assert {:error, :not_found} = Runic.Runner.get_workflow(context.runner, id)
    end

    for field <- ~w(output effects) do
      Managed.with_execution(context, Unsafe, %{field: field}, [], fn id, runtime, _options ->
        assert {:error, _} = Managed.complete(context.runner, id, runtime.token, :automatic)
      end)
    end
  end
end
