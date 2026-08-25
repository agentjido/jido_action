# Jido.Flow and Runic Design Plan

Status: Complete on `v3-spike`.

The canonical Flow data design, native Runic execution, and test architecture
are implemented. This document is now the fixed design baseline for
`Jido.Flow`. New package simplification work builds on this baseline. See
`JIDO_PKG_SIMPLIFY.md`.

## Implementation status

Stages 1 through 13 are implemented:

- `%Jido.Flow{}` and all canonical component structs
- One expression, reference, condition, and portable data grammar
- Strict structural and executable validation
- `Jido.Flow.Codec.encode/2` and `decode/2` with the trusted Registry
- Direct, Builder, Spark, and stored JSON convergence
- Step-only Subflow derivation
- A separate Spark source map
- The derived `Jido.Flow.Compiled` data container
- Removal of the old authoring aliases, inference layers, and duplicate models
- Native Runic Step, Map, Reduce, Workflow, FanOut, FanIn, Join, and
  InputBinding execution
- Direct native Map-to-Reduce fan-in and scalar Map collection
- Native Runnable step-wise execution without a second Jido scheduler
- Removal of `NodeResult`, `MapResult`, and the temporary runtime compiler
- A migrated Runic execution test suite and user documentation
- A Splode-based `Jido.Flow.Error` boundary for Flow definition, compilation,
  native execution, and execution-state failures
- One `Jido.Executable` target contract for Actions, Flow modules, and runtime
  Flow values
- `Jido.Instruction.target` support for all three executable target forms,
  including Flow options and step-wise execution for Flow targets
- Transitive Subflow source paths, sibling instance identity, recursive module
  cycle checks, and transitive child compilation digests
- Stored Codec limits and JSON round trips for string, integer, and registered
  atom map keys

The phase-three test architecture pass is also implemented:

- Data, Codec, compilation, and execution have explicit test owners.
- One `JidoActionTest.Fixtures` namespace and six fixture files replace four
  fixture roots and 12 files. The files use `action`, `flow`, `codec`, and
  `execution` folders.
- Direct, Builder, Spark, and JSON parity use one canonical mixed Flow and one
  trusted Registry fixture.
- Action, Instruction, Flow-adapter, process-ownership, and Flow component
  execution contracts have focused test files.
- Public Choice, Map, Reduce, reference, and condition runtime behavior moved
  out of compiler tests.
- Duplicate Codec and Registry cases moved out of general Flow validation.
- Nineteen dead fixture modules and unused helper functions were removed.
- Killed Action containment covers Action modules, Action Instructions, Flow
  values, Flow modules, Flow Instructions, and Subflows.
- `Jido.Exec.Supervisor` owns the Task Supervisor, concurrency Registry, and
  concurrency DynamicSupervisor. Action data has no supervisor ownership.
- Jido Action v2 had a `Jido.Exec.Supervisors` resolver for instance-scoped
  Task Supervisors. V3 keeps the useful `jido:` contract in the smaller
  `Jido.Exec.Supervisor` module. `jido: MyApp.Jido` routes all Action workers,
  including Flow and Subflow work, through `MyApp.Jido.TaskSupervisor`. This
  matches Jido core. A missing instance is an error. There is no silent global
  fallback.
- The Flow concurrency Registry and DynamicSupervisor stay Exec-global. Their
  workers are short-lived and keyed by a unique execution ID. Jido core does
  not need a second per-instance Exec tree.
- Flow module execution compiles the exact `flow/0` value with its source map.
  It does not trust an independent `compiled/0` result.

The shared executable resolver uses `Jido.Action.Error.ConfigurationError` for
failures that occur before it knows the executable kind. Flow-owned failures
use `Jido.Flow.Error`. An Action failure inside a Flow keeps its original
`Jido.Action.Error` type. There is no separate `Jido.Executable.Error` or
`Jido.Exec.FlowFailureError` model.

Verification for this implementation:

- `mix test`: 315 tests passed and 2 tests were excluded.
- `mix test.integration`: 2 integration tests passed.
- `mix test --cover --warnings-as-errors`: total coverage is 93.13%.
- `mix quality`: formatting, compilation with warnings as errors, Credo, and
  Dialyzer passed.
- `mix docs --warnings-as-errors`: the public documentation build passed.

## Goal

Define one canonical authoring data type for `Jido.Flow`.

The canonical value must be a `%Jido.Flow{}` struct. The Spark DSL, runtime
Builder, stored JSON, and direct construction must produce this value. The
value must describe a local Jido workflow that can compile into native Runic
components.

Jido Actions are the executable leaf units. A Flow module is also
Action-compatible. When a Spark `step` names a Flow module, the lowerer derives
one canonical `Jido.Flow.Subflow` component. A Flow keeps the Jido Action input
validation, output validation, and `run/2` pattern at each Flow boundary.

## Fixed constraint

Do not change the public Spark DSL shape.

Keep these Spark terms and forms:

- `step`, `choice`, `option`, `otherwise`, `map`, `reduce`, `iterate`, `state`,
  and `output`
- `params`, `after`, `meta`, `on_error`, `while`, `repeat`, and
  `max_iterations`
- The current reference helpers and condition operators

Spark can continue to use DSL entity structs because Spark stores quoted
syntax in them. These structs are parser data. They are not canonical Flow
data. The Spark lowerer is the only Spark syntax adapter.

Subflow scope is fixed:

- Only `step action:` can derive a Subflow.
- Choice option, Choice fallback, Map, Reduce, and Iterate `action` fields are
  Action-only.
- A Flow module in an Action-only field is a validation error.
- The compiler must not generate a replacement graph for that error.

## Native Runic design rule

Prefer native Runic components, ports, cardinality, and connection semantics.
Do not preserve a Jido runtime model when native Runic already supplies the
same workflow concept.

Use native Runic Step, Map, Reduce, Connection, FanOut, FanIn, InputBinding,
and Join behavior where their semantics match the Flow construct. Do not add a
Jido aggregate or graph model around these components.

When a Jido construct does not match a specialized Runic construct, lower it
to the smallest correct composition of native Runic Steps. Do not force Choice
into independent Rules or Iterate into StateMachine. Correct semantics are
more important than matching component names.

## Phase-one baseline findings

The code inspected before this implementation had these design problems. The
implemented stages resolve them:

- `%Jido.Flow{}` stores `nodes` and `return`, but the DSL uses `params`,
  `after`, `meta`, and `output`. See `lib/jido_flow.ex` and
  `lib/jido_flow/dsl/extension.ex`.
- Validation writes inferred reference dependencies into the authored `deps`
  field. See `normalize_node_deps/1` in `lib/jido_flow/validation.ex`.
- The DSL, Builder, and JSON decoder make intermediate maps. They pass these
  maps to `Jido.Flow.Constructor`. See `lib/jido_flow/dsl/lowerer.ex`,
  `lib/jido_flow/builder.ex`, and `lib/jido_flow/map_codec.ex`.
- `Jido.Flow.Element` accepts several shapes and infers old variants. See
  `lib/jido_flow/element.ex`.
- The JSON decoder infers Step or Choice when a stored record has no explicit
  kind. See `lib/jido_flow/map_codec/decoder.ex`.
