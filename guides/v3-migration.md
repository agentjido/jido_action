# Migrate To v3

The `v3-spike` branch contains the phase-one Jido.Flow data change. Native
Runic execution and the full `Jido.Exec` migration are phase-two work.

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

## Verify phase one

For each Flow:

1. Compile the module with warnings as errors.
2. Call `Jido.Flow.validate_executable/1`.
3. Compare direct, Builder, Spark, and Codec values where those routes apply.
4. Round-trip stored records through real JSON bytes.
5. Check that source data is outside the canonical Flow.
6. Record old `Jido.Exec` fixtures for the phase-two migration.

See [Flows](flows.md), [Runtime Builder](flow-builder.md), and [Stored Flow
JSON](flow-storage.md) for the current data contract.
