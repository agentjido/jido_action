Code.require_file("support/report.exs", __DIR__)

defmodule JidoActionTest.Property.ReportTest do
  use ExUnit.Case, async: true
  @moduletag :property
  alias JidoActionTest.Property.Report

  test "the documented fuzz inventory matches the full gate" do
    register = File.read!(Path.expand("../../guides/public-contracts.md", __DIR__))
    ids = Regex.scan(~r/^\| `([a-z][a-z_]+)` \|/m, register) |> Enum.map(&List.last/1)
    assert Enum.sort(ids) == Report.fuzz_ids()
  end

  setup do
    suffix = "#{System.pid()}-#{System.unique_integer([:positive])}"
    dir = Path.join([Mix.Project.build_path(), "property-report-tests", suffix])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, tmp_dir: dir}
  end

  test "a new run replaces old evidence before test files load", %{tmp_dir: dir} do
    path = Path.join(dir, "report.json")
    File.write!(path, JSON.encode!(%{status: "finished", outcome: "passed"}))
    Report.prepare!(path)
    assert %{"status" => "incomplete", "started_at" => _} = report = read(path)
    refute Map.has_key?(report, "outcome")
  end

  test "failed and excluded declarations remain visible without passed case evidence", %{
    tmp_dir: dir
  } do
    report =
      finish(dir, [
        test_record("pass", nil, ["ACT-001"], ["ACT-001/missing"]),
        test_record("fail", {:failed, []}, ["ACT-001", "UNKNOWN-001"], ["UNKNOWN-001/case"]),
        test_record("exclude", {:excluded, []}, ["ACT-002"], ["ACT-002/raise"]),
        test_record("skip", {:skipped, []}, ["ACT-003"], ["ACT-003/after-callback"])
      ])

    assert report["outcome"] == "failed"
    assert report["contracts_with_passed_evidence"] == ["ACT-001"]
    assert report["declared_forced_cases_in_passed_tests"] == ["ACT-001/missing"]
    assert report["unknown_contract_ids"] == ["UNKNOWN-001"]
    assert report["invalid_case_ids"] == ["UNKNOWN-001/case"]
    assert "ACT-002" in report["contracts_without_passed_evidence"]

    assert Enum.map(report["tests"], & &1["result"]) == [
             "excluded",
             "failed",
             "passed",
             "skipped"
           ]
  end

  test "a case must belong to a known contract declared by its test", %{tmp_dir: dir} do
    report =
      finish(dir, [test_record("invalid tags", nil, ["ACT-001"], ["ACT-002/raise", "ACT-001/"])])

    assert Enum.sort(report["invalid_case_ids"]) == ["ACT-001/", "ACT-002/raise"]
    assert report["outcome"] == "failed"
  end

  test "an empty selection has no evidence and an invalid test fails the run", %{tmp_dir: dir} do
    assert finish(dir, [test_record("excluded", {:excluded, []}, ["ACT-001"], [])])["outcome"] ==
             "no_evidence"

    assert finish(dir, [test_record("invalid", {:invalid, nil}, ["ACT-001"], [])])["outcome"] ==
             "failed"

    normal = %{test_record("normal", {:failed, []}, [], []) | tags: %{}}
    assert finish(dir, [normal])["outcome"] == "failed"
  end

  test "an exported source tree has unknown Git metadata", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "guides"))
    File.write!(Path.join(dir, "guides/public-contracts.md"), "| ACT-001 | A promise | Cases |\n")
    report = finish(dir, [test_record("pass", nil, ["ACT-001"], [])], root: dir)
    assert report["status"] == "finished"
    assert report["outcome"] == "passed"
    assert report["revision"] == nil
    assert report["working_tree_dirty"] == nil
    assert report["contracts_without_passed_evidence"] == []
  end

  test "fuzz evidence belongs only to the current run", %{tmp_dir: dir} do
    path = Path.join(dir, "report.json")
    {:ok, state} = Report.init(path: path)
    fuzz_dir = Path.join([dir, "property-fuzz", state.metadata.run_id])
    File.mkdir_p!(fuzz_dir)
    current = measurement(state.metadata.run_id)
    stale = %{id: "stale", run_id: "previous-run", generated: 900}
    File.write!(Path.join(fuzz_dir, "current.json"), JSON.encode!(current))
    File.write!(Path.join(fuzz_dir, "stale.json"), JSON.encode!(stale))
    {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
    assert read(path)["fuzz"] == [JSON.decode!(JSON.encode!(current))]
  end

  test "old malformed files cannot break a new report", %{tmp_dir: dir} do
    fuzz_dir = Path.join([dir, "property-fuzz", "old-run"])
    File.mkdir_p!(fuzz_dir)
    File.write!(Path.join(fuzz_dir, "broken.json"), "not json")
    assert finish(dir, [test_record("pass", nil, ["ACT-001"], [])])["outcome"] == "passed"
  end

  test "a malformed current artifact produces a finished failed report", %{tmp_dir: dir} do
    path = Path.join(dir, "report.json")
    {:ok, state} = Report.init(path: path)
    fuzz_dir = Path.join([dir, "property-fuzz", state.metadata.run_id])
    File.mkdir_p!(fuzz_dir)
    File.write!(Path.join(fuzz_dir, "broken.json"), "not json")
    {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
    assert read(path)["status"] == "finished"
    assert read(path)["outcome"] == "failed"
    assert [%{"path" => _, "error" => _}] = read(path)["artifact_errors"]
  end

  test "a passed fuzz test without measurements fails the report", %{tmp_dir: dir} do
    record = test_record("fuzz pass", nil, ["ACT-001"], [])
    record = %{record | tags: record.tags |> Map.delete(:property) |> Map.put(:fuzz, true)}
    report = finish(dir, [record])
    assert report["outcome"] == "failed"
    assert report["validation_errors"] != []
    assert report["contracts_with_passed_evidence"] == ["ACT-001"]
  end

  test "failed or incomplete measurements cannot pass with a passed test", %{tmp_dir: dir} do
    for outcome <- ["failed", "incomplete"] do
      path = Path.join(dir, "report.json")
      {:ok, state} = Report.init(path: path)
      write_measurement(dir, %{measurement(state.metadata.run_id) | outcome: outcome})
      {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
      assert read(path)["outcome"] == "failed"
    end
  end

  test "measurement counts and budgets must be valid", %{tmp_dir: dir} do
    for invalid <- [
          %{generated: -1},
          %{limits: %{max_runs: 0}},
          %{observations: %{"checked" => 8}}
        ] do
      path = Path.join(dir, "report.json")
      {:ok, state} = Report.init(path: path)
      write_measurement(dir, Map.merge(measurement(state.metadata.run_id), invalid))
      {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
      assert read(path)["outcome"] == "failed"
      assert read(path)["artifact_errors"] != []
    end
  end

  test "an artifact without a passed owner cannot provide full-suite evidence", %{tmp_dir: dir} do
    path = Path.join(dir, "report.json")
    {:ok, state} = Report.init(path: path)
    record = test_record("unrelated property", nil, ["ACT-001"], [])
    {:noreply, state} = Report.handle_cast({:test_finished, record}, state)
    write_measurement(dir, measurement(state.metadata.run_id))
    {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
    assert read(path)["outcome"] == "failed"
  end

  test "a full fuzz gate rejects a missing required case", %{tmp_dir: dir} do
    report = finish(dir, [test_record("pass", nil, ["ACT-001"], [])])
    assert report["outcome"] == "passed"

    assert_raise RuntimeError, ~r/missing fuzz cases/, fn ->
      Report.check!(Path.join(dir, "report.json"), ["action_boundaries"])
    end
  end

  test "measurement tags must match the owning passed test", %{tmp_dir: dir} do
    path = Path.join(dir, "report.json")
    {:ok, state} = Report.init(path: path)
    record = test_record("fuzz pass", nil, ["ACT-002"], [])
    record = %{record | tags: %{fuzz: true, fuzz_id: "action_boundaries", contracts: ["ACT-002"]}}
    {:noreply, state} = Report.handle_cast({:test_finished, record}, state)
    write_measurement(dir, measurement(state.metadata.run_id))
    {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
    assert read(path)["outcome"] == "failed"
    assert read(path)["validation_errors"] != []
  end

  defp measurement(run_id) do
    %{
      id: "action_boundaries",
      run_id: run_id,
      variant: "fuzz",
      seed: 0,
      generated: 7,
      examples: 0,
      replayed: 0,
      shrink_attempts: 0,
      confirmations: 0,
      elapsed_ms: 1,
      outcome: "passed",
      contracts: ["ACT-001"],
      declared_forced_cases: [],
      observations: %{"checked" => 7},
      test_timeout: 900_000,
      limits: %{max_runs: 7, max_run_time: 10_000, max_shrinking_steps: 200}
    }
  end

  defp write_measurement(dir, record) do
    path = Path.join([dir, "property-fuzz", record.run_id, "#{record.id}-#{record.variant}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(record))
  end

  test "short properties cannot fill gaps in fuzz contract evidence", %{tmp_dir: dir} do
    property = test_record("short", nil, ["ACT-001"], ["ACT-001/short"])
    fuzz = test_record("long", nil, ["ACT-002"], ["ACT-002/long"])
    fuzz = %{fuzz | tags: fuzz.tags |> Map.delete(:property) |> Map.put(:fuzz, true)}
    failed = test_record("failed long", {:failed, []}, ["ACT-003"], ["ACT-003/long"])
    failed = %{failed | tags: failed.tags |> Map.delete(:property) |> Map.put(:fuzz, true)}
    report = finish(dir, [property, fuzz, failed])
    assert report["contracts_with_passed_evidence"] == ["ACT-001", "ACT-002"]
    evidence = report["contract_evidence_by_suite"]
    assert evidence["property"]["contracts_with_passed_evidence"] == ["ACT-001"]
    assert evidence["fuzz"]["contracts_with_passed_evidence"] == ["ACT-002"]
    assert evidence["fuzz"]["declared_forced_cases_in_passed_tests"] == ["ACT-002/long"]
    assert "ACT-001" in evidence["fuzz"]["contracts_without_passed_evidence"]
    assert "ACT-003" in evidence["fuzz"]["contracts_without_passed_evidence"]
  end

  defp test_record(name, state, contracts, cases) do
    %ExUnit.Test{
      module: __MODULE__,
      name: name,
      state: state,
      tags: %{property: true, contracts: contracts, contract_cases: cases}
    }
  end

  defp finish(dir, tests, options \\ []) do
    path = Path.join(dir, "report.json")
    {:ok, state} = Report.init([path: path] ++ options)

    state =
      Enum.reduce(tests, state, fn test, state ->
        {:noreply, state} = Report.handle_cast({:test_finished, test}, state)
        state
      end)

    {:noreply, _} = Report.handle_cast({:suite_finished, %{}}, state)
    read(path)
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()
end