- Literal expressions do not have one canonical representation. The DSL wraps
  literals in `Ref.value/1`, but other paths can keep bare literals. See
  `lib/jido_flow/dsl/expression.ex` and `lib/jido_flow/expression.ex`.
- The compiler wraps every Jido component in a generic Runic Step. It does not
  use native Runic Map, Reduce, or Rule components. See
  `lib/jido_flow/compiler.ex`.
- Current Choice execution checks options in order, stops at the first true
  condition, and uses the fallback only when all options are false. See
  `lib/jido_flow/compiler/choice.ex`.
- Current Map execution returns one `MapResult` aggregate with separate result
  and error lists. See `lib/jido_flow/compiler/map.ex` and
  `lib/jido_flow/compiler/map_result.ex`.
- Current Iterate execution is a bounded local pre-test loop. It validates
  local state for each update and fails on maximum-iteration exhaustion. See
  `lib/jido_flow/compiler/iterator.ex`.

The installed Runic source gives these useful design rules:

- `Runic.Component` supports native Step, Rule, Map, Reduce, Accumulator,
  StateMachine, and Workflow components. See
  `deps/runic/lib/workflow/component.ex`.
- `Runic.Workflow.Connection` stores author connection intent. Runic lowers
  this data into internal `InputBinding` and `Join` nodes. See
  `deps/runic/lib/workflow/connection.ex` and `deps/runic/lib/workflow.ex`.
- A Runic Workflow contains graphs, hashes, components, build events, inputs,
  mapped paths, and runtime state. It is derived runtime data. See
  `deps/runic/lib/workflow.ex`.
- Runic Map uses FanOut and has cardinality-many output. Runic Reduce uses
  FanIn and can connect directly to a Map. See
  `deps/runic/lib/workflow/component.ex`.
- Runic Rules are independent condition/reaction components. They do not
  define an ordered, exclusive Choice container. See `deps/runic/lib/runic.ex`
  and `deps/runic/lib/workflow/rule.ex`.
- Runic execution has prepare, execute, and apply phases. See
  `deps/runic/lib/workflow/invokable.ex`.
- Runic StateMachine keeps state across workflow invocations and runs reactive
  rules. This does not match the local bounded Jido Iterate operation. See
  `deps/runic/lib/workflow/state_machine.ex`.
- `Jido.Executable.resolve/1` returns an exact `:action` or `:flow` descriptor.
  A module owns this descriptor through `__jido_executable__/0`. This gives the
  Spark lowerer a trusted derivation rule. It does not need callback or field
  inference. See `lib/jido_executable.ex`.
- Current Jido execution accepts Flow modules in Step, Choice, Map, Reduce, and
  Iterate Action positions. The tests also require each nested Flow input and
  output boundary to run once. See `test/jido_exec/choice_runtime_test.exs`,
  `test/jido_exec/collection_runtime_test.exs`, and
  `test/jido_exec/execution_continuation_test.exs`.
- A Runic Workflow with input or output ports is a native nested component.
  Runic stores its boundary and child build log as one Workflow definition.
  See the nested Workflow boundary code in `deps/runic/lib/workflow.ex` and
  `deps/runic/lib/workflow/definition.ex`.
- Runic does not make a new instance of repeated child internals. Its Workflow
  component implementation merges the child graph and component map. A local
  check with two copies of one child produced two boundary components but one
  shared internal Step. Jido must compile each Subflow instance with scoped
  names and hashes.

## 1. Canonical Jido.Flow struct

Use this public authoring type:

```elixir
@type t :: %Jido.Flow{
  name: String.t(),
  description: String.t() | nil,
  schema: Zoi.schema() | [],
  output_schema: Zoi.schema() | [],
  components: [Jido.Flow.Component.t()],
  output: Jido.Flow.Expression.t()
}
```

Field rules:

- `name` is a nonempty string.
- `description` is optional.
- `schema` and `output_schema` use the same static Zoi rules as
  `Jido.Action`.
- `components` contains canonical component structs.
- The component list preserves author declaration order.
- Declaration order does not create an execution dependency.
- `output` is required and uses the common expression grammar.

The Flow struct must not contain:

- A dependency graph
- Effective dependencies
- A topological order
- Runic components or hashes
- Runtime input or context
- Runtime results or events

The in-memory struct does not need a format version. The stored JSON envelope
has a version.

Each component has these common fields:

```elixir
name: String.t()
after: [String.t()]
meta: Jido.Flow.Data.object()
```

`after` contains only explicit author control order. It does not contain
dependencies inferred from references.

`meta` contains explicit author metadata. It uses the same portable data
grammar as literal expression data. It does not contain functions, PIDs,
references, arbitrary structs, or DSL source locations.

The Spark compiler keeps file, line, column, and entity annotations in a local
source table. It uses this table for compile errors and passes it to
`Jido.Flow.Compiled.source_map` for inspection and runtime diagnostics. This
source table is parser and diagnostic data. It is not part of `%Jido.Flow{}`,
semantic equality, semantic identity, or stored JSON. Do not merge explicit
`meta` data with compiler-generated source data.

Dependency analysis returns separate data:

```elixir
%{
  "charge" => %{
    after: ["authorize"],
    references: ["load_customer"],
    effective: ["authorize", "load_customer"]
  }
}
```

Validation and compilation can use this result. They must not write it into
the Flow.

## 2. Canonical component structs

All authoring structs use `Zoi.struct/3`, strict known keys, `new/1`, and
`new!/1`. `Jido.Flow.Expression` is not a struct. It is the type, validation,
traversal, codec, and resolution module for the expression data union.

### Jido.Flow.Step

```elixir
%Jido.Flow.Step{
  name: String.t(),
  action: module(),
  params: Jido.Flow.Expression.t(),
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}
```

Lower this component to one `Runic.Workflow.Step`. The Step runs the Jido
Action through the normal Jido Action runner.

The `action` must resolve to a `Jido.Executable` descriptor with kind
`:action`. A canonical Step does not store a Flow module as an Action. The
Spark lowerer and Builder derive a Subflow before they construct canonical
data.

Replace `Jido.Flow.Node` with `Jido.Flow.Step`. This makes the canonical name
equal to the existing Spark DSL term.

### Jido.Flow.Subflow

```elixir
%Jido.Flow.Subflow{
  name: String.t(),
  flow: module(),
  params: Jido.Flow.Expression.t(),
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}
```

`flow` is a module that has an exact `Jido.Executable` descriptor with kind
`:flow`. The field does not contain an inline `%Jido.Flow{}` value.
The module reference keeps the parent artifact small, gives the Registry a
stable trusted resolution point, and prevents a second recursive JSON form.

Subflow has no new Spark term. The unchanged syntax is:

```elixir
step "charge",
  action: MyApp.ChargeFlow,
  params: %{order: result("load")}
```

The Spark lowerer ensures that `MyApp.ChargeFlow` is compiled and calls
`Jido.Executable.resolve/1`. It constructs a Step for kind `:action` and a
Subflow for kind `:flow`. It reports any other result at the source location
of the `step`. This is descriptor resolution, not legacy shape inference.

This derivation applies only to a top-level Spark `step` entity and to the
matching `Builder.step` operation. It does not apply to an `action` field in a
Choice option, Choice fallback, Map, Reduce, or Iterate. Those four component
types contain Action execution slots, not independent Flow components.

