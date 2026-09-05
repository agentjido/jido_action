defmodule JidoActionBench.Report do
  @moduledoc false

  def limitations do
    [
      "Timing has no tracing or memory sampling. Setup and result checks are outside each timed interval.",
      "Caller reductions exclude helpers. Helper reductions and exact memory peaks are unavailable (null).",
      "Memory peaks are observed maxima at start, callback/pause/result barriers, and completion. Short-lived allocations can be missed.",
      "Resource reports keep every separate run and field medians. Medians of observed peaks are not exact lifetime peaks.",
      "Process heap and process memory include the measured caller and traced descendants. Shared binary bytes deduplicate observed off-heap binary references.",
      "VM memory includes the observer, supervisor, loaded code, and unrelated activity. It does not establish ownership or leaks.",
      "Owned starts follow spawn traces from the caller and dedicated Task.Supervisor. Both roots and the observer are excluded from helper counts.",
      "Cleanup uses trace-delivery barriers and process monitors. Failed probes stop and confirm observed descendants before returning the failure. Global process-count differences are not used.",
      "Flat and copied heap sizes exclude off-heap binary payloads; external bytes include the external term representation. Receiver memory includes its process overhead.",
      "Retained terms come from a separate checked call: the authored Flow, compiled graph, returned result, or actual paused and finished execution. Paused values are copied after the execution is finished.",
      "Prepared reuse uses a benchmark-only internal adapter with empty schemas. It omits public target/input validation and graph compilation. It is not a public compiled-graph API.",
      "Paused-continue timing excludes a fresh Exec.start per sample; its resource run includes start and the paused barrier.",
      "Focused cases run once per profile, outside the size/payload matrix. Ready timing covers 100 reads and retains the last descriptor list; resource runs include setup and completion. Collector timing excludes its 32-producer setup wave.",
      "Comparisons show raw ratios. No speedup claim is valid from these shared-host measurements. Repeat on an idle host with the same environment."
    ]
  end

  def markdown(report) do
    rows =
      Enum.map(report.cases, fn row ->
        resources = row.resources.median

        "| #{row.id} | #{row.timing.wall_ns.median} | #{row.timing.wall_ns.p95} | #{resources.observed_peak.process_memory_bytes} | #{resources.observed_peak.shared_binary_bytes} | #{resources.owned_process_starts} | #{resources.owned_remaining} |"
      end)

    retained_rows =
      for row <- report.cases, {name, term} <- Enum.sort(row.retained_terms) do
        "| #{row.id} | #{name} | #{term.local_heap_bytes} | #{term.copied_flat_heap_bytes} | #{term.external_bytes} |"
      end

    """
    # Execution benchmark

    Commit: `#{report.source.commit}`. Runtime source dirty: `#{report.source.runtime_dirty}`.
    Tool SHA-256: `#{report.source.tool_sha256}`.
    Profile: `#{report.settings.profile}`. Elixir: `#{report.environment.elixir}`. OTP: `#{report.environment.otp}`.
    Warm-up: #{report.settings.warmup}. Timing samples per case: #{report.settings.samples}.
    Resource samples per case: #{report.settings.resource_samples}. Memory and helper columns show field medians.
    See the JSON report for raw samples, reductions, term sizes, memory, and full machine data.

    | Case | Median ns | p95 ns | Process bytes | Binary bytes | Helper starts | Remaining |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{Enum.join(rows, "\n")}

    ## Retained terms

    | Case | Term | Local heap bytes | Copied heap bytes | External bytes |
    | --- | --- | ---: | ---: | ---: |
    #{Enum.join(retained_rows, "\n")}

    ## Measurement limits

    #{Enum.map_join(limitations(), "\n", &("- " <> &1))}
    """
  end

  def compare!(before, after_report) do
    for field <- ["schema_version", "environment", "settings", "method"] do
      if Map.fetch!(before, field) != Map.fetch!(after_report, field) do
        raise ArgumentError, "reports have different #{field} values"
      end
    end

    tool_hash = get_in(before, ["source", "tool_sha256"])

    if not is_binary(tool_hash) or tool_hash != get_in(after_report, ["source", "tool_sha256"]),
      do: raise(ArgumentError, "reports have missing or different tool hashes")

    old = index!(before)
    new = index!(after_report)

    if Enum.sort(Map.keys(old)) != Enum.sort(Map.keys(new)),
      do: raise(ArgumentError, "reports have different case sets")

    rows =
      for id <- Enum.sort(Map.keys(old)) do
        a = old[id]
        b = new[id]
        median_a = a["timing"]["wall_ns"]["median"]
        median_b = b["timing"]["wall_ns"]["median"]

        resources_a = a["resources"]["median"]
        resources_b = b["resources"]["median"]

        process_ratio =
          ratio(
            resources_a["observed_peak"]["process_memory_bytes"],
            resources_b["observed_peak"]["process_memory_bytes"]
          )

        binary_ratio =
          ratio(
            resources_a["observed_peak"]["shared_binary_bytes"],
            resources_b["observed_peak"]["shared_binary_bytes"]
          )

        "| #{id} | #{median_a} | #{median_b} | #{ratio(median_a, median_b)} | #{process_ratio} | #{binary_ratio} | #{resources_a["owned_process_starts"]} → #{resources_b["owned_process_starts"]} | #{resources_b["owned_remaining"]} |"
      end

    """
    # Execution benchmark comparison

    Before: `#{get_in(before, ["source", "commit"])}`.
    After: `#{get_in(after_report, ["source", "commit"])}`.
    Ratio is after / before. No speedup claim is made. Environment, settings, method, and tool hash match.
    Check runtime source state in both JSON files before using these ratios.

    | Case | Before median ns | After median ns | Time ratio | Process bytes ratio | Binary bytes ratio | Helper starts | After remaining |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{Enum.join(rows, "\n")}

    ## Measurement limits

    #{Enum.map_join(limitations(), "\n", &("- " <> &1))}
    """
  end

  defp ratio(0, _after), do: "unavailable"
  defp ratio(before, after_value), do: :erlang.float_to_binary(after_value / before, decimals: 3)

  defp index!(report) do
    rows = Map.fetch!(report, "cases")
    indexed = Map.new(rows, &{Map.fetch!(&1, "id"), &1})
    if map_size(indexed) != length(rows), do: raise(ArgumentError, "duplicate case IDs")
    indexed
  end
end
