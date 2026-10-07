# Load verification

Run the opt-in load suite from the package root:

```sh
mix test.load
```

The suite starts 200 concurrent one-step workflows and verifies that each
result keeps its own input. It checks correctness under concurrent caller
load. Elapsed time is not a pass condition.

Run repeated fresh VMs with:

```sh
sh test/load/burn_in.sh 10
```

Use `test/bench/run.exs` for manual performance comparisons. Do not treat the
load suite as a throughput benchmark.