Lower Subflow to one native Runic Workflow boundary. The child Workflow has
one input port for resolved `params` and one output port for the validated
child Flow result. Compiler-owned entry and exit Steps keep these boundary
rules:

- Validate the child Flow input once.
- Make the child input available to child `input` references.
- Evaluate the child Flow output expression once.
- Validate the child Flow output once.
- Keep the parent context and execution identifier.
- Keep the child error path in the parent Flow lifecycle. Do not add a separate
  child Flow lifecycle around the native Workflow boundary.

The Runic boundary is one parent component. Its internal child components are
native Runic components. Parent result references read the boundary output.
The Jido stepwise API exposes native Runic runnables. A nested Workflow is not
one runnable. Its entry validator, internal components, output resolver, and
output validator can appear as separate Runic runnables. Do not add a Jido
boundary scheduler to group or hide them.

Each Subflow `name` is also an instance identity. The compiler recursively
compiles the child with a path namespace such as `parent/charge`. It gives the
boundary and every child Runic component a deterministic name and hash in
that namespace. This prevents two uses of the same Flow module from sharing
Runic vertices, facts, hooks, or component lookup entries. Do not depend on a
captured function value to make these hashes different.

Recursive compilation keeps a module stack and rejects a cycle such as
`AFlow -> BFlow -> AFlow`. Two sibling instances of the same child are valid.
The compiled cache key includes the compiler version and the transitive child
Flow identities. A change in a child Flow must invalidate its parent compiled
value.

### Action-only embedded targets

The `action` fields in Choice options, Choice fallback, Map, Reduce, and
Iterate must resolve to executable kind `:action`. If one of these fields
resolves to kind `:flow`, executable validation returns an error at that exact
field. The Spark compiler attaches the related source location.

Do not create an Action-or-Flow target union for these fields. Do not lower an
embedded Flow target through the nested Flow adapter. Do not move an embedded
target into a generated top-level Subflow because that can change Choice,
Map, Reduce, or Iterate semantics.

### Jido.Flow.Choice

```elixir
%Jido.Flow.Choice{
  name: String.t(),
  options: [Jido.Flow.Choice.Option.t()],
  fallback: Jido.Flow.Choice.Fallback.t(),
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}

%Jido.Flow.Choice.Option{
  name: String.t(),
  condition: Jido.Flow.Condition.t(),
  action: module(),
  params: Jido.Flow.Expression.t()
}

%Jido.Flow.Choice.Fallback{
  action: module(),
  params: Jido.Flow.Expression.t()
}
```

A native Runic Rule does not give a first-match Choice container. Independent
Rules can all match the same input. Rewriting each later condition to exclude
all earlier conditions causes repeated evaluation and requires a generated
branch-result merge. It can also change Jido condition-error behavior.

Keep Choice as one Jido authoring type. Lower it to a small native Runic Step
pipeline:

1. A selector Step resolves the conditions once in declared order. It returns
   the selected option or the required fallback, with resolved Action params.
2. An Action dispatcher Step runs exactly the selected Jido Action through the
   normal Jido Action runner.
3. The dispatcher output is the Choice output.

The compiler can combine these into one Runic Step if separate selector and
Action scheduling is not required. Do not lower Choice to a set of independent
Rules in the first implementation.

### Jido.Flow.Map

```elixir
%Jido.Flow.Map{
  name: String.t(),
  collection: Jido.Flow.Expression.t(),
  action: module(),
  params: Jido.Flow.Expression.t(),
  on_error: :fail_fast | :collect_errors,
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}
```

Lower Map to one native `Runic.Workflow.Map`. Its pipeline contains one native
Step that runs the Jido Action.

The runtime supplies `item`, `item_index`, and `item_id` data to the parameter
resolver. This data is runtime data. It is not stored in the Map struct.

For `:fail_fast`, an Action failure fails the Map path. For
`:collect_errors`, the Action Step converts each error into portable output
data. The Map still uses native Runic FanOut behavior.

Map uses native Runic cardinality-many output. Remove the current `MapResult`
aggregate. The compiler also adds one native scalar collector branch to each
Map. This makes an input-index-ordered list available to any normal result
expression without a second reference-use planning pass. A direct Reduce
consumes the many-valued Map port and bypasses the collector. The approved
contract is in the design-decisions section.

### Jido.Flow.Reduce

```elixir
%Jido.Flow.Reduce{
  name: String.t(),
  collection: Jido.Flow.Expression.t(),
  initial: Jido.Flow.Expression.t(),
  action: module(),
  params: Jido.Flow.Expression.t(),
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}
```

Lower Reduce to one native `Runic.Workflow.Reduce`. Its reducer resolves
`item` and `accumulator` references, then runs the Jido Action through the
normal Action runner.

When Reduce consumes Map output, connect the native Reduce FanIn directly to
the native Map path.

### Jido.Flow.Iterate

```elixir
%Jido.Flow.Iterate{
  name: String.t(),
  action: module(),
  params: Jido.Flow.Expression.t(),
  state: Jido.Flow.Iterate.State.t(),
  completion: Jido.Flow.Condition.t(),
  max_iterations: pos_integer(),
  after: [String.t()],
  meta: Jido.Flow.Data.object()
}

%Jido.Flow.Iterate.State{
  schema: Zoi.schema() | [],
  initial: Jido.Flow.Expression.t(),
  update: Jido.Flow.Expression.t()
}
```

Replace `Jido.Flow.Iterator` with `Jido.Flow.Iterate`.

Do not lower Iterate to Runic StateMachine. The semantics do not match. Lower
Iterate to one native Runic Step that owns the bounded local loop. Each loop
body call is still a Jido Action call.

The unchanged Spark lowerer converts `while` or `repeat` into canonical
`completion` and `max_iterations` data.

### Component union

Use a type union:

```elixir
@type Jido.Flow.Component.t() ::
        Jido.Flow.Step.t()
        | Jido.Flow.Subflow.t()
        | Jido.Flow.Choice.t()
        | Jido.Flow.Map.t()
        | Jido.Flow.Reduce.t()
        | Jido.Flow.Iterate.t()
```

This module can be type-only. Do not replace `Jido.Flow.Element` with another
map conversion and inference layer.

Do not implement `Runic.Component` directly for canonical Jido authoring
structs. Reference binding and control connections need Flow-wide context.
The Flow compiler creates native Runic components. Runic protocols apply to
those derived components.

### Runic type coverage

Do not add another canonical Flow component only to mirror each Runic struct.
Add a Jido authoring type only when the unchanged Flow authoring model has the
same semantics and needs to preserve author intent.

| Runic type | Jido representation | Decision |
| --- | --- | --- |
| `Step` | `Jido.Flow.Step` and internal Steps for Choice and Iterate | Include |
| `Map` | `Jido.Flow.Map` | Include with native many cardinality |
| `Reduce` | `Jido.Flow.Reduce` | Include with native FanIn |
| `Condition` | `Jido.Flow.Condition` data inside Choice or Iterate | Do not add a top-level component |
| `Rule` | No direct type | Do not use it to emulate ordered Choice |
| `Connection` | Derived from `after` and result references | Do not duplicate author intent |
| `Workflow` | `%Jido.Flow{}` and `Jido.Flow.Subflow` | Compile a Subflow as a native Workflow boundary |
| `Accumulator` | No local Flow equivalent | Exclude because its state persists across invocations |
| `StateMachine` | No local Flow equivalent | Exclude because Iterate is a bounded local loop |
| `FSM` | No local Flow equivalent | Exclude because it is event-driven persistent state |
| `Aggregate` | No local Flow equivalent | Exclude because it adds CQRS and event-sourcing semantics |
| `ProcessManager` | No local Flow equivalent | Exclude because it is reactive cross-aggregate coordination |
| `Saga` | No current Flow equivalent | Defer until compensation is an explicit Jido requirement |
| Tuple pipeline syntax | No data type | Exclude because it is Runic authoring syntax |

