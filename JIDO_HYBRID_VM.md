# Jido Hybrid VM Design Notes

## Status

This document captures a design discussion about where `jido_action`, `jido`,
Runic, and the wider ecosystem may evolve. It is not an implementation spec yet.
It is intended to sharpen the architecture before API changes are made.

The central idea is that Jido is evolving from "agents that run actions" into a
stateful execution substrate. In that model, each agent acts like a small hybrid
virtual machine: it receives signals, interprets programs, invokes actions,
emits directives, updates state, and resumes over time.

## Core Thesis

The architecture becomes clearer if the system is described by this rule:

```text
Actions compute.
Programs compose.
Agents interpret.
Directives suspend.
Signals resume.
```

This keeps the boundary around `Jido.Action` crisp while still allowing Jido to
grow into richer graph/dataflow execution.

## Problem Statement

`Jido.Action` began as a simple and powerful concept:

- a single module pattern containing one discrete action
- a way to execute those actions reliably through `Jido.Exec`
- a struct to capture intent to run an action

As the ecosystem has grown, more concepts have accumulated around that center:

- workflows and plans
- tool conversion
- catalogs
- built-in tools
- lifecycle hooks
- compensation
- output directives
- async execution
- dynamic or LLM-generated actions
- graph and dataflow needs

The pressure point is composition. A single action is crisp when it is a leaf:

```text
validated input -> one unit of work -> validated output + optional directive
```

The boundary becomes blurry when an action invokes another action internally:

```elixir
def run(params, context) do
  with {:ok, a} <- Jido.Exec.run(ActionA, params, context),
       {:ok, b} <- Jido.Exec.run(ActionB, a, context) do
    {:ok, b}
  end
end
```

At that point the action is no longer just a leaf capability. It is also an
orchestrator. This hides composition inside opaque Elixir control flow and
makes it harder to inspect, schedule, trace, resume, optimize, or reason about
the program.

## FP Perspective

From a functional programming perspective, `Jido.Action` is best understood as
an explicitly effectful function boundary. It is close to a Kleisli-style arrow:

```text
params, context -> {:ok, output}
params, context -> {:ok, output, directive}
params, context -> {:error, reason}
params, context -> {:error, reason, directive}
```

Jido actions are not purely functional in the strict sense. They may perform
I/O, call APIs, write files, query databases, invoke tools, or produce agent
directives. The functional discipline comes from making the boundary explicit:

- inputs are validated
- outputs are validated
- failure is explicit
- continuation/effect requests are explicit
- execution policy is handled outside the action body

Composition should also be represented as data. A composition value can be
inspected, transformed, serialized, compiled, scheduled, replayed, resumed, and
interpreted. Hidden nested action calls lose those properties.

## Fundamental Concepts

The full architecture can be described with these conceptual units.

### Jido.Action

One executable capability.

An action is the smallest meaningful unit of work. It has a name, description,
Zoi input schema, Zoi output schema, and a `run/2` callback.

The action should not know about graph structure, scheduling, fan-out, fan-in,
workflow state, or agent program interpretation.

### Jido.Action.Contract

The verified static shape of an action.

A contract represents the part of an action that can be checked before
execution:

- module
- name
- description
- input schema
- output schema
- supported return shapes
- optional contract hash
- optional code version

The contract is the bridge between compile-time guarantees and runtime
verification.

### Jido.Invocation

One requested call to an action.

This is what `Jido.Instruction` is trying to be. It should be small:

```elixir
%Jido.Invocation{
  action: MyAction,
  params: %{},
  context: %{}
}
```

An invocation should not carry AST, source code, bytecode, or workflow
structure. It is a call frame, not a code artifact.

### Jido.Program

A pure composition value describing many invocations and their dependencies.

A program is where actions are composed:

```elixir
program =
  Jido.Program.new()
  |> Jido.Program.step(:validate, ValidateOrder)
  |> Jido.Program.step(:charge, ChargeCard, after: :validate)
  |> Jido.Program.step(:fulfill, FulfillOrder, after: :charge)
```

This is the conceptual successor to the useful parts of `Jido.Plan`, but it
should not become a hidden second action system. It should represent program
structure as data.

