# Jido Flow Script Syntax

Developer review notes for the current `Jido.Flow.Script` surface.

This is not user-facing documentation. It is meant to make the script language
easy to critique while we harden the IR and parser.

## Current Status

The script parser is implemented in `Jido.Flow.Script`.

The current pipeline is:

```text
string script
-> Code.string_to_quoted/2 with static atom encoding
-> restricted AST parser
-> Jido.Flow IR
-> optional normalized script rendering with to_script/1
```

The script is legal Elixir syntax, but it is not evaluated as Elixir. Only the
forms listed in this document are accepted.

Current coverage is strong for the parser and renderer:

- `Jido.Flow.Script`: public facade
- `Jido.Flow.Script.Parser`: AST to Flow IR
- `Jido.Flow.Script.Parser.Support`: reference and option validation helpers
- `Jido.Flow.Script.Renderer`: Flow IR to normalized script

## Design Goals

- Keep `Jido.Flow` as the canonical Elixir-term IR.
- Keep atom use explicit and bounded.
- Avoid `String.to_atom/1`.
- Avoid arbitrary code evaluation.
- Prefer explicit data movement over hidden runtime behavior.
- Keep syntax small enough that it does not become a full language.
- Use script coverage as a pressure test for the shape of `Jido.Flow`.

## Key Review Flags

These are the main areas that deserve design review.

- `loop` is intentionally not supported. It was parse-time code generation,
  not Flow IR, so it broke the “script -> IR -> script” goal.
- `over:` is preserved as Flow IR on map/reduce/accumulate entries. It lowers
  to concrete project/source wiring only when compiling to Runic.
- `switch` is executable as a Flow component. Compact switch emits selected
  route values when `return: true`; block switch runs the selected branch flow.
- `debug` and `trace` parse as IR. Runtime behavior is intentionally thin right
  now; they are primarily structural/debugging entries.
- `return` is metadata on `Jido.Flow`. It does not currently change execution.
- `source(result(:step, [:path]))` is allowed, but compiler projection naming
  still needs design pressure. Explicit `project` is clearer today.

## Safety Model

Scripts are parsed with `Code.string_to_quoted/2` and a static atom encoder.

Atoms are accepted only when they already exist in the VM or are passed through
`allowed_atoms: [...]`.

```elixir
Jido.Flow.Script.parse!(source, allowed_atoms: [:checkout, :load_cart])
```

The parser must not evaluate arbitrary quoted code.

Rejected examples:

```elixir
if true do
  step :add, MyApp.Add
end

for item <- [1, 2, 3] do
  step item, MyApp.Add
end

step :add, MyApp.Add, params: %{amount: String.to_integer("1")}
```

## Top-Level Flow

Every script defines one flow.

```elixir
flow :checkout do
  input(:cart_id)

  step :load_cart, MyApp.LoadCart do
    argument(:cart_id, input(:cart_id))
  end

  return(result(:load_cart))
end
```

Accepted:

- `flow :name do ... end`

Rejected:

- options on `flow`
- top-level forms other than the forms listed here

IR shape:

```elixir
%Jido.Flow{
  name: :checkout,
  inputs: [:cart_id],
  flow: [...],
  return: {:result, :load_cart}
}
```

## Literal Values

The script parser supports a constrained set of literal values:

- atoms
- strings
- integers
- floats
- lists
- keyword lists
- maps
- tuples
- module aliases
- external captures such as `&MyApp.Math.sum/2`

It does not support arbitrary expressions or function calls.

## References

References are data terms. They are not runtime function calls.

### `input/1`

References declared runtime input.

```elixir
input(:cart_id)
```

IR:

```elixir
{:input, :cart_id}
```

Top-level `input/1` declares expected input keys:

```elixir
flow :checkout do
  input(:cart_id)
end
```

### `result/1`

References a prior component result.

```elixir
result(:load_cart)
```

IR:

```elixir
{:result, :load_cart}
```

In reference positions, a bare atom is also treated as a result reference:

```elixir
return(:load_cart)
```

normalizes to:

```elixir
return(result(:load_cart))
```

### `result/2`

References a path inside a prior result.

```elixir
result(:load_cart, [:items])
result(:load_cart, [:items, 0, :sku])
```

IR:

```elixir
{:result, :load_cart, [:items]}
```

Paths must be non-empty lists of atom keys and non-negative integer indexes.

### `value/1`

Embeds a literal value.

```elixir
value(1)
value("USD")
value(%{currency: "USD"})
```

IR:

```elixir
{:value, 1}
```

## Callables

Map/reduce/accumulate/switch predicates accept data-oriented callable refs.

Accepted forms:

