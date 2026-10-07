# Jido Exec Rebuild Plan — Runic-Owned Execution

## Status

This plan is ready for implementation. Build it in design-gate order. Stop at
each gate until its focused tests pass.

The rejected Exec implementation is safe in the Git stash named
`backup rejected Exec V2 implementation before Runic restart`.

The branch is reset to the prepared Exec rebuild base. The package does not
compile at this point because the old Exec source was removed on purpose. Only
this plan is changed.

## Core decision

Runic is the execution engine for Jido Actions and Flows.

One Action execution is a one-step Flow:

```text
Jido.Action
    |
    v
Jido.Instruction
    |
    v
executable Runic component
    |
    v
Runic Runnable
```

A multi-step `%Jido.Flow{}` compiles to a larger Runic Workflow. It uses the
same executable Action components.

Jido does not build a second scheduler, readiness engine, task system,
checkpoint format, or recovery system. Runic owns these runtime functions.

Build against the pinned Runic `0.1.0-alpha.11` dependency. Do not patch or
fork Runic for this work.

## Vocabulary and ownership

### Jido.Action

An Action is one validated unit of work. It owns its input schema, output
schema, and `run/2` callback.

### Jido.Instruction

An Instruction is the call template for one Action. It contains the Action
target, bound parameters, context, and metadata.

An Instruction is durable definition data. It is not a Runic Runnable.

### Jido.Flow

A Flow is a declarative control program. Its leaves are Instruction templates,
its values are computed by Expr, and its executable behavior comes from
Actions.

`Jido.Flow` owns authoring only:

- Spark DSL authoring
- map-based authoring
- validation
- JSON definition encoding and decoding
- source locations
- the canonical `%Jido.Flow{}` definition

`Jido.Flow` does not own runtime scheduling or durable execution state.

### Runic.Workflow

A Runic Workflow is the executable graph made from a Flow.

Runic owns:

- graph readiness
- Runnable creation
- scheduling
- concurrency
- retries
- timeouts
- backoff
- fallback
- execution events
- checkpoints
- persistence
- recovery
- resume

### Runic Runnable

A Runnable is one runtime activation. It includes the input Fact, activation
identity, and attempt state. Runic creates and manages it.

Authors do not create Runnables when they define Actions, Instructions, or
Flows.

### Jido.Exec

`Jido.Exec` is a thin public facade and a Jido-to-Runic adapter.

It normalizes an executable target, compiles it to Runic, starts or calls the
Runic runtime, and projects the Runic result into the Jido result contract.

## Architecture invariants

1. Every executable Action leaf is a real executable Runic component.
2. Runic is the only owner of runtime scheduling and runtime policy.
3. Jido does not keep parallel runtime results, effects, cursors, or
   checkpoints.
4. A custom Runic component is allowed. A custom Jido scheduler is not
   allowed.
5. Immediate and durable execution use the same compiled Runic components.
6. Stored Flow definitions and stored execution state are separate data.
7. Durable state cannot contain PIDs, references, Tasks, closures, monitors,
   or process dictionary values.
8. The system does not claim exactly-once external effects.
9. Jido uses the public Runic protocols and extension points as they exist in
   `0.1.0-alpha.11`.
10. Jido does not implement `Runic.Transmutable` for `Atom`.

## Prior art from jido_runic

The older `jido_runic` package proves the useful base design:

- a Jido Action can execute as a real Runic component
- the component can expose Action input and output schemas
- Runic can create a Runnable for that component
- two Action components can connect as a normal Runic pipeline

Reuse these behaviors and focused test cases. Do not add `jido_runic` as a
dependency and do not copy its Agent strategy, Signal adapter, directives, or
child-worker runtime.

The old package also shows three designs that this rebuild must avoid:

- its ActionNode calls `Jido.Exec.run/4`, which would recurse after Exec starts
  Runic
- its `Runic.Transmutable` implementation for `Atom` changes protocol behavior
  for every atom
- its ActionNode reads Runic graph internals for Map and Reduce behavior

Use Runic native collection components and public protocols instead.

