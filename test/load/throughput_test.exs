Code.require_file("support/throughput.exs", __DIR__)

defmodule JidoActionTest.Load.ThroughputCheck do
  use ExUnit.Case, async: false
  @moduletag :throughput

  alias JidoActionLoad.Throughput

  test "the separate smoke run checks every result and reports scaling data" do
    report = Throughput.run("smoke")

    assert length(report.cases) == 13
    assert Enum.all?(report.cases, &(&1.wall_ns.median > 0))
    assert Enum.all?(report.cases, &(&1.items_per_second > 0))
    assert Enum.all?(report.cases, &(&1.final_graph.vertices > 0))
    assert Enum.all?(report.cases, &(&1.final_graph.edges > 0))

    for row <- report.cases do
      assert row.phase_probe.calls["Runic.Workflow.prepare_for_dispatch/1"].calls > 0
      assert row.phase_probe.calls["Runic.Workflow.execute_runnable/1"].calls > 0
    end

    assert Enum.count(report.comparisons, &(&1.kind == "map_size")) == 4
    assert Enum.count(report.comparisons, &(&1.kind == "partition")) == 1
    assert Enum.count(report.comparisons, &(&1.kind == "graph_edges")) == 1

    [one_map, four_maps] =
      report.cases
      |> Enum.filter(&(&1.kind == "partition"))
      |> Enum.sort_by(& &1.dimensions.groups)

    assert one_map.items == four_maps.items
    assert one_map.dimensions.groups == 1
    assert four_maps.dimensions.groups == 4
    assert four_maps.final_graph.edges > one_map.final_graph.edges
  end

  @tag :tmp_dir
  test "the report writes JSON and Markdown with exact case IDs", %{tmp_dir: directory} do
    report = Throughput.run("smoke", "map/runic/repeated/8")
    assert [%{id: "map/runic/repeated/8"}] = report.cases
    assert report.comparisons == []

    Throughput.write!(report, directory)
    decoded = directory |> Path.join("report.json") |> File.read!() |> JSON.decode!()
    assert [%{"id" => "map/runic/repeated/8"}] = decoded["cases"]
    assert File.read!(Path.join(directory, "report.md")) =~ "map/runic/repeated/8"
  end

  test "the largest work is opt-in and does not use a speed pass limit" do
    assert Throughput.settings("stress").sizes == [128, 512, 2_048, 8_192]
    assert Throughput.settings("extreme").sizes == [16_384]
    assert_raise ArgumentError, fn -> Throughput.settings("unknown") end
  end

  test "a memory stop is reported and later cases can continue" do
    report =
      Throughput.run("smoke", "map/runic/unique/8", max_case_process_bytes: 1)

    assert [%{status: "aborted", observed_peak_process_bytes: peak}] = report.cases
    assert peak > 1
    assert report.comparisons == []
  end
end
