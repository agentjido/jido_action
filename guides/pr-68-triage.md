# PR #68 Triage Plan

This document tracks decomposition of draft PR [#68](https://github.com/agentjido/jido_action/pull/68) into focused, reviewable work.

## Snapshot

- Source PR: `#68 refactor(exec): OTP/async hygiene + mailbox cleanup (prelim)`
- PR state: `OPEN`, `DRAFT`, `DIRTY` (as of 2026-02-14)
- Source branch head: `4debf1b64c5ae2246784556f67acc37244f1487c`
- Comparison base for triage: `origin/main`

## Already Landed from the Audit Track

The highest-risk OTP hygiene changes from the audit were already merged via focused PRs:

- `#69` duplicate `elixirc_paths` cleanup
- `#70` plan dependency validation hardening
- `#71` chain async supervision hardening
- `#72` async mailbox/monitor cleanup
- `#73` compensation mailbox/monitor cleanup
- `#74` workflow parallel timeout/failure policy
- `#80` async cancel monitor/result cleanup
- `#81` LuaEval supervision via `Task.Supervisor.async_nolink`
- `#82` runtime timeout/retry config fallback guards

## Follow-up Issues and PRs

- [#84](https://github.com/agentjido/jido_action/issues/84): Normalize error return shapes
  - Implementation PR: [#87](https://github.com/agentjido/jido_action/pull/87)
- [#85](https://github.com/agentjido/jido_action/issues/85): Document async/config behavior contracts
  - Implementation PR: [#88](https://github.com/agentjido/jido_action/pull/88)
- [#86](https://github.com/agentjido/jido_action/issues/86): This triage/decomposition tracking issue

## Remaining Unmerged Themes in PR #68

The draft still contains broad refactors and API behavior changes that were not merged to `main`:

1. Large execution/runtime refactors (`TaskLifecycle`, `TimeoutBudget`, `AsyncRef` struct migration)
2. Workflow/Req/Weather timeout-budget propagation changes
3. Telemetry metadata sanitization behavior changes
4. Broad test-suite rewrites and coverage-only churn
5. Cross-cutting API/return-shape normalization beyond focused merged fixes

## Decomposition Policy

Do not merge PR #68 as a single unit. Continue with narrowly scoped PRs that:

1. isolate one behavior change per PR,
2. include targeted regression tests for that behavior,
3. document compatibility impacts explicitly,
4. avoid unrelated test churn.

## Candidate Future Slices (if still desired)

1. Telemetry metadata sanitization as opt-in behavior.
2. Timeout-budget propagation for workflow/request/weather paths.
3. AsyncRef struct migration with explicit compatibility/deprecation window.

## Disposition

Treat PR #68 as historical context only. Once required slices are extracted into focused PRs/issues, close PR #68.
