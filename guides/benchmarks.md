# Execution Benchmarks

This page is for contributors who change `jido_action` itself. Application
code does not need it.

The repository has two manual probes. Run them from a checkout of the
`jido_action` repository, not from an application that depends on it. Neither
probe is a test; no timing value is a pass condition.

## Execution Benchmark

```bash
MIX_ENV=prod mix run test/bench/run.exs --samples 100 --warmup 20
```

It checks each result and reports median and 95th percentile wall-clock time
for one Action run, one Flow compilation, and one serial Flow run.

## DSL Compilation Probe

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix run --no-compile \
  test/bench/dsl_compile_probe.exs test/bench/results/dsl-compile
```

It measures cold, changed-file, and no-change compilation of Flow DSL
modules. It does not measure execution.

See the
[benchmark README](https://github.com/agentjido/jido_action/blob/main/test/bench/README.md)
for how to compare two revisions fairly.