Runic `FanOut`, `FanIn`, `Join`, `InputBinding`, Facts, Runnables, events,
call contracts, hashes, and scheduler state are compiled or runtime data. They
must not appear in canonical Flow data.

Runic SchedulerPolicy is execution policy, not workflow author intent in the
current Flow DSL. Keep retry, timeout, priority, durability, executor, and
circuit-breaker settings in `Jido.Exec` or compiler options. Do not add them to
the canonical Flow until Jido defines a portable policy contract.

Subflow is the only added component that the Runic coverage review requires.
It does not need a new Spark form because the trusted executable descriptor
can derive it from the current `step action:` field.

## 3. One data, expression, reference, and condition grammar

Use one grammar in all authoring and storage paths:

```text
data :=
    nil
  | boolean
  | finite_number
  | string
  | atom
  | list(data)
  | map(portable_key, data)

expression :=
    data_scalar
  | list(expression)
  | map(portable_key, expression)
  | reference

reference :=
  %Jido.Flow.Ref{
    source: source,
    component: String.t() | nil,
    path: [path_segment]
  }

source :=
    :input
  | :context
  | :result
  | :item
  | :item_index
  | :item_id
  | :accumulator
  | :state
  | :iteration_index
  | :body_result

condition :=
    %Jido.Flow.Condition{
      operator: comparison_operator,
      operands: [expression, expression]
    }
  | %Jido.Flow.Condition{
      operator: :all | :any,
      operands: [condition, ...]
    }
  | %Jido.Flow.Condition{
      operator: :not,
      operands: [condition]
    }
```

Grammar rules:

- `component` is present only when `source` is `:result`.
- A path segment is an atom, string, or nonnegative integer.
- `data_scalar` is `nil`, a boolean, a finite number, a string, or an atom.
- A portable key is a string, a nonnegative integer, or an atom.
- Structural validation can accept an in-memory atom without a Registry. The
  stored encoder requires a trusted Registry identifier for that atom.
- Functions, tuples, arbitrary structs, and executable terms are not
  expressions or metadata.
- Remove the `:value` reference type and the `value` field from `Ref`.
- A literal stays a literal in the canonical value.
- The unchanged Spark `value/1` form lowers to a bare literal.
- Conditions use the same expression validator and resolver.
- One traversal collects result references from expressions and conditions.
- Validation, dependency analysis, JSON, and compilation use this traversal.

`Jido.Flow.Data` owns validation for portable literal and `meta` data.
`Jido.Flow.Data.object()` is the portable map subtype used by component
`meta`. `meta` defaults to `%{}`.
`Jido.Flow.Expression` owns the expression union. It is not an authoring
struct. `Jido.Flow.Ref` and `Jido.Flow.Condition` are strict Zoi-backed
structs.

Stored JSON uses explicit tagged records for references and conditions. It
uses one explicit entry-list record for every expression or `meta` map. This
preserves atom, string, and integer keys and prevents a user map from looking
like a `$ref` or condition record. User-data atoms use trusted Registry
identifiers. Closed Flow enums such as reference sources, condition operators,
component kinds, and `on_error` values use fixed codec tables and do not need
Registry entries.

## 4. Layer boundaries

### Authoring data

This layer contains only the canonical Flow, component, reference, condition,
and nested authoring structs.

It has no Runic graph and no runtime values.

### Structural validation

`Jido.Flow.validate/1` checks:

- The canonical struct shapes
- Known fields
- Names and duplicate names
- Expression and condition scopes
- Known result references
- Explicit `after` references
- Cycles in effective dependencies
- Static input, output, and Iterate state schemas
- Required explicit Flow output

This function is inert. It does not load target modules, run code, merge
dependencies, or change the Flow.

### Trusted resolution and executable validation

Executable validation checks:

- Each Step resolves with kind `:action`. If its module resolves with kind
  `:flow`, the authoring adapter must have derived a Subflow before this phase.
- Each Choice option, Choice fallback, Map, Reduce, and Iterate target resolves
  with kind `:action`. Kind `:flow` is an error in these positions.
- Each Subflow module resolves with kind `:flow`.
- Required Action-compatible callbacks exist.
- A Subflow module provides `flow/0` and returns a valid child Flow.
- Recursive Subflow references do not form a module cycle.
- Required schema modules and values are available.
- No canonical Step uses a Flow module as an Action.

This is an internal compilation phase. A separate public
`validate_executable/1` function can remain for inspection, but execution and
codec code must use the same compiler-owned validation function.

### Required stored codec and trusted Registry

All database and transport JSON must go through `Jido.Flow.Codec` and a trusted
`Jido.Flow.Registry`. This is a required boundary, not an optional helper.

The codec converts between a canonical `%Jido.Flow{}` and a JSON-compatible
document map. A JSON library can convert that document to or from bytes. Do
not derive a stored record by applying a generic JSON encoder directly to the
Flow struct.

Encoding requires Registry identifiers for:

- Each Action module
- Each Subflow module
- Each Flow input, output, and Iterate state schema
- Each user-data atom, including atom literals, atom map keys, and atom path
  segments

Extend the trusted Registry kind union to `:action | :flow | :schema | :atom`.
A `{:flow, module}` write entry is valid only for a module that later resolves
with executable kind `:flow`. Registry construction can remain data-only.
Executable validation performs the module check before compilation or use.

Decoding requires the corresponding trusted Registry entries. It is not
sufficient that a module with a matching name exists. The codec must never
convert an untrusted module-name string into a module atom.

The stored JSON reader performs these steps:

1. Check the untrusted record shape and resource limits.
2. Decode the closed expression grammar.
3. Resolve Action, Flow, schema, and atom identifiers through the host
   registry.
4. Construct canonical component structs.
5. Call `Jido.Flow.new/1`.

The reader must not create atoms or derive module names from JSON strings.
The encoder must validate the canonical Flow before it produces stored data.
The decoder must reject unknown fields, unknown kinds, unknown identifiers,
and unsupported format versions.

