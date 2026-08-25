# Migrate To v3

The `v3-spike` branch contains the canonical Jido.Flow data model and native
Runic execution.

## Canonical Flow changes

Update direct and Builder authoring to these names:

- `components`, not `nodes`
- `output`, not `return`
- `Jido.Flow.Step`, not `Jido.Flow.Node`
- `Jido.Flow.Iterate`, not `Jido.Flow.Iterator`
- `params`, not `input`
- `after`, not `deps`
- `meta`, not `provenance`

Every Flow now needs an explicit output expression. Result dependencies stay
derived and do not get copied into `after`.

The public Spark DSL shape does not change. Its `step`, `choice`, `map`,
`reduce`, `iterate`, `state`, `output`, `while`, and `repeat` forms remain.

## Subflow changes

A Spark or Builder `step` derives `Jido.Flow.Subflow` when the target has exact
executable kind `:flow`. Choice options, Choice fallback, Map, Reduce, and
Iterate require an Action. Replace a Flow target in these fields with an
Action, or redesign the Flow before migration.

## Builder changes

Use `Builder.output/2`. Use canonical `after`, `meta`, `completion`, and
`max_iterations` data. The Builder does not keep `deps`, `provenance`,
`return`, `while`, `until`, or `repeat` aliases.

## Stored data changes

Use the Codec and a trusted Registry:

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
{:ok, restored} = Jido.Flow.Codec.decode(document, registry)

restored == flow
```

Add distinct Registry entries for Actions and Flows. Every stored component
has an explicit `kind`. Stored maps use canonical `components`, `output`,
`params`, `after`, and `meta` names.

This is the initial stored format. No migration reader is required. Do not add
old record inference to the Codec.

## Execution changes

`Jido.Flow.compile/2` returns `%Jido.Flow.Compiled{}` with the native Runic
workflow, component index, source map, output expression, and compilation
digest. A Spark Flow module also provides `compiled/0`.

The step-wise API exposes native `%Runic.Workflow.Runnable{}` values. It can
show authored work and Runic support work. `Jido.Exec.ready/1` returns these
values. `step/2` accepts a ready Runnable or its integer ID. `step/1` and
`wave/1` return executed Runnable values.

Remove code that expects `Jido.Exec.NodeResult`. Remove code that expects
`Jido.Flow.Compiler.MapResult`. A Map produces native many-valued work and an
ordered list when one scalar expression value is required.

## Verify v3

For each Flow:

1. Compile the module with warnings as errors.
2. Call `Jido.Flow.validate_executable/1`.
3. Call `Jido.Flow.compile/2` and inspect the native Runic workflow.
4. Compare direct, Builder, Spark, and Codec values where those routes apply.
5. Round-trip stored records through real JSON bytes.
6. Check that source data is outside the canonical Flow.
7. Check run-to-completion and step-wise execution for the same final value.

See [Flows](flows.md), [Runtime Builder](flow-builder.md), and [Stored Flow
JSON](flow-storage.md) for the current data contract.
