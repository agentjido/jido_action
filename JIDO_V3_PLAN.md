# Jido Action v3 Plan

This document is the working plan for the v3 spike. It is intentionally
standalone: code remains authoritative, but this plan records the target shape
and the architectural decisions we want the code to converge on.

## Thesis

Jido Action v3 should be a small, explicit package for:

- defining validated action modules,
- representing action invocations as data,
- preserving intentional non-map action outputs,
- normalizing action errors,
- composing action invocations into a compact Flow IR,
- executing actions, instructions, and flows through Runic.

Runic owns generic workflow mechanics: scheduling, retries, timeouts, durable
execution, facts, joins, event logs, and low-level workflow execution.

Jido owns the action contract, action call frames, action output/error boundary,
the Jido-specific Flow IR, and the Exec adapter that connects Jido semantics to
Runic.

## Design Principles

- Keep the public API slim and explicit.
- Treat actions as leaf units of work.
- Treat instructions as call frames, not workflow policy.
- Treat Flow as a typed AST/IR for Jido action composition.
- Treat Exec as the runtime adapter, not a second workflow engine.
- Keep package-owned data structs Zoi-backed where they are normal data.
- Keep concrete exception modules as exceptions, with Splode used for error
  classification and normalization.
- Do not add compatibility shims unless they are intentionally part of v3.
- Do not duplicate Runic primitives under weaker Jido names.

## Dependency Policy

The intended direct production dependencies are:

- `jason`
- `telemetry`
- `zoi`
- `runic`
- `splode`

Do not add direct production dependencies outside this set without a deliberate
design review.

## Module Plan

### `Jido.Action`

`Jido.Action` defines one reusable unit of work.

Responsibilities:

- validate action compile-time configuration,
- expose action metadata,
- expose input and output schemas,
- provide `validate_params/1`,
- provide `validate_output/1`,
- require `run/2`.

Target behavior:

- `name` is required and must be a bounded non-blank string.
- `description` is optional.
- `schema` is optional and defaults to no validation.
- `output_schema` is optional and defaults to no validation.
- normal successful action results are maps.
- abnormal successful action results use `Jido.Action.Output`.
- action bodies may be pure or effectful, but should stay leaf-level.
- hidden orchestration inside `run/2` should remain discouraged.

Supported action returns:

```elixir
{:ok, map}
{:ok, map, directives}
{:ok, %Jido.Action.Output{}}
{:ok, %Jido.Action.Output{}, directives}
{:error, reason}
{:error, reason, directives}
```

Non-goals:

- scheduling,
- retries,
- timeouts,
- durable execution,
- workflow composition,
- runtime supervision.

### `Jido.Instruction`

`Jido.Instruction` is a small call frame for one action invocation.

Canonical shape:

```elixir
%Jido.Instruction{
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant_123"}
}
```

Responsibilities:

- normalize action, params, and context into a Zoi-backed struct,
- validate that `action` is an atom-shaped module reference,
- normalize params/context from maps or keyword lists,
- merge additional params/context when wrapping an existing instruction.

Important boundary:

- construction validates call-frame shape,
- execution validates the action callback contract.

`Jido.Instruction` must not own:

- runtime input,
- result names,
- graph dependencies,
- retry policy,
- timeout policy,
- scheduler policy,
- workflow identity.

Those belong to Flow or Exec.

### `Jido.Action.Output`

`Jido.Action.Output` is the explicit envelope for abnormal successful outputs.

Canonical shape:

```elixir
%Jido.Action.Output{
  kind: :raw | :stream | :batch | :opaque,
  value: term(),
  meta: %{}
}
```

Responsibilities:

- preserve intentionally non-map successful action results,
- validate envelope shape,
- enforce kind-specific constraints where they matter:
  - `:stream` values must be enumerable,
  - `:batch` values must be lists.

Use cases:

- raw external API values,
- streams,
- batch payloads,
- opaque handles or process-owned resources.

The runtime must preserve these envelopes. It should not force them through
normal map output validation.

### `Jido.Action.Error`

`Jido.Action.Error` is the package error vocabulary and normalization boundary.