### Jido.Exec

The hardened invocation engine.

`Jido.Exec` should run one action or one invocation reliably. It should not
become the workflow runtime.

It owns:

- contract verification
- input validation
- timeout
- retry
- telemetry
- crash normalization
- return shape enforcement
- output validation
- directive preservation

It should not own:

- graph composition
- catalog lookup
- AI tool coercion
- workflow branching
- compensation workflows
- Runic graph semantics

### Jido.Runtime

The interpreter for programs.

This is the layer that takes a `Jido.Program`, determines what can run, invokes
steps through `Jido.Exec`, applies results, handles directives, and resumes over
time.

Runic can power this layer.

### Jido.Agent

A stateful VM instance.

An agent hosts state, receives signals, chooses or synthesizes programs, runs or
resumes programs, emits directives, and updates state.

In the hybrid VM model, an agent has:

```text
code      = actions
program   = program/graph of invocations
state     = agent state + context + memory
mailbox   = signals
effects   = directives
runtime   = invocation/program interpreter
scheduler = agent loop + supervision
```

### Jido.Signal

A message/event delivered to an agent or runtime.

Signals are the inputs that wake, resume, or alter a running agent VM.

### Jido.Directive

An explicit effect or continuation request.

Directives let actions or programs say "something else should happen" without
performing orchestration privately inside a leaf action.

Examples:

- run another program
- dispatch a tool call
- await external input
- emit a signal
- schedule continuation
- persist state

## Hybrid VM Model

The VM analogy is useful if it stays precise:

```text
Jido.Action     = instruction implementation / capability
Jido.Contract   = verified instruction signature
Jido.Invocation = instruction call frame
Jido.Program    = bytecode/control-flow/dataflow representation
Jido.Exec       = instruction executor
Jido.Runtime    = program interpreter
Jido.Agent      = VM instance
Jido.Signal     = VM message/event
Jido.Directive  = VM effect/continuation
```

The point is not to expose all of these nouns to every user. The point is to
keep the implementation concepts separated.

Beginner-facing vocabulary should be much smaller:

```text
Action  = one capability
Program = composition of actions
Agent   = stateful runner
```

Intermediate and advanced APIs can reveal `Exec`, `Signal`, `Directive`,
`Contract`, `Invocation`, `Runtime`, and the Runic backend as needed.

## Jido.Action Direction

`Jido.Action` should be trimmed back to the leaf concept.

### Keep

- `use Jido.Action`
- `name/0`
- `description/0`
- `schema/0`
- `output_schema/0`
- `validate_params/1`
- `validate_output/1`
- `run/2`
- an internal contract function such as `__jido_action__/0`
- three-tuple directive returns

### Standardize On Zoi

Zoi should be the single first-class schema system for action validation.

The action schema should be the source of truth:

```elixir
use Jido.Action,
  name: "send_email",
  description: "Sends one email",
  schema: Zoi.object(...),
  output_schema: Zoi.object(...)
```

NimbleOptions support should be considered compatibility-only. JSON Schema
should not be accepted as a first-class runtime schema in `Jido.Action`.

### Keep Three-Tuple Returns

Directive returns are important for the agent/runtime model:

```elixir
@type result ::
        {:ok, map()}
        | {:ok, map(), directive :: term()}
        | {:error, term()}
        | {:error, term(), directive :: term()}
```

Directives are how actions request continuation or effects without becoming
private orchestrators.

### Trim

These should not be first-class in the action macro:

- `category`
- `tags`
- `vsn`
- `compensation`
- `to_tool/0`
- `to_json/0`
- JSON Schema maps as action schemas
- NimbleOptions as the main schema path
- hidden aliases unrelated to the action contract
- hidden context mutation such as always injecting action metadata

`category`, `tags`, and `vsn` are catalog/discovery metadata.

`to_tool/0` is an adapter concern.

`compensation` is a workflow/runtime concern.

JSON Schema is an edge projection concern.

### Lifecycle Hooks

The default lifecycle hook surface should be cut aggressively.

Current hooks that should be questioned or removed:

