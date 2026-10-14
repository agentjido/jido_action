# Load verification

Run the opt-in load suite from the package root:

```sh
mix test.load
```

The suite runs 200 one-step workflows. It limits concurrent callers to the
number of online schedulers and checks that each result keeps its own input.
Elapsed time is not a pass condition.

Run repeated fresh VMs with:

```sh
sh test/load/burn_in.sh 10
```

Use `test/bench/run.exs` for manual performance comparisons. Do not treat the
load suite as a throughput benchmark.

The load inputs are fixed. Each burn-in run uses a fresh VM; it does not
generate a new input set.
