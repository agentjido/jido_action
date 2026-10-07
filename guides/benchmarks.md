# Execution Benchmarks

The repository has one small manual benchmark for the current Exec API:

```bash
MIX_ENV=prod mix run test/bench/run.exs --samples 100 --warmup 20
```

It checks every result and measures:

- one Action through `Jido.Exec.run/4`;
- one Flow through `Jido.Exec.compile/2`; and
- one serial Flow through `Jido.Exec.run/4`.

The output reports median and 95th percentile wall-clock time in microseconds.
No timing value is a test pass condition.

Use the same host, Elixir and OTP versions, scheduler count, dependency lock,
and command when you compare revisions. Run fresh VMs and alternate the
revision order. Keep the output with the exact commits.

## DSL Compilation Probe

The separate DSL probe measures cold, changed-file, and no-change compilation:

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix run --no-compile \
  test/bench/dsl_compile_probe.exs test/bench/results/dsl-compile
```

This probe measures compiler behavior. It does not measure Runic execution.