```elixir
&MyApp.Math.double/1
{MyApp.Math, :double}
{:mfa, MyApp.Math, :double}
```

Anonymous functions are not accepted in string scripts.

## `step`

Steps run Jido action modules.

### Compact Form

```elixir
step :add, MyApp.Add
step :add, MyApp.Add, params: %{amount: 2}
step :add, MyApp.Add, params: [amount: 2]
step :add, MyApp.Add, context: %{trace_id: "trace"}
step :double, MyApp.Double, after: :add
step :join, MyApp.Join, after: [:left, :right]
```

Options:

- `params:` map or keyword list
- `context:` map or keyword list
- `after:` atom or non-empty list of atoms

IR:

```elixir
%{
  type: :step,
  name: :add,
  action: MyApp.Add,
  params: %{amount: 2},
  context: %{},
  after: nil
}
```

### Block Form

```elixir
step :format, MyApp.Format do
  argument(:value, result(:sum))
  argument(:amount, value(1))
  wait_for(:sum)
end
```

Block forms:

- `argument(name, reference)`
- `wait_for(dependency)`

`argument/2` names must be atoms. Argument values must be references:

```elixir
argument(:cart_id, input(:cart_id))
argument(:items, result(:load_cart, [:items]))
argument(:amount, value(2))
```

`wait_for/1` accepts an atom or non-empty list of atoms:

```elixir
wait_for(:load_cart)
wait_for([:validate, :price])
```

Current behavior:

- block arguments become `params`
- result references in arguments derive default dependencies
- `params:` cannot be combined with an argument block
- `after:` can still be used on block steps, but mixing `after:` and
  `wait_for/1` is confusing and should probably be tightened

## `project`

Explicit projection is the clearest data movement form.

### Compact Form

```elixir
project :items, from: :load_cart, path: [:items]
project :first_item, from: :load_cart, path: [:items, 0]
```

Options:

- `from:` atom, required
- `path:` non-empty list of atoms and non-negative integers, required
- `mode:` currently only `:value`

Block form is not supported.

IR:

```elixir
%{
  type: :project,
  name: :items,
  from: :load_cart,
  path: [:items],
  mode: :value,
  after: :load_cart
}
```

## `map`

Maps a callable over a collection.

### Compact Form

```elixir
map :double_each, &MyApp.Math.double/1
map :double_each, {MyApp.Math, :double}
map :double_each, {:mfa, MyApp.Math, :double}
```

Options:

- `source:` reference or atom
- `over:` atom or path-source tuple
- `after:` atom or non-empty list of atoms
- `inputs:` Runic input options
- `outputs:` Runic output options

Inline source:

```elixir
map :double_each, &MyApp.Math.double/1, source: result(:items)
map :double_each, &MyApp.Math.double/1, source: :items
```

`source: :items` normalizes to `source: result(:items)`.

### Block Form

```elixir
map :double_each, &MyApp.Math.double/1 do
  source(result(:items))
end
```

Block forms:

- `source(reference)`

Block form can still use `after:`, `inputs:`, and `outputs:` options:

```elixir
map :line_totals, &MyApp.Pricing.line_total/1,
  inputs: [input: :value],
  outputs: [output: :value] do
  source(result(:items))
end
```

### `over:` IR

Simple source shorthand:

```elixir
map :double_each, &MyApp.Math.double/1, over: :items
```

is preserved in Flow IR:

```elixir
%{
  type: :map,
  name: :double_each,
  mapper: {MyApp.Math, :double},
  source: nil,
  over: :items,
  after: :items
}
```

Path source shorthand:

```elixir
map :double_each, &MyApp.Math.double/1,
  over: {:items, from: :load_cart, path: [:items]}
```

is also preserved in Flow IR:

```elixir
%{
  type: :map,
  name: :double_each,
  mapper: {MyApp.Math, :double},
  source: nil,
  over: {:items, from: :load_cart, path: [:items]},
  after: :items
}
```

Compiler note: `Jido.Flow.to_workflow/1` lowers path `over:` into an explicit
Runic projection component before the map/reduce/accumulate primitive. The
lowering does not mutate the Flow IR returned by `Jido.Flow.to_map/1`.

## `reduce`

Reduces a collection to one value.

### Compact Form

```elixir
reduce :sum, 0, &MyApp.Math.sum/2
reduce :sum, 0, {MyApp.Math, :sum}, after: :double_each, map: :double_each
```

Options:

- `source:` reference or atom
- `over:` atom or path-source tuple
- `after:` atom or non-empty list of atoms
- `map:` map component name for Runic map/reduce wiring
- `inputs:` Runic input options
- `outputs:` Runic output options