## The Action component bridge

Add one small internal component:

```elixir
%Jido.Exec.ActionNode{
  id: node_id,
  name: node_name,
  instruction: %Jido.Instruction{},
  inputs: input_ports,
  outputs: output_ports
}
```

`Jido.Exec.ActionNode` implements:

- `Runic.Component`
- `Runic.Workflow.Invokable`
- `Runic.Transmutable`

Do not compile an Action to a Runic Step that contains an anonymous closure.
The component must keep portable data and named modules.

Implement `Runic.Transmutable` for `Jido.Instruction`. An Action Instruction
converts to `Jido.Exec.ActionNode`. `to_workflow/1` wraps that node in a
one-step Workflow. A Flow Instruction delegates to `Jido.Exec.Compiler` for
`to_workflow/1`; it is not a single Action component.

Do not implement `Runic.Component` or `Runic.Workflow.Invokable` directly on
Instruction. The ActionNode gives the graph a stable node identity and
explicit ports without adding graph fields to the Instruction contract.

Do not implement `Runic.Transmutable` for Action module atoms. Exec first
normalizes an Action module to an Instruction, then transmutes the Instruction.

### Prepare phase

Runic selects a ready ActionNode and creates a Runnable. The Runnable contains
the input Fact and Runic activation data.

Jido does not perform a separate readiness check.

### Execute phase

The ActionNode:

1. merges the Instruction data with the input Fact
2. validates the Action input
3. calls `Action.run/2`
4. validates the Action output
5. returns Runic completion or failure data

The node does not schedule another node. It does not save a checkpoint.
It does not call `Jido.Exec.run/4`.

### Apply phase

Runic applies the Runnable result to the Workflow. Runic emits Facts, updates
graph state, records events, and makes new nodes ready.

Jido does not repeat this work.

## One normalization path

All public executable targets use one path:

```text
Action module
    |
Instruction
    |
Flow module
    |
%Jido.Flow{}
    v
canonical %Jido.Flow{}
    v
Jido.Exec.Compiler
    v
executable Runic.Workflow
    v
Runic runtime
    v
Jido result projection
```

An Action module becomes an Instruction. The Instruction becomes a one-step
Flow through `Runic.Transmutable`. This makes standalone Action execution and
Flow execution use the same runtime rules.

## Public API

Expose runtime compilation from Exec:

```elixir
Jido.Exec.compile(target, opts \\ [])
Jido.Exec.compile!(target, opts \\ [])
```

These functions return an executable `Runic.Workflow`. They accept the source
map option used for compiler diagnostics.

Keep the Jido V2 name for immediate execution:

```elixir
Jido.Exec.run(target, params \\ %{}, context \\ %{}, opts \\ [])
```

`target` can be:

- an Action module
- a `%Jido.Instruction{}`
- a Flow module
- a `%Jido.Flow{}`

`run/4` normalizes the target, compiles it, runs it with the in-memory Runic
runtime, and waits for a terminal result.

Add a managed entry point only after the in-memory path works:

```elixir
Jido.Exec.start(runner, execution_id, target, params, context, opts)
```

This operation delegates to `Runic.Runner`. It does not create a Jido worker.

Use Runic operations directly for resume, stop, checkpoint, and result
inspection unless Jido must translate a value or error.

## Results, errors, and effects

Use one data model between Actions and Runic.

Start with `Jido.Action.Output` as the value in a Runic Fact. It can contain:

- the Action value
- deferred effects
- Action metadata

Before this contract is final, compare it with Runic named output ports. Use
named ports if they remove wrappers and preserve deterministic joins.

An Action error must fail the Runic Runnable. Do not emit a successful Fact
that contains an error tuple.

Effects stay as data. The host decides when to dispatch them. Their identity
must be derived from stable Runic execution, activation, and output identity
so that retries do not create unstable effect identities.

## Action continuations

Do not add `{:continue, %Jido.Instruction{}}` to the first rebuild.

Runic owns the next executable node. A result-level continuation would add a
second control-flow system.

Model dynamic behavior with explicit Runic components:

- Choice uses Condition or Rule
- Iterate uses StateMachine or a custom Runic component
- Dispatch uses dynamic composition or a custom Runic component
- a nested Flow uses Workflow composition

If Action-level continuation is still required after these cases work, add it
as an explicit Runic graph mutation contract. Do not let Exec follow it in a
private loop.

## Flow compilation

Place runtime lowering under `Jido.Exec.Compiler`.

`Jido.Flow` produces a validated declarative definition. The compiler
converts that definition to executable Runic components and edges.

The compiler must produce stable component IDs from stable Flow node IDs.
Source maps are compiler diagnostics. They are not runtime control state.

### Existing Flow boundary cleanup

The reset branch still has references to removed `Jido.Exec.Flow` runtime
modules. Remove these references during the first build slice.

- Move runtime `compile/2` and `compile!/2` entry points from `Jido.Flow` to
  `Jido.Exec`.
- Move executable target validation from `Jido.Flow.validate_executable/1` to
  `Jido.Exec.Compiler`.
- Keep `Jido.Flow.DSL.ModuleCompiler` responsible for Spark lowering,
  structural validation, `%Jido.Flow{}` creation, and source maps.
- Do not run executable graph compilation from the Spark compiler.
- A generated Flow module can keep `compiled/0` and `run/2` as thin delegates
  to `Jido.Exec.compile!/2` and `Jido.Exec.run/4`.
- Use `Runic.Workflow.t()` in generated runtime type specifications. Do not
  add another compiled-plan struct.

Do not add runtime modules under `Jido.Flow`.

### Initial component mapping

| Flow authoring construct | Runic runtime construct |
| --- | --- |
| Step | `Jido.Exec.ActionNode` |
| Dependency | Runic edge and ports |
| Choice | Condition or Rule |
| Map | Map or FanOut |
| Join | Join or FanIn |
| Nested Flow | Workflow component or Workflow merge |
| Reduce | Select after a semantic comparison |
| Iterate | StateMachine or a small custom component |
| Dispatch | Dynamic composition or a small custom component |

Do not copy the old Flow runtime state machines before this mapping is tested.
Use a custom component only when a native Runic component cannot keep the Flow
semantics.

## Expressions and value flow

Use these data sources in this order:

1. Runic input Fact
2. values carried by edges and named ports
3. immutable run context
4. bound Instruction parameters

`Jido.Expr` evaluates declarative expressions over these values.

Add a small resolver only when the existing Expr API cannot read a required
value. Do not add a second value graph.

## Stored Flow definitions

Flow definitions must round-trip through JSON:

```text
JSON
  -> Jido.Flow.Codec
  -> safe module registry
  -> %Jido.Flow{}
  -> Jido.Exec.Compiler
  -> Runic.Workflow
```

The codec must:

- preserve stable Flow and node IDs
- preserve Instruction parameters, context, and metadata
- preserve Expr data
- use a caller-supplied registry for Action and Flow modules
- never create atoms from untrusted input
- reject unsupported executable values

Do not store a compiled Workflow as the canonical Flow definition. Compile the
stored `%Jido.Flow{}` after hydration.

## Durable execution state

Runic Store and Runic execution events are the source of truth for runtime
progress.

The durable test must use this sequence:

1. hydrate or build the Flow definition
2. compile it to a Runic Workflow
3. start a Runic execution
4. persist Runic execution state
5. stop the worker process
6. restore through Runic
7. continue from the next ready Action

Do not place Jido runtime checkpoints in Instruction parameters. Do not
reserve keys such as `"__jido_flow__"`.

Definition storage and execution storage can use different records:

- Flow definition record: Jido JSON definition
- execution record: Runic events, snapshot, or checkpoint

If the application requires JSON for Runic events or snapshots, implement a
Runic Store adapter or codec through the public Store contract. Do not create
a parallel Jido checkpoint format.

## Runic compatibility boundary

Do not change Runic source code for this rebuild.

Use these public Runic extension points when needed:

- `Runic.Component`
- `Runic.Workflow.Invokable`
- `Runic.Transmutable`
- `Runic.Runner.Store`
- `Runic.Runner.Executor`
- `Runic.Runner.Scheduler`

Do not read or change Runic private graph state from ActionNode. Native Runic
Map, Reduce, FanOut, FanIn, Join, Condition, Rule, and StateMachine components
own their runtime behavior.

If a required Flow semantic cannot use a public Runic API, stop at that design
gate and record the unsupported semantic. Do not add a second Jido runtime as
a workaround.

## Process and policy ownership

Use Runic Runner, Worker, Task supervisor, Scheduler, Executor, and Store.

Map Jido options to Runic policy:

- timeout
- maximum attempts
- backoff
- concurrency
- scheduler policy
- executor
- store
- checkpoint frequency

Do not add `Jido.Exec.Scope`, a private Task supervisor, an async handle, or a
second cancellation model. Use the Runic Runner extension points.

## Initial module budget

Start with three runtime modules and one protocol implementation:

- `Jido.Exec` — public facade and result projection
- `Jido.Exec.Compiler` — target normalization and Flow-to-Runic lowering
- `Jido.Exec.ActionNode` — executable Runic Action component
- `Runic.Transmutable` for `Jido.Instruction` — explicit conversion to an
  ActionNode or Workflow

Add another module only when a design gate needs it.

## Build preparation

The build starts from the current reset branch. The old Exec modules are
absent, so the full package suite is not a valid baseline until Gate 1 restores
the public Exec entry point.

Create these first files:

- `lib/jido_exec.ex`
- `lib/jido_exec/compiler.ex`
- `lib/jido_exec/action_node.ex`
- `lib/jido_exec/transmutable_instruction.ex`
- `test/jido_exec/action_node_test.exs`
- `test/jido_exec/exec_test.exs`

Make narrow boundary edits in these existing files:

- `lib/jido_flow.ex`
- `lib/jido_flow/dsl/module_compiler.ex`

These edits remove references to the deleted `Jido.Exec.Flow` modules. They do
not add execution logic under `Jido.Flow`.

The first focused tests must cover:

- Action module to Instruction normalization
- Instruction to ActionNode conversion
- stable node identity
- Action schema exposure through `Runic.Component`
- Runic prepare, execute, and apply phases
- successful Action output
- Action validation error
- Action exception
- invalid Action return
- one-step `Jido.Exec.run/4`
- `Jido.Exec.compile/2` returns a real `Runic.Workflow`
- normal atom behavior in Runic remains unchanged

Do not copy the old `jido_runic` module. Port only the behavior required by
these tests and update it for the current Instruction, Zoi schema, Action
result, and Runic `0.1.0-alpha.11` contracts.

## Design gates

### Gate 1 — One Action is one-step Flow

Prove:

- Action module normalization
- Instruction normalization
- Instruction-to-ActionNode transmutation
- real Runic preparation
- Action execution through a Runnable
- Runic apply
- Jido success and error projection
- no global Atom protocol implementation
- no call from ActionNode back into `Jido.Exec.run/4`

No direct Action execution path can bypass Runic.

### Gate 2 — Runtime policy belongs to Runic

Prove timeout, retry, backoff, cancellation, and crash behavior with Runic
Runner or the supported three-phase API.

Do not implement Jido policy code for these cases.

### Gate 3 — Data and effects compose

Prove:

- two serial Actions
- one branch
- one Join
- parameter and context resolution
- deferred effect order
- failed Action propagation

Choose the Fact and output-port contract after these tests.

### Gate 4 — Durable resume

Compile a ten-step Flow to executable Runic components.

Run five Actions, persist Runic state, terminate the worker, restore through
Runic, and verify that Action 6 is the next Action. Verify that Actions 1
through 5 do not run again.

The test must fail if a Jido cursor or Jido checkpoint is used.

### Gate 5 — Stored Flow definition

Encode the same ten-step Flow as JSON, decode it through a safe registry,
compile it, and run or resume it with the same stable component identity.

## Implementation sequence