- `on_before_validate_params/1`
- `on_after_validate_params/1`
- `on_before_validate_output/1`
- `on_after_validate_output/1`
- `on_after_run/1`
- `on_error/4`

With Zoi-only schemas, validation, coercion, defaults, and basic refinement
belong in Zoi. Business transformations belong in `run/2`. Compensation belongs
in the runtime or program layer.

`on_after_run/1` is especially questionable. It is exposed as a lifecycle hook,
but if it is not invoked by the execution path, it creates API surface without a
reliable semantic role.

The stronger default is: no lifecycle hooks until a concrete repeated need
cannot be expressed through Zoi, `run/2`, directives, or program composition.

## JSON Schema Position

JSON Schema matters across the ecosystem, especially for tools, catalogs, LLMs,
and external integrations. But it should be an edge representation, not the
runtime schema source.

Recommended rule:

```text
Jido.Action owns Zoi validation.
Tooling/catalog/LLM packages own JSON Schema projection.
Runtime validation should never silently skip because a schema is "tool-only".
```

Other packages can derive JSON Schema from Zoi:

```elixir
MyAction.schema()
|> Zoi.to_json_schema(...)
```

Useful improvements to discuss with the Zoi maintainer:

- stable and documented JSON Schema export
- export options for target dialects
- strict object export with `additionalProperties: false`
- predictable atom-key to string-key object property conversion
- preservation of descriptions, defaults, examples, enum values, and formats
- clear handling for refinements that cannot be represented in JSON Schema
- lossy export warnings

Example shape:

```elixir
{:ok, json_schema, warnings} =
  Zoi.to_json_schema(schema, target: :openai)
```

The important principle is that JSON Schema is a projection of the action
schema. If the projection is lossy, the adapter should say so.

## Jido.Exec Direction

`Jido.Exec` should move closer to the Elixir compiler by separating contract
verification from execution.

Today, `Exec.run/4` discovers and validates action shape at the point of use.
For hundreds of steps, hot code loading, or LLM-generated actions, it is useful
to gate execution through an explicit verification step.

Potential API:

```elixir
{:ok, contract} = Jido.Exec.verify(MyAction)
{:ok, result} = Jido.Exec.run(contract, params, context, timeout: 5_000)
```

Possible names:

- `verify/1`
- `load/1`
- `resolve/1`
- `compile_contract/1`

Avoid `prepare/1` if Runic's "prepare executable graph work" vocabulary remains
prominent. `verify/1` or `load/1` is clearer for action contracts.

### Verify Step Responsibilities

The verification step can:

- call `Code.ensure_compiled/1`
- verify the action behavior or contract function
- verify required exports
- validate Zoi schemas
- cache metadata/schema references
- compute a contract hash
- record code version
- produce a reusable action contract

Example structure:

```elixir
%Jido.Action.Contract{
  module: MyAction,
  name: "my_action",
  description: "Does one thing",
  schema: input_schema,
  output_schema: output_schema,
  returns: [:ok, :ok_directive, :error, :error_directive],
  contract_hash: "...",
  code_version: "..."
}
```

### Run Step Responsibilities

The run step should:

- validate/coerce input with Zoi
- execute `run/2`
- enforce valid return shape
- preserve directives
- validate output with Zoi
- apply timeout/retry/telemetry policy
- normalize crashes into structured errors

It should not compose multiple actions.

## Dynamic And LLM-Generated Actions

Dynamic actions cannot honestly have compile-time guarantees. They need a
compiler-like admission path:

```text
source/AST -> compile/load -> verify contract -> run invocation
```

Potential flow:

```elixir
{:ok, module, definition} = Jido.Action.Compiler.compile(source_or_ast)
{:ok, contract} = Jido.Exec.verify(module)
{:ok, result} = Jido.Exec.run(contract, params, context)
```

Source code, AST, bytecode, and provenance should not live in each invocation.
They belong in a separate definition/provenance artifact:

```elixir
%Jido.Action.Definition{
  module: MyGeneratedAction,
  source_hash: "...",
  ast_hash: "...",
  contract_hash: "..."
}
```

Invocations can reference the verified contract or module.

## Instruction, Invocation, And Prepared Actions