### Block Form

```elixir
reduce :sum do
  source(result(:double_each))
  init(0)
  run(&MyApp.Math.sum/2)
end
```

Block forms:

- `source(reference)`, optional
- `init(value)`, required
- `run(callable)`, required

If `source(result(:double_each))` is used and no `map:` option is provided, the
parser sets `map: :double_each`.

IR:

```elixir
%{
  type: :reduce,
  name: :sum,
  init: 0,
  reducer: {MyApp.Math, :sum},
  source: {:result, :double_each},
  map: :double_each,
  after: :double_each
}
```

## `accumulate`

Accumulates state over time.

### Compact Form

```elixir
accumulate :counter, 0, &MyApp.Counter.sum/2
accumulate :counter, 0, {MyApp.Counter, :sum}, after: :sum
```

Options:

- `source:` reference or atom
- `over:` atom or path-source tuple
- `after:` atom or non-empty list of atoms
- `inputs:` Runic input options
- `outputs:` Runic output options

### Block Form

```elixir
accumulate :counter do
  source(result(:sum))
  init(0)
  run({MyApp.Counter, :sum})
end
```

Block forms:

- `source(reference)`, optional
- `init(value)`, required
- `run(callable)`, required

IR:

```elixir
%{
  type: :accumulate,
  name: :counter,
  init: 0,
  reducer: {MyApp.Counter, :sum},
  source: {:result, :sum},
  after: :sum
}
```

## `chain`

Groups entries into a linear dependency chain.

### Block Form

```elixir
chain do
  step :add, MyApp.Add, params: %{amount: 1}
  step :double, MyApp.Double
  step :format, MyApp.Format
end
```

Options are not supported.

Nested `input/1` and `return/1` are not supported.

IR:

```elixir
%{
  type: :chain,
  name: nil,
  flow: [...],
  after: nil
}
```

Review note: `chain` is first-class Flow IR today and round-trips as `chain`.

## `fanout`

Groups entries that depend on one source component.

### Block Form

```elixir
fanout :load_user do
  step :load_profile, MyApp.LoadProfile
  step :load_settings, MyApp.LoadSettings
end
```

Options are not supported.

Nested `input/1` and `return/1` are not supported.

IR:

```elixir
%{
  type: :fanout,
  name: nil,
  from: :load_user,
  flow: [...],
  after: :load_user
}
```

## `collect`

Collects named values into a map-shaped result.

### Block Form

```elixir
collect :dashboard do
  argument(:user, result(:load_user))
  argument(:profile, result(:load_profile))
  argument(:settings, result(:load_settings))
end
```

Options are not supported.

Block forms:

- `argument(name, reference)`

At least one argument is required.

IR:

```elixir
%{
  type: :collect,
  name: :dashboard,
  arguments: %{
    user: {:result, :load_user},
    profile: {:result, :load_profile}
  },
  after: [:load_user, :load_profile]
}
```

Review note: runtime collect behavior still deserves scrutiny. The current
runtime projection is simple and may not be the final fan-in shape.

## `debug`

Adds an explicit inspection/pass-through component.

### Compact Form

```elixir
debug :items_debug
debug :items_debug, source: result(:load_items)
debug :items_debug, source: result(:load_items, [:items]), label: "loaded items", limit: 5
```

Options:

- `source:` optional reference or atom
- `label:` optional string
- `limit:` optional positive integer

### Block Form

```elixir
debug :items_debug do
  source(result(:load_items, [:items]))
  label("loaded items")
  limit(5)
end
```

Block forms:

- `source(reference)`, optional
- `label(string)`, optional
- `limit(positive_integer)`, optional

IR:

```elixir
%{
  type: :debug,
  name: :items_debug,
  source: {:result, :load_items, [:items]},
  label: "loaded items",
  limit: 5,
  after: :load_items
}
```

Review note: the syntax is implemented. The runtime/debug output policy is not
deeply designed yet.

## `trace`

Adds explicit trace metadata as a Flow entry.

### Compact Form

```elixir
trace(:loaded_items)
trace(:loaded_items, source: result(:format))
trace :loaded_items, source: :format
```

Options:

- `source:` optional reference or atom

Block form is not supported.

IR:

```elixir
%{
  type: :trace,
  name: :loaded_items,
  source: {:result, :format},
  after: :format
}
```

## `switch`

Defines runtime branching IR.

Switch is executable as a Jido-owned Runic component. It evaluates predicates
against the value selected by `on`.

### Compact Form

Compact switch selects named targets.

