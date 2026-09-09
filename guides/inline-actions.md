# Inline Actions

An inline Action keeps small, local work inside the Flow that owns it. Its body
is normal Elixir code, but it compiles to an ordinary `Jido.Action`.

Inline Actions use normal input validation, output validation, errors,
telemetry, timeout, cancellation, and concurrency behavior. They do not store
code in a Flow and they do not create runtime function targets.

Use a named Action module when the work needs independent reuse, lifecycle
hooks, a public module API, or a separate deployment boundary.

## Write An Inline Step

The short Step form binds Flow data before it runs the body:

```elixir
defmodule MyApp.Flows.Greeting do
  use Jido.Flow, name: "greeting"

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    step "greet", name <- result("normalize", :name) do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output result("greet")
  end
end
```

The binding expression is Flow data. The body is normal Elixir. The body can
call functions, use pipes, match values, and call private functions in the
owner module.

The short Step form accepts only Step options such as `after:` and `meta:`.
Use a nested `action` block for Action schemas, descriptions, or context.

## Configure An Inline Action

The nested form separates component fields from Action fields:

```elixir
step "greet", after: ["normalize"], meta: %{kind: "message"} do
  action name <- result("normalize", :name),
    name: "build_greeting",
    description: "Build a greeting",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()}),
    context: ctx do
    {:ok, %{message: ctx.prefix <> ", " <> name}}
  end
end
```

Inline Action options are:

- `name`
- `description`
- `schema`
- `output_schema`
- `context`
- the required `do` body

Omitted schemas are `[]`. Bindings do not infer fields, types, or defaults.
Schemas validate the resolved parameter map before the body runs.

`context: ctx` binds the second Action callback argument. It does not add a
parameter. Bind `ctx <- context()` only when context must become part of the
Action parameter map.

## Bind Inputs

Bound inline Actions resolve Flow expressions into an atom-keyed parameter map:

| Header | Parameters passed to the Action |
| --- | --- |
| `value <- source` | `%{value: resolved_source}` |
| `[left <- source, right <- other]` | A map with both resolved values. |
| `%{name: name} <- source` | The complete resolved source map. |
| `[]` | `%{}` |

Examples:

```elixir
action value <- input(:value) do
  {:ok, %{value: value * 2}}
end

action [left <- input(:left), right <- input(:right)] do
  {:ok, %{total: left + right}}
end

action %{name: name} <- input(:person) do
  {:ok, %{name: String.trim(name)}}
end
```

Do not mix a map binding with named bindings. A map binding must be the only
binding. Pins, header guards, top-level struct patterns, duplicate names, and
bare `_` bindings are not supported.

## Match Several Clauses

Use clause heads when one inline Action must match several input shapes:

```elixir
step "divide" do
  action operand <- input(:operand),
    schema: Zoi.object(%{operand: Zoi.number()}), context: ctx do
    %{operand: 0} ->
      {:error, Jido.Action.Error.validation_error("Cannot divide by zero")}

    %{operand: operand} ->
      {:ok, %{value: ctx.total / operand}}
  end
end
```

All clauses belong to one Action identity and use one schema. Clause heads can
use guards, `_`, a named variable, or a map pattern. Do not mix clause heads
with a separate expression body.

## Use Inline Actions In Components

The nested `action` form works in Step, Map, Reduce, Iterate, Choice options,
and Choice fallback blocks.

```elixir
flow do
  map "doubled" do
    collection input(:values)

    action value <- item() do
      {:ok, %{value: value * 2}}
    end
  end

  reduce "total" do
    collection result("doubled")
    initial %{total: 0}

    action [total <- accumulator(:total), value <- item(:value)] do
      {:ok, %{total: total + value}}
    end
  end

  choice "label" do
    option "positive" do
      condition result("total", :total) > 0

      action [] do
        {:ok, %{label: :positive}}
      end
    end

    otherwise do
      action [] do
        {:ok, %{label: :empty}}
      end
    end
  end

  iterate "counter" do
    state Zoi.object(%{count: Zoi.integer()}), initial: %{count: 0}

    action count <- state(:count) do
      {:ok, %{count: count + 1}}
    end

    repeat 2
  end

  output %{
    total: result("total", :total),
    label: result("label", :label),
    count: result("counter", [:state, :count])
  }
end
```

Map preserves source order. Reduce and Iterate run serially. Each binding
source uses the reference scope of the component that owns it.

Do not combine an inline block with an explicit `action` or `params` field for
the same component slot.

## Use Inline Actions In Dispatch

Dispatch has two inline roles. The decision uses bound mode. The expander uses
callback mode and receives the complete decision result:

```elixir
dispatch "next" do
  decision value <- input(:value) do
    {:ok, %{value: value + 1}}
  end

  expander %{value: value}, context: ctx do
    {:continue, %{value: value, prefix: ctx.prefix}, MyApp.Actions.Finish}
  end
end
```

The expander can instead return `{:ok, result}` to complete the Flow. It does
not have an `expander_params` field because its input is always the decision
result.

See [Dynamic Flows](dynamic-flows.md) for terminal placement,
continuations, output ownership, and execution limits.

## Return Values

An inline Action uses the same return forms as a named Action:

```elixir
{:ok, result}
{:ok, result, extra}
{:error, reason}
{:error, reason, extra}
```

A normal success result is a map. Use `Jido.Action.Output` for an intentional
raw, stream, batch, or opaque value.

Flow components discard Action extras. A root Action or a Dispatch expander
can return `{:continue, input, target}`. Other Flow positions cannot continue.

## Reuse A Compiled Inline Action

An inline body compiles with its owner module. You can reuse the compiled
Action target without using its generated module name:

```elixir
target = MyApp.Flows.Greeting.step_action("normalize")

{:ok, %{name: "Ada"}} =
  Jido.Exec.run(target, %{name: " Ada "})
```

`step_action/1` works only for Action-backed Steps. Use typed lookup for other
roles:

```elixir
target =
  Jido.Action.Inline.target!(MyApp.Flows.Example,
    host: Jido.Flow,
    map: "doubled",
    role: :action
  )
```

The target does not retain the original Flow binding expressions. Supply a new
parameter map when you run it or place it in a Builder Flow.

Register a reused target under an application-owned stable identifier. Do not
store its generated module name. JSON stores target identifiers and data, not
inline bodies.

## Compile-Time Limits

An inline body can use the owner module's private helpers, aliases, imports,
module attributes, and `__MODULE__`. It cannot capture runtime variables from
outside its declaration.

Inline Actions are compile-time code. Direct constructors, Builder, and stored
JSON cannot accept body code, anonymous functions, or MFAs. Deploy the owner
module and its generated Action modules together.

Packages that want to add this syntax to another compile-time DSL can use the
public host API. See
[Building DSLs With Inline Actions](building-dsls-with-inline-actions.md).