`Jido.Instruction` should probably shrink or be renamed conceptually to
`Jido.Invocation`.

The important distinction:

```text
Action module   = code definition
Contract        = verified executable shape
Invocation      = intent to call an action with params/context
Program         = composition of invocations
```

An invocation should not be the output of action verification. Verification
produces a reusable contract. Many invocations can reference one contract.

Example:

```elixir
contract = Jido.Exec.verify!(SendEmail)

invocation = %Jido.Invocation{
  action: contract,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant_123"}
}
```

This keeps invocations small, serializable, loggable, queueable, and durable.

## Composition Rules

The main design rule:

```text
Actions should not compose actions.
Programs compose actions.
```

Allowed:

```elixir
def run(params, context) do
  MyApp.Billing.charge(params, context)
end
```

Discouraged:

```elixir
def run(params, context) do
  Jido.Exec.run(OtherAction, params, context)
end
```

Preferred:

```elixir
def run(params, context) do
  {:ok, %{accepted: true}, %Jido.Directive.RunProgram{program: program}}
end
```

This preserves observability and keeps scheduling, retries, directives, and
provenance in the runtime.

### Compile-Time Smell Warning

It is feasible and useful to warn when a Jido action invokes another action via
`Jido.Exec`.

This should be a smell warning, not a proof of correctness.

Catch common cases:

```elixir
Jido.Exec.run(OtherAction, params)
Jido.Exec.run_async(OtherAction, params)

alias Jido.Exec
Exec.run(OtherAction, params)
```

Suggested warning:

```text
warning: nested Jido action execution inside MyApp.Actions.PlaceOrder.run/2

Calling Jido.Exec.run/4 inside an action makes composition opaque.
Prefer returning a directive, invocation, or program.

Set @jido_allow_nested_exec true if this action is intentionally an orchestrator.
```

Provide an escape hatch:

```elixir
@jido_allow_nested_exec true
```

or a global policy:

```elixir
config :jido_action, nested_exec: :warn
```

Possible modes:

- `:allow`
- `:warn`
- `:error`

Default should be `:warn`.

## Jido.Program And Runic

Runic should be understood as the graph/dataflow engine behind Jido's program
composition layer, not as something that leaks into `Jido.Action`.

The developer concept should be `Jido.Program`, even if the implementation is
powered by Runic.

```text
Jido.Program    = Jido-level semantic model
Runic.Workflow  = graph/dataflow backend
```

Runic's strengths:

- workflows as data
- graph composition
- facts and data dependencies
- fan-out and fan-in
- branching and reductions
- prepare/execute/apply lifecycle
- provenance through dataflow
- general-purpose workflow evaluation

Jido's strengths:

- agent-oriented execution substrate
- action contracts
- effectful capabilities
- signals
- directives
- stateful process lifecycle
- LLM/tool boundaries
- hardened execution policy

The clean boundary:

```text
Jido.Action  = effectful leaf
Jido.Program = pure composition value
Jido.Runtime = interpreter
Runic        = graph/dataflow backend
Jido.Agent   = stateful host
```

Developers should not need to know Runic to write a simple action or compose a
basic program. Advanced users can drop down to Runic-level graph power when they
need it.

## Jido.Plan Direction

`Jido.Plan` was trying to solve the right problem: action composition.

The issue is that it can drift into becoming a workflow runtime inside the
action package. If it grows graph scheduling, joins, branching, provenance,
facts, resumability, and runtime state, it becomes Runic-lite.

Recommended direction:

- replace or evolve `Jido.Plan` into `Jido.Program`
- keep it as a pure composition value
- let Runic power graph/dataflow execution
- deprecate rich workflow semantics in `jido_action`
- provide compatibility conversion if needed

Possible bridge:

```elixir
Jido.Program.from_plan(plan)
Jido.Plan.to_program(plan)
```

Long term, `Jido.Plan` should not be a peer to a Runic-backed program model.
There should be one blessed composition concept.

## Developer Cognitive Load

The architecture has many precise internal concepts. Exposing all of them at
once would create too much cognitive load.

The beginner-facing model should be:

```text
Action  = one capability
Program = composition of actions
Agent   = stateful runner
```

