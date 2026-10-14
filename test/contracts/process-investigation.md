# Covenant process investigation — 2026-10-14

The user first stopped the coverage work after BEAM process load increased.
Later controlled runs found code retention and a VM module-table limit.
Bounded worker lifetimes now let the Inline runtime gate pass. The final run
left zero owned job processes. The records below retain the earlier failures.

## Cause

I ran too many validation batches at once. The overlapping commands selected
four Inline macro workers, four Expression macro workers, two Inline runtime
workers and two Expression runtime workers. Each command also starts a manager
VM. Package checks added more VMs. The machine has ten logical CPUs.

The worker commands did not set a scheduler limit. Covenant limits the worker
count only within one invocation; it has no shared limit across invocations.
`jobs_for/3` caps by mutant count and only warns when jobs exceed scheduler
count. `spawn_worker/5` forwards no scheduler cap to the worker VM.

These workers were still doing work. The saved logs show zero watchdog stops
and zero watchdog restarts. The runtime Inline run had judged 157 of 350
mutants when stopped. Each mutant runs 111 selected tests; a complete run can
execute 38,850 test cases before any reruns. Its logged rate was about five
mutants per minute per worker. The macro run completed all 353 mutants while
the process audit was in progress.

The watchdog limits the gap between completed tests. Each test completion
resets it. It does not limit total batch duration or total CPU use. The parent
watcher stops a worker when the Mix manager closes its stdin. A chat turn
interruption left the tool commands and their Mix managers alive, so that
watcher did not stop the jobs.

## Actions taken

- Saved the scoped process records and logs under
  `/private/tmp/jido-covenant-runaway-audit-20261014/`.
- Sent TERM to the remaining runtime manager, its two workers and their two
  helper processes. No KILL was needed. The macro manager and last worker had
  already finished before signals were sent.
- Confirmed no task mutation BEAMs and no BEAMs in the worktree or its private
  copies remain. Other applications and other tasks were left alone.
- Removed only the two stopped workers' private project copies. Their build
  links were not followed. Repository sources and build trees were preserved.

## Coverage state

| Check | State |
| --- | --- |
| Expression runtime | Complete: 752 sites, 679 killed, 18 reviewed survivors, 55 invalid, no timeout |
| Expression macro | Complete: 753 sites, 525 killed, 18 reviewed survivors, 210 invalid, no timeout |
| Inline macro | Complete: 353 sites, 189 killed, 22 reviewed survivors, 142 invalid, no timeout |
| Inline runtime | Complete after the lifetime fix: 350 sites, 301 killed, 22 reviewed survivors, 27 invalid, no timeout |

The three complete mutation gates pass with full test credit. Invalid caller
compilation gets no kill credit. Do not add runtime and macro totals together.
Full package Covenant coverage remains incomplete.

## Controls for a later run

Run one validation batch at a time. Start with `--jobs 1` and
`ERL_FLAGS='+S 2:2'`. Keep package suites separate from mutation batches, and
run supported runtime suites in sequence because they share fixture paths.
Use an external total job deadline and explicit process cleanup on cancellation.
The current Covenant `--timeout` flag is a per-test timeout, not a batch deadline.

These controls were proposals at the first investigation. The later fork
changes add a total batch deadline and managed cancellation. The local
supervisor also uses a shared batch lock.

## One-worker restart result

A later user-approved batch used one worker and capped schedulers under an
external 45-minute deadline. It failed after 154 of 350 sites and 17 minutes
37 seconds with a BEAM literal allocator error. It left no job processes.

The cleanup probe confirms that the Inline tests' purge/delete sequence retains
old code. Deleted modules are omitted from both loaded and available module
lists, so a later scan misses them. A final purge is required. The runtime runner
also skips generated-module cleanup when there are no recompile files. The old
code retention is a likely cause of this single-worker failure; the dump was
removed with the private copy, so full allocator statistics are unavailable.

The controlled restart exposed a memory problem in addition to the earlier
concurrent-batch load. Further batches remained stopped at that point.

## Check after the Covenant fixes

The user authorized the three Covenant review fixes and one new bounded Inline
runtime batch. The fork commit is `6b2055f`; its full suite passed 481 tests and
100 obligations. Runtime and macro cleanup now track deleted in-memory modules
and purge their old code. Job cancellation and atomic checkpoints are covered
by regression tests. A shared protocol body keeps all module identities.

The consumer worktree compiled with this local fork. One manager (PID 51357)
and one worker (PID 51381) ran the 350-site runtime batch. Both used two normal
schedulers and one scheduler in each dirty class. A native task guard and an
external process-tree supervisor each set a 2,700-second deadline. The external
guard included VM startup. No concurrent batch was started.

The job exited with status 1 after 1,775.126 seconds. It saved 171 verdicts:
153 killed, 12 reviewed survivors and 6 invalid, with no mutation timeout.
The raw checkpoint is explicitly incomplete. No full matrix or acceptance
claim is available. Final verification did not run.

The worker passed the old 154-site literal allocator failure point. Sampled
RSS was about 185 MiB at 26 sites, 286 MiB at 117 sites and 350 MiB at 168 sites.
The old run was about 621 MiB at 49 sites. The latest dump has no literal
allocator failure; its failure is `no more index entries in module_code
(max=65536)`.

The dump reports:

- Module table: 65,536 entries, with a 65,536-entry limit.
- Loaded modules: 1,136; loaded code: 19,793,500 bytes.
- Total VM memory: 324,786,828 bytes; atom count: 157,334.
- Atom names include 39,908 `elixir_compiler_*` names and 20,980 generated
  Inline Action names. These atom counts do not measure loaded modules.

