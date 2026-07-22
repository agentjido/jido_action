# Runic Capability Baseline for Flow Script

- Status: Research baseline
- Date: 2026-07-20
- Flow Script status: Pre-design
- Runic package: `0.1.0-alpha.8`
- Runic source commit: [`4f1269a4d04c3b83731bf343f2098387e8a7395f`](https://github.com/zblanco/runic/tree/4f1269a4d04c3b83731bf343f2098387e8a7395f)

## 1. Purpose

This document defines the Runic capability baseline for Flow Script.

Flow Script is a planned text form for Runic workflows. This document does not
define the Flow Script grammar. It identifies the Runic features that a language
can expose. It also identifies features that need a clear language-level
decision.

The baseline has three goals:

1. Record what Runic can model.
2. Separate stable behavior from incomplete alpha behavior.
3. Give Flow Script a feature inventory and a design checklist.

This baseline applies only to Runic `0.1.0-alpha.8`. Runic is an alpha package.
Later versions can change these semantics.

## 2. Research Method

The review used the following evidence:

- The package version in this repository.
- The exact upstream source commit for that package version.
- The public modules and protocols.
- The upstream guides and module documentation.
- The upstream tests.
- Small execution probes for unclear or conflicting behavior.

The local Jido Action test baseline was:

- 397 tests and 1 property.
- 398 total passes.
- 0 failures.
- 96.48 percent total coverage.

The exact Runic source baseline was:

- 1,316 tests and 55 doctests.
- 1,371 total passes.
- 0 failures.
- 13 skips.

The test counts show that the package has a large test suite. They do not make
all documented features correct. This review found some documentation and
runtime conflicts.

### 2.1 Confidence Labels

This document uses four labels.

| Label | Meaning |
| --- | --- |
| **Verified** | Source and tests or a direct probe confirm the behavior. |
| **Implemented** | Source contains the behavior, but this review did not prove all cases. |
| **Declared** | An API, option, field, or document exists, but the runtime does not fully use it. |
| **Defective** | The current package does not provide the documented or intended behavior. |

## 3. Baseline Summary

Runic is more than a static workflow graph. It is a forward-chaining execution
engine with facts, persistent graph memory, stateful components, execution
policy, event logs, and a managed runner.

The most useful Flow Script feature groups are:

| Group | Runic capabilities | Baseline status |
| --- | --- | --- |
| Pure work | Steps and nested workflows | Verified |
| Decisions | Conditions, rules, patterns, guards, and Boolean condition reuse | Verified |
| Graph shape | Sequences, branches, joins, merge, add, and remove | Verified |
| Collection work | Map, fan-out, reduce, fan-in, and early halt | Verified |
| State | Accumulators, state machines, and meta queries | Mixed |
| Domain models | FSM, aggregate, saga, and process manager | Mixed |
| Data contracts | Named ports, types, cardinality, required inputs, and boundary results | Implemented with limits |
| Runtime context | Global and component context with defaults | Verified |
| Execution | Planning, eager reaction, three-phase dispatch, and concurrency | Verified |
| Failure policy | Retry, backoff, timeout, fallback, skip, halt, and workflow deadline | Mixed |
| Durable runtime | Runner, stores, checkpoints, recovery, schedulers, and executors | Implemented |
| History | Facts, ancestry, results, event logs, and replay | Verified |
| Extension | Component, invocation, conversion, store, scheduler, and executor protocols | Implemented |
| Inspection | Graph queries, Mermaid, DOT, Cytoscape, and edge lists | Verified |

The best first Flow Script target is the declarative graph and data model. The
managed runtime can be a separate execution configuration. This choice matches
the current `Jido.Flow` direction, where retry, timeout, fallback, persistence,
and durable execution stay outside the flow artifact.

## 4. The Runic Execution Model

### 4.1 Workflow

A `Runic.Workflow` contains:

- A directed multigraph.
- A root node.
- Registered components.
- Input facts and produced facts.
- Activation memory.
- Component names and hashes.
- Run context.
- Scheduling policies.
- Build events and runtime events.
- Execution hooks.
- Optional boundary ports.

The graph has more than data-flow edges. It also has:

- Structural flow edges.
- Component ownership edges.
- Matchable, runnable, and ran memory edges.
- Meta-reference edges.
- State feedback edges.

Runic documentation often describes a workflow as a directed acyclic graph.
That statement is true for many simple workflows. It is not a complete runtime
invariant. Stateful components add feedback flow edges. A Flow Script
implementation must not assume that every lowered graph is acyclic.

### 4.2 Fact

A fact is the unit of data in the engine.

A fact contains:

- `value`: the Elixir term.
- `hash`: the content address.
- `ancestry`: the producer and parent fact.
- `meta`: extra metadata.

An input fact has no ancestry. A produced fact has ancestry in this form:

~~~elixir
{producer_hash, parent_fact_hash}
~~~

Runic uses a 32-bit `:erlang.phash2/2` value for fact and component identity.
This hash is not a cryptographic identifier. Hash collisions are possible.

Flow Script should use explicit, unique source identifiers. It must not use a
Runic hash as the only durable source identity.

### 4.3 Activation

A structural edge becomes active when its source produces a fact. Runic records
this state in graph memory.

The normal life cycle is:

1. A condition sees a matchable activation.
2. The condition accepts or consumes that activation.
3. A work node gets a runnable activation.
4. The work node executes.
5. Runic applies the result and marks the activation as ran.
6. A new fact activates downstream nodes.

A condition and a step have different roles:

- A condition is the match phase.
- A step is the execute phase.

A rule combines these two phases.

### 4.4 Forward Chaining

Runic reacts to available facts. It does not only walk a fixed sequence once.
New facts can enable more reactions. State components can also feed new facts
back into the graph.

`Workflow.react/2` processes one reaction cycle. `react_until_satisfied/2`
continues until the workflow has no more runnable work.

An open or recursive workflow can continue without an end. A language must
define how a caller limits such execution.

## 5. Core Authoring Primitives

### 5.1 Step

Status: **Verified**

A step applies a function to an input fact. It can use:

- A zero-argument function.
- A one-argument function.
- A two-argument function.
- A named external function capture.
- Explicit options such as name and port contracts.

A two-argument step expects a two-item list. A join normally creates that list.
Runic spreads the two list values into the two function arguments.

A step can return any Elixir term. A `nil` return still creates a fact.

Runic catches an exception during invocation. The runnable gets a failed status.
The normal direct workflow path consumes the activation and does not produce a
downstream fact. It does not raise the original exception to the direct caller
when no scheduler policy handles the failure.

Language feature candidates:

- `step` declaration.
- Explicit input binding.
- Explicit output binding.
- Zero-, one-, and multi-input call forms.
- Named action or function reference.
- A defined failure result.

Flow Script should not embed anonymous Elixir functions as its portable form.
It should refer to registered actions or functions by stable name.

#### Captured Values

Runic asks the author to pin a captured variable with `^`. This makes the
capture part of the component source and hash.

The captured value must be serializable. Runic rejects values such as:

- Process identifiers.
- References.
- Ports.
- Anonymous functions.
- Local function captures.

External function captures are supported.

A Flow Script literal and reference model can make captures explicit. This is
safer than hidden lexical capture.

### 5.2 Condition

Status: **Verified**

A condition is a reusable predicate. It receives a fact value.

- `true` passes the same fact to downstream work.
- `false` consumes the activation.
- A function-clause mismatch is false.
- A wrong function arity is false.

A named condition can be a shared graph component. More than one rule can use
the same condition result.

Language feature candidates:

- Named predicate.
- Pattern test.
- Comparison expression.
- Reusable condition reference.
- Explicit pass-through semantics.

### 5.3 Rule

Status: **Verified**

A rule contains a condition and a reaction. Runic supports several Elixir forms:

- An anonymous function with patterns and an optional guard.
- `condition:` and `reaction:` options.
- An `if ... do` expression.
- A `given / where / then` block.

The `given` section supports:

- Literal matches.
- Variable binding.
- Map patterns.
- Struct patterns.
- Tuple patterns.
- List patterns.
- Nested destructuring.

The `where` section supports normal Elixir expressions. It is not limited to
Elixir guard expressions.

The `then` section receives a map of the variables from `given`.

The `given` and `where` sections are optional. The `then` section is required
in the block form.

#### Named Condition Expressions

A rule can refer to a named condition:

~~~elixir
condition(:is_valid) and condition(:has_credit)
~~~

Runic supports:

- `and` and `or`.
- `&&` and `||`.
- Nested expressions.
- A mix of named conditions and inline expressions.

If more than one branch of an OR expression is true, the reaction runs once for
that input activation.

The referenced condition must already be in the workflow. An unresolved
reference raises `Runic.UnresolvedReferenceError` when Runic connects the rule.

Language feature candidates:

- Pattern-based rules.
- A separate filter expression.
- Named predicates.
- Boolean condition trees.
- A reaction block.
- Static reference validation.

#### Rule Limit

Meta queries are not supported in the guard part of the anonymous-function rule
form. They work in supported rule bodies and in the `given / where / then` form.
A Flow Script expression model should have one consistent rule expression
system.

## 6. Graph Construction and Composition

### 6.1 Workflow Creation

Status: **Verified**

`Runic.workflow/1` creates a workflow. It can declare:

- A name.
- Input ports.
- Output ports.

`Runic.transmute/1` converts supported values into components or workflows.

### 6.2 Sequence and Parallel Branches

Status: **Verified**

A flat component list places components at the workflow root. These components
can become ready from the same input.

A tuple form creates a parent with child branches:

~~~elixir
{parent, [child_a, child_b]}
~~~

The child can contain another nested shape.

Language feature candidates:

- Sequence or pipeline.
- Parallel block.
- Nested branch block.
- Explicit dependency references.

The current Runic list and tuple syntax is compact, but it is not clear in a
text language. Flow Script should make sequence and branch intent explicit.

### 6.3 Join

Status: **Verified**

A component can connect to a list of parent components. Runic inserts a join.

The join:

- Waits for one fact from each parent.
- Keeps the declared parent order.
- Produces one ordered list.
- Activates the child once for the complete set.

A two-argument child receives the first and second list items as separate
arguments.

Language feature candidates:

- `join` declaration.
- Named inputs for each join branch.
- Ordering rules.
- A policy for missing or repeated branch values.

Runic joins facts by graph activation and ancestry. Flow Script must define the
join key if it supports more than one concurrent logical run in one workflow.

### 6.4 Merge

Status: **Verified**

Runic can merge workflows. Root-level components from the child workflow become
part of the receiving workflow. Run context, hooks, component maps, inputs, and
build events also merge.

Language feature candidates:

- Workflow import.
- Workflow include.
- Namespaced component reference.
- Parameterized reusable subflow.

Flow Script should define name collision behavior. Runic stores component names
in a map. A duplicate name can replace the earlier lookup entry. Runic does not
give source-language name uniqueness.

### 6.5 Dynamic Add and Remove

Status: **Verified**

Runic can:

- Add a component at the root.
- Add a component after another component.
- Add a component after many parents.
- Remove a component.
- Reconnect upstream and downstream nodes after a removal.
- Preserve shared nodes that other components still use.

This is a runtime graph-editing feature. It is different from a static source
language feature.

Possible Flow Script choices:

- Do not expose graph mutation in version 1.
- Expose compile-time composition only.
- Add a later patch language for live workflow changes.

### 6.6 Nested Workflow as a Component

Status: **Verified**

A workflow can be connected as a component of another workflow. Its root edges
are connected to the parent component.

A source language needs clear boundary rules for:

- Input mapping.
- Output mapping.
- Names.
- Context.
- Policy.
- Internal state.

## 7. Collection Features

### 7.1 Map and Fan-Out

Status: **Verified**

`Runic.map/2` takes an enumerable input and emits one fact for each item.

The map body can be:

- One function.
- A nested component pipeline.
- A parallel component list.
- A structure that contains joins.

The mapped item work can run concurrently when the execution strategy permits
it.

Language feature candidates:

- `map item in collection`.
- A named item binding.
- A nested flow body.
- A concurrency limit at the execution boundary.
- Empty collection semantics.

### 7.2 Reduce and Fan-In

Status: **Verified**

`Runic.reduce/3` folds values into an accumulator.

Without a map, it reduces one enumerable value. With a map, it waits for the
mapped results and folds them in fan-out order.

The reducer can return:

- A raw new accumulator.
- `{:cont, new_accumulator}`.
- `{:halt, new_accumulator}`.

The halt form stops the fold early.

Language feature candidates:

- Initial value.
- Item and accumulator bindings.
- Continue and halt results.
- A declared ordering rule.

### 7.3 Mergeable State

Status: **Declared**

The lower-level `Accumulator` and `FanIn` structures have a `mergeable` field.
It can describe algebraic properties such as:

- Associative.
- Commutative.
- Idempotent.

The public `accumulator` and `reduce` macros do not set this field from their
options in alpha.8. Flow Script should not treat mergeability as a working
public feature in this baseline.

Merge properties can become valuable later. They can permit safe reorder,
parallel reduction, deduplication, and replay.

## 8. Stateful Components

### 8.1 Accumulator

Status: **Verified**

An accumulator stores state across workflow inputs.

It has:

- An initial value or zero-argument initializer.
- A reducer with `input` and current `state`.
- One new state result for each accepted input.

The current state is a produced fact. State also stays in graph memory.

Language feature candidates:

- Named state cell.
- Initial value.
- State reducer.
- State read expression.
- State output.

A Flow Script implementation must define state scope:

- Per workflow artifact.
- Per workflow run.
- Per durable workflow identifier.
- Per correlation key.

Runic state belongs to the workflow value or managed runner worker.

### 8.2 General State Machine

- Status: **Verified** for the keyword form
- Status: **Defective** for the documented block form

The working form contains:

- `name`.
- `init`.
- A reducer.
- Zero or more reactors.

Each reactor observes a new state. It can emit another fact when the new state
matches its predicate. Reactors are independent rules.

The initializer can be:

- A literal.
- A zero-argument function.
- A module-function-arguments tuple.

The upstream documentation also shows a `handle` and `react` block form. The
public macro only accepts the keyword form in alpha.8. A compile probe confirms
that the documented block form does not compile.

Flow Script can still use the useful model:

- `initial` state.
- `on input reduce state`.
- `when state emit`.

It must not claim that it maps to the current Runic block API.

### 8.3 Finite State Machine

Status: **Verified**

`Runic.fsm/2` provides a specific state-transition model.

It supports:

- A required initial state.
- Declared states.
- Named atom events.
- A target state for each event.
- An optional input guard.
- An optional entry action.
- Self-transitions.

Compile-time checks include:

- The initial state must be declared.
- Each target state must be declared.
- One state cannot have duplicate handlers for the same event.

The component produces state and transition facts. An event that does not match
a transition makes no state change.

Language feature candidates:

- `state` declarations.
- `initial` declaration.
- `on event -> state` transitions.
- Optional guard.
- Entry action.
- Transition output.

Runic event and state identifiers are atoms in this release. Flow Script can use
strings or identifiers and map them to safe registered atoms. It must not create
unbounded atoms from untrusted text.

### 8.4 Aggregate

Status: **Verified**

`Runic.aggregate/2` models command handling and event folding.

It has:

- Initial aggregate state.
- Command handlers.
- An optional command guard that reads current state.
- An emitted domain event.
- Event handlers that fold domain events into state.

The normal flow is:

1. An input command matches a command handler.
2. The guard accepts or rejects the command.
3. The command emits a domain event.
4. The event handler updates aggregate state.

A rejected command emits no event and makes no state change.

Domain events are workflow fact values. They are not Runic engine log events.

Language feature candidates:

- Aggregate declaration.
- Command pattern.
- State guard.
- Domain event emission.
- Domain event fold.

The language must keep these two event types separate:

- Domain events in the workflow data plane.
- Engine events in the Runic persistence plane.

### 8.5 Saga

Status: **Implemented with important limits**

`Runic.saga/2` declares:

- Named transactions.
- One compensation for each transaction.
- An optional completion handler.
- An optional abort handler.

The macro checks that each transaction has a compensation.

The current runtime has a major semantic detail. It executes all transactions
inside one accumulator reducer for one input. It does not dispatch each
transaction as an independent Runic graph step.

A transaction result is interpreted as follows:

- `{:ok, value}` is success.
- `{:error, reason}` is failure.
- Any other return value is also success.
- A transaction exception becomes a failure.

On a failure, Runic calls compensation functions for completed work.
Compensation errors do not stop the remaining compensation work.

Current limits:

- The declared transactions are not independent schedulable nodes.
- Per-step retry, timeout, telemetry, and persistence do not naturally apply to
  each transaction.
- The compensation traversal uses result-map keys. It does not guarantee the
  reverse of declared transaction order.
- The final `compensated` field records step names, not a result map.

Language feature candidates:

- Transaction sequence.
- Explicit compensation for each transaction.
- Complete and abort handlers.
- A strict result contract.
- A guaranteed reverse compensation order.

Flow Script should define saga semantics itself. It should not copy the current
alpha.8 implementation limits into the language contract.

### 8.6 Process Manager

Status: **Implemented with important limits**

`Runic.process_manager/2` models a stateful event coordinator.

It supports:

- Initial map state.
- Event patterns.
- One state update map per event handler.
- Zero or more emitted command values.
- An optional completion predicate.
- A completion output in the form `{:process_completed, name}`.

More than one update statement in one handler is a compile error. More than one
emit statement becomes one list output fact.

An event handler that only updates state has no command rule. It still changes
the accumulator state.

Current limits:

- Timeout statements are parsed and counted, but no timer or graph rule is
  built.
- The documented `state` variable in an emit expression is not bound.
- A direct probe of the documented state-based emit form does not compile.

The current reliable emit inputs are values from the matched event and explicit
pinned captures.

Language feature candidates:

- Event handler.
- State patch.
- Command emission.
- Completion predicate.
- Timer or deadline event.
- Correlation key.

Flow Script must not expose process-manager timeouts until the lowering target
has working timer semantics.

## 9. Meta Queries and History Expressions

Runic macros can compile special queries into graph meta references.

The public query names are:

| Query | Intended result | Baseline |
| --- | --- | --- |
| `state_of(component)` | Latest accumulator state | Verified |
| `fact_count(component)` | Count of facts from a component | Verified |
| `latest_value_of(component)` | Value at greatest ancestry depth | Verified |
| `latest_fact_of(component)` | Fact at greatest ancestry depth | Verified |
| `all_values_of(component)` | All non-nil values | Verified |
| `all_facts_of(component)` | All facts, including nil values | Verified |
| `step_ran?(component)` | Whether the component ran | Defective |
| `step_ran?(component, fact)` | Whether it ran for one fact | Declared, not compiled |
| `context(key)` | Runtime context value | Verified |
| `context(key, default: value)` | Context value with a default | Verified |

These functions are compiler markers. Direct calls outside a supported Runic
macro raise an error.

### 9.1 History Scope

The fact queries read workflow history. They do not only read values from the
current input.

This is important for Flow Script. An expression such as `latest(step_a)` can
mean one of two different things:

- Latest value in the current logical run.
- Latest value in all retained workflow history.

Runic implements the second meaning unless the graph structure or runner
isolates the history.

### 9.2 Latest Value

Runic selects the fact with the greatest ancestry depth. If more than one fact
has the same depth, graph edge order can decide the result.

Flow Script should define a deterministic tie rule or reject an ambiguous
`latest` query.

### 9.3 State References

`state_of` resolves an accumulator. A composite component often needs an
explicit subcomponent reference such as its internal accumulator.

Flow Script should hide internal graph component names. It should expose a
stable state interface for a stateful declaration.

### 9.4 Broken `step_ran?` Behavior

The alpha.8 meta compiler does not implement the two-argument form.

The one-argument form compiles, but an end-to-end probe does not react. The
getter searches a `:ran` edge in the opposite direction from the edge that the
engine records.

Flow Script must not include this query in its supported baseline.

## 10. Runtime Context

Status: **Verified**

Run context is configuration data that does not travel as workflow facts.

Runic supports:

- A global context map.
- A context map for each component.
- Component values that override global values.
- Required-key discovery.
- Required-key validation.
- A literal default.
- A lazy zero-argument default.
- Nested dot access.

Context is not part of:

- The component hash.
- The fact data plane.
- The event log.

A missing context key without a default returns `nil`. A default makes the key
optional for validation.

Language feature candidates:

- `context.name` read.
- Required context declaration.
- Default context value.
- Component context override.
- A schema for context.

Flow Script must define if context can affect reproducibility. A durable replay
cannot reconstruct a context value that was never stored.

## 11. Ports and Data Contracts

Status: **Implemented with limits**

A component port is a named keyword entry. It can have:

- `type`.
- `doc`.
- `cardinality`.
- `required`.

A workflow boundary port can also have:

- `to` for an input binding.
- `from` for an output binding.

### 11.1 Default Component Ports

| Component | Default input | Default output |
| --- | --- | --- |
| Step | `in` | `out` |
| Condition | `in` | `out` |
| Rule | `in` | `out` |
| Map | `items: many` | `out: many` |
| Reduce | `items: many` | `result` |
| Accumulator | `in` | `state` |
| State machine | `in` | `state` |
| FSM | `event` | `state`, `transition` |
| Aggregate | `command` | `state`, `events` |
| Saga | `in` | `state`, `result` |
| Process manager | `event` | `state`, `commands` |
| Workflow | None unless declared | None unless declared |

### 11.2 Type Compatibility

Runic supports these type relations:

- `:any` is compatible with every type.
- Equal literal type terms are compatible.
- `{:list, type}` describes a list item type.
- `{:one_of, [types]}` describes alternatives.

This is connection compatibility. It is not a runtime value validator.

Runic does not provide:

- Value coercion.
- Object-field schemas.
- Runtime input type checks.
- Runtime output type checks.
- A structural schema language.

Jido already uses Zoi schemas. Flow Script can use those schemas for runtime
validation and use Runic ports only for graph compatibility.

### 11.3 Port Matching

Connection logic uses these rules:

- One producer output and one consumer input connect without a name match.
- Many producer outputs and one consumer input select a compatible output.
- Many-to-many matching uses required consumer port names.

The connection validation mode can be:

- Error.
- Warning.
- Off.

### 11.4 Port Limits

Ports are mostly contracts and result selectors. They are not a complete named
channel router.

In alpha.8:

- A workflow input `to` value is validated as a component name.
- It does not route a separate runtime value to that component.
- A root input value still activates root branches.
- Cardinality guides compatibility and result shape.
- Cardinality does not enforce a runtime item count.
- `required` affects composition matching.
- `required` does not validate a runtime input object.

Flow Script should not imply named input routing if its Runic lowering only sets
boundary port metadata.

## 12. Results and Data Selection

Status: **Verified**

Runic can return:

- All raw produced values.
- Produced facts.
- Values from selected components.
- Facts from selected components.
- A boundary result map from declared output ports.

A boundary output port uses `from` to select a component. Cardinality controls
the normal result:

- `one` returns the last value.
- `many` returns a list.

Options can request:

- Facts instead of values.
- All values instead of only the normal selected value.

Raw productions include intermediate and state values. They are not only final
leaf values.

Language feature candidates:

- One explicit return expression.
- Named outputs.
- Output cardinality.
- Result projection.
- History result query.

The current `Jido.Flow` model has one declared return expression. This is
simpler than the full Runic result model. Flow Script can keep one source-level
return and lower it to one boundary output.

## 13. Planning and Execution

### 13.1 Planning

Status: **Verified**

Runic can inspect work before execution.

Important operations include:

- `plan`.
- `plan_eagerly`.
- `is_runnable?`.
- `prepared_runnables`.

Planning finds work that current facts and graph memory enable.

Language feature candidates:

- Dry run.
- Explain plan.
- Static graph view.
- Ready-node inspection.

These are mainly tool features. They do not need grammar.

### 13.2 Three-Phase Dispatch

Status: **Verified**

Runic separates execution into three phases:

1. Prepare runnable work in the workflow.
2. Execute a runnable outside the workflow.
3. Apply the runnable result to the workflow.

A runnable contains the work and input that it needs. It does not contain the
whole workflow.

This separation permits:

- Task-based execution.
- Remote execution.
- Custom worker pools.
- External scheduling.
- Parallel execution of independent work.
- A central, ordered apply phase.

Flow Script can stay independent of the execution location. A deployment
configuration can select an executor.

### 13.3 Reaction Modes

Status: **Verified**

Runic has:

- One-cycle reaction.
- Reaction until no work remains.
- Eager planning.
- A workflow deadline for a direct reaction loop.

The language or host API must define:

- The stop condition.
- The maximum cycle count.
- The deadline.
- How an open workflow yields control.

## 14. Scheduler Policy

Status: **Mixed**

A workflow can hold an ordered list of scheduler policies. The first matching
policy applies.

A policy can match by:

- Exact component name.
- Component-name regular expression.
- Component module.
- A list of component modules.
- A custom function.
- A default match.

### 14.1 Active Direct-Execution Features

The policy driver uses:

- Maximum retries.
- No, linear, exponential, or jitter backoff.
- Base delay.
- Maximum delay.
- Per-attempt timeout.
- Failure action: halt or skip.
- Fallback work.
- Synthetic fallback value.
- A workflow-level deadline.
- Per-run policy override in merge or replace mode.

A fallback can:

- Return a changed runnable.
- Request a retry with changed metadata.
- Produce a synthetic success value.

### 14.2 Declared but Not Active in Direct Reaction

These policy fields exist, but direct `Workflow.react` does not use them as full
execution controls:

- `execution_mode`.
- `priority`.
- `idempotency_key`.
- Policy `deadline_ms`.
- `circuit_breaker`.
- `executor`.
- `executor_opts`.

The managed Runner uses some of these fields. For example, it uses durable
execution mode and executor selection.

The inline executor intentionally does not apply a timeout. Retry and fallback
still apply.

Runic also provides policy presets for:

- Large-language-model work.
- Input/output work.
- Fast failure.

### 14.3 Flow Script Decision

There are three possible language boundaries:

1. Put policy in the Flow Script file.
2. Put policy in a separate deployment file.
3. Let the host attach policy at execution time.

The current Jido design direction supports options 2 and 3. It says that a flow
is not a policy container.

This baseline recommends that Flow Script version 1 does not put scheduler
policy in the core grammar.

## 15. Managed Runner

Status: **Implemented**

`Runic.Runner` manages long-lived workflow workers.

It has:

- A supervisor.
- A registry.
- A dynamic worker supervisor.
- A task supervisor.
- One worker process for each workflow identifier.

The public runner can:

- Start a workflow.
- Send an asynchronous input.
- Read results.
- Read workflow state.
- List managed workflows.
- Stop and persist a workflow.
- Request a checkpoint.
- Resume a workflow.

### 15.1 Checkpoints

Supported checkpoint strategies are:

- `:every_cycle`.
- `{:every_n, n}`.
- `:on_complete`.
- `:manual`.

The default is `:every_cycle`.

A stream-capable store receives new events. A legacy store receives a full event
log snapshot.

### 15.2 Recovery

Recovery modes include:

- Full.
- Hybrid.
- Lazy.

Runic can replace fact values with `FactRef` values. It can later rehydrate cold
facts from a content-addressed fact store.

### 15.3 Store Adapters

Built-in stores include:

- ETS.
- Mnesia.

The store behavior supports:

- Snapshot save and load.
- Optional event append and stream.
- Optional snapshots.
- Optional content-addressed fact values.
- Workflow lifecycle operations.

### 15.4 Executors

Runic has:

- A task executor.
- An inline executor.
- A GenStage executor with back pressure.
- A custom executor behavior.
- Per-component executor overrides in the Runner.

### 15.5 Schedulers

Runic has:

- A default scheduler for individual runnables.
- A chain-batching scheduler.
- A flow-batch scheduler for chains and parallel groups.
- An adaptive scheduler that profiles work.
- A custom scheduler behavior.

Schedulers produce promises. Sequential promise work can commit a successful
prefix before a later item fails. Parallel promise work is independent.

### 15.6 Hooks

Runner worker hooks include:

- Dispatch.
- Complete.
- Failed.
- Idle.
- Runnable transformation.

Workflow execution hooks can run before or after a node. Hook APIs can accept or
reject application of a result. Some legacy hook forms can also change the
workflow.

### 15.7 Flow Script Decision

The Runner is a host and deployment concern. It can run a Flow Script artifact,
but it does not need to be part of the source grammar.

A separate run profile can contain:

- Store.
- Checkpoint strategy.
- Recovery mode.
- Scheduler.
- Executor.
- Concurrency.
- Runtime policy.
- Hooks.

## 16. Persistence and Replay

Status: **Verified**

Runic has two event histories.

### 16.1 Build Log

The build log records workflow structure, such as:

- Component additions.
- Component removals.
- Closure metadata.
- Connection-related structure.

### 16.2 Runtime Event Log

Runtime events include:

- Fact production.
- Condition satisfaction.
- Activation consumption.
- Runnable activation.
- Runnable dispatch.
- Runnable completion.
- Runnable failure.
- Join progress.
- Fan-out progress.
- Fan-in progress.
- State initialization.

Runic can:

- Return the full event log.
- Track uncommitted events.
- Rebuild a workflow from a log.
- Rebuild from events.
- Apply custom events through a protocol.

### 16.3 Serialization

Runic serializes events with the Erlang external term format. Closure metadata
contains quoted Elixir syntax and captured bindings.

This gives good Elixir and BEAM replay support. It is not a portable
cross-language workflow source format.

Important limits:

- The serialized form can contain arbitrary Elixir terms.
- Safe decode needs module atoms to exist.
- Closure source is Elixir-specific.
- A component identity can depend on captured Elixir data.

Flow Script should be the portable source form. It should compile to Runic. It
should not use the Runic event-log binary as its source format.

## 17. Extensibility

Status: **Implemented**

Runic has several extension points.

### 17.1 Component Protocol

`Runic.Component` defines:

- Connection.
- Connection compatibility.
- Source representation.
- Hash.
- Input ports.
- Output ports.
- Subcomponent access.

A custom component can control how it lowers into the workflow graph.

### 17.2 Invokable Protocol

`Runic.Invokable` defines work execution behavior. A custom invokable can
prepare, execute, invoke, and match or execute.

### 17.3 Transmutable Protocol

`Runic.Transmutable` converts a value to a component or workflow.

Built-in conversions include:

- Functions.
- Lists.
- Tuple graph forms.
- Runic components.
- Constant values through the fallback implementation.

### 17.4 Other Extension Points

Other extension points include:

- Activator.
- Coordinator.
- Event applicator.
- Store.
- Scheduler.
- Executor.

Language feature candidates:

- A registered component type.
- A compiler extension registry.
- Custom syntax only through versioned namespaces.

Flow Script version 1 should prefer a small closed core. A later extension
mechanism can map a namespaced declaration to a custom Runic component.

## 18. Inspection, Visualization, and Observability

Status: **Verified**

Runic exposes graph and history inspection.

It can inspect:

- Components.
- Steps.
- Conditions.
- Dependencies.
- Dependents.
- Ancestry.
- Causal depth.
- Component subgraphs.
- Component results.
- Produced facts.

It can remove old graph memory with memory purge functions.

Serializers include:

- Mermaid flowchart.
- Mermaid causal sequence.
- Graphviz DOT.
- Cytoscape data.
- Edge list.

The Runner emits Telemetry events for:

- Workflow start, stop, and exception.
- Runnable start, stop, and exception.
- Store start, stop, and exception.
- Promise start and stop.
- Rehydration completion.

These capabilities are strong tooling targets for Flow Script:

- Format and parse.
- Validate.
- Compile.
- Explain dependencies.
- Show a graph.
- Show execution history.
- Show ready work.
- Show state.
- Trace one result to its input.

## 19. Known Alpha.8 Gaps

This table is a design guardrail. A Flow Script feature must not depend on a
broken or inactive Runic feature without a lowerer or runtime fix.

| Area | Gap | Effect on Flow Script |
| --- | --- | --- |
| State machine | Documented block form does not compile | Use a compiler lowerer or the working keyword form |
| Process manager | Timeout is parsed but not built | Do not expose timers yet |
| Process manager | Documented `state` emit variable is unbound | Provide explicit state reads in the lowerer |
| Meta query | `step_ran?/1` has a graph-edge direction defect | Exclude from supported expressions |
| Meta query | `step_ran?/2` is documented but not compiled | Exclude from supported expressions |
| Scheduler policy | Several fields are stored but inactive in direct reaction | Validate policy by execution host |
| Ports | Input `to` does not route named values | Do not claim named channel routing |
| Ports | Types are compatibility terms, not runtime schemas | Use Jido or Zoi validation |
| Ports | Cardinality is not runtime count enforcement | Validate cardinality outside Runic |
| Names | Duplicate names can replace lookup entries | Enforce unique source identifiers |
| Identity | Hashes are 32-bit non-cryptographic values | Use explicit stable source IDs |
| Graph model | Stateful graphs can contain cycles | Do not require a DAG after lowering |
| Saga | Transactions run inside one accumulator invocation | Define source-level transaction boundaries |
| Saga | Compensation order is not guaranteed as reverse declaration order | Define and test strict reverse order |
| Reduce | Mergeable metadata is not exposed by the public macro | Treat parallel fold laws as future work |
| History | Latest-value ties can depend on graph order | Define a deterministic query rule |
| Context | Context is not in replay data | Store replay-critical context explicitly |
| Serialization | Closures and terms are Elixir-specific | Keep Flow Script as the portable form |

## 20. Flow Script Feature Inventory

This section turns the Runic baseline into a language design inventory.

### 20.1 Core Version 1 Candidates

These features have clear Runic semantics and fit a slim flow language:

- Workflow name and version.
- Typed input schema.
- Typed output schema.
- Stable and unique step identifiers.
- Action references.
- Literal values.
- Input references.
- Context references.
- Prior result references.
- Nested data selection.
- Explicit return expression.
- Sequence from data dependencies.
- Independent branches.
- Explicit join.
- Named conditions.
- Pattern and predicate rules.
- Map.
- Reduce.
- Accumulator state.
- Reusable subflows.
- Static validation.
- Graph visualization.

### 20.2 Optional Version 1 Candidates

These features are useful, but they increase semantic scope:

- Finite state machine.
- General state reducer with reactors.
- Aggregate.
- Named output ports.
- Multiple outputs.
- History queries.
- Dynamic workflow imports.

### 20.3 Later Language Candidates

These features need more runtime design:

- Saga.
- Process manager.
- Timers.
- Live graph mutation.
- Mergeable reduction laws.
- Custom component syntax.
- History queries across durable runs.
- Correlation-aware joins.

### 20.4 Host Configuration, Not Core Syntax

These capabilities can stay outside the Flow Script file:

- Retry.
- Backoff.
- Timeout.
- Fallback.
- Failure halt or skip.
- Workflow deadline.
- Store.
- Checkpoint strategy.
- Recovery mode.
- Scheduler.
- Executor.
- Concurrency.
- Telemetry handlers.
- Runtime hooks.

## 21. Required Language Decisions

The Flow Script design must answer these questions before its grammar is stable.

### 21.1 Identity

- Are source identifiers strings or identifiers?
- Are identifiers unique in one workflow or in one namespace?
- How does an imported subflow get a namespace?
- What identity stays stable after formatting or reordering?

Recommendation: Use explicit source IDs. Generate Runic hashes only during
lowering.

### 21.2 Action Binding

- How does a text action name resolve to a `Jido.Action` module?
- Can a script call an arbitrary function?
- Is the registry fixed at compile time?
- How are action versions selected?

Recommendation: Resolve names through an explicit action registry. Do not create
module atoms from untrusted text.

### 21.3 Data Expressions

- Which literal types are portable?
- How do input, context, state, and result references differ?
- Can expressions call functions?
- Is data shaping pure?
- How are missing paths handled?

Recommendation: Use a small data-expression language. Keep arbitrary Elixir
outside the portable script.

### 21.4 Branch and Join

- Do references create dependencies automatically?
- Is an explicit branch block only for display?
- Does a join use branch order or named inputs?
- How does a join correlate facts from parallel runs?
- What happens when a branch emits zero or many values?

Recommendation: Use named join inputs. Define one value per dependency in the
first version.

### 21.5 State

- Is state local to one invocation or durable across inputs?
- How does a caller reset state?
- Can two workflow workers share state?
- Does state need a schema?
- Is state in the portable result?

Recommendation: Make state scope explicit. Do not infer it from the executor.

### 21.6 Rules

- Which pattern forms are portable?
- Which operators are allowed in predicates?
- Can a rule read history?
- Can one fact activate the same reaction more than once?
- How are OR branches deduplicated?

Recommendation: Define a closed predicate syntax and one activation per rule and
input fact.

### 21.7 Failure

- What is an action success result?
- What is an action error result?
- Does a thrown exception stop the workflow?
- Does a skipped step make downstream joins incomplete?
- Can fallback values satisfy output schemas?

Recommendation: Normalize every action result at the Jido boundary. Do not use
the current silent direct-step exception behavior as the language contract.

### 21.8 Determinism

- Is independent work order observable?
- Is result order stable?
- What does latest mean?
- Does replay use stored context?
- Can a function read time or random data?

Recommendation: Make graph order non-semantic. Define explicit ordering only for
map results, reduce, join inputs, and declared sequences.

### 21.9 Port and Schema Model

- Are ports named data channels or only contracts?
- Is cardinality checked at compile time, runtime, or both?
- Does a port use Zoi, Runic types, or both?
- How does one source output map to many target inputs?

Recommendation: Use Zoi as the value schema. Use source references for routing.
Use Runic ports as lowered compatibility metadata.

### 21.10 Runtime Boundary

- Which options belong in the script?
- Which options belong in a run profile?
- Can the same script run in direct and durable modes?
- Which runtime changes can affect semantic results?

Recommendation: Keep the source artifact declarative. Put scheduling and
durability in a separate run profile.

## 22. Proposed Semantic Layers

Flow Script can use four clear layers.

| Layer | Responsibility | Example |
| --- | --- | --- |
| Source | Portable text and stable identifiers | Steps, references, joins, rules |
| Canonical model | Parsed and validated data structure | Versioned Flow Script AST |
| Runic lowerer | Runic components and graph | Step, Rule, Map, Accumulator |
| Run profile | Execution and durable runtime | Retry, Runner, store, scheduler |

This split gives two benefits:

- The text does not depend on Elixir closure serialization.
- The same flow can use more than one execution profile.

The canonical model is the language contract. The Runic graph is one execution
form. This protects Flow Script from alpha package changes.

## 23. Minimum Conformance Tests

A Flow Script implementation should test language semantics at two levels.

### 23.1 Canonical Model Tests

Test:

- Parse and format round trips.
- Stable identifiers.
- Duplicate name rejection.
- Unknown action rejection.
- Unknown reference rejection.
- Dependency-cycle rules.
- Schema compatibility.
- Deterministic canonical ordering.
- Version migration.

### 23.2 Runic Lowering Tests

Test:

- One step.
- Sequence.
- Independent branches.
- Join input order.
- Condition true and false.
- Rule pattern and predicate.
- Map with empty and non-empty input.
- Reduce continue and halt.
- Accumulator state across inputs.
- Context default and override.
- Result projection.
- Step failure.
- Replay.
- Direct and Runner result equivalence.

### 23.3 Regression Tests for Alpha Gaps

Keep explicit tests for:

- Duplicate Runic component names.
- `step_ran?` behavior.
- State-machine lowering.
- Process-manager state reads.
- Process-manager timers.
- Saga compensation order.
- Boundary input routing.
- Equal-depth latest-value queries.

These tests can change from expected failure to expected pass when Runic fixes
the related feature.

## 24. Public Capability Index

The main Runic authoring entry points are:

~~~text
step
condition
rule
workflow
transmute
map
reduce
accumulator
state_machine
fsm
aggregate
saga
process_manager
state_of
fact_count
latest_value_of
latest_fact_of
all_values_of
all_facts_of
step_ran?
context
~~~

The main workflow operations cover:

~~~text
construct and compose
add and remove components
merge workflows
set and validate run context
set scheduler policy
plan runnable work
react for one cycle
react until idle
prepare, execute, and apply runnables
read values, facts, and component results
inspect graph dependencies and ancestry
build and replay event logs
serialize graph views
purge old memory
~~~

The managed runtime adds:

~~~text
workflow worker lifecycle
asynchronous input
checkpoint
resume
event or snapshot storage
fact rehydration
scheduler selection
executor selection
hooks
telemetry
~~~

## 25. Source Map

The most relevant upstream source files are:

- [Public authoring API](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic.ex)
- [Workflow engine](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow.ex)
- [Component protocol and lowering](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/component.ex)
- [Invocation protocol](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/invokable.ex)
- [Facts](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/fact.ex)
- [Runnable model](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/runnable.ex)
- [Scheduler policy](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/scheduler_policy.ex)
- [Policy driver](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/policy_driver.ex)
- [Runner](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic/runner.ex)
- [Runner worker](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic/runner/worker.ex)
- [Runner store behavior](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic/runner/store.ex)
- [Runner scheduler behavior](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic/runner/scheduler.ex)
- [Runner executor behavior](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/runic/runner/executor.ex)
- [Event serializer](https://github.com/zblanco/runic/blob/4f1269a4d04c3b83731bf343f2098387e8a7395f/lib/workflow/events/serializer.ex)

## 26. Baseline Conclusion

Runic gives Flow Script a broad semantic target. Its strongest capabilities are:

- Fact-based forward chaining.
- Explicit graph composition.
- Pattern and predicate rules.
- Joins.
- Collection fan-out and fan-in.
- Stateful reducers.
- Domain-oriented state components.
- Three-phase execution.
- Event history and replay.
- A durable managed runner.
- Strong graph inspection.

Flow Script should not be a text copy of the Runic macros. Some macros depend on
Elixir syntax, closures, and runtime terms. Some alpha.8 features are incomplete
or defective.

The safer design is:

1. Define a small portable source language.
2. Parse it into a versioned canonical model.
3. Validate identity, references, schemas, and semantics before lowering.
4. Lower supported features into Runic components.
5. Keep execution policy and durability in a separate run profile.
6. Add stateful domain components only after their exact language semantics are
   defined.

This baseline makes Runic the execution capability reference. It does not make
Runic alpha.8 behavior the permanent Flow Script language contract.