For a valid Flow and a Registry that contains all required identifiers, this
must hold:

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
{:ok, decoded} = Jido.Flow.Codec.decode(document, registry)
decoded == flow
```

This equality includes component order, explicit `after` order, expressions,
schemas after Registry resolution, and portable `meta`. DSL source data is not
part of either value.

### Runic compilation

Compilation accepts a validated Flow and returns internal derived data:

```elixir
%Jido.Flow.Compiled{
  workflow: %Runic.Workflow{},
  component_index: map(),
  output: Jido.Flow.Expression.t(),
  source_map: Jido.Flow.Compiled.source_map(),
  compilation_digest: binary()
}
```

`Jido.Flow.Compiled` is not an authoring type. It is not stored.
`output` is the validated canonical output expression. Runtime result handling
resolves it against the completed native Runic results. A second output selector
type is not required.
`source_map` is optional diagnostic data. Spark compilation supplies it.
Builder, JSON, and direct construction can compile with an empty source map or
with source data supplied by the caller. It does not affect workflow hashes,
semantic identity, or execution results.

`compilation_digest` is derived data. It includes the compiler version and
the semantic identities of all resolved child Flows. Use it for compiled
cache validation. It is not the direct semantic identity of the parent
authoring value.

Use canonical data paths as source-map keys, for example:

```elixir
%{
  [:components, "load"] => %{file: "flow.ex", line: 12, column: 3},
  [:components, "route", :options, "priority"] =>
    %{file: "flow.ex", line: 20, column: 5},
  [:output] => %{file: "flow.ex", line: 31, column: 3}
}
```

This supports component, Choice branch, Iterate state, and output diagnostics
without adding source fields to each authoring struct.

The compiler:

- Converts `after` into readiness connections or gates. These connections do
  not become Action params and do not change the value resolved by an
  expression.
- Converts result references into dependency readiness and expression data.
- Uses Runic selectors and target paths at native Workflow boundaries.
- Lets Runic generate InputBinding, Join, FanOut, and FanIn nodes.
- Keeps a name-to-component and name-to-output-port index.
- Recursively compiles each Subflow as an instance-scoped Runic Workflow
  boundary.
- Prefixes child source-map paths with the parent Subflow component path.
- Rejects recursive module cycles before it builds a Runic graph.
- Copies diagnostic source locations into `source_map` without copying them
  into the Flow or Runic component metadata.
- Does not change the Flow.

Runic named-port Connections carry data at Workflow boundaries. Jido `after`
carries only control intent. For local components, one native Join can wait for
both reference and `after` predecessors. The expression resolver reads values
only for declared result references, so `after` output never enters Action
parameters. This removes a second gate when one Join is sufficient.

Runic logical Connections are a useful model for this boundary. The authored
connection stays distinct from the internal executable nodes that Runic
generates.

### Execution

Execution keeps the Action pattern:

1. Validate Flow parameters.
2. Compile the exact executable Flow value returned by `flow/0`.
3. Use Runic prepare, execute, and apply phases.
4. Run each leaf through the normal Jido Action runner.
5. Evaluate the Flow output expression.
6. Validate the Flow output.

Runic defines the stepwise work units. `Jido.Exec.ready/1` returns native
`Runic.Workflow.Runnable` values. `step/1`, `step/2`, and `wave/1` execute and
apply those values through the Runic prepare, execute, and apply phases.

This API can expose Steps, Joins, InputBindings, FanOuts, FanIns, collectors,
validators, and nested Workflow internals. It does not group these runnables
into authored Jido component boundaries. It does not promise Jido declaration
order for ready work.

`Jido.Exec.run/4`, `continue/1`, `status/1`, and `result/1` remain Jido
convenience functions. They keep Flow input and output validation, Action
execution, context, execution IDs, Flow lifecycle telemetry, and final error
handling.

`Jido.Flow.Compiled.component_index` supports inspection, output selection,
source diagnostics, and authored-to-Runic lookup. It does not control
scheduling and does not identify hidden runnable groups.

Compilation includes executable validation. Do not maintain separate compiler
and executor implementations of the same target checks.

Generated Flow modules declare both `@behaviour Jido.Action` and
`@behaviour Jido.Executable`. They provide:

- `name/0`
- `description/0`
- `schema/0`
- `output_schema/0`
- `validate_params/1`
- `validate_output/1`
- `run/2`
- `flow/0`
- `compiled/0`

The Spark module compiler stores its source map separately and makes it
available through a private diagnostic callback. `compiled/0` supplies that
source map to `Jido.Flow.compile/2` and remains a compilation and inspection
convenience. It is not execution authority. The Flow execution adapter reads
`flow/0` once and compiles that exact value with the private source map. Direct
and decoded Flow values call `Jido.Flow.compile/1` with an empty source map.

The compiler recursively reads each trusted child module's `flow/0` value. It
passes the Subflow instance namespace and active module stack through its own
private compile state. This creates correct child names and hashes before graph
construction. It does not require a second generated module callback, and it
does not rewrite Runic graph internals after compilation.

A Flow module must return one stable canonical value from `flow/0` for the life
of the loaded module version. Validation, compilation, and execution can read
this value more than once. A new application version can change that value. Its
semantic identity and transitive compilation digest then invalidate old
compiled data. Do not add a resolved intermediate Flow model only to support a
changing `flow/0` result.

Flow nodes discard Action extras and use only the Action output or error
reason. This agrees with the present Action contract.

## 5. Authoring form convergence

### Direct construction

Direct construction is a supported authoring route:

```elixir
step = Jido.Flow.Step.new!(...)
subflow = Jido.Flow.Subflow.new!(name: "child", flow: MyApp.ChildFlow, ...)
flow = Jido.Flow.new!(components: [step, subflow], output: ...)
```

A raw struct literal can exist, but the caller must validate it before use.
Normal authoring routes use `new/1` or `new!/1`.

### Spark DSL

Keep the Spark DSL shape unchanged.

The Spark translation is one-way. The lowerer does not need a reverse mapping
from canonical Flow data back to Spark entities. Keep the translation explicit
and as small as possible.

The lowerer performs only these translations:

- Parse quoted syntax into the common expression and condition data.
- Resolve each `step action:` module through `Jido.Executable`. Construct a
  Step for kind `:action` or a Subflow for kind `:flow`.
- Copy `params` to canonical `params`.
- Copy `after` to canonical `after`.
- Copy explicit `meta` to canonical `meta`.
- Copy source information to a local source table for compile errors and the
  later `Jido.Flow.Compiled.source_map`. Do not put it in the canonical Flow.
- Convert `while` or `repeat` into canonical `completion` and
  `max_iterations`.
- Copy the `output` value to canonical `output`.

The lowerer constructs component structs directly. It does not create node
specification maps and does not call `Jido.Flow.Constructor`.

Except for quoted expression parsing, Step-to-Subflow derivation, and Iterate
termination normalization, Spark field names match canonical field names. Do
not add a general-purpose normalizer between the Spark entities and the
canonical structs.

The generated Flow module stores the source table separately from `flow/0`.
Its `compiled/0` function passes the table to `Jido.Flow.compile/2`. This keeps
the one-way lowerer small and keeps diagnostic data available for inspection.
Execution reads the same source table but compiles the exact `flow/0` value. It
does not trust a separate `compiled/0` result that can disagree with that
value.

### Runtime Builder

The Builder stores canonical component structs, not maps.

Each Builder function calls the related component constructor. `build/1`
passes the component list and output expression to `Jido.Flow.new/1`.

`Builder.step` uses the same trusted executable resolution as the Spark
lowerer. It appends a Step for kind `:action` and a Subflow for kind `:flow`.
Do not add a second Builder alias only for this derivation. Direct construction
uses `Jido.Flow.Subflow.new/1` when the caller already knows the target kind.

The canonical Builder terms are:

- `after`, not `deps`
- `meta`, which is also the unchanged Spark term
- `completion` and `max_iterations`, not `while`, `until`, or `repeat`
- `output/2`, not `return/2`

`Builder.value/1` can remain as an ergonomic helper. It returns the supplied
literal and does not create `Ref.value` data.

### Stored JSON

Stored JSON is accepted and produced only through `Jido.Flow.Codec` with a
trusted `Jido.Flow.Registry`.

The Codec format mirrors the canonical field names:

```json
{
  "type": "jido.flow",
  "version": 1,
  "name": "example",
  "schema": "schemas/example-input",
  "output_schema": "schemas/example-output",
  "components": [
    {
      "kind": "step",
      "name": "load",
      "action": "actions/load",
      "params": {"$type": "map", "entries": []},
      "after": []
    },
    {
      "kind": "subflow",
      "name": "charge",
      "flow": "flows/charge",
      "params": {"$type": "map", "entries": []},
      "after": ["load"]
    }
  ],
  "output": {
    "$ref": {
      "source": "result",
      "component": "charge",
      "path": []
    }
  }
}
```

Every component has an explicit `kind`, including Step and Subflow. The
decoder does not infer a kind from record fields. A Subflow uses a Registry
entry of kind `:flow`. An Action uses an entry of kind `:action`, even though a
Flow module is Action-compatible.

After trusted registry resolution, the decoder returns the same component
structs as direct construction, Spark, and Builder.

`meta` is stored only when it passes `Jido.Flow.Data` validation. DSL source
locations are not stored. Encoding is deterministic: component order and
`after` order are preserved, and map entries use a defined key order.

Use one public Codec module and one paired API:

```elixir
Jido.Flow.Codec.encode(flow, registry)
Jido.Flow.Codec.decode(document, registry)
```

`encode/2` returns a JSON-compatible document map. `decode/2` accepts a decoded
JSON document map. The database adapter or configured JSON library owns the
conversion between that document and JSON bytes. The versioned document
grammar remains the public persistence contract.

Keep serialization and deserialization in one `Jido.Flow.Codec` source file.
Do not expose separate encoder, decoder, lookup, or record-validator modules as
public APIs. Small private functions in the Codec file can share grammar and
path handling. Remove the current `to_stored_map` and `from_stored_map` names.

### Parity rule

Tests compare canonical structs directly. Do not use `Flow.to_map/1` to hide
type or field differences.

All four authoring routes must produce equal canonical structs, including
portable `meta`. DSL-only source tables are outside this comparison.

## 6. Unreleased cleanup policy

This code is unreleased. There is no prior Codec format to migrate. The Spark
DSL shape stays unchanged.

The canonical model has these intentional breaking changes:

- `nodes` becomes `components`.
- `return` becomes `output`.
- `Jido.Flow.Node` becomes `Jido.Flow.Step`.
- A Spark `step` that names a Flow module becomes `Jido.Flow.Subflow`.
- Flow modules are no longer valid targets in Choice, Map, Reduce, or Iterate.
- `Jido.Flow.Iterator` becomes `Jido.Flow.Iterate`.
- `input` becomes `params`.
- `deps` becomes `after`.
- Root `provenance` is removed.
- Component `provenance` becomes portable author `meta`.
- DSL file and line data moves to a parser-owned source table.
- Reference dependencies are not stored in `after`.
- Every stored component has an explicit kind.
- Flow output is required.
- Terminal-node output inference is removed.
- Builder aliases and legacy record inference are removed.

Remove these layers after all call sites move:

- `Jido.Flow.Element` as a conversion and inference layer
- `Jido.Flow.Constructor`
- `Jido.Flow.Builder.Normalizer`
- `Jido.Flow.Iterator.Termination`
- `Jido.Flow.SemanticMap` as a second model
- Canonical source-provenance fields and provenance equality exceptions
- Legacy Choice inference
- Legacy stored-record kind inference
- Duplicate expression and condition codec grammars

Registry read aliases are different from authoring aliases. They can permit a
stored identifier to move to a new canonical identifier. The writer always
uses one canonical identifier.

## 7. Test plan

### Canonical parity

- Test direct construction, Spark DSL, Builder, and JSON for each component.
- Test that one Flow module in `step action:` produces the same Subflow through
  Spark, Builder, direct Subflow construction, and JSON.
- Test that a Flow module in a Choice option, Choice fallback, Map, Reduce, or
  Iterate fails executable validation. Test Spark, Builder, direct
  construction, and JSON records.
- Confirm that these failures identify the component and exact target field.
- Test one complete mixed Flow.
- Compare the returned canonical structs directly.
- Confirm that no path returns DSL entity structs or component maps.
- Confirm that explicit Spark `meta` is equal in all authoring routes.
- Confirm that DSL file and line information is not present in the canonical
  Flow or stored JSON.
- Confirm that Spark file, line, and column information is available in
  `Jido.Flow.Compiled.source_map`.
- Confirm that source-map changes do not change semantic identity or Runic
  component hashes.

### Dependency separation

- Create a component with explicit `after` data and result references.
- Confirm that `validate/1` does not change `after`.
- Confirm that dependency analysis reports `after`, `references`, and
  `effective` separately.
- Test unknown dependencies and cycles.

### Expression grammar

- Test every reference source in its valid scope.
- Test invalid scoped references.
- Test nested lists and maps.
- Test condition recursion and operator arity.
- Test that bare literals and Spark `value/1` produce equal canonical data.
- Test JSON round trips for registered atoms and nonstring map keys.
- Test that Expression is a validated union and not a duplicate wrapper
  struct.

### Stored JSON and trust

- Test unknown registry identifiers.
- Test identifiers with the wrong registry kind.
- Test that a Subflow rejects an `:action` Registry identifier for the same
  module and accepts only its `:flow` identifier.
- Test that decoding does not create atoms.
- Test that an existing but unregistered module name cannot be loaded from
  stored data.
- Test that generic JSON encoding of `%Jido.Flow{}` is not the persistence
  path.
- Test `Codec.encode/2` and `Codec.decode/2` as exact inverses with a complete
  Registry.
- Test unknown fields and missing explicit component kinds.
- Test resource limits and invalid nesting.
- Test deterministic encoding.
- Test component order and explicit `after` order preservation.
- Test rejection of nonportable `meta` data.

### Native Runic lowering

- Confirm that Step becomes `Runic.Workflow.Step`.
- Confirm that Subflow becomes one native Runic Workflow boundary with input
  and output ports.
- Confirm that the child Flow input and output validators each run once.
- Compile the same child module as two sibling Subflows. Confirm that their
  internal Runic names, hashes, facts, and results are independent.
- Confirm that a recursive Subflow module cycle fails before graph creation.
- Confirm that native child Runic runnables are visible through the parent
  stepwise API.
- Confirm that a child source map is prefixed with the Subflow path.
- Confirm that a child semantic change changes the parent compilation digest.
- Confirm that Map becomes `Runic.Workflow.Map`, uses FanOut, and has native
  cardinality-many output.
- Confirm that Reduce becomes `Runic.Workflow.Reduce` and uses FanIn.
- Confirm that a Reduce can connect directly to a Map.
- Confirm that a Map result used as one expression value becomes an
  input-index-ordered list at that boundary.
- Confirm that no `MapResult` aggregate is created.
- Confirm that Choice uses an ordered selector Step and one Action dispatcher
  Step, or one combined Step.
- Confirm that overlapping Choice conditions run only the first Action.
- Confirm that Choice condition errors remain Jido execution errors and do not
  become a false condition.
- Confirm that Iterate becomes one bounded native Step and not StateMachine.
- Confirm that `after` gates execution without adding predecessor values to
  Action params.
- Confirm that generated InputBinding and Join nodes are not stored in the
  Flow.
- Confirm that compilation does not change the canonical Flow.

### Execution contract

- Test Flow input validation.
- Test nested Flow input and output validation at each Subflow boundary.
- Test that Subflow execution keeps the parent context and execution ID.
- Test nested Flow telemetry and error paths.
- Test Action input and output validation for each leaf call.
- Test Flow output validation.
- Test Action errors and discarded extras.
- Test full-run and native-runnable stepwise-run parity.
- Test that `ready/1`, `step/1`, `step/2`, and `wave/1` expose native Runic
  Runnable values.
- Test visible Join, InputBinding, FanOut, FanIn, validator, collector, and
  nested Workflow runnables where the compiled graph needs them.
- Test independent component concurrency.
- Test Map error modes.
- Test Iterate completion and maximum iteration errors.

## 8. Staged implementation

Stages 1 through 13 are complete.

1. Record the approved public types, native Runic Map contract, and Codec
   contract in failing tests.
2. Add `Jido.Flow.Data` and the one Expression validator and traversal. Add
   Zoi-backed Ref, Condition, Step, Subflow, Choice, Choice.Option,
   Choice.Fallback, Map, Reduce, Iterate, and Iterate.State structs. Do not add
   an Expression wrapper struct.
3. Add strict Flow construction and validation. Keep authored and derived
   dependencies separate. Add executable validation that permits kind `:flow`
   only for Subflow.
4. Add the one required `Jido.Flow.Codec` file with `encode/2` and `decode/2`,
   stored JSON grammar, resource limits, and trusted Registry
   resolution. Add the distinct Registry kind `:flow`.
5. Change Builder to store canonical component structs. Derive Step or Subflow
   through the executable descriptor in `Builder.step`.
6. Change the current Spark lowerer to construct canonical structs directly.
   Derive Step or Subflow through the executable descriptor, copy author
   `meta`, pass source data to `Jido.Flow.Compiled.source_map`, and do not
   change the Spark DSL. Reject Flow modules in Choice, Map, Reduce, and
   Iterate Action positions with source-aware errors.
7. Add recursive Subflow compilation. Use native Workflow boundaries,
   instance-scoped names and hashes, cycle checks, transitive compilation
   digests, and Flow boundary validation.
8. Add Runic lowering for Step, Choice, and Iterate. Choice uses a selector and
   dispatcher Step. Iterate uses one bounded Step.
9. Add native Runic Map and Reduce lowering. Use cardinality-many Map output,
   direct Map-to-Reduce FanIn, and one scalar collector branch per Map. Direct
   Reduce bypasses that collector.
10. Keep `after` as control-only readiness and result references as expression
    data. Use one native Join when it can satisfy both readiness sets.
11. Connect execution to the compiled Runic workflow and keep the Action
    validation pattern. Expose native Runic runnables from the stepwise API.
12. Delete old constructors, aliases, inference paths, duplicate models,
    canonical provenance fields, and `MapResult`.
13. Update documentation and run formatting, unit tests, static analysis, and
    the full project test suite.

Each stage starts with contract tests. Remove an old path only after the new
path passes parity and migration tests.

The phase-two cleanup has these results:

- `Jido.Flow.Compiler` is the one graph lowerer. Its small helper modules
  resolve expressions and run local Choice and Iterate Step semantics. They do
  not construct alternate graphs.
- `Jido.Flow.Compiler.MapResult` is removed.
- `OrderedTaskRunner` moved to `Jido.Exec`. `Jido.Flow.NodeError` is removed.
- Do not keep a Jido implementation of Runic Choice, Map, Reduce, or Iterate
  semantics in parallel with native Runic.
- Keep `Jido.Flow.Compiled` as the only derived compilation data type.
- `Jido.Exec.NodeResult` and the Jido component-boundary scheduler are removed.
- Do not partition Runic runnables into public and internal sets.
- Do not automatically drain support runnables to make one authored component
  look like one execution step.

## 9. Phase-three test architecture

Phase three refreshes the test suite around public contracts. It does not add
a second runtime model, a test-only execution API, or broad production
abstractions.

### Test ownership rule

Each behavior has one primary test owner. A higher-level test can prove that
boundaries connect, but it must not repeat the full lower-level test matrix.

Use these four test boundaries:

1. **Data definition** owns Action, Flow, component, expression, condition,
   Executable, and Instruction construction. It also owns structural and
   executable validation. These tests do not call `Jido.Exec` unless one
   small end-to-end parity test needs it.
2. **Codec** owns `Jido.Flow.Codec`, `Jido.Flow.Registry`, the stored document
   grammar, Registry trust, portability, resource limits, deterministic
   encoding, and JSON byte round trips. Codec tests do not compile or execute
   a Flow.
3. **Compilation** owns canonical Flow to native Runic lowering. It inspects
   native components, ports, connections, source maps, instance identity, and
   compilation digests. It does not repeat public `Jido.Exec` error and
   scheduling tests.
4. **Execution** owns Action and Flow input/output validation during a call,
   native runnable transitions, full-run results, Action error propagation,
   Flow error propagation, process exits, caller exits, timeouts, concurrency,
   and telemetry.

Error data and error behavior have different owners:

- `Jido.Action.Error` and `Jido.Flow.Error` struct construction, class
  selection, stable maps, and JSON protocol behavior are data tests.
- Raised values, throws, exits, killed Action processes, failed validation,
  nested Flow failures, and stale execution values are execution tests.

### Test directory rule

Keep the production-module directories because they make ownership clear:

```text
test/jido_action/       Action data, validation, output, and error values
test/jido_flow/         Flow data, validation, authoring, Codec, and Registry
test/jido_flow/compiler Canonical Flow to native Runic compilation
test/jido_instruction/  Instruction data and merge rules
test/jido_exec/         Public execution, failures, process policy, and telemetry
```

Do not create a second directory hierarchy only to label the same modules as
"data" or "execution". File names and test descriptions state the contract.
Move an execution test out of a data or compiler file when `Jido.Exec` is the
subject of the assertion.

### Central fixture rule

Use one fixture namespace and one fixture tree:

```text
test/support/fixtures/
├── action/
│   ├── definitions.ex
│   └── failures.ex
├── codec/
│   └── registry.ex
├── execution/
│   └── runtime.ex
└── flow/
    ├── authoring.ex
    └── modules.ex
