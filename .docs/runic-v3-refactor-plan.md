# Runic V3 refactor preparation

Prepared on 13 October 2026 for `release/v3`.

## Baseline

- Jido Action base: `d7358a32`.
- Local dependency: `{:runic, path: "../runic", override: true}`.
- Runic branch: `integration/jido-action-pr45-pr46-20261013`.
- Runic support commit: `5e5ffe8c0c4956ea5e161c7ec0443c48a5244592`.
  It includes upstream main, PRs #45 and #46, and the admission-sort callback.
- Default Jido tests: 756 passed, 120 excluded; seed 36, max cases 4.
- Coverage: 93.07 percent. Quality checks passed.
- Authoring: 59 passed. Property: 49 passed. System and load: one passed each.
- Runic: 2,002 passed, 13 skipped.
- Three fuzz failures also occur in the unchanged Jido release snapshot:
  expression-tree literal roots, Iterate body error phase, and graph rejection
  fixtures. Keep their baseline separate from migration regressions.

Checks used Elixir 1.20.4 and OTP 29. Other supported runtime versions still
need release validation. No published Hex version is assumed to contain the
local admission-sort callback. Verify that support before replacing the path.

## Refactor objective

Reduce the Runic lifecycle and graph details that Jido must implement.
Keep Action validation, return conversion, errors, local-value wrapping,
source locations, telemetry, Flow value resolution, and ordered effects in Jido.
For each change, identify the old code removed and the contracts verified.

## Work order

