# Issue 287: Measurements

The final design uses supervised workers, monitors, and explicit termination.
It removes worker lifetime guards, the telemetry tracker, delivery process,
delivery guard, and execution ETS tables. The controller and scheduler hold
active workers and open spans in maps. The revision helper remains to prevent
execution revision reuse. See `287-execution-ownership.md`.

## Repeated Action measurements

Machine: Apple M1 Max, Elixir 1.20.4, OTP 29.1, 10 schedulers, `MIX_ENV=prod`.
The same portable Action script ran in three fresh VMs. Each case used 200
warmups, 1,000 untraced timed calls, and seven separate resource samples.
Values are medians of the three run medians. Earlier baseline samples were
retained from this machine; they were not interleaved with the final runs.
No other test or build VM ran during these samples.

Before issue 287: execution code from `af16008`, also present in `d6d29ac`.
Before this cut: `4d8f9f7`, with the same runtime as measured `c761a79`.
Final: the implementation in this commit.

| Small Action | Time before issue / before cut / final (µs) | Process + ETS memory before issue / before cut / final (bytes) | Starts before issue / before cut / final |
| --- | ---: | ---: | ---: |
| direct | 7.375 / 1.250 / 1.208 | 11,520 / 2,696 / 2,696 | 2 / 0 / 0 |
| timed | 27.875 / 23.958 / 10.125 | 23,024 / 20,856 / 9,864 | 7 / 4 / 1 |
| async | 38.042 / 33.500 / 17.375 | 26,120 / 24,672 / 17,840 | 8 / 5 / 2 |

Compared with the code before this cut, small timed calls take 57.7% less time
and use 52.7% less sampled memory. Async calls take 48.1% less time and use
27.7% less sampled memory. Direct execution is effectively unchanged. Compared
with the code before issue 287, timed and async calls take 63.7% and 54.3%
less time. All Action resource samples have zero owned ETS memory and zero
remaining owned processes.

Async memory varies: the three run medians are 14,824, 17,840, and 17,840 bytes.
The table uses their median. Memory includes the caller, observed framework
processes, and their ETS tables at explicit observation points. It is sampled
active-call memory, not total allocation, exact peak, retained memory, or VM
RSS. Existing supervisors and shared binary storage are excluded. Process
counts are total starts. Local samples are not performance guarantees.

## Flow and collection measurements

The existing ownership script uses 10 warmups, 50 untraced timing samples,
and three separate resource samples per case in the development environment.
Final values are medians from three fresh VMs. The retained baseline is one
run. These measurements include process memory only, excluding ETS. Do not
mix their absolute values with the production Action table.

| Case | Time before issue / final (µs) | Starts before / final | Observed live peak before / final | Process memory before / final (bytes) |
| --- | ---: | ---: | ---: | ---: |
| sync | 8.21 / 2.12 | 2 / 0 | 2 / 0 | 8,512 / 2,696 |
| timed | 37.04 / 12.00 | 7 / 1 | 7 / 1 | 27,104 / 9,864 |
| async | 42.00 / 20.21 | 8 / 2 | 8 / 2 | 30,200 / 15,968 |
| serial | 257.46 / 183.46 | 7 / 1 | 3 / 1 | 55,008 / 55,008 |
| map/256/c1 | 24,173.58 / 22,333.25 | 513 / 1 | 3 / 1 | 2,926,432 / 4,261,384 |
| map/256/c8 | 30,222.25 / 32,614.88 | 770 / 257 | 26 / 9 | 11,604,240 / 14,930,936 |
| reduce/256/c1 | 4,006.08 / 2,253.33 | 513 / 1 | 3 / 1 | 293,256 / 287,440 |
| reduce/256/c8 | 4,018.92 / 2,227.46 | 513 / 1 | 3 / 1 | 293,256 / 287,440 |

`serial` runs three Actions. Collections contain 256 items; `c1` and `c8`
select concurrency 1 and 8. Reduce stays serial. Serial Flow takes 28.7% less
time, and serial Reduce takes 43.8% less time. Concurrent Map still takes
7.9% more time and uses 28.7% more sampled process memory than before issue
287, despite starting 257 processes instead of 770. Serial Map takes 7.6%
less time but uses 45.6% more sampled process memory. Repeated final samples
retain these Map memory increases. The probe does not establish whether this
is higher allocation, retained data, or a different point in the GC cycle.
This change does not establish a general Flow memory improvement.

## Source size and V2 comparison

Production code has 13,717 lines in 77 files. Before this cut it had 13,981
lines; the cut removes 264 production lines and one module. Test, fixture,
and benchmark code falls from 30,543 to 30,100 lines, a reduction of 443.
Counts use cloc 2.06 for Elixir source and exclude blanks, comments, and
recognized documentation.

The initial issue 287 implementation had 13,991 production lines. After
issue 286 there were 13,744. Thus final issue 287 removes 27 net production
lines, and issues 286 and 287 together remove three from the `af16008` baseline.
V2 has 7,172 production lines and 11,705 test/support lines. V3 still has
91.3% more production code than V2 and includes a much larger Flow feature set.

The V2 baseline is `00907be`. Small Actions without a field schema take
1.125 µs direct, 5.375 µs timed, and 12.667 µs async. Final V3 takes 1.208,
10.125, and 17.375 µs. With a stored integer Zoi schema, V2 direct takes
2.625 µs and final V3 takes 2.375 µs. V3 improves supported expression behavior
and Flow features. This cut makes managed execution much cheaper, but V2
still wins on small managed-call time. Do not claim that V3 is always faster
or smaller.

## Accepted behavior

Supervisor startup and telemetry delivery are synchronous, as requested.
Blocked startup or cleanup handlers can delay timeout or cancellation
responses. A living controller still stops active work, including callbacks
that trap exits. Async owner death still cancels work through a living
controller. Workers can survive abrupt controller or scheduler death.
No lifetime guard, delivery helper, or ownership table restores that rejected
guarantee. The execution deadline does not reset; queued control messages
cannot extend it.

## Reproduction and checks

The collection probe is in this repository:

```sh
mix run test/bench/ownership.exs /tmp/jido-action-ownership.json
```

The comparison artifact retains `action_compare.exs`, `measure.exs`,
`v2-style-run1.json` through `v2-style-run3.json`,
`v2-style-collections1.json` through `v2-style-collections3.json`, and
`v2-style-summary.json`. Earlier raw baselines remain unchanged. Run with:

```sh
MIX_ENV=prod mix run /path/to/action_compare.exs v3 /tmp/action-comparison.json
```

Every benchmark result and resource sample passed its checks. All observed
owned processes stopped. The default suite passes on OTP 27, 28, and 29:
1,111 passed and 104 excluded. Coverage on OTP 29 is 95.59%. All 61 authoring
checks and 32 system checks pass. `mix quality` passes: format, compilation,
Doctor, docs, Credo, and Dialyzer. Production compilation also passes with
warnings as errors. The CHANGELOG is unchanged.
