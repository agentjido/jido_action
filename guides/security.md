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
error details, component metadata, or telemetry.

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

## Apply Runtime Limits

Use a finite complete-call `timeout` when the caller needs a hard in-memory
limit. Use `max_concurrency` to bound one concurrent Flow execution. Also
validate collection sizes in application input. Runtime Map does not use the
Codec collection limit.

Each Iterate has a bound from 1 through 10,000. Select a smaller application
limit when body work is expensive.

This package does not provide automatic retry, per-node timeout, public
cancellation, durable checkpoints, or exactly-once effects.

## Design Effects For Repetition

A caller, process restart, or higher-level runtime can repeat work. Use
idempotency keys, conditional writes, deduplication, or transactions when an
effect must not occur twice.

Step-wise stale-revision checks stop one old Execution value from dispatching
again. They do not create a durable exactly-once guarantee.

## Protect Errors And Telemetry

Errors can contain module names, node names, details, and in-memory
stacktraces. Telemetry contains execution, Flow, node, target, item, and
iteration identifiers.

Redact errors before external logging. Do not place credentials, tokens,
personal data, or full context maps in error messages or telemetry metadata.
Treat telemetry handlers as a data-access boundary.
