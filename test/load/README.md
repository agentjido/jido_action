# Load verification

Run `mix test.load` from `jido_action`. This opt-in suite checks bounded wide
Flow and Map work, input order, exact work counts, concurrency limits, and
owned Task cleanup. It also runs 60 mixed synchronous and asynchronous calls.
It does not use elapsed time as a pass condition.

The default workload seed is `20260914`. To replay another seed, run
`JIDO_ACTION_LOAD_SEED=20260915 mix test.load`. A failure reports its seed,
workload, or call index. Run `sh test/load/burn_in.sh 10` for ten fresh BEAM
runs with consecutive seeds. Each `mix` invocation starts a new VM. Stop on
the first failure; do not use a successful later run to dismiss it.

Use `test/bench` for performance comparisons. Do not treat this suite as a
throughput benchmark.
