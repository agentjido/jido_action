# Migrate To v3

Version 3.0.0-rc.1 is a release candidate. Test this migration with your own
Actions and stored data before production use. This guide lists only changes
that are present in the v3 package and changelog.

## Update The Runtime

Jido Action v3 requires Elixir `~> 1.20`. Update the dependency and get the
locked packages:

```elixir
{:jido_action, "~> 3.0.0-rc.1"}
```

```text
mix deps.get
```

## Use The Flow Module DSL

Use `use Jido.Flow` for developer-authored Flows. Give each node a stable
string name. Use `input`, `context`, and named `result` references to declare
data dependencies.

The DSL is declarative. It does not run arbitrary Elixir expressions.
Assignments, pattern matching, pipes, and application function calls are
invalid inside Flow expressions. Put computation in an Action.

The DSL declaration `output` becomes the canonical `return` field. The DSL
form `iterate` becomes a `Jido.Flow.Iterator` node. These are naming boundaries,
not compatibility aliases.

Do not restore an earlier Flow syntax or source parser. Convert source modules
to the current DSL.

## Move Runtime Flow Data To Maps

Use `Jido.Flow.Builder` only when runtime data defines graph structure. For
portable storage, use a versioned map or JSON object and a host-owned
`Jido.Flow.Registry`:

```elixir
{:ok, stored} = Jido.Flow.to_stored_map(flow, registry)
{:ok, restored} = Jido.Flow.from_stored_map(stored, registry)
```

Stored data contains stable Action, schema, and data atom identifiers. Add one
`{:atom, atom}` Registry entry for each atom literal, atom map key, and atom
reference path segment. Stored data does not contain Elixir source, module
names, schema terms, or atom names. Verify the semantic round trip:

```elixir
Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

## Use Jido Exec

Use `Jido.Exec.run/4` for full execution. Use `start/4`, `ready/1`, `step/1`,
`step/2`, `wave/1`, `continue/1`, and `result/1` for step-wise execution.

Flow execution accepts only `async` and `max_concurrency`. Each execution is a
caller-owned, in-memory value. Always retain the newest value. A stale value
can run an Action side effect again.

Jido Exec does not provide durable orchestration. Keep persistence, queues,
scheduling, recovery, retries, cancellation, deadlines, distributed
coordination, supervision, and deployment-safe continuation in an outer
system.

## Update Instructions And Removed APIs

`Jido.Instruction` now contains one Action module, parameters, and context. Move
execution policy out of the Instruction.

The v3 package does not provide `Jido.Action.Exec.*`, `Jido.Action.Catalog`,
`Jido.Action.Tool`, `Jido.Plan`, or `Jido.Tools.*`. It also does not provide the
old installer and Action generator Mix tasks. Move those concerns to the
package or application that owns them.

## Verify The Migration

For each migrated Flow:

1. Compile the Flow module with warnings as errors.
2. Check `Jido.Flow.validate_executable/1`.
3. Compare full and step-wise results.
4. Round-trip every stored Map or JSON fixture.
5. Check telemetry consumers against the nine v3 lifecycle events.
6. Test Action side effects for repeat safety.

See [Flows](flows.md), [Stored Flow JSON](flow-storage.md), and [Executing
Flows](flow-execution.livemd) for the current contracts.
