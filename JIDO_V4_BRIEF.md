# Jido Action v4 Brief

## Thesis

Jido Action v4 should sharpen `Jido.Flow` the same way v3 sharpened
`Jido.Action`.

`Jido.Action` is the execution boundary. `Jido.Instruction` is one invocation.
`Jido.Flow` should become both:

- a compile-time composite action built with `use Jido.Flow`;
- a canonical runtime action-plan IR that can be generated, inspected, and
  executed.

The product should not make `Jido.Flow` a full agent framework or workflow
runtime. Runic owns runtime execution mechanics. Higher Jido packages can own
agent loops, memory, approval, persistence, observability, and platform
features.

The core product phrase:

> Runic should see Jido work as executable nodes. Jido users should see
> executable nodes as actions.

## Product Frame

Mastra and LangGraph offer broad agent workflow platforms: agents, tools,
graphs, state, persistence, human-in-the-loop, memory, debugging, and
deployment. Jido can offer comparable capability as an ecosystem, but
`jido_action` should stay the kernel:

- define validated tools with `Jido.Action`;
- represent tool calls with `Jido.Instruction`;
- define composed tools with compile-time `Jido.Flow` modules;
- generate runtime action-plan data with `%Jido.Flow{}`;
- execute the composition through Runic with `Jido.Exec`.

This gives `jido_action` a defensible boundary: it is the agentic tool and flow
kernel, not the whole platform.

## Action Boundary Model

The v4 model should organize every execution surface around the `Jido.Action`
boundary:

```text
leaf action
  use Jido.Action

composite action
  use Jido.Flow

runtime action plan
  %Jido.Flow{}

execution substrate
  Runic workflow nodes
```

A compile-time Flow module is a specialized action. It should expose the same
boundary as a leaf action:

```elixir
MyApp.Flows.Checkout.name()
MyApp.Flows.Checkout.description()
MyApp.Flows.Checkout.schema()
MyApp.Flows.Checkout.output_schema()
MyApp.Flows.Checkout.validate_params(params)
MyApp.Flows.Checkout.validate_output(output)
MyApp.Flows.Checkout.run(params, context)
```

It should also expose the flow artifact:

```elixir
MyApp.Flows.Checkout.flow()
MyApp.Flows.Checkout.to_map()
MyApp.Flows.Checkout.compile()
```

This creates a simple composition rule:

```text
Action = leaf tool
Flow module = composed tool
%Jido.Flow{} = runtime data artifact
```

Runtime `%Jido.Flow{}` values are executable by `Jido.Exec`, but they are not
themselves `Jido.Action` modules because there is no callback boundary.

## Raw Elixir Counterfactual

Raw Elixir should remain the default way to compose actions when the composition
is ordinary application code.

If a workflow is fixed, local, small, and only exists inside one codebase, this
is clearer than a Flow:

```elixir
with {:ok, quote} <- MyApp.Actions.PriceCart.run(%{cart: cart}, context),
     {:ok, reservation} <-
       MyApp.Actions.ReserveInventory.run(%{cart: cart, quote: quote}, context),
     {:ok, charge} <-
       MyApp.Actions.ChargeCard.run(%{quote: quote, reservation: reservation}, context) do
  {:ok, charge}
end
```

`Jido.Flow` should not compete with `with`, pipes, functions, or ordinary module
composition. It earns its place only when the composition must become data:

- generated dynamically at runtime;
- inspected before execution;
- serialized, stored, diffed, or reviewed;
- explained as dependencies, edges, returns, and provenance;
- emitted by agents as a tool plan;
- compiled into Runic for graph execution and runtime policy;
- executed through different runtime modes without rewriting application code.

The decision rule:

```text
If composition is just application code, write Elixir.
If composition is an artifact, use Jido.Flow.
```

This is the central guardrail for v4. The macro DSL and parsed string DSL are
not justified by being a nicer way to write Elixir. They are justified only if
they produce an inspectable, executable action plan.

## Flow Direction

The new `Jido.Flow` direction is IR-first, syntax-second.

Every authoring surface should lower into the same canonical Flow IR. The IR is
the product surface; syntax is only a way to author the artifact:

```text
authoring surface
  -> shared Flow syntax AST
  -> Flow lowerer
  -> canonical %Jido.Flow{}
  -> Runic compilation
```

The three authoring surfaces are:

1. Compile-time macro DSL with `use Jido.Flow`.
2. Runtime builder API for programmatic flow construction.
3. Runtime text parsing with `Code.string_to_quoted/2`, parsed as data and
   lowered through the same pipeline.

The macro DSL and string DSL should be developed in parallel feature-by-feature
so they cannot drift.

`Jido.Flow` should therefore optimize for artifact properties first:

- stable canonical maps;
- predictable lowering;
- clear validation errors;
- dependency introspection;
- source provenance;
- semantic hashes;
- execution through Runic.

