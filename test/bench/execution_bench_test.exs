Code.require_file("../../bench/support/suite.exs", __DIR__)

defmodule JidoActionTest.ExecutionBenchTest do
  use ExUnit.Case, async: false

  alias JidoActionBench.{Fixtures, Measure, MemoryCases, Report, Suite}

  setup do
    start_supervised!({Task.Supervisor, name: JidoActionBench.TaskSupervisor})
    :ok
  end

  test "Action cases occur once per payload, independent of graph sizes" do
    workloads = Fixtures.workloads([2, 8, 16], [:small, :large_map, :large_binary])
    actions = Enum.filter(workloads, &String.starts_with?(&1.id, "action/"))
    assert length(workloads) == 147
    assert length(actions) == 12
    assert length(Enum.uniq_by(workloads, & &1.id)) == length(workloads)
  end

  test "resource summaries retain three separate runs and their medians" do
    owner = self()
    tag = make_ref()

    workload = %{
      setup: fn _ -> nil end,
      run: fn _ ->
        send(owner, {tag, self()})
        :ok
      end,
      check: fn :ok -> :ok end
    }

    resources = Measure.resources(workload, 3)
    assert length(resources.samples) == 3

    callers =
      for _ <- 1..3 do
        assert_received {^tag, pid}
        refute Process.alive?(pid)
        pid
      end

    assert length(Enum.uniq(callers)) == 3
    values = Enum.map(resources.samples, & &1.observed_peak.process_memory_bytes)
    assert resources.median.observed_peak.process_memory_bytes == Enum.at(Enum.sort(values), 1)
    assert Enum.all?(resources.samples, &(&1.owned_remaining == 0))
  end

  test "paused retention measures execution values from the measured call" do
    workload =
      Enum.find(Fixtures.workloads([2], [:small]), &(&1.name == "serial/paused_continue"))

    prepared = workload.setup.(%{})
    result = workload.run.(prepared)
    assert :ok == workload.check.(result)
    terms = workload.retained.(prepared, result)
    assert %Jido.Exec.Execution{status: :running} = terms.paused_execution
    assert %Jido.Exec.Execution{status: :succeeded} = terms.finished_execution
    assert terms.paused_execution.id == terms.finished_execution.id
    measured = Measure.retained(workload)
    assert measured.paused_execution.copied_flat_heap_bytes > 0
    assert measured.finished_execution.copied_flat_heap_bytes > 0
  end

  test "focused memory cases check results, copied terms, and helper cleanup" do
    workloads = MemoryCases.workloads()
    assert length(workloads) == 18
    assert length(Enum.uniq_by(workloads, & &1.id)) == length(workloads)

    for workload <- workloads do
      assert length(Measure.timing(workload, 1, 1).wall_ns.samples) == 1
      assert Measure.resources(workload).median.owned_remaining == 0

      for {_name, measured} <- Measure.retained(workload) do
        assert measured.copied_flat_heap_bytes == measured.flat_heap_bytes
      end

      assert Task.Supervisor.children(JidoActionBench.TaskSupervisor) == []
    end

    failure = Enum.find(workloads, &(&1.id == "retention/failure/large_list"))
    terms = Measure.retained(failure)

    assert terms.finished_execution.copied_flat_heap_bytes >
             terms.failure_records.copied_flat_heap_bytes
  end

  test "every first-stage workload checks its result in timing and resource runs" do
    for payload <- [:small, :large_map, :large_binary],
        workload <- Fixtures.workloads([2], [payload]) do
      timing = Measure.timing(workload, 1, 2)
      assert length(timing.wall_ns.samples) == 2
      assert timing.caller_reductions.min >= 0
      resources = Measure.resources(workload)
      assert resources.median.owned_remaining == 0
      assert resources.median.observations > 0
      assert resources.median.observed_peak.process_memory_bytes > 0
    end
  end

  test "incorrect results cannot be accepted as measurements" do
    workload = %{setup: fn _ -> nil end, run: fn _ -> :wrong end, check: fn :right -> :ok end}
    assert_raise FunctionClauseError, fn -> Measure.timing(workload, 1, 1) end
    assert_raise RuntimeError, ~r/resource caller failed/, fn -> Measure.resources(workload) end
  end

  test "a failed probe stops and confirms its waiting child and grandchild" do
    owner = self()
    tag = make_ref()

    workload = %{
      setup: fn _ -> nil end,
      run: fn _ ->
        caller = self()

        {:ok, child} =
          Task.Supervisor.start_child(JidoActionBench.TaskSupervisor, fn ->
            Process.flag(:trap_exit, true)
            child = self()

            grandchild =
              spawn(fn ->
                Process.flag(:trap_exit, true)
                send(child, {tag, :ready, self()})
                receive do: (:release -> :ok)
              end)

            receive do
              {^tag, :ready, ^grandchild} -> send(caller, {tag, :ready, child, grandchild})
            end

            receive do: (:release -> :ok)
          end)

        receive do
          {^tag, :ready, ^child, grandchild} -> send(owner, {tag, child, grandchild})
        end

        :incorrect
      end,
      check: fn _ -> raise "probe rejected" end
    }

    assert_raise RuntimeError, ~r/resource caller failed:.*probe rejected/, fn ->
      Measure.resources(workload)
    end

    assert_received {^tag, child, grandchild}

    for pid <- [child, grandchild] do
      refute Process.alive?(pid)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :noproc}
    end

    assert Task.Supervisor.children(JidoActionBench.TaskSupervisor) == []
    direct = Enum.find(Fixtures.workloads([2], [:small]), &(&1.name == "action/direct"))
    assert Measure.resources(direct).median.owned_process_starts == 0
  end

  test "traced Action helpers belong to the caller and dedicated supervisor" do
    workloads = Fixtures.workloads([2], [:small])
    direct = Enum.find(workloads, &(&1.name == "action/direct"))
    run = Enum.find(workloads, &(&1.name == "action/run"))
    assert Measure.resources(direct).median.owned_process_starts == 0
    assert Measure.resources(run).median.owned_process_starts > 0
    assert Task.Supervisor.children(JidoActionBench.TaskSupervisor) == []
  end

  test "a small shared term cannot bypass the flat copy bound" do
    shared = Enum.reduce(1..22, :leaf, fn _, child -> {child, child} end)
    assert :erts_debug.size(shared) < 1_000

    assert_raise RuntimeError, ~r/term transfer exceeds the 64 MiB heap bound/, fn ->
      Measure.term_size(shared)
    end
  end

  test "copy growth stays bounded for the first-stage graphs" do
    assert :ok == Suite.check_growth!()
    assert_raise ArgumentError, fn -> Fixtures.workloads([33], [:small]) end
    assert_raise ArgumentError, fn -> Fixtures.workloads([0], [:small]) end
  end

  test "comparison joins case identities and rejects incompatible measurements" do
    row = %{
      "id" => "action/run/small",
      "timing" => %{"wall_ns" => %{"median" => 100}},
      "resources" => %{
        "median" => %{
          "owned_process_starts" => 2,
          "owned_remaining" => 0,
          "observed_peak" => %{"process_memory_bytes" => 100, "shared_binary_bytes" => 20}
        }
      }
    }

    before = %{
      "schema_version" => 2,
      "source" => %{"tool_sha256" => "same-tool"},
      "method" => "test-method",
      "environment" => %{"otp" => "29"},
      "settings" => %{"samples" => 2},
      "cases" => [row]
    }

    after_report = put_in(before, ["cases"], [put_in(row, ["timing", "wall_ns", "median"], 120)])

    after_report =
      put_in(
        after_report,
        ["cases", Access.at(0), "resources", "median", "observed_peak", "process_memory_bytes"],
        80
      )

    assert Report.compare!(before, after_report) =~ "1.200"
    assert Report.compare!(before, after_report) =~ "0.800"
    assert Report.compare!(before, after_report) =~ "No speedup claim"

    assert_raise ArgumentError, ~r/environment/, fn ->
      Report.compare!(before, put_in(after_report, ["environment", "otp"], "28"))
    end

    assert_raise ArgumentError, ~r/tool/, fn ->
      Report.compare!(before, put_in(after_report, ["source", "tool_sha256"], "changed-tool"))
    end

    assert_raise ArgumentError, ~r/method/, fn ->
      Report.compare!(before, put_in(after_report, ["method"], "changed-method"))
    end

    assert_raise ArgumentError, ~r/schema_version/, fn ->
      Report.compare!(before, %{after_report | "schema_version" => 1})
    end

    assert_raise ArgumentError, ~r/settings/, fn ->
      Report.compare!(before, put_in(after_report, ["settings", "resource_samples"], 3))
    end

    assert_raise ArgumentError, ~r/case/, fn ->
      Report.compare!(before, %{after_report | "cases" => []})
    end
  end
end