```elixir
switch(:route,
  on: result(:load_order),
  matches?: [
    enterprise: {&MyApp.Order.enterprise?/1, :enterprise},
    premium: {&MyApp.Order.premium?/1, :premium}
  ],
  default: :standard,
  return: true
)
```

Options:

- `on:` reference, required
- `matches?:` keyword list, required and non-empty
- `default:` optional literal target
- `return:` boolean, optional, defaults to `false`

Matches are keyword entries where each value is `{predicate, target}`. With
`return: true`, the switch component emits the selected target or default. With
`return: false`, it emits the selected `on` value.

Renderer note: normalized compact switch may render matches as explicit tuples
inside the list:

```elixir
matches?: [
  {:premium, {&MyApp.Order.premium?/1, :premium}}
]
```

This is still a keyword list in Elixir.

IR:

```elixir
%{
  type: :switch,
  name: :route,
  on: {:result, :load_order},
  matches: [
    %{name: :premium, predicate: {MyApp.Order, :premium?}, then: :premium}
  ],
  default: :standard,
  return?: true,
  after: :load_order
}
```

### Block Form

Block switch defines branch-local flow bodies.

```elixir
switch :route do
  on(result(:load_order))

  matches? :premium, &MyApp.Order.premium?/1 do
    step :premium, MyApp.PremiumFulfillment
    return(result(:premium))
  end

  default do
    step :standard, MyApp.StandardFulfillment
    return(result(:standard))
  end
end
```

Block forms:

- `on(reference)`, required once
- `matches?(name, predicate) do ... end`, at least one
- `default do ... end`, optional at most once

Inside `matches?` and `default` blocks:

- normal Flow entries are allowed
- `return/1` is allowed
- `input/1` is not allowed

Empty branch bodies are rejected.

Runtime note: block switch executes only the selected branch flow. The branch
receives the selected `on` value as its input, and branch `return/1` selects the
value emitted by the switch component.

IR:

```elixir
%{
  type: :switch,
  name: :route,
  on: {:result, :load_order},
  matches: [
    %{
      name: :premium,
      predicate: {MyApp.Order, :premium?},
      flow: [%{type: :step, name: :premium, ...}],
      return: {:result, :premium}
    }
  ],
  default: %{
    flow: [%{type: :step, name: :standard, ...}],
    return: {:result, :standard}
  },
  return?: false,
  after: :load_order
}
```

## Unsupported Syntax

These are intentionally not script syntax:

```elixir
if condition do
  ...
end

case value do
  ...
end

for item <- items do
  ...
end

Enum.map(items, fn item -> ... end)
```

Runtime conditionals should use `switch`.

Repeated runtime processing should use Runic-backed primitives such as `map`,
`reduce`, and `accumulate`.

Template/code-generation loops are intentionally out of scope for foundational
Flow Script IR. If needed later, they should live in a separate projection or
template layer.

## Normalized Rendering

`Jido.Flow.Script.to_script/1` renders normalized script. It does not preserve
comments or original formatting.

Currently round-tripped by tests:

- empty flows
- compact and block steps
- `project`
- compact and block `map`
- compact and block `reduce`
- compact and block `accumulate`
- `chain`
- `fanout`
- `collect`
- compact and block `debug`
- `trace`
- compact and block `switch`

Known non-lossless forms:

- comments and original formatting are not preserved

## Complete Implemented Example

```elixir
flow :checkout do
  input(:cart_id)

  step :load_items, MyApp.LoadItems do
    argument(:items, value([1, 2, 3]))
  end

  project :items, from: :load_items, path: [:items]

  map :line_totals, &MyApp.Pricing.line_total/1 do
    source(result(:items))
  end

  reduce :subtotal do
    source(result(:line_totals))
    init(0)
    run(&MyApp.Money.sum/2)
  end

  step :format_receipt, MyApp.FormatReceipt do
    argument(:subtotal, result(:subtotal))
    wait_for(:subtotal)
  end

  debug :receipt_debug do
    source(result(:format_receipt))
    label("receipt")
    limit(10)
  end

  trace(:checkout_complete, source: result(:receipt_debug))

  return(result(:format_receipt))
end
```

## Current Open Questions

- If iteration-like template expansion is useful, should it live in a separate
  projection/template layer?
- Should block `step` reject using both `after:` and `wait_for/1`?
- Should `argument/2` allow only references, or should literal values be passed
  directly without `value/1`?
- Should `return/1` influence `Exec.run/3`, or only a future projection helper?
- Should `debug` and `trace` be runtime components, telemetry-only metadata, or
  dev-only projection annotations?
- Should `collect` remain a Flow primitive, or become sugar over a generated
  action/step?
- Should normalized rendering favor compact forms or block forms when both are
  possible?
