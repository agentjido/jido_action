Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Execution.ScheduleContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.Exec
  alias JidoActionTest.Property.{Fuzz, Runtime}
  @ready_timeout 5_000

  for {suite, runs, maximum, budget} <- [{:property, 40, 6, 10_000}, {:fuzz, 400, 8, 300_000}] do
    @tag [
      {suite, true},
      max_runs: runs,
      max_run_time: budget,
      max_workers: maximum,
      timeout: if(suite == :fuzz, do: 900_000, else: 90_000)
    ]
    @tag contracts: ["EXEC-004", "EXEC-006", "EFFECT-001", "EFFECT-002"]
    @tag contract_cases: [
           "EXEC-004/scheduled-failure",
           "EXEC-006/scheduled-cancel",
           "EFFECT-001/scheduled-success",
           "EFFECT-002/scheduled-prefix"
         ]
    test "#{suite}: controlled completion schedules preserve effects and terminal cleanup",
         context do
      generator =
        fixed_map(%{
          "ranks" => list_of(integer(0..20), min_length: 4, max_length: context.max_workers),
          "limit" => integer(2..3),
          "cut" => integer(0..8),
          "prior" => integer(-10..10),
          "outcome" => member_of(["success", "failure", "cancel"])
        })

      examples =
        for outcome <- ["success", "failure", "cancel"] do
          %{
            "ranks" => [3, 2, 1, 0],
            "limit" => 2,
            "cut" => 1,
            "prior" => -1,
            "outcome" => outcome
          }
        end

      Fuzz.check(
        "async_schedules",
        generator,
        Map.to_list(context) ++ [examples: examples],
        &assert_schedule/1
      )
    end
  end

  defp assert_schedule(sample) do
    count = length(sample["ranks"])
    limit = sample["limit"]

    ranks =
      sample["ranks"] |> Enum.with_index(1) |> Map.new(fn {rank, index} -> {index, rank} end)

    Runtime.with_context(fn context ->
      flow = flow(count, sample["prior"])
      handle = Exec.run_async(flow, %{}, context, Runtime.options(context, limit))

      try do
        {active, pending} =
          Enum.reduce(1..limit, {%{}, MapSet.new(1..count)}, fn _, {active, pending} ->
            {index, worker} = ready(context, pending)
            {Map.put(active, index, worker), MapSet.delete(pending, index)}
          end)

        # Stop before the pending queue is empty so failure/cancel cases test it.
        cut = rem(sample["cut"], count - limit)
        {active, pending, released} = advance(cut, active, pending, [], ranks, context)

        released =
          case sample["outcome"] do
            "success" ->
              {empty, pending, released} =
                advance(count - cut, active, pending, released, ranks, context)

              assert empty == %{}
              assert MapSet.size(pending) == 0
              ref = handle.ref
              pid = handle.pid
              assert_receive {:jido_exec_async_result, ^ref, ^pid, _} = message, @ready_timeout
              expected = {:ok, %{done: true}, [sample["prior"] | Enum.to_list(1..count)]}
              assert Exec.handle_message(handle, message) == {:done, expected}
              released

            "failure" ->
              {index, worker} = select(active, ranks)
              send(worker, {context.token, :fail})
              Runtime.assert_workers_stopped([worker])

              # A failed worker has stopped admission before it exits. Let all
              # other admitted callbacks finish, then use the terminal barrier.
              rest = Map.delete(active, index)
              Enum.each(rest, fn {_index, pid} -> send(pid, {context.token, :release}) end)

              assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
                       Exec.await(handle)

              assert details.reason == {:rejected, index}
              Runtime.assert_workers_stopped(Map.values(rest))
              released ++ [index]

            "cancel" ->
              assert :ok = Exec.cancel(handle)
              Runtime.assert_workers_stopped(Map.values(active))
              released
          end

        assert {:error, _} = Exec.await(handle, 0)
        Runtime.assert_workers_stopped([handle.pid])
        Runtime.assert_calls(context, [sample["prior"]])
        token = context.token
        refute_received {^token, :ready, _, _}
        ref = handle.ref
        pid = handle.pid
        refute_received {:jido_exec_async_result, ^ref, ^pid, _}

        [
          sample["outcome"],
          "limit:#{limit}",
          "workers:#{count}",
          if(released == Enum.sort(released), do: "ordered-release", else: "reordered-release"),
          if(cut == 0, do: "no-completed-gates", else: "completed-prefix")
        ]
      after
        Exec.cancel(handle)
      end
    end)
  end

  defp advance(0, active, pending, released, _ranks, _context), do: {active, pending, released}

  defp advance(count, active, pending, released, ranks, context) do
    {index, worker} = select(active, ranks)
    send(worker, {context.token, :release})
    Runtime.assert_workers_stopped([worker])
    active = Map.delete(active, index)

    {active, pending} =
      if MapSet.size(pending) == 0 do
        {active, pending}
      else
        {next, worker} = ready(context, pending)
        {Map.put(active, next, worker), MapSet.delete(pending, next)}
      end

    advance(count - 1, active, pending, released ++ [index], ranks, context)
  end

  defp select(active, ranks),
    do: Enum.min_by(active, fn {index, _pid} -> {ranks[index], index} end)

  defp ready(context, pending) do
    token = context.token
    assert_receive {^token, :ready, index, worker}, @ready_timeout
    assert MapSet.member?(pending, index)
    {index, worker}
  end

  defp flow(count, prior) do
    gates =
      for index <- 1..count do
        JidoActionTest.FlowComponent.step!(
          name: "n#{index}",
          action: Runtime.Gate,
          params: %{value: index},
          needs: ["first"]
        )
      end

    JidoActionTest.FlowBuilder.new!(
      name: "schedule",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "first",
          action: Runtime.Emit,
          params: %{value: prior}
        )
        | gates
      ],
      output: %{done: true}
    )
  end
end