The tests repeatedly create unique owner modules. Generated Action identities
also change with those owners. Removing their code does not clear all VM module
bookkeeping. A later run needs a bounded number of mutations per worker VM,
followed by a fresh VM. Keep only one worker active at a time. Raising the
deadline or repeating an unbounded worker does not address the module limit.

The supervisor reported no remaining job processes and removed the private
worker copy. The checkpoint and dump remain available:

- `tmp/covenant/mutate/jido_action.inline/run-olp54qZi/raw-1-1.json`
- `tmp/covenant-pilot/inline-runtime-bounded.log`
- `tmp/covenant-pilot/inline-runtime-bounded-status.json`
- `tmp/covenant-pilot/inline-runtime-bounded-inputs.json`
- `tmp/covenant-pilot/inline-runtime-erl_crash.dump`

No second Inline batch was started. The user-approved rerun is complete as a
failed, bounded check. The remaining VM-capacity issue is recorded in fork PR #1.

## Bounded worker lifetime result

The user authorized a worker lifetime limit, regression tests, publication to
fork PR #1, and one new Inline runtime batch. Covenant commit `60740b6`
limits each worker VM to 50 verdicts by default. All verdict types count.
Each group must pass the original suite. Only then can the old VM exit and
the same worker slot start a fresh VM. Replacement does not reset the total
deadline. A failed final suite or ordinary checkpoint cannot cause retirement.

The fork passed 487 tests and 101 obligations. All 11 focused lifetime and
job control tests also passed on OTP 27 / Elixir 1.18. Regression tests cover
serial VM exit, private-copy removal, one- and two-verdict limits, two-worker
slices, failed final verification, deadline and SIGTERM after replacement,
and macro caller recompilation with invalid mutations.

The single Inline runtime batch used manager PID 3906 and these worker PIDs
in sequence: 3933, 6028, 7930, 10870, 12686, 14998, and 19180. Only one
worker was active at a time. Manager and workers used two normal schedulers
and one scheduler in each dirty class. Native and external job deadlines
were 4,500 seconds. The external guard included VM startup. The shared batch
lock prevented another validation batch from starting.

The batch exited with status zero after 2,253.09 seconds (37 minutes
33 seconds). All 350 sites completed: 301 killed, 22 reviewed survivors,
27 invalid, and no timeout. The complete matrix has no problems. All seven
groups passed the original 111-test suite. Six workers retired and the final
worker completed. The largest sampled worker RSS was 232,832 KiB (227.4 MiB).
There was no allocator error, module-table error, or watchdog restart.

The survivor reviews still apply: 15 equivalent, four unpromised, and three
dead-code cases. The invalid mutations consist of 12 struct field errors,
12 unbound pattern variables, and three invalid function capture or arity
changes. They receive no kill credit. No further test or product gap was found.

The supervisor reported zero remaining job processes. Worker private copies
were removed. The raw directory `run-2z6qx8iP` was removed only after the
complete matrix was written. Input hashes for source, tests, obligations, and
survivors were unchanged. No Jido implementation or tests changed in this
turn. Jido changes and validation results remain local.

The subsequent local consumer contract check passed 467 tests and properties
and 42/42 obligations. The static check also passed 42/42. Both supervisors
reported zero remaining job processes. Full package coverage remains incomplete.

Evidence:

- `tmp/covenant/mutate/jido_action.inline/runtime_kill_matrix.json`
- `tmp/covenant-pilot/inline-runtime-retirement.log`
- `tmp/covenant-pilot/inline-runtime-retirement-status.json`
- `tmp/covenant-pilot/inline-runtime-retirement-inputs.json`
- `tmp/covenant-pilot/inline-runtime-retirement-resources.jsonl`
- `tmp/covenant-pilot/inline-closed-contract-status.json`
- `tmp/covenant-pilot/inline-closed-static-status.json`

## Revalidation after the main update — 2026-10-14

All ten declared mutation profiles completed with one worker slot, two normal
schedulers, one scheduler in each dirty class and a 50-verdict VM limit. Each
whole job had native and external 4,500-second deadlines. The shared local lock
prevented concurrent jobs. Each worker group passed its original suite before
retirement. No job was restarted to hide a failed final verification.

Inline runtime used eight VMs in sequence and completed 357 sites in 2,338.886
seconds. Its annotation review changed no verdict or test credit. Inline macro
used eight VMs and passed 360 sites in 2,554.405 seconds. Every mutation profile
has zero timeouts. Each process supervisor reports zero remaining owned PIDs.
The progress monitor has also stopped. Resource samples and status records are
under tmp/covenant-pilot/rebase-mutate-*. Input records and the full summary are
saved in that directory. See rebase-mutation-summary.json and the progress report
for exact profile results and the test gaps found after main's refactor.

The Covenant library remains at the existing 60740b6 commit. No library changes
or PR updates were made for this consumer update. Package checks also run in
sequence under the external deadline and the same scheduler limit.

Final package checks passed: 917 default cases on each of OTP 27, 28 and 29;
500 contract cases and 42 obligations; static and quality; and 95.11 percent
line coverage. Every final status file records exit zero and no remaining PIDs.
The separate progress monitor exited zero too. This confirms bounded completion
of the checks on the saved snapshot. Main's later test changes are recorded in
the update manifest and have not been validated as part of this snapshot.
