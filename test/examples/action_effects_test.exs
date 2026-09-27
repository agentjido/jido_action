defmodule JidoActionTest.Examples.ActionEffectsTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Output
  alias Jido.{Exec, Instruction}

  setup_all do
    guide = Path.expand("../../guides/action-effects.livemd", __DIR__)

    blocks =
      Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide), capture: :all_but_first)
      |> List.flatten()

    # Mix.install belongs to Livebook. Tests use this package's compiled source.
    [install | examples] = blocks
    assert install =~ "Mix.install"

    on_exit(fn ->
      for module <- [EffectExamples.ApproveOrder, EffectExamples.ExportOrders] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    {_, bindings} = Code.eval_string(Enum.join(examples, "\n"), [], file: guide)

    {:ok,
     approval_flow: Keyword.fetch!(bindings, :approval_flow),
     export_flow: Keyword.fetch!(bindings, :export_flow)}
  end

  test "the approval example keeps its map and optional request through a Flow", context do
    for target <- [EffectExamples.ApproveOrder, context.approval_flow] do
      assert Exec.run(target, %{order_id: "order-42", notify: true}) ==
               {:ok, %{order_id: "order-42", status: :approved},
                [{:send_confirmation, "order-42"}]}

      assert Exec.run(target, %{order_id: "order-42", notify: false}) ==
               {:ok, %{order_id: "order-42", status: :approved}}
    end
  end

  test "the approval callback omits effects when notification is off" do
    assert apply(EffectExamples.ApproveOrder, :run, [%{order_id: "order-42", notify: false}, %{}]) ==
             {:ok, %{order_id: "order-42", status: :approved}}
  end

  test "the export example stays lazy through Action, Flow, Instruction, and async calls",
       context do
    owner = self()
    ref = make_ref()

    rows =
      Stream.map([%{order_id: 42, total_cents: 1250}], fn row ->
        send(owner, {ref, :read, row.order_id})
        row
      end)

    params = %{report_id: "report-7", audit: true}
    instruction = Instruction.new!(target: context.export_flow, params: params)

    results = [
      Exec.run(EffectExamples.ExportOrders, params, %{rows: rows}),
      Exec.run(context.export_flow, params, %{rows: rows}),
      Exec.run(instruction, %{}, %{rows: rows}),
      Exec.await(Exec.run_async(context.export_flow, params, %{rows: rows}))
    ]

    # All calls have completed. None has consumed the stream.
    refute_received {^ref, :read, _}

    for result <- results do
      assert {:ok, %Output{kind: :stream, value: stream, meta: meta},
              [{:audit, %{event: :export_prepared, report_id: "report-7"}}]} = result

      assert meta == %{content_type: "text/csv", report_id: "report-7"}
      assert Enum.to_list(stream) == ["order_id,total_cents\n", "42,1250\n"]
      assert_received {^ref, :read, 42}
      refute_received {^ref, :read, _}
    end
  end

  test "the export example also supports a stream without effects", context do
    for target <- [EffectExamples.ExportOrders, context.export_flow] do
      assert {:ok, %Output{kind: :stream, value: stream}} =
               Exec.run(target, %{report_id: "report-7", audit: false}, %{rows: []})

      assert Enum.to_list(stream) == ["order_id,total_cents\n"]
    end
  end

  test "step-wise approval and export return the same requests", context do
    assert {:ok, approval} =
             Exec.start(context.approval_flow, %{order_id: "order-42", notify: true})

    assert {:ok, approval} = Exec.continue(approval)

    assert Exec.result(approval) ==
             {:ok, %{order_id: "order-42", status: :approved}, [{:send_confirmation, "order-42"}]}

    assert {:ok, export} =
             Exec.start(context.export_flow, %{report_id: "report-7", audit: true}, %{rows: []})

    assert {:ok, export} = Exec.continue(export)

    assert {:ok, %Output{kind: :stream, value: stream},
            [{:audit, %{event: :export_prepared, report_id: "report-7"}}]} = Exec.result(export)

    assert Enum.to_list(stream) == ["order_id,total_cents\n"]
  end

  test "a missing row source returns an error with no audit request", context do
    for target <- [EffectExamples.ExportOrders, context.export_flow] do
      assert {:error, _error} = Exec.run(target, %{report_id: "report-7", audit: true})
    end
  end

  test "a row source can fail after the export request has been returned", context do
    rows = Stream.map([42], fn _ -> raise "row source unavailable" end)

    assert {:ok, %Output{value: stream},
            [{:audit, %{event: :export_prepared, report_id: "report-7"}}]} =
             Exec.run(context.export_flow, %{report_id: "report-7", audit: true}, %{rows: rows})

    assert_raise RuntimeError, "row source unavailable", fn -> Enum.to_list(stream) end
  end
end