It is powered by Splode. Splode matters because it gives the package a coherent
classification layer for aggregation and normalization, but application code
should primarily interact with concrete exception structs and the normalized
map shape.

Public concrete errors:

- `Jido.Action.Error.InvalidInputError`
- `Jido.Action.Error.ConfigurationError`
- `Jido.Action.Error.ExecutionFailureError`
- `Jido.Action.Error.TimeoutError`
- `Jido.Action.Error.InternalError`

Canonical public error types:

- `:validation_error`
- `:configuration_error`
- `:execution_error`
- `:timeout`
- `:internal_error`

Responsibilities:

- create concrete exceptions through helper functions,
- normalize arbitrary reasons into known error types,
- serialize errors through `to_map/1`,
- expose conservative retry classification through `retryable?/1`.

Runtime retry decisions still belong to Runic scheduler policy. Jido retryability
is advisory metadata, not a scheduler.

### `Jido.Flow`

`Jido.Flow` is the Jido-specific composition IR.

It should be smaller than Runic. Flow should model Jido action composition and
data dependencies, then compile to Runic.

Foundational model:

```text
FlowEntry = Node | Loop
Body      = List FlowEntry
Ref       = Input | Result | Value | State
```

Canonical structs:

```elixir
%Jido.Flow{}
%Jido.Flow.Node{}
%Jido.Flow.Ref{}
%Jido.Flow.Loop{}
```

#### Flow Root

Canonical shape:

```elixir
%Jido.Flow{
  name: :checkout,
  entries: [%Jido.Flow.Node{}],
  return: %Jido.Flow.Ref{type: :result, name: :receipt}
}
```

Responsibilities:

- hold the program name,
- hold ordered entries,
- hold an optional return ref,
- normalize builder input into canonical structs,
- render to plain maps,
- discover dependencies,
- delegate compilation to `Jido.Flow.Compiler`.

Avoid adding flow-level `inputs` until it has real semantics. Runtime input
dependencies are expressed by input refs.

#### Node

`Jido.Flow.Node` is the normal executable binding in the IR.

Canonical shape:

```elixir
%Jido.Flow.Node{
  type: :node,
  name: :price_cart,
  input: %Jido.Flow.Ref{type: :input, name: :cart},
  instruction: %Jido.Instruction{
    action: MyApp.Actions.PriceCart,
    params: %{currency: "USD"},
    context: %{}
  },
  hash: term(),
  meta: %{}
}
```

A node exists because an instruction is only a call frame. Flow needs to bind
that call frame to:

- a result name,
- a runtime input expression,
- optional IR metadata,
- a Runic component identity.

`input` rules:

- `nil` means no dynamic runtime input; the action receives static params only.
- `{:input, :input}` means the node consumes the root runtime input.
- `{:input, name}` means the node selects a named key from the root runtime input.
- `{:result, name}` means the node consumes a prior result.
- `{:result, name, path}` means the node consumes a path inside a prior result.
- maps and lists may contain refs and are resolved into ordinary values.
- literal nil should be represented as `{:value, nil}` if it needs to be
  distinct from no dynamic input.

Only introduce a new Flow entry type when the semantics are different from a
normal action node. Most conveniences should lower to ordinary nodes.

#### Ref

`Jido.Flow.Ref` is a value expression and dependency marker.

Canonical refs:

```elixir
%Jido.Flow.Ref{type: :input, name: :cart}
%Jido.Flow.Ref{type: :result, name: :price_cart}
%Jido.Flow.Ref{type: :result, name: :price_cart, path: [:total_cents]}
%Jido.Flow.Ref{type: :value, value: %{currency: "USD"}}
%Jido.Flow.Ref{type: :state}
%Jido.Flow.Ref{type: :state, path: [:answer]}
```

Validation rules:

- input refs require atom names,
- result refs require atom names,
- result and state paths must be non-empty lists when present,
- value refs carry literal values,
- state refs should only be meaningful inside loop semantics.

The compiler should derive graph dependencies from result refs in one place.

#### Loop

`Jido.Flow.Loop` is the planned bounded control-flow entry.

Canonical shape:

```elixir
%Jido.Flow.Loop{
  type: :loop,
  name: :react,
  state: %Jido.Flow.Ref{type: :input, name: :conversation},
  body: [
    %Jido.Flow.Node{name: :reason},
    %Jido.Flow.Node{name: :observe}
  ],
  until: %Jido.Flow.Ref{type: :result, name: :reason, path: [:done?]},
  max_iterations: 20,
  return: %Jido.Flow.Ref{type: :state, path: [:answer]},
  meta: %{}
}
```

Loop bodies should be plain lists of entries. Do not add a `Block` struct unless
blocks need identity, metadata, or independent execution semantics.

Required loop semantics before implementation:

- bounded execution,
- explicit initial state,
- iteration-local body evaluation,
- state handoff between iterations,
- completion condition,
- max-iteration failure shape,
- return extraction,
- provenance and telemetry behavior.

Loop compilation should target a dedicated Runic component or adapter. Do not
hide loop semantics in generated chains of anonymous steps.

#### Built-In Flow Actions

Builder conveniences should usually produce ordinary nodes backed by ordinary
actions.

Good candidates:

- select/project,
- merge/collect,
- identity,
- value-level decide,
- path update,
- state update.

These are not canonical entry types unless they need graph or control-flow
semantics distinct from a normal node.

Graph-routing decisions are different from value-level decisions. If a decision
changes which nodes run, model it as explicit control flow later.

### `Jido.Flow.Compiler`

The compiler lowers Flow IR to Runic.

Target pipeline:

```text
Jido.Flow
  -> validate canonical entries
  -> validate result refs
  -> derive dependency edges from refs
  -> register each node as a Runic component
  -> compile loops through a dedicated loop adapter
  -> return Runic.Workflow
```

Compiler responsibilities:

- keep dependency derivation deterministic,
- reject unknown result refs,
- reject unsupported entries clearly,
- avoid embedding a second action runtime in anonymous closures,
- preserve enough node identity for results, telemetry, and provenance.

Flow return handling can initially live in `Jido.Exec.Result` by extracting the
declared return ref after execution. Add a terminal Runic projection only if a
concrete Runtime or Runic need appears.

### `Jido.Exec`

`Jido.Exec` is the public runtime facade.

Accepted inputs:

- action module,
- `Jido.Instruction`,
- `Jido.Flow`.

Responsibilities:

- normalize actions and instructions into one-node flows,
- compile flows to Runic workflows,
- run workflows to quiescence,
- step workflows one dispatch generation,
- resume prior execution results,
- validate runtime options,
- apply run context,
- apply scheduler policies,
- apply deadlines and max cycles,
- execute runnables through a worker boundary,
- capture telemetry,
- return `Jido.Exec.Result`.

Runtime policy options:

- `:run_context`
- `:scheduler_policies`
- `:scheduler_policies_mode`
- `:deadline_ms`
- `:deadline_at`
- `:max_cycles`
- `:checkpoint`

Exec should not become a generic workflow API. Raw Runic workflows can remain
an explicit advanced path outside the normal Jido surface.

### `Jido.Exec.ActionRunner`

The action invocation boundary should live under Exec.

Responsibilities:

- validate action contract,
- merge static params and resolved input,
- merge instruction context and runtime context,
- validate params,
- call `run/2`,
- normalize action return shapes,
- preserve `Jido.Action.Output`,
- validate normal map outputs,
- capture directives,
- normalize errors, throws, exits, and exceptions.

Params merge policy:

1. Start with `instruction.params`.
2. If resolved input is a map, merge it over static params.
3. If resolved input is not a map, expose it as `%{input: value}`.
4. Preserve the full resolved input under `:input` when the resolved input map
   does not already provide that key.

Context merge policy:

1. Start with `instruction.context`.
2. Merge runtime context over it.
3. Runtime context wins.

These rules are subtle and must stay well tested.

### `Jido.Exec.Result`

`Jido.Exec.Result` is the local execution result value.

Canonical shape:

```elixir
%Jido.Exec.Result{
  status: :ok | :error | :max_cycles,
  workflow: %Runic.Workflow{},
  results: term(),
  events: [],
  cycles: non_neg_integer(),
  error: nil | Exception.t(),
  directives: []
}
```