```

The root namespace is `JidoActionTest.Fixtures`. Fixture modules below it can
use `Actions` and `Flows` namespaces where that improves the call site.

- `flow/authoring.ex` owns small canonical Flow values, Builder forms, and
  authoring-form matrices.
- `codec/registry.ex` owns trusted Registry values for stored Flow tests.
- `action/definitions.ex` owns small successful Actions that two or more test
  files use.
- `action/failures.ex` owns deliberate validation failures, bad return values,
  raises, throws, exits, hard kills, and blocking process probes.
- `flow/modules.ex` owns compiled Spark Flow modules that support a named
  contract. A small incidental Flow can stay in its test file.
- `execution/runtime.ex` owns direct runtime Flow factories, transforms,
  iterator factories, and execution-path matrices. It does not contain
  assertions.

Do not use generic `helpers.ex`, `basic_actions.ex`, `result_actions.ex`, or
`runtime_probe_actions.ex` names. A file path must state why the fixture exists.
Do not keep separate `ExecFixtures`, `IteratorFixtures`,
`FlowFixtures`, and `TestActions` roots.

A fixture must be deterministic and must not hide the contract under test.
Use real small Actions instead of mocks. Keep process probes such as a killed
Action or a blocking Action explicit. They test OTP failure boundaries that a
generic mock cannot prove.

### Contract matrices

Use small shared matrices only where the same public rule must hold for more
than one representation:

- Direct Flow, Builder Flow, Spark Flow, and decoded Flow must be equal.
- A Flow module, runtime `%Jido.Flow{}`, Flow Instruction, and parent Subflow
  must have the same successful Flow boundary result where all forms apply.
- A leaf Action module and Action Instruction must have the same Action error
  containment where both forms apply.
- Full-run and step-wise execution must have the same final Flow result.

The matrix returns named values or zero-arity functions. It does not make
assertions. Each test reports the representation name when it fails.

Do not force unlike contracts into one matrix. Action extras, Flow options,
and step-wise Flow execution have different public shapes and need focused
tests.

### Execution and failure coverage

Execution tests use a small contract table:

| Boundary | Success | Returned error | Raise or throw | Process exit | Caller exit |
| --- | --- | --- | --- | --- | --- |
| Action module | Required | Required | Required | Required | Required |
| Action Instruction | Required parity | Required parity | Required parity | Required parity | Covered by Action worker ownership |
| Flow value | Required | Required | Required at a leaf | Required at a leaf | Required |
| Flow module | Required parity | Required parity | Required parity | Required parity | Covered by Flow execution ownership |
| Flow Instruction | Required parity | Required parity | Required parity | Required parity | Covered by Flow execution ownership |
| Subflow | Required | Required | Required at a child leaf | Required at a child leaf | Covered by parent ownership |

Tests for killed and interrupted processes must use monitors and messages.
They must not depend on sleeps. Concurrency tests must assert active work and
ordered results, not task completion order. Stale execution tests must retain
the old value and prove that it cannot mutate the current execution.

### Simplification and deletion rules

- Remove duplicate Registry and Codec boundary cases from general Flow
  validation files. The Registry and Codec test files own them.
- Split Instruction execution from Action execution when the Instruction
  merge or target rule is the subject.
- Move Choice, Map, Reduce, and Iterate runtime behavior out of compiler tests
  when the assertion is about public execution rather than the Runic graph.
- Keep one comprehensive authoring-form convergence test. Component
  constructor tests then cover only their own fields and invalid boundaries.
- Keep one full stored Flow round trip. Focus the other Codec tests on one
  grammar or trust rule each.
- Remove a support fixture when no active contract reaches it. Keep a small
  incidental one-use fixture next to its test. A centralized failure or Flow
  contract fixture can have one test-file consumer when that keeps the contract
  file clear.
- Do not add a helper only to save one or two assertion lines.
- Do not use coverage percentage as the reason for duplicate tests. Coverage
  is a backstop after the contract suite is clear.

### Phase-three stages

1. Record the test ownership rules and take a green baseline.
2. Replace the four fixture roots with `JidoActionTest.Fixtures`. Move one-use
   fixtures into their test files.
3. Remove duplicate Codec and Registry tests from general Flow boundary tests.
4. Split mixed Action, Instruction, Flow-adapter, and process-failure tests by
   public contract.
5. Move runtime semantic assertions from compiler tests to execution tests.
   Keep native graph assertions in compiler tests.
6. Add the execution and failure contract matrix, with explicit hard-kill and
   caller-exit cases.
7. Fix production code only when the new contract tests show a defect. First,
   test that execution compiles the exact Flow value returned by `flow/0` and
   does not trust a mismatched `compiled/0` value.
8. Remove redundant tests and fixtures. Then run unit tests, integration tests,
   coverage, quality checks, and documentation checks.

The target is a smaller and clearer suite. The 93% coverage threshold remains
a release check, but test ownership and failure-contract coverage have higher
priority than the raw percentage.

## 10. Approved and open design decisions

### Map output semantics: approved

Use native Runic cardinality-many output. Remove the current `MapResult` record
with separate `results` and `errors` lists.

Define the author-visible behavior as follows:

- Native Runic Map emits one internal item outcome for each input item.
- `:fail_fast` fails the Map when an item Action fails.
- With `:fail_fast`, successful downstream and collected values are the Action
  outputs.
- With `:collect_errors`, downstream and collected values are portable tagged
  success or error outcomes.
- A direct native Reduce consumes the cardinality-many Map port without a
  collector in its data path.
- The compiler attaches one scalar collector branch to every Map. Normal result
  expressions and the Flow output read its input-index-ordered list. This avoids
  a second compiler pass that plans scalar reference use.
- The compiler-owned item index and item ID are runtime data. They are not
  fields in the canonical Map.

This gives Runic native fan-out and fan-in behavior while the one expression
grammar still receives an ordinary list value at a scalar Action parameter or
Flow output boundary.

Do not keep the current `MapResult` aggregate. The behavior change from
`MapResult` to native many-valued output, with one scalar collector branch for
normal result expressions, is approved.

### Stored Codec format: approved and implemented

This is the initial Codec format. Its stored envelope uses `"version": 1` so a
future incompatible format can fail clearly. There is one `Jido.Flow.Codec`
API.

### Registry read aliases: approved and implemented

Recommended choice: keep read-only registry aliases for stored identifier
rotation. Do not permit aliases in Flow constructors, Builder, or the stored
record grammar.

### Explicit Flow output: approved and implemented

Recommended choice: require `output` for every Flow. Do not infer a terminal
component. The Spark DSL syntax stays the same, but a Flow without `output`
gets a compile error.

### Subflow scope: approved

Keep the Spark DSL shape. When a `step action:` module has executable kind
`:flow`, lower it to `Jido.Flow.Subflow`. Use a native Runic Workflow boundary.
Use the same derivation in `Builder.step`. JSON and direct construction use the
explicit Subflow kind.

The old spike code accepted a Flow module in a Choice option or fallback, Map,
Reduce, and Iterate Action field. The canonical model removes this behavior.
These positions are not equivalent to a top-level Subflow:

| DSL position | Native Runic fit | Canonical rule |
| --- | --- | --- |
| `step action:` | One named Workflow boundary | Derive Subflow |
| Choice branch `action` | A conditional call inside one Choice | Require Action |
| Map `action` | A child Workflow could be a different Map pipeline model | Require Action |
| Reduce `action` | One child run for each fold operation | Require Action |
| Iterate `action` | One child run inside the bounded loop Step | Require Action |

This approved rule keeps Subflow equal to one native Runic Workflow component.
It avoids a second executable-target union across four structs. Validation
reports old nested Flow uses in Choice, Map, Reduce, and Iterate. It does not
infer or generate a replacement graph.

### Builder compatibility: approved and implemented

Recommended choice: make a clean Builder break in this release. Do not keep
`deps`, `provenance`, `return`, `while`, `until`, or `repeat` aliases outside
the unchanged Spark DSL. Builder accepts canonical `meta`.
