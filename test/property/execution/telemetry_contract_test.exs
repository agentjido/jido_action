Code.require_file("../support/fuzz.exs", __DIR__)
Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.TelemetryContractTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias JidoActionTest.Property.Fuzz
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.Runtime

  @families [[:jido, :action], [:jido, :flow], [:jido, :flow, :node], [:jido, :flow, :target]]
  @events for family <- @families, phase <- [:start, :stop, :error], do: family ++ [phase]
  @collection_families [
    [:jido, :flow, :map, :item],
    [:jido, :flow, :reduce, :item],
    [:jido, :flow, :iterate, :iteration]
  ]

  defmodule Collections do
    use Jido.Flow, name: "fuzz_telemetry_collections"

    flow do
      map "mapped",
        collection: input(:items),
        action: JidoActionTest.Property.Runtime.Emit,
        params: %{value: item(), fail: input(:phase) == "map" and item() == input(:failure)}

      reduce "fold",
        collection: result("mapped"),
        initial: %{value: 0},
        action: JidoActionTest.Property.Runtime.Emit,
        params: %{
          value: accumulator(:value) + item(:value),
          fail: input(:phase) == "reduce" and item(:value) == input(:failure)
        }

      iterate "loop" do
        action JidoActionTest.Property.Runtime.Emit

        params %{
          value: state(:value) + 1,
          fail: input(:phase) == "iterate" and iteration_index() == input(:failure)
        }

        state [], initial: %{value: result("fold", :value)}
        update %{value: body_result(:value)}
        while(iteration_index() < input(:count))
        max_iterations 20
      end

      output result("loop")
    end
  end

  defmodule CancelCollection do
    use Jido.Flow, name: "fuzz_telemetry_cancel"

    flow do
      map "mapped",
        collection: input(:items),
        action: JidoActionTest.Property.Runtime.Gate,
        params: %{value: item()}

      output %{items: result("mapped")}
    end
  end

  @tag :fuzz
  @tag max_runs: 180, max_run_time: 300_000, timeout: 900_000
  @tag contracts: ["OBS-001"]
  @tag contract_cases: [
         "OBS-001/fuzz-collection-success",
         "OBS-001/fuzz-collection-failure",
         "OBS-001/fuzz-collection-cancel",
         "OBS-001/fuzz-collection-selection"
       ]
  test "fuzz: selected nested collection events close once on every terminal path", context do
    generator =
      fixed_map(%{
        "count" => integer(1..12),
        "failure" => integer(0..20),
        "outcome" => member_of(~w(success failure cancel)),
        "phase" => member_of(~w(map reduce iterate)),
        "nested" => boolean(),
        "detailed" => boolean(),
        "limit" => integer(1..3)
      })

    examples =
      for outcome <- ~w(success failure cancel),
          phase <- ~w(map reduce iterate),
          detailed <- [false, true] do
        %{
          "count" => 3,
          "failure" => 1,
          "outcome" => outcome,
          "phase" => phase,
          "nested" => true,
          "detailed" => detailed,
          "limit" => 2
        }
      end

    Fuzz.check(
      "telemetry_lifecycle",
      generator,
      Map.to_list(context) ++ [examples: examples],
      &check_lifecycle/1
    )
  end

  defp check_lifecycle(sample) do
    Runtime.with_context(fn runtime ->
      count = sample["count"]

      input = %{
        items: Enum.to_list(0..(count - 1)),
        count: count,
        phase: if(sample["outcome"] == "failure", do: sample["phase"], else: "none"),
        failure: rem(sample["failure"], count)
      }

      child = if sample["outcome"] == "cancel", do: CancelCollection, else: Collections

      target =
        if sample["nested"] do
          JidoActionTest.FlowBuilder.new!(
            name: "telemetry_wrapper",
            components: [
              JidoActionTest.FlowComponent.subflow!(name: "child", flow: child, params: input)
            ],
            output: Ref.result("child")
          )
        else
          child
        end

      families = @families ++ if(sample["detailed"], do: @collection_families, else: [])
      selected = for family <- families, phase <- [:start, :stop, :error], do: family ++ [phase]

      with_handler(
        fn ref ->
          if sample["outcome"] == "cancel" do
            handle =
              Exec.run_async(target, input, runtime, Runtime.options(runtime, sample["limit"]))

            try do
              token = runtime.token

              workers =
                for _ <- 1..min(count, sample["limit"]) do
                  assert_receive {^token, :ready, _, worker}, 5_000
                  worker
                end

              assert :ok = Exec.cancel(handle)
              Runtime.assert_workers_stopped(workers ++ [handle.pid])
              refute_received {^token, :ready, _, _}
            after
              Exec.cancel(handle)
            end
          else
            result = Exec.run(target, input, runtime, Runtime.options(runtime, sample["limit"]))

            if sample["outcome"] == "success" do
              assert {:ok, %{iterations: ^count, state: %{value: total}}, _effects} = result
              assert total == Enum.sum(input.items) + count
            else
              assert {:error, error} = result
              assert is_exception(error)
            end

            Runtime.assert_workers_stopped(Enum.map(Runtime.calls(runtime), &elem(&1, 1)))
          end

          recorded = events(ref)
          assert_closed(recorded, families)

          assert Enum.count(recorded, fn {event, _, _} -> event == [:jido, :flow, :start] end) ==
                   1

          assert Enum.any?(recorded, fn {event, _, _} -> List.last(event) == :error end) ==
                   (sample["outcome"] != "success")

          collection =
            Enum.filter(recorded, fn {event, _, _} ->
              Enum.drop(event, -1) in @collection_families
            end)

          assert collection != [] == sample["detailed"]

          if sample["detailed"] and sample["outcome"] == "success" do
            for family <- @collection_families do
              assert Enum.count(collection, fn {event, _, _} -> event == family ++ [:start] end) ==
                       count
            end
          end

          for {event, measurements, metadata} <- recorded do
            if List.last(event) == :start do
              assert is_integer(measurements.system_time)
              assert is_integer(measurements.monotonic_time)
            end

            if List.last(event) == :error do
              assert Map.has_key?(metadata, :error)
              assert Map.has_key?(metadata, :error_type)
            end
          end
        end,
        selected
      )
    end)

    [
      sample["outcome"],
      sample["phase"],
      if(sample["detailed"], do: "collection-events", else: "core-events")
    ]
  end

  defmodule Child do
    use Jido.Flow, name: "property_telemetry_child"

    flow do
      step "emit",
        action: JidoActionTest.Property.Runtime.Emit,
        params: %{value: input(:value), fail: input(:fail)}

      output result("emit")
    end
  end

  @tag contracts: ["OBS-001"]
  @tag contract_cases: ["OBS-001/nested-success", "OBS-001/nested-error", "OBS-001/execution-id"]
  property "nested success and failure close every started lifecycle with one execution ID" do
    check all(value <- integer(), count <- integer(1..4), max_runs: 25) do
      for fail <- [false, true], concurrency <- [1, 3] do
        Runtime.with_context(fn context ->
          components =
            for index <- 1..count,
                do:
                  JidoActionTest.FlowComponent.subflow!(
                    name: "child_#{index}",
                    flow: Child,
                    params: %{value: value + index, fail: fail and index == count},
                    needs:
                      if(index == count,
                        do: for(previous <- 1..count, previous < count, do: "child_#{previous}"),
                        else: []
                      )
                  )

          flow =
            JidoActionTest.FlowBuilder.new!(
              name: "telemetry_parent",
              components: components,
              output: %{done: true}
            )

          with_handler(fn ref ->
            result = Exec.run(flow, %{}, context, Runtime.options(context, concurrency))

            if fail,
              do: assert(match?({:error, _}, result)),
              else: assert(match?({:ok, _, _}, result))

            events = events(ref)
            assert_closed(events)

            flow_events =
              Enum.filter(events, fn {event, _, _} -> event == [:jido, :flow, :start] end)

            assert length(flow_events) == 1

            assert Enum.count(events, fn {event, _, _} ->
                     event == [:jido, :flow, :target, :start]
                   end) == count

            assert Enum.any?(events, fn {event, _, _} ->
                     List.last(event) == if(fail, do: :error, else: :stop)
                   end)
          end)

          calls = Runtime.calls(context)
          assert Enum.sort(Enum.map(calls, &elem(&1, 0))) == Enum.map(1..count, &(value + &1))
          Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
        end)
      end
    end
  end

  @tag contracts: ["OBS-001", "EFFECT-002"]
  @tag contract_cases: ["OBS-001/cancellation"]
  property "explicit cancellation closes active Flow node and target spans with errors" do
    check all(value <- integer(), max_runs: 20) do
      Runtime.with_context(fn context ->
        token = context.token

        flow =
          JidoActionTest.FlowBuilder.new!(
            name: "telemetry_cancel",
            components: [
              JidoActionTest.FlowComponent.step!(
                name: "blocked",
                action: Runtime.Gate,
                params: %{value: value}
              )
            ],
            output: Ref.result("blocked")
          )

        with_handler(fn ref ->
          handle = Exec.run_async(flow, %{}, context, Runtime.options(context))

          try do
            assert_receive {^token, :ready, ^value, worker}, 1_000
            assert :ok = Exec.cancel(handle)
            Runtime.assert_workers_stopped([worker, handle.pid])
            recorded = events(ref)
            assert_closed(recorded)
            assert Enum.count(recorded, fn {event, _, _} -> List.last(event) == :error end) == 3
            refute Enum.any?(recorded, fn {event, _, _} -> List.last(event) == :stop end)
          after
            Exec.cancel(handle)
          end
        end)
      end)
    end
  end

  def record(event, measurements, metadata, {owner, ref}),
    do: send(owner, {ref, :event, event, measurements, metadata})

  defp with_handler(fun, selected \\ @events) do
    ref = make_ref()
    id = {__MODULE__, ref}
    :ok = :telemetry.attach_many(id, selected, &__MODULE__.record/4, {self(), ref})

    try do
      fun.(ref)
    after
      :telemetry.detach(id)
      events(ref)
    end
  end

  defp events(ref, acc \\ []) do
    receive do
      {^ref, :event, event, measurements, metadata} ->
        events(ref, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_closed(events, families \\ @families) do
    assert events != []

    assert [_id] =
             events |> Enum.map(fn {_, _, metadata} -> metadata.execution_id end) |> Enum.uniq()

    grouped =
      Enum.group_by(events, fn {event, _, metadata} ->
        {Enum.drop(event, -1), Map.drop(metadata, [:error, :error_type])}
      end)

    for {{family, metadata}, lifecycle} <- grouped do
      assert family in families
      assert Map.has_key?(metadata, :execution_id)
      # Repeated child invocations can have identical public metadata.
      starts = Enum.count(lifecycle, fn {event, _, _} -> List.last(event) == :start end)
      assert starts > 0
      assert length(lifecycle) == starts * 2

      assert Enum.count(lifecycle, fn {event, _, _} -> List.last(event) in [:stop, :error] end) ==
               starts

      for {event, measurements, _} <- lifecycle, List.last(event) != :start do
        assert is_integer(measurements.duration)
        assert measurements.duration >= 0
      end
    end
  end
end