Intermediate model:

```text
Exec      = run one action reliably
Signal    = event/message
Directive = requested effect or continuation
```

Advanced model:

```text
Contract   = verified action shape
Invocation = one action call frame
Runtime    = program interpreter
Runic      = graph/dataflow backend
```

Documentation should use progressive disclosure:

1. write an action
2. run an action
3. compose actions into a program
4. let an agent run programs over time
5. understand directives/signals
6. understand contracts/runtime/backend details

This allows the system to be powerful without making every user carry the whole
VM model in their head.

## Possible API Sketches

These sketches are not final names.

### Action

```elixir
defmodule MyApp.Actions.SendEmail do
  use Jido.Action,
    name: "send_email",
    description: "Sends one email",
    schema: @schema,
    output_schema: @output_schema

  @impl true
  def run(params, context) do
    {:ok, %{message_id: id}}
  end
end
```

### Contract Verification

```elixir
{:ok, contract} = Jido.Exec.verify(MyApp.Actions.SendEmail)
{:ok, result} = Jido.Exec.run(contract, params, context)
```

### Invocation

```elixir
invocation = %Jido.Invocation{
  action: contract,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant_123"}
}

Jido.Exec.run(invocation)
```

### Program

```elixir
program =
  Jido.Program.new(:checkout)
  |> Jido.Program.step(:validate, ValidateOrder)
  |> Jido.Program.step(:charge, ChargeCard, after: :validate)
  |> Jido.Program.step(:fulfill, FulfillOrder, after: :charge)
```

### Directive From An Action

```elixir
def run(params, context) do
  program = build_followup_program(params, context)

  {:ok, %{accepted: true}, %Jido.Directive.RunProgram{program: program}}
end
```

### Agent As VM

```elixir
def handle_signal(signal, state) do
  program = choose_program(signal, state)
  {:run, program, state}
end
```

## Non-Goals

This direction should not:

- make `Jido.Action` graph-aware
- make actions responsible for orchestration
- make JSON Schema a runtime validation source
- force every user to learn Runic
- hide action composition inside `run/2`
- make `Jido.Exec` a workflow runtime
- require dynamic actions to pretend they have compile-time guarantees

## Open Questions

- Should `Jido.Instruction` be renamed to `Jido.Invocation`, or should the old
  name remain for compatibility?
- What is the best public name for action contract verification: `verify/1`,
  `load/1`, `resolve/1`, or something else?
- Should `Jido.Program` be a public module name, or should another word better
  fit the developer model?
- How much Runic vocabulary should be visible in advanced APIs?
- Should nested action invocation warnings live in the macro, Credo, or both?
- Should `Jido.Action` keep any lifecycle hooks at all?
- What is the minimum directive protocol needed for program execution and agent
  resumption?
- How should contract hashes and code versions be computed for hot-loaded
  modules?
- How should lossy Zoi-to-JSON-Schema projection warnings be represented?

## Recommended Next Steps

1. Trim `Jido.Action` around the Zoi-only leaf contract.
2. Make three-tuple directive returns explicit in the action callback type.
3. Remove or deprecate lifecycle hooks that do not have a clear runtime role.
4. Add nested `Jido.Exec.run` compile-time warnings in action modules.
5. Introduce action contract verification in `Jido.Exec`.
6. Shrink `Jido.Instruction` toward invocation semantics.
7. Define `Jido.Program` as the single developer-facing composition concept.
8. Use Runic as the program/dataflow backend without making actions graph-aware.
9. Reposition or deprecate `Jido.Plan` in favor of `Jido.Program`.
10. Document the progressive learning path: Action, Program, Agent first;
    Exec, Signal, Directive second; Contract, Invocation, Runtime, Runic
    backend third.

## Summary

Jido's architecture becomes sharper when `Jido.Action` remains a leaf executable
capability and composition moves into an explicit program value.

The hybrid VM model gives the ecosystem a coherent spine:

```text
Actions compute.
Programs compose.
Agents interpret.
Directives suspend.
Signals resume.
```

Runic can power program/dataflow semantics, but the Jido developer model should
remain centered on actions, programs, agents, signals, and directives.

