# Direct Construction And Builder

Direct constructors and `Jido.Flow.Builder` are official Flow APIs. Both
produce the same canonical `%Jido.Flow{}` as the module DSL.

## Direct Construction

Use direct constructors when application code already has the component data.

```elixir
alias Jido.Flow
alias Jido.Flow.Ref
alias Jido.Flow.Step

flow =
  Flow.new!(
    name: "runtime_greeting",
    description: "A directly constructed Flow",
    schema: [],
    output_schema: [],
    components: [
      Step.new!(
        name: "greet",
        action: MyApp.Actions.CreateGreeting,
        params: %{name: Ref.input(:name)},
        meta: %{source: "application"}
      )
    ],
    output: Ref.result("greet")
  )
```

Use `new/1` for untrusted or fallible construction. Do not use raw struct
literals as a substitute for constructor validation.

Each canonical component has `new/1` and `new!/1`. Choice options, Choice
fallbacks, and Iterate State have constructors too.

## Runtime Builder

Use Builder when code adds components in stages.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(
    name: "runtime_greeting",
    description: "A Flow built in stages"
  )
  |> Builder.step(
    "greet",
    MyApp.Actions.CreateGreeting,
    %{name: Builder.input(:name)},
    meta: %{source: "application"}
  )
  |> Builder.output(Builder.result("greet"))

{:ok, flow} = Builder.build(builder)
```

Builder keeps the first construction error. Each add function returns the
Builder. `build/1` returns that error or validates the complete Flow.

## Reuse An Inline Step

First run the module definition in [Build Your First Flow](build-your-first-flow.livemd).
Then look up its compiled targets. No generated module name is needed.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(
    name: FirstFlow.Greeting.name(),
    description: FirstFlow.Greeting.description(),
    schema: FirstFlow.Greeting.schema(),
    output_schema: FirstFlow.Greeting.output_schema()
  )
  |> Builder.step(
    "normalize",
    FirstFlow.Greeting.step_action("normalize"),
    %{name: Builder.input(:name)}
  )
  |> Builder.step(
    "greet",
    FirstFlow.Greeting.step_action(:greet),
    %{name: Builder.result("normalize", :name)}
  )
  |> Builder.output(Builder.result("greet"))

{:ok, built_flow} = Builder.build(builder)
true = built_flow == FirstFlow.Greeting.flow()
{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(built_flow, %{name: " Ada "})
```

This rebuilds the same graph. You can instead supply different parameters,
dependencies, and metadata. `step_action/1` returns only an Action target; it
does not copy the original Step's fields. Named bindings require a parameter
map with those atom keys. A sole map-pattern binding receives the complete
source map. A no-input Step receives `%{}`.

The target is an ordinary Action, so an existing Map can also reuse it:

```elixir
{:ok, names_flow} =
  Builder.new(name: "normalize_names")
  |> Builder.map(
    "names",
    Builder.input(:people),
    FirstFlow.Greeting.step_action("normalize"),
    %{name: Builder.item()}
  )
  |> Builder.output(%{names: Builder.result("names")})
  |> Builder.build()

{:ok, %{names: [%{name: "Ada"}, %{name: "Grace"}]}} =
  Jido.Exec.run(names_flow, %{people: [" ada ", " grace "]})
```

This Builder example reuses a compiled Action target. The module DSL can also
author an inline Map body through a nested `action` block.
Builder and direct constructors still accept only compiled targets, not body
code, anonymous functions, or MFAs. Use `Jido.Action.Inline.target!/2` to reuse
other inline roles with a new parameter mapping. See
[Portable Inline Actions](inline-actions.md). This API requires
`3.0.0-beta.6` or later.

## Builder Functions

Builder provides component functions:

```text
step  choice  map  reduce  iterate  dispatch  output
```

It also provides the canonical reference and condition helpers:

```text
input  context  result  select  value
item  item_index  item_id  accumulator
state  iteration_index  body_result
eq  neq  lt  lte  gt  gte  in  all  any  not
```

`step/5` resolves its target. An Action target becomes `Jido.Flow.Step`. A
Flow module target becomes `Jido.Flow.Subflow`.

## Example Choice

```elixir
options = [
  Builder.option(
    "priority",
    Builder.eq(Builder.input(:tier), :priority),
    MyApp.Actions.PriorityRoute,
    %{request: Builder.input(:request)}
  )
]

fallback =
  Builder.fallback(
    MyApp.Actions.StandardRoute,
    %{request: Builder.input(:request)}
  )

builder =
  Builder.new(name: "route_request")
  |> Builder.choice("route", options, fallback)
  |> Builder.output(Builder.result("route"))

{:ok, flow} = Builder.build(builder)
```

Direct constructors give the clearest canonical shape. Builder gives a fluent
runtime assembly API. Use the module DSL for static source-code definitions
and Codec for stored JSON.
