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

2. Adopt native task ownership (#292).
   Replace the custom TaskExecutor where the native executor meets the current
   contract. Review the immediate caller watcher separately. Verify caller and
   Worker death, trapping exits, crash containment, cancellation, task release,
   supervisor selection, group leader, and failed persistent stop.

3. Adopt SingleOutput (#293).
   Convert the Action node first. Remove repeated context, hook, child Fact,
   activation, and collection event construction. Keep Jido result conversion
   explicit. Verify local values and portable managed values, schemas, retry
   classification, telemetry, effects, and replay. Convert other ordinary nodes
   only where their readiness contract fits.

4. Adopt public ports (#295).
   Replace compiler endpoint lookup and manual multi-parent Join construction.
   Verify all-input semantics, nested boundaries, declared outputs, missing
   ports, build-log replay, and effect order.

5. Adopt Batch (#296).
   Replace manual FanOut/FanIn wiring, the empty-item token, and first-item
   frame retention. Preserve public item IDs, input order, fail-fast admission,
   collected errors, effects, and supported recovery. Measure stored Facts and
   worker copies separately.

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