1. Finish execution observation adoption (#294).
   Use Runic input and execution identities in managed observation and result
   selection. Reduce the duplicate snapshot and observation result paths.
   Preserve restored-workflow behavior before replacing snapshot event scanning.
   Verify active work, stopped admission, uncertain exits, repeated inputs,
   failure order, and persistence status.

   Implemented locally: `start/6` admits a Runic execution scope, and
   `result(runner, execution_id)` reads its observation. Snapshot and observed
   results share projection and error normalization. Runic does not restore
   process-local observations, so resumed work retains snapshot event scanning
   after active and ready work checks. Remove that scan only when Runic supplies
   restored observations.
   Managed admission uses the same sort callback as immediate execution. The
   local Runic Worker now applies that callback to resolved candidates at the
   lowest ready or active causal depth. This Worker support also needs to reach
   the Runic Hex release before replacing the local path dependency.

   Runic Worker support commit: `84db769`. Saved failures use the same selector
   as live observations. Rejected initial input closes the new Worker through
   Runic cancellation. Validation: 767 default tests passed, 93.07 percent
   coverage, and quality checks passed. The three recorded fuzz failures remain.
   Custom ordering is now proposed upstream in [Runic PR #47](https://github.com/zblanco/runic/pull/47).

2. Adopt native task ownership (#292).
   Replace the custom TaskExecutor where the native executor meets the current
   contract. Review the immediate caller watcher separately. Verify caller and
   Worker death, trapping exits, crash containment, cancellation, task release,
   supervisor selection, group leader, and failed persistent stop.

   Implemented locally for managed execution: use Runic's default Task
   executor and remove `Jido.Exec.Runner.TaskExecutor`. Runic owns task scopes,
   task release, and confirmed shutdown. Custom executor options still pass
   through to Runic. Immediate execution keeps its existing caller watcher as
   a private function in `Jido.Exec`; its supervisor and caller-exit contracts
   remain covered by the immediate task tests.
   Validation: 774 default tests passed with 93.05 percent coverage. Format,
   strict compilation, quality, authoring, property, system, and load checks
   passed. Fuzz retains the three recorded baseline failures. Ownership tests
   cover timed and untimed work that traps exits, Worker and caller death,
   stop and cancel, task release, supervisor and group leader, and failed
   persistent stop. Jido implementation commit: `c89fafac`.

3. Adopt SingleOutput (#293).
   Convert the Action node first. Remove repeated context, hook, child Fact,
   activation, and collection event construction. Keep Jido result conversion
   explicit. Verify local values and portable managed values, schemas, retry
   classification, telemetry, effects, and replay. Convert other ordinary nodes
   only where their readiness contract fits.

   Implemented locally for the Action node: use `Runic.Workflow.SingleOutput`
   and return its explicit value or failure result. Runic now owns preparation,
   hooks, child Facts, activation consumption, and collection tracking. Jido
   retains validation, error conversion, local-value encoding, telemetry, and
   effect metadata. The Fact helper separates value encoding from construction;
   telemetry reads the native callback context. This removes 59 production lines.
   Validation: 52 focused tests and 779 default tests passed, with 93.12 percent
   coverage. Quality, strict test compilation, authoring, property, system, and
   load checks passed. Fuzz retains the three recorded baseline failures.
   The Action-only #293 change passed a design review. The review reran 139
   Exec tests and six temporary contract probes; all passed. Native before-hook
   error nesting remains a separate Runic error-format decision.
   Jido implementation commit: `92fe548b`.

4. Adopt public ports (#295).
   Replace compiler endpoint lookup and manual multi-parent Join construction.
   Verify all-input semantics, nested boundaries, declared outputs, missing
   ports, build-log replay, and effect order.

   Implemented locally in the compiler: named connections select public ports
   for multiple parents, with `input_mode: :all` and explicit input positions.
   Single-parent connections use Runic's public whole-output connection, which
   resolves nested exports without an extra binding node. The compiler no
   longer inspects child output endpoints or constructs multi-parent Joins.
   The existing Dispatch completion gate remains. Direct native grouped Action
   composition remains supported and has a parent-order/rebuild test.
   This removes 14 production lines and adds no module or Runic change.
   Tests cover ordinary and nested parents, `needs`, an explicit non-terminal
   child output, effect order under serial and concurrent execution, missing
   ports, build-log replay, and managed execution. Validation: 783 default tests
   passed with 93.05 percent coverage. Quality, strict test compilation,
   authoring, property, system, and load checks passed. Fuzz retains the three
   recorded baseline failures. The design review reran 143 Exec tests and seven
   temporary contract probes; all passed, with no findings.
   Jido implementation commit: `7ed376f0`.

5. Adopt Batch (#296).
   Replace manual FanOut/FanIn wiring, the empty-item token, and first-item
   frame retention. Preserve public item IDs, input order, fail-fast admission,
   collected errors, effects, and supported recovery. Measure stored Facts and
   worker copies separately.

   Implemented and reviewed for Map on `release/v3`.
   Runic Batch owns FanOut/FanIn wiring, empty completion,
   item occurrences, and ordered outcomes. A native Runic Step converts the
   Batch result to a Jido frame and exports the Map output through its public
   port. The Map no longer implements Invokable, retains a first-item frame,
   sorts completed items, or creates an empty-item token. This removes 43
   production lines and adds no production module or Runic source change.
   Jido retains reference resolution, public item IDs, Action error conversion,
   collected-error results, and ordered effects. Small local-value encoding
   clauses preserve immediate local values across the native Batch boundary.
   Task-loss failure selection reads retained Runic input Facts, so item order
   is the same for live results and restored snapshots. The projection's return
   spec also includes nested Flow frames.

   Tests cover empty, single, many, and duplicate items; separate nested and
   repeated batches; local values and following Actions; reverse completion;
   stable failure selection and stopped admission; retries; cancellation; and
   build-log replay. The existing checkpoint/resume test confirms that accepted
   Map items are not repeated. Full-value events and native snapshots are the
   supported recovery boundary. Unfinished or uncertain work can repeat its
   external effects. Runic lazy/hybrid replay, remote progress, and portable
   journals remain outside the native Batch recovery contract.

   Size samples compare `7ed376f0` with this change on the same local Runic.
   They use EchoParams over integer items, immediate local values, and a
   prepared callback for item index 1. Stored bytes are the sum of the encoded
   Fact values; callback bytes are the encoded Runnable size. Copy bytes are
   the memory of a fresh process that holds the Runnable after garbage
   collection. This measures one copied callback, not peak Runner memory.
   Each byte column shows before -> after.

   | Items | Facts | Stored value bytes | Callback bytes | Process copy bytes |
   | --- | --- | --- | --- | --- |
   | 100 | 205 | 37,052 -> 95,456 | 5,668 -> 7,501 | 8,744 -> 13,632 |
   | 1,000 | 2,005 | 408,218 -> 979,014 | 5,668 -> 11,639 | 8,744 -> 34,328 |

   Stored Fact values stay linear in collection size. Native outcome records
   add stored data. Runic prepares shared parent data in each callback context,
   so copied callback size now grows with the parent. This is a measured cost
   of the native contract, not a memory reduction.

   Memory follow-up: the unnecessary callback parent copy is in Runic's
   SingleOutput preparation. Jido's Action callback does not read that parent.
   Runic now supports `use Runic.Workflow.SingleOutput, batch_parent: false`;
   Jido's Action member uses that option. Item coordinates remain available,
   and the source Fact and completed Batch result keep the parent. The default
   and ordinary Steps retain their parent view. Regression tests show that a
   10,000-item parent does not increase the opted-out prepared callback size.
   The patch is submitted separately in
   [the fork memory PR](https://github.com/mikehostetler/runic/pull/1) as `c0a3998` and
   retained in the combined local integration as `e50f5e6`. The memory patch
   was removed from PR #45 with a forward revert; PR #45 retains its Batch
   scope. The memory PR is based on `mikehostetler/runic:codex/runic-issue-35`,
   the source branch of PR #45. GitHub confirms one commit and exactly seven
   changed files. Upstream PR #48 is closed and links the replacement; GitHub
   does not permit an existing PR to change its base repository.

   | Items | Callback bytes after fix | Process copy bytes after fix |
   | --- | --- | --- |
   | 100 | 7,232 | 13,632 |
   | 1,000 | 7,232 | 13,632 |

   Encoded stored value bytes are unchanged by this callback fix. At 1,000
   items, Runic outcome envelopes add 423,232 encoded bytes over their values.
   Jido LocalValue wrappers add 206,412 encoded bytes across the stored Fact
   values. These are encoding costs, not total heap memory, and the columns
   count a shared value again when another Fact encodes it. The first supports
   outcome identity and status; the second preserves local values and local
   execution across native item Facts. Neither is removed by the parent fix.
   The fresh native workflow occupies 3,872,752 shared heap bytes in this sample;
   a process copy is a separate measurement. This is not a comparison with the
   previous Map's total heap use.

   Patch validation: the memory-fix branch passed 1,904 tests with 13 skipped.
   The restored PR #45 branch passed 1,901 tests with 13 skipped.
   The combined local Runic passed 2,015 with 13 skipped. Format and compile
   checks passed; the combined source also passed strict test compilation.
   Final Jido validation: 794 default tests passed, 120 excluded, with 93.11 percent
   coverage. Quality, strict test compilation, authoring (59), property (49),
   system (1), and load (1) checks passed. Fuzz retains the three recorded
   baseline failures. The 154 Exec tests passed on OTP 27, 28, and 29, using
   Elixir 1.18.5, 1.18.4, and 1.20.4 respectively. The nine temporary design
   review probes passed after the failure-selection and nested-frame spec fixes.
   Regression coverage checks serial and concurrent item failure selection,
   stopped admission, persisted snapshots, resume, and stable public item IDs.
   Publication and final validation against a Runic Hex release remain pending.
6. Assess Dispatch child invocation in a separate change.
   Start with ordinary Action targets. Verify Runic Call's supported target
   set and selected-output semantics before changing Flow targets. Call has no
   whole-child success barrier. Record the remaining Jido completion and effect
   responsibilities before removing Finish or gate code.

## Checks for each implementation change

Use existing failing tests or add one contract regression before changing code.
Run focused tests, the default suite with coverage, applicable quality checks,
and the required authoring, property, system, load, and fuzz suites. Keep known
baseline failures visible. Keep commits scoped to one repository.

Avoid forwarding functions that add only a second name. Prefer one constructor
or operation with a clear owner. New public APIs need a concrete consumer use.
