# Flow Data Definitions

Use `Jido.Flow.new/1` to validate a Flow definition made from maps. The module
DSL, data definitions, and stored JSON through `Jido.Flow.Codec` produce the
same canonical `%Jido.Flow{}` value.

## Define A Flow

```elixir
alias Jido.Flow
alias Jido.Flow.Ref

{:ok, flow} =
  Flow.new(%{
    name: "send_notice",
    components: [
      %{
        kind: :step,
        name: "send",
        action: MyApp.SendNotice,
        params: %{address: Ref.input(:address)}
      }
    ],
    output: Ref.result("send")
  })
```

`new/1` returns `{:ok, flow}` or a structured validation error. `new!/1` raises
that error. The Flow definition must be a map with atom keys. Each component
must be a tagged map. Unknown fields and invalid component kinds are rejected.
An explicit, non-nil `output` is required.

Use normal Elixir list and map operations to assemble runtime definitions.
Construct the complete definition, then call `Jido.Flow.new/1`. There is no
separate finalization call.

## Component Kinds

| `kind` | Target fields | Other main fields |
| --- | --- | --- |
| `:step` | `action` | `params` |
| `:subflow` | `flow` | `params` |
| `:choice` | `options`, `fallback` | Ordered routing options |
| `:map` | `action` | `collection`, `params`, `on_error` |
| `:reduce` | `action` | `collection`, `initial`, `params` |
| `:iterate` | `action` | `params`, `state`, `completion`, `max_iterations` |
| `:dispatch` | `decision`, `expander` | `params` |

All component kinds accept `name`, `needs`, and `meta`. Choice options, the
fallback, and Iterate state are nested maps.

Keep components and Choice options in lists. Choice evaluates options in list
order. Component declaration order does not create dependencies. Result
references and `needs` define dependencies. Canonical dependency and name order
define execution results and effect order.

Data definitions use an explicit `:subflow` kind and `flow` field for a child
Flow module. A `:step` uses an Action module. The module DSL can derive a
Subflow from a `step` target. Definition validation is inert;
`Jido.Flow.validate_executable/1` also checks target contracts.

## Canonical Graph Shape

`Jido.Flow.new/1` is the semantic normalization boundary. The input component
list becomes a map keyed by component name in the `components` field of
`%Jido.Flow{}`. The map supports direct lookup and does not carry declaration
order as execution meaning. Dependencies define the graph order.

A Step and a Subflow both normalize to a `:call` node. The target kind is held
by an inert `Jido.Instruction` template:

```elixir
%{kind: :call, needs: [], meta: %{}, call: {template, params}} =
  flow.components["send"]

%Jido.Instruction{
  kind: :action,
  target: MyApp.SendNotice,
  params: %{},
  context: %{}
} = template

%{address: %Jido.Flow.Ref{}} = params
```

Each parameterized Action slot in Choice, Map, Reduce, Iterate, and Dispatch
uses the same `{instruction_template, params_expression}` call tuple. The
Dispatch expander keeps only its template because it receives the complete
decision result. A template contains no bound params or context. Exec evaluates
the expression and binds runtime data before execution.

Do not build this normalized graph directly. Use a tagged component list with
`Jido.Flow.new/1`. Use `Jido.Flow.to_map/1` for deterministic inspection and
`Jido.Flow.Codec` for JSON storage.

## References And Expressions

Use `Jido.Flow.Ref` for input, context, component results, collection items,
accumulators, and iteration state. `Ref.select/2` appends a path after it
validates the source reference. Flow validation checks the complete resulting
path and its scope.

Use `Jido.Expr.new/2`, `new!/2`, or the expression helper DSL for operations.
Ordinary map and list values remain literal data. Do not interpret a literal
map as an operation or reference based on its field names.

## Reuse An Inline Step

A compiled Flow module exposes a Step Action through `step_action/1`. Supply
new parameter expressions, dependencies, and metadata when you reuse it:

```elixir
alias Jido.Flow
alias Jido.Flow.Ref

Flow.new!(%{
  name: "normalize_names",
  components: [
    %{
      kind: :map,
      name: "names",
      collection: Ref.input(:people),
      action: MyApp.NormalizePerson.step_action("normalize"),
      params: %{name: Ref.item()}
    }
  ],
  output: %{names: Ref.result("names")}
})
```

Data definitions accept compiled targets. They do not accept inline body code,
anonymous functions, or MFA targets.

## Stored Or AI-Generated Definitions

Elixir data definitions contain trusted host modules and references. For
JSON-compatible definitions from storage or an AI model, use
`Jido.Flow.Codec.decode/2` with a host-owned `Jido.Flow.Registry`. The Registry
resolves approved identifiers. Input strings must not create atoms or derive
module names. `Jido.Flow.to_map/1` is an inspection view; use Codec for
serialization. See [Flow Storage](flow-storage.md).

## Migrate From Builder

`Jido.Flow.Builder` was removed in V3 beta. Replace its pipeline with a complete
Flow map and `Jido.Flow.new/1`. Replace its reference helpers with `Jido.Flow.Ref`,
its condition helpers with `Jido.Expr`, and Choice helpers with option and
fallback maps. Use an explicit `:subflow` component for child Flow targets.