It should not optimize for replacing normal Elixir control flow.

## Desired Developer Experience

The compile-time form should feel like the sibling of `use Jido.Action`:

```elixir
defmodule MyApp.Flows.Checkout do
  use Jido.Flow,
    name: "checkout",
    description: "Price, reserve, and charge a cart",
    schema:
      Zoi.object(%{
        cart: Zoi.map(),
        payment_method: Zoi.map()
      }),
    output_schema:
      Zoi.object(%{
        receipt_id: Zoi.string(),
        total_cents: Zoi.integer()
      })

  flow do
    quote =
      step :price_cart, MyApp.Actions.PriceCart,
        with: %{cart: input(:cart)}

    reservation =
      step :reserve_inventory, MyApp.Actions.ReserveInventory,
        with: %{cart: input(:cart), quote: quote}

    authorization =
      step :authorize_payment, MyApp.Actions.AuthorizePayment,
        with: %{
          quote: quote,
          reservation: reservation,
          payment_method: input(:payment_method)
        }

    return authorization
  end
end
```

The equivalent runtime text form should use the same language:

```elixir
Jido.Flow.parse("""
flow checkout,
  schema: MyApp.FlowSchemas.CheckoutInput,
  output_schema: MyApp.FlowSchemas.CheckoutOutput do

  quote =
    step :price_cart, MyApp.Actions.PriceCart,
      with: %{cart: input(:cart)}

  reservation =
    step :reserve_inventory, MyApp.Actions.ReserveInventory,
      with: %{cart: input(:cart), quote: quote}

  authorization =
    step :authorize_payment, MyApp.Actions.AuthorizePayment,
      with: %{
        quote: quote,
        reservation: reservation,
        payment_method: input(:payment_method)
      }

  return authorization
end
""")
```

The parsed form must not eval user code. It should parse quoted Elixir syntax,
walk only allowed forms, reject everything else, and lower to the same Flow
syntax AST used by the macro DSL.

Flow schemas should follow the `Jido.Action` pattern: the public contract is
`schema` and `output_schema`, not a separate flow-specific `input_schema`.
`input(:cart)` is a reference into the runtime input, not the contract itself.

## Core Operations

Start with operations that can lower cleanly into the current IR.

### Phase 1: Core Composition

- `input` references runtime input declared by the flow schema.
- `value` wraps literal values explicitly.
- `result` references a named step result.
- `step` binds one `Jido.Action` invocation to a flow result name.
- variable binding maps developer-friendly names to result refs.
- `return` declares the public flow result.

These should all lower to ordinary `%Jido.Flow.Node{}` values and
`%Jido.Flow.Ref{}` expressions.

### Phase 2: Data Shaping Sugar

- `select` projects a path from input or result data.
- `shape` builds structured input payloads from refs and literals.
- `collect` can remain an ordinary built-in action-backed node.
- `merge` can remain an ordinary built-in action-backed node.

These operations should avoid creating a general expression language. If logic
is meaningful business behavior, it belongs in an action.

### Phase 3: Static Parallelism

- `parallel` groups independent branches for authoring clarity.
- It should not introduce a new canonical entry type at first.
- The lowerer should emit ordinary nodes and dependency edges.

Parallelism is a property of the dependency graph and Runic execution, not a
separate Jido runtime policy.

### Later: Control Flow

Only add `choose`, `each`, or `loop` when their canonical semantics are clear.
Each of these adds real product and runtime weight:

- `choose` needs branch execution semantics and result shape rules.
- `each` needs collection mapping, concurrency, ordering, and failure behavior.
- `loop` needs state, max iterations, completion, return, telemetry, and
  provenance semantics.

These should not be smuggled in as syntax sugar before the IR can represent
them honestly.

## Runtime And Compile-Time Story

Compile-time flow modules should expose the `Jido.Action` boundary plus stable
artifact functions:

```elixir
MyApp.Flows.Checkout.run(params, context)
MyApp.Flows.Checkout.flow()
MyApp.Flows.Checkout.to_map()
MyApp.Flows.Checkout.compile()
```

Runtime builders and parsers should produce the same result:

```elixir
{:ok, flow} = Jido.Flow.parse(source)
{:ok, workflow} = Jido.Flow.compile(flow)
```

`Jido.Exec.run/3` should accept both module and data forms:

```elixir
Jido.Exec.run(MyApp.Actions.PriceCart, input, context: context)
Jido.Exec.run(MyApp.Flows.Checkout, input, context: context)
Jido.Exec.run(%Jido.Flow{} = flow, input, context: context)
Jido.Exec.run(%Jido.Instruction{} = instruction, input, context: context)
```

The compile-time module path can use the action callbacks. The runtime data
path validates and executes the flow artifact directly.

The core invariant:

```text
macro DSL canonical map == parsed string canonical map == builder canonical map
```

Every supported operation should have tests proving that invariant.