Responsibilities:

- cache execution results,
- expose refreshable result/event helpers through Exec,
- summarize execution,
- expose provenance,
- capture action directives from produced facts and failed runnables,
- eventually respect Flow-level `return`.

### `Jido.Exec.Telemetry`

Telemetry should stay low-cardinality.

Action spans should include:

- action module,
- package/runtime tags such as `:jido`,
- outcome,
- normalized error type,
- retryability,
- directive presence.

Action spans should not include:

- raw params,
- raw context,
- raw output payloads,
- unbounded user identifiers.

## ReAct Motivation

Flow must be capable of modeling a future LLM ReAct loop without becoming an LLM
package.

Generic ReAct shape:

```text
state
  -> reason(state)
  -> decide(final? or tool_call?)
  -> if final: return answer
  -> if tool_call: execute tool
  -> observe tool result
  -> update state
  -> repeat
```

Core Flow only needs:

- bounded `Loop`,
- action `Node`,
- `Jido.Instruction`,
- refs,
- select/merge/decide helper actions,
- Exec/Runic runtime policy.

The future LLM package should compile its higher-level builders into generic
Flow IR. Core Flow should not contain `:llm`, `:agent`, `:tool`, or `:react`
entry types.

## What Not To Build In Flow

Do not add canonical Flow entries for generic Runic concepts:

- generic transform,
- map,
- reduce,
- accumulate,
- raw workflow,
- subflow,
- generic step,
- saga,
- FSM,
- aggregate,
- process manager,
- scheduler policy.

Use a Jido action for small data transforms. Use Runic directly for generic
workflow primitives. Use higher-level packages for domain-specific orchestration.

## Testing Plan

Use TDD for each module.

Core test groups:

- action config validation,
- action param/output validation,
- output envelope validation,
- error normalization and serialization,
- instruction construction and normalization,
- action contract validation,
- Flow ref validation,
- Flow node construction,
- Flow dependency derivation,
- Flow built-in action lowering,
- Flow compiler edge derivation,
- Exec action/instruction/flow dispatch,
- Exec scheduler policy integration,
- Exec action boundary errors,
- Exec directives,
- Exec telemetry,
- Exec result helpers,
- Exec resume and max-cycle behavior.

Run focused tests while iterating. Run the broader suite when touching shared
boundaries such as Action, Instruction, Flow, Exec, Result, or Error.

## Milestones

1. Stabilize `Jido.Action`, `Jido.Instruction`, `Jido.Action.Output`, and
   `Jido.Action.Error` as the core action boundary.
2. Build `Jido.Exec.ActionRunner` and make all execution paths use it.
3. Rebuild `Jido.Flow` as the canonical Zoi-backed IR.
4. Compile Flow nodes to Runic workflows.
5. Make `Jido.Exec` run actions, instructions, and flows through one path.
6. Preserve output envelopes, directives, telemetry, and provenance.
7. Implement Flow return extraction.
8. Specify loop semantics in tests.
9. Implement loop compilation only after the semantics are clear.
10. Rebuild docs and examples from the v3 surface, not from legacy APIs.

## Known Risks

- `Node` may become too coupled to Runic if the IR struct also owns runtime
  component behavior. Move adapter logic behind the compiler if that coupling
  starts to obscure the IR.
- `hash` needs a clear contract: runtime identity, source-stable identity, or
  durable workflow identity.
- Root input resolution across resume and multiple runtime inputs must be
  explicit.
- Flow-level `return` must eventually affect result extraction.
- State refs should be rejected outside loop contexts or given clear semantics.
- Built-in Flow actions can quietly grow into a standard library. Keep them
  narrow.
- Direct action name derivation must avoid creating atoms from untrusted input.
- Telemetry must stay low-cardinality.
- Error details must remain useful without leaking sensitive params/context.

## Current North Star

The smallest useful v3 kernel is:

```text
Action + Instruction + Output + Error
  -> Flow(Node, Ref, Loop)
  -> Compiler
  -> Exec(ActionRunner, Result, Telemetry)
  -> Runic
```

Everything else should justify itself against that kernel.
