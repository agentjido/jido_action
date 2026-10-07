# Manual performance checks

Run the small Exec V2 smoke benchmark from the package root:

```sh
MIX_ENV=prod mix run test/bench/run.exs --samples 100 --warmup 20
```

It checks and measures one Action run, one Flow compilation, and one serial
Flow run. The output reports median and 95th percentile wall-clock time in
microseconds. Timing values are not test pass conditions.

Use the same host, Elixir and OTP versions, scheduler count, dependency lock,
and command for before and after comparisons. Run fresh VMs and alternate the
revision order. Keep raw terminal output with the compared commits.

The separate `dsl_compile_probe.exs` measures cold and incremental DSL
compilation. It is not an execution benchmark.
