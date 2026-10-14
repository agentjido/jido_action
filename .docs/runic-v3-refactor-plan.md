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
   Jido implementation commit: `02c30779`. The six local commits were published
   to `release/v3` on 13 October 2026; Jido Action #292–#296 are closed as completed.
   Final validation against a Runic Hex release remains pending.

6. Assess Dispatch child invocation in a separate change.
   Start with ordinary Action targets. Verify Runic Call's supported target
   set and selected-output semantics before changing Flow targets. Call has no
   whole-child success barrier. Record the remaining Jido completion and effect
   responsibilities before removing Finish or gate code.

   Initial ordinary Action assessment completed on 13 October 2026 against
   local Runic `e50f5e6`, with Jido Action at `02c30779`. That assessment changed
   only this plan; production code and local Runic stayed unchanged.
   A temporary prototype uses the existing Action adapter as a ChildInvocation
   target, a one-input request Step inside Call, and the existing Finish
   projection connected explicitly to Call's public `out` port.

   The ordinary Action adapter is accepted without a new adapter module.
   Its input/output validation, structured failures, rejection of a second
   continuation, runtime context, target-phase telemetry, and ordered effects
   still work. Equal requests in separate execution scopes have separate child
   occurrences. Definition reconstruction and accepted full-value event replay
   work. A manual checkpoint after Action acceptance resumes the return path
   without running that Action again. Native cancellation stops a child Action
   that traps exits.

   | Boundary | Assessment result |
   | --- | --- |
   | Child request input | Supply the complete native child value. Immediate execution must encode the child frame itself with the existing local-value adapter. A locally encoded outer request does not protect raw PIDs or references inside ChildInvocation. |
   | Selected output | Consume `{call_name, :out}` through public connections. The current Finish connection callback uses direct `add_step` wiring; its whole-component `to:` form can attach to the request node instead of the selected return producer. |
   | Completion | The Call Runnable accepts the request before child output exists. A request result must not become the Dispatch result. Call's public port has `:many` cardinality; the current ordinary Action emits one accepted result. |
   | Frame and effects | Keep Jido projection. The existing target mode carries the parent frame and decision effects; Finish places the target result and ordered effects under the Dispatch component name. Call does not perform that conversion. |
   | Direct expander result | Call requires ChildInvocation and rejects an ordinary final value. Preserve the expander's `{:ok, result}` path outside Call. A policy fallback has different semantics and is not an equivalent final-result path. |
   | Flow targets | The current compiled Jido Flow is rejected because it lacks a declared native input port. Adding that port alone is insufficient: its Input/Output and other coordination nodes are outside Call's stateless SingleOutput target set. Retain the existing Flow target path and its completion gate. |

   Initial assessment decision: ordinary Action calls are compatible, but Call is not a complete
   replacement for Dispatch. Keep Finish's frame/effect projection and the
   current completion Condition during the first implementation. Keep Jido
   target resolution and source/error tagging, and preserve the direct final
   result and Flow target branches. No production deletion was established by
   that prototype: the current Action target already uses SingleOutput, while
   Call adds native occurrence, entry, and return nodes. A proposed integration
   must show which current wiring or lifecycle code it removes before adoption.
   Check memory cost with the parent frame still present in the return path.

   Validation: the 13 existing Dispatch, reconstruction, and durability tests
   passed. All 12 temporary contract probes passed with strict test compilation
   on Elixir 1.20.4 / OTP 29.1. The probes are
   `/private/tmp/jido-dispatch-call-assessment_test.exs`; the final log is
   `/private/tmp/jido-dispatch-call-assessment-green.log`. They assess the native
   boundary, not a completed Jido compiler migration. A production change still
   needs committed public-boundary regressions and the package checks below.

   Ordinary Action migration implemented locally on 14 October 2026. Dispatch
   builds a ChildInvocation for each continued Action and attaches a native
   Call. The reusable Call uses an identity request Step; target parameters
   live in the request Fact. A regression with two different inputs verifies
   that the second occurrence does not reuse the first target's parameters.
   The existing Finish consumes Call's public `out` port and updates the Flow
   frame and effects. The finished Condition ignores pending child requests.
   Flow targets and direct expander results keep their existing paths.

   The change removes the duplicate target metadata map, Instruction binding,
   and Action construction. All three Dispatch Action phases use the existing
   constructor, with the same authored IDs and names. The direct Action
   attachment is replaced by Runic's child occurrence attachment and return
   wiring. Finish, the completion Condition, and Dispatch's current Invokable
   remain. A five-line local-value clause keeps ChildInvocation visible to
   Call and encodes its child input. Only two production files change, with no
   new module: 40 lines added and 40 removed. This is no net line reduction.

   A sample retains 100 or 1,000 integers in the parent input while Dispatch
   selects Add with one value parameter. It compares `02c30779` with this
   change on the same local Runic and checks the same final result. The previous
   Dispatch source is loaded only inside the isolated measurement process.

   | Retained integers | Facts before -> after | Encoded Fact value bytes before -> after |
   | --- | --- | --- |
   | 100 | 7 -> 13 | 1,361 -> 8,724 |
   | 1,000 | 7 -> 13 | 26,189 -> 58,380 |

   Call adds six stored Facts in this sample. Request construction data and
   additional frame values increase encoded storage; growth stays linear.
   These totals encode shared values again for each Fact. They exclude Fact
   metadata, event logs, and total or peak process memory. Keep this cost
   visible when deciding whether to retain the migration.

   Validation: 22 focused Dispatch, reconstruction, and durability tests passed.
   The default suite passed 803 tests, with 120 excluded and 93.11 percent
   coverage. Quality and strict test compilation passed. The 163 Exec tests
   passed on OTP 27, 28, and 29 with Elixir 1.18.5, 1.18.4, and 1.20.4.
   Authoring (59), property (49), system (1), and load (1) checks passed. Fuzz
   retains the same three recorded baseline failures (7/10 passed).
   Regressions cover current parameters across repeated inputs, local values,
   validation/error locations, ordered and discarded effects, direct results,
   Action and Flow recovery, accepted Action progress, and cancellation.
   Committed locally on `release/v3`. Local Runic remains unchanged at `e50f5e6`.

## Checks for each implementation change

Use existing failing tests or add one contract regression before changing code.
Run focused tests, the default suite with coverage, applicable quality checks,
and the required authoring, property, system, load, and fuzz suites. Keep known
baseline failures visible. Keep commits scoped to one repository.

Avoid forwarding functions that add only a second name. Prefer one constructor
or operation with a clear owner. New public APIs need a concrete consumer use.
