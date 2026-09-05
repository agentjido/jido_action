Code.require_file("../../bench/support/suite.exs", __DIR__)

defmodule JidoActionTest.ExecutionBenchTest do
  use ExUnit.Case, async: false

  alias JidoActionBench.{Fixtures, Measure, Report, Suite}

  setup do
    start_supervised!({Task.Supervisor, name: JidoActionBench.TaskSupervisor})
    :ok
  end

  test "every first-stage workload checks its result in timing and resource runs" do
    for payload <- [:small, :large_map, :large_binary],
        workload <- Fixtures.workloads(2, payload) do
      timing = Measure.timing(workload, 1, 2)
      assert length(timing.wall_ns.samples) == 2
      assert timing.caller_reductions.min >= 0
      resources = Measure.resources(workload)
      assert resources.owned_remaining == 0
      assert resources.observations > 0
      assert resources.observed_peak.process_memory_bytes > 0
    end
  end

  test "incorrect results cannot be accepted as measurements" do
    workload = %{setup: fn _ -> nil end, run: fn _ -> :wrong end, check: fn :right -> :ok end}
    assert_raise FunctionClauseError, fn -> Measure.timing(workload, 1, 1) end
    assert_raise RuntimeError, ~r/resource caller failed/, fn -> Measure.resources(workload) end
  end

  test "traced Action helpers belong to the caller and dedicated supervisor" do
    workloads = Fixtures.workloads(2, :small)
    direct = Enum.find(workloads, &(&1.name == "action/direct"))
    run = Enum.find(workloads, &(&1.name == "action/run"))
    assert Measure.resources(direct).owned_process_starts == 0
    assert Measure.resources(run).owned_process_starts > 0
    assert Task.Supervisor.children(JidoActionBench.TaskSupervisor) == []
  end

  test "copy growth stays bounded for the first-stage graphs" do
    assert :ok == Suite.check_growth!()
    assert_raise ArgumentError, fn -> Fixtures.workloads(33, :small) end
    assert_raise ArgumentError, fn -> Fixtures.workloads(0, :small) end
  end

  test "comparison joins case identities and rejects incompatible measurements" do
    row = %{
      "id" => "action/run/small/2",
      "timing" => %{"wall_ns" => %{"median" => 100}},
      "resources" => %{"owned_process_starts" => 2, "owned_remaining" => 0}
    }

    before = %{
      "schema_version" => 1,
      "environment" => %{"otp" => "29"},
      "settings" => %{"samples" => 2},
      "cases" => [row]
    }

    after_report = put_in(before, ["cases"], [put_in(row, ["timing", "wall_ns", "median"], 120)])
    assert Report.compare!(before, after_report) =~ "1.200"
    assert Report.compare!(before, after_report) =~ "No speedup claim"

    assert_raise ArgumentError, ~r/environment/, fn ->
      Report.compare!(before, put_in(after_report, ["environment", "otp"], "28"))
    end

    assert_raise ArgumentError, ~r/case/, fn ->
      Report.compare!(before, %{after_report | "cases" => []})
    end
  end
end