## Parser Safety

`Code.string_to_quoted/2` is useful because it avoids inventing a grammar, but
the parsed source must be treated as data.

Rules:

- never eval parsed flow source;
- use a strict allowlist of AST forms;
- reject arbitrary function calls, aliases, captures, module attributes, sigils,
  comprehensions, imports, requires, and remote calls except allowed action
  module aliases;
- decide explicitly whether `parse/1` is trusted developer input or safe
  end-user configuration;
- if runtime text may be untrusted, use `existing_atoms_only: true` and avoid
  creating atoms from source text.

The current Flow IR is atom-heavy. That is acceptable for trusted developer
source. It is a design risk for arbitrary user-submitted flow text.

## Implementation Shape

Prepare the codebase by extracting builder lowering out of `Jido.Flow.new/1`.
Current `continue` sugar proves the need for a lowering layer, but it should not
remain embedded in canonical construction as the syntax grows.

Suggested modules:

- `Jido.Flow.Syntax` for syntax AST structs or normalized operation maps.
- `Jido.Flow.Syntax.Lowerer` for converting syntax operations into
  `%Jido.Flow{}`.
- `Jido.Flow.DSL` for compile-time macro collection and composite action
  generation.
- `Jido.Flow.Parser` for `Code.string_to_quoted/2` parsing and AST allowlisting.

The canonical structs should remain:

- `Jido.Flow`
- `Jido.Flow.Node`
- `Jido.Flow.Ref`
- `Jido.Instruction`

Do not make the macro DSL the canonical representation. Do not make the parsed
text representation canonical. The IR stays canonical.

`use Jido.Flow` should generate an action-compatible module. It can either build
on `use Jido.Action` or generate the same callback surface directly, but the
public result must be a normal action boundary. Because the generated `run/2`
intentionally delegates to `Jido.Exec`, it should be treated as the explicit
orchestrator exception to the leaf-action warning.

## Testing Strategy

This work should proceed test-first.

For each feature, add tests in four layers:

1. Lowerer tests: syntax AST lowers to expected canonical `Flow.to_map/1`.
2. Macro tests: `use Jido.Flow` produces that same canonical map.
3. Parser tests: string source produces that same canonical map.
4. Execution tests: only when the feature changes runtime behavior.

Keep the existing property tests around canonical maps, dependency edges,
compiled dependencies, and `Flow.explain/1`. Add new properties once the syntax
layer is stable:

- macro/string/builder forms round-trip to equivalent canonical maps;
- sugar never appears in canonical maps;
- unsupported AST forms are rejected clearly;
- parsed source cannot introduce unsafe atoms when strict parsing is enabled.

## Scope Boundaries

In scope for `jido_action`:

- leaf and composite action boundaries;
- action composition syntax;
- canonical Flow IR;
- references and structured data expressions;
- static dependency derivation;
- Runic compilation;
- result extraction and provenance;
- artifact operations such as explanation, serialization, comparison, and
  source-safe lowering.

Out of scope for `jido_action` core:

- replacing ordinary Elixir composition;
- agent loops;
- model/tool choice;
- memory;
- human approval workflows;
- durable checkpoint storage;
- retry and timeout policy DSLs;
- scheduler configuration DSLs;
- arbitrary Elixir execution inside flows;
- a full custom non-Elixir grammar.

## First Milestone

The first milestone should be intentionally small:

```elixir
defmodule MyApp.Flows.Math do
  use Jido.Flow,
    name: "math",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  flow do
    added =
      step :add, MyApp.Actions.Add,
        with: %{value: input(:value), amount: value(1)}

    doubled =
      step :double, MyApp.Actions.Double,
        with: added

    return doubled
  end
end
```

Deliverables:

- shared lowerer exists;
- current `continue` behavior is preserved through the lowerer;
- macro DSL supports `input`, `value`, `step`, binding, and `return`;
- `use Jido.Flow` exposes the `Jido.Action` boundary;
- parser supports the same subset;
- macro and parser forms produce the same canonical map;
- existing Flow and Exec tests still pass.

This proves the architecture before adding richer operations.

## Open Decisions

- Is `Jido.Flow.parse/1` trusted developer input only, or should it be safe for
  end-user supplied source?
- Should canonical flow and node names remain atoms long term, or should v4
  consider string-safe identifiers?
- Should variable bindings be retained as metadata for provenance/debugging, or
  should they disappear entirely after lowering?
- Should `parallel` remain pure authoring sugar, or should it eventually become
  a canonical grouping entry?
- Where is the boundary between built-in data helper actions and flow syntax?
- Should `use Jido.Flow` call `use Jido.Action` internally, or generate the
  action-compatible callbacks directly?
- How should generated Flow actions preserve directives and execution metadata
  while returning an ordinary action result?

These decisions should be resolved before implementing `choose`, `each`, or
`loop`.
