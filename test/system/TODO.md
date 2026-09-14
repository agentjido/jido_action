# In-memory Exec system test backlog

Run `mix test.system` from `jido_action`. This file is about local, in-memory
`Jido.Exec` behavior. It excludes storage, Signals, Agents, Topology, and
durable recovery. Keep correctness checks separate from benchmark timing.

## Current coverage

- [x] A composed Flow runs two concurrent Steps, then Map, with exact Action
  counts and input-order results.
- [x] A controlled Action uses ready/release and injected-failure messages.
  The test confirms the Step failure stops Map admission.
- [x] Cancellation and complete-call timeout stop held workers. Owner death
  stops the async handle. Task.Supervisor shutdown returns a structured error.
- [x] Tests monitor held workers, check the owned Task.Supervisor is empty, and
  require no new ready messages after the terminal barrier.
- [x] Flow, node, target, and Map-item telemetry have balanced start and
  terminal counts for the tested paths, one execution ID, and no duplicate
  terminal span signatures.

## Open work

- [x] Compose Subflow, Choice, Map, Reduce, and Iterate in one local scenario.
  Check exact leaf work, nested node paths, and deterministic final order.
- [x] Hold a parent and child Flow at different barriers. Cancel or time out
  between them. Confirm no child or later parent work starts.
- [x] Race cancellation with a released last worker and with `Exec.await/2`.
  Confirm one terminal result and no duplicate telemetry terminal event.
- [x] Race the complete-call timeout with a returned Action error. Preserve
  the winning public error and close each started span once.
- [x] Kill one admitted worker while a sibling is held and pending work exists.
  Confirm fail-fast admission, exact failure list order, and worker cleanup.
- [x] Stop the owner and Task.Supervisor at each composed-Flow phase: initial
  Step wave, Map fan-out, Map fan-in, and final output. Check exact work and
  no fallback to the global Task.Supervisor.
- [x] Check mailbox cleanup after await timeout, cancellation, owner death,
  and supervisor loss. Use monitor and protocol barriers, not sleep timers.
- [x] Check Flow and Action telemetry metadata values and error types at each
  nested boundary, not only span balance and execution ID.
- [x] Check peak live workers against `max_concurrency` across nested Flow and
  collection work with a controlled shared ledger.

## Expected rejections

Step-wise use of a Flow with terminal Dispatch and use of that Flow as a
Subflow are expected rejections. Unowned async await/cancel calls and invalid
Task.Supervisor references are also expected errors, not runtime defects.
Add tests through the public boundary if a composed scenario needs them.

## Confirmed failures

No `test/system` runtime failure is confirmed. The separate authoring
`AUTHOR-MAP-01` fail-fast regression now passes; do not label it as a new
system finding.
