# Security

Jido validates data and owns execution processes. The host application still
owns authorization, effects, secrets, and resource policy.

## Keep Source And Stored Data Separate

The module DSL is trusted compile-time Elixir source. Do not evaluate user or
generated Elixir source to create a Flow.

Use `Jido.Flow.Codec` for database, API, UI, or AI-authored Flow data. The
Codec accepts decoded map data and a host-owned trusted Registry.

Stored data cannot create atoms or derive module names. It can select only the
Actions, Flows, schemas, and atoms that the Registry contains.

## Validate Before Effects

Use Action schemas to reject malformed input before `run/2`. A schema is not
authorization. Check tenant access, object ownership, and current permissions
at the application boundary or inside the Action before an effect.

Make file, network, database, and process effects clear in Action names,
schemas, and tests. Give an Action only the capabilities that it needs.

Treat context as sensitive caller data. Do not copy secrets into Flow results,
error details, component metadata, or persisted execution events.

## Apply Storage Limits

The Codec decoder rejects:

- invalid UTF-8;
- depth greater than 100;
- one collection wider than 10,000 entries; and
- more than 100,000 data nodes in one document.

These checks occur after the caller decodes JSON. Apply HTTP byte limits,
parser limits, and request timeouts before Codec.

Registry size is limited to 10,000 entries. Registry lookup is inert. It does
not load or execute an Action.

## Bound Expressions

An expression is a `Jido.Expr` operation in a Flow field, such as
`input(:a) + 1` or `input(:tags) == ["x"]`. Flow evaluates each expression
with these limits:

| Limit | Default |
| --- | --- |
| Nesting depth | 64 levels |
| Visited values, including data the expression reads | 10,000 |
| Binary bytes visited or produced | 1,048,576 |
| Integer size | 4,096 bits |

An expression that exceeds a limit fails the Flow with a
`Jido.Flow.Error.ExecutionFailureError`. Its `details.reason` names the limit,
such as `:max_nodes`. Limits apply to each evaluation. Data that an operation
reads counts toward them, so comparing a large input list can exceed a limit.
A plain reference such as `input(:list)` is not an expression and has no
limit.

## Trust Dispatch Targets

A Dispatch expander returns `{:continue, input, target}`, and Exec runs that
target. Select the target only from values your code trusts. When a name comes
from input, an AI model, or storage, look it up in an application-owned
registry of allowed Actions and Flows. Do not convert external text to a
module atom.

## Apply Runtime Limits

Use a finite `timeout` to bound each attempt of each Action call and internal
Flow node. There is no whole-call timeout, so the total time can grow with the
number of nodes and attempts. Keep `max_attempts` and `max_concurrency` small.
Also validate collection sizes in application input. Runtime Map does not use
the Codec collection limit.

Each Iterate has a bound from 1 through 10,000. Select a smaller application
limit when body work is expensive.

Use `Runic.Runner.stop/3` to stop managed work. Cancellation cannot undo
completed side effects. Runic owns retry, per-node timeout, checkpoints, and
recovery. This package does not provide exactly-once effects.

## Design Effects For Repetition

A caller, process restart, or higher-level runtime can repeat work. Use
idempotency keys, conditional writes, deduplication, or transactions when an
effect must not occur twice.

Stable Runnable and effect identities support host deduplication. They do not
create a durable exactly-once guarantee.

## Protect Errors And Events

Errors can contain module names, node names, details, and in-memory
stacktraces. Runic events contain execution, node, activation, item, and
iteration identifiers.

Redact errors before external logging. Do not place credentials, tokens,
personal data, or full context maps in error messages or persisted event
metadata. Treat Store and event adapters as data-access boundaries.
