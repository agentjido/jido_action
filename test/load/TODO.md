# In-memory Exec load test backlog

Run `mix test.load` from `jido_action`. Use
`JIDO_ACTION_LOAD_SEED=<positive integer> mix test.load` to replay a seed.
Run `sh test/load/burn_in.sh <runs>` for fresh BEAM runs. These are bounded
correctness and resource tests, not throughput benchmarks. Keep routine
benchmarks in `test/bench`; the separate opt-in throughput stress runner is
under `test/load`.

## Current coverage

- [x] A wide 24-Step Flow and a 40-item Map run with four held workers at a
  time. Tests check exact and unique work IDs, input-order results, and a
  measured peak of at most four active Actions.
- [x] Sixty seeded calls mix direct Action, synchronous Flow, and asynchronous
  Flow execution. Every expected Action ID appears once.
- [x] Tests monitor completed workers, wait for async handles to exit, and
  check the owned Task.Supervisor after quiescence.
- [x] The burn-in script starts a fresh BEAM for each seed and stops at the
  first failure. Failures include a seed and workload or call index.

## Open work

- [x] Add a deeper serial Flow that exceeds one scheduler wave. Check final
  value, each node's one-time execution, and bounded retained resources.
- [x] Add a wider diamond graph with many shared prerequisites and readers.
  Check that each producer runs once, independent of map enumeration.
- [x] Grow Map inputs through bounded sizes such as 40, 200, and 1,000. Check
  exact item IDs, output order, and max-concurrency adherence.
- [x] Mix sync, async, step-wise, timeout, cancellation, and faulted calls in
  one seeded sequence. Confirm exact starts, completions, and terminal errors.
- [x] Add bounded concurrent callers with separate execution IDs and one
  shared Task.Supervisor. Check cross-call isolation and global child cleanup.
- [x] After each load phase reaches quiescence, compare owned process count,
  Task.Supervisor children, mailbox length, and telemetry handler count with
  the baseline. Use a bounded, non-timing-based growth limit.
- [x] Add a seeded reduction case for any failure: print the smallest case
  index, input size, execution mode, and seed. Replay it in one fresh BEAM.
- [x] Provide a documented longer fresh-BEAM burn-in matrix for release
  validation across compatible Elixir/OTP versions; do not rely on one VM's
  accumulated state. Run the script on each listed runtime pair before release.

## Expected rejections

Timeout and cancellation errors are expected when the seeded workload asks
for them. Invalid options and stale step-wise revisions must fail before
Action work; they are not evidence of a load defect.

## Confirmed failures

No persistent resource leak is confirmed. An immediate supervisor-child check
after a completed call saw a child that was still exiting. The test now waits
for monitored worker and handle exits before it claims quiescence; three
fresh-BEAM seed runs passed after that barrier. The separate authoring
`AUTHOR-MAP-01` fail-fast regression now passes. The 1,000-item Map test found
that every Runic FanIn result carried the full sibling set. Jido now keeps
FanIn coordination in the caller, removes unused sibling data from results,
and skips graph updates after the first result consumes all sisters. The test
checks the same output and worker bound after this change.