1. Make this plan the only Exec rebuild source of truth.
2. Inventory the Action, Instruction, Expr, Flow, and public Runic
   `0.1.0-alpha.11` contracts that remain on the branch. Use the old
   `jido_runic` ActionNode and pipeline tests only as prior art.
3. Remove the stale `Jido.Exec.Flow` runtime references from `Jido.Flow` and
   its DSL module compiler.
4. Implement the one-step Flow normalizer.
5. Implement `Jido.Exec.ActionNode` and its Runic protocols.
6. Implement `Runic.Transmutable` for `Jido.Instruction`. Do not implement it
   for `Atom`.
7. Implement `Jido.Exec.compile/2`, `compile!/2`, and `run/4`.
8. Complete Gate 1.
9. Map execution options to Runic and complete Gate 2.
10. Compile the minimum serial Flow to real ActionNodes and edges.
11. Complete Gate 3 and settle the Fact and output-port contract.
12. Connect Runic Runner and Store, then complete Gate 4.
13. Implement or refine `Jido.Flow.Codec`, then complete Gate 5.
14. Add Choice and Map with native Runic components.
15. Add Reduce, Iterate, nested Flow, and Dispatch one at a time. Use focused
    semantic tests before each mapping is accepted.
16. Migrate the remaining package tests and documentation.
17. Run format, strict compile, package tests, property tests, system tests,
    static analysis, documentation checks, and supported version checks.

Make one checkpoint commit after each accepted gate.

## Acceptance tests

### One Action

- An Action module runs as a one-node Runic Workflow.
- A bound Instruction runs through the same path.
- An Action Instruction transmutes to an ActionNode.
- A Flow Instruction transmutes to a compiled Workflow.
- A normal atom keeps Runic's existing behavior.
- Input and output schemas are enforced.
- Action exceptions and invalid returns fail the Runnable.

### Flow execution

- A serial Flow uses real Runic edges.
- Choice and Join use Runic readiness.
- Map uses Runic collection or fan-out behavior.
- Exec does not select ready nodes.

### Durability

- A ten-step Flow stops after Action 5 and resumes at Action 6.
- Recovery uses Runic Store data.
- Stable activation and attempt identity survive recovery.
- A retry does not change the logical effect identity.
- No Jido runtime checkpoint exists.

### Collections and state

- Map progress recovers through Runic state.
- Reduce semantics match the Flow definition.
- Iterate state recovers through Runic StateMachine or the accepted custom
  component.

### Dynamic behavior

- Nested Flow composition uses Runic Workflow composition.
- Dispatch uses the accepted Runic dynamic composition contract.
- No Action result creates a private Exec continuation loop.

### Storage and security

- Flow JSON round-trips through a safe registry.
- Unknown modules are rejected.
- JSON decoding does not create atoms.
- Runtime persistence uses the Runic Store contract.

## Explicit exclusions

Do not implement:

- a Jido Flow runner
- a Jido scheduler
- a Jido readiness engine
- Jido cursor maps
- Jido runtime checkpoint Instructions
- reserved checkpoint parameter keys
- a Jido retry loop
- a Jido timeout Task tree
- a Jido database, queue, lease, or recovery service
- exactly-once external effects
- old Exec compatibility wrappers
- non-executable Runic placeholder nodes
- a Runic fork or source patch
- a global `Runic.Transmutable` implementation for `Atom`
- calls from ActionNode to `Jido.Exec.run/4`
- reads of private Runic graph state from ActionNode

## Completion criteria

The rebuild is complete when:

1. one Action runs as a one-step Runic Workflow
2. a `%Jido.Flow{}` compiles to executable Runic components
3. `Jido.Exec` stays a thin facade and adapter
4. Runic owns all scheduling, policy, checkpoints, persistence, and resume
5. a ten-step durable Flow resumes at Action 6 after process loss
6. a JSON-stored Flow hydrates and compiles with stable node identity
7. no Jido module repeats a Runic runtime responsibility
8. the build uses the unmodified Runic `0.1.0-alpha.11` dependency
9. all package quality checks pass
