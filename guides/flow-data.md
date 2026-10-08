# Flow Data Definitions

Use `Jido.Flow.new/1` to build a Flow at runtime from plain maps. A data
definition, a Flow module, and a stored JSON document decoded by
`Jido.Flow.Codec` all produce the same kind of canonical `%Jido.Flow{}` value,
and `Jido.Exec` runs it the same way.

Use a data definition when your application assembles a Flow at runtime, such
as from configuration or a builder UI. Use a [Flow module](flow-modules.md)
when you write the Flow in source code. Use [stored JSON](flow-storage.md) when
the definition comes from a database, another service, or an AI model.

## Define A Flow

```elixir
defmodule MyApp.Actions.SendNotice do
  use Jido.Action,
    name: "send_notice",
    schema: Zoi.object(%{address: Zoi.string()})

  @impl true
  def run(%{address: address}, _context), do: {:ok, %{sent_to: address}}
end

alias Jido.Flow
alias Jido.Flow.Ref

{:ok, flow} =
  Flow.new(%{
    name: "send_notice",
    components: [
      %{
        kind: :step,
        name: "send",
        action: MyApp.Actions.SendNotice,
        params: %{address: Ref.input(:address)}
      }
    ],
    output: Ref.result("send")
  })

{:ok, %{sent_to: "ada@example.com"}} = Jido.Exec.run(flow, %{address: "ada@example.com"})
```

`new/1` returns `{:ok, flow}` or a structured validation error. `new!/1`
raises that error. Validation does not load or run Action targets. Call
`Jido.Exec.compile/1` when you also want to check target contracts without
running work.

The definition is a map with atom keys:

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | Yes | The Flow name, a string. |
| `description` | No | A string description. |
| `schema` | No | A static input schema. Defaults to `[]`. |
| `output_schema` | No | A static output schema. Defaults to `[]`. |
| `components` | Yes | A non-empty list of component maps. |
| `output` | Yes | A non-`nil` Flow value, usually a map of references. |

Unknown keys and unknown component kinds are rejected. Build the complete
definition with normal list and map operations, then call `Jido.Flow.new/1`.
There is no separate finalization step.

## Component Kinds

Every component map has a `kind` and a `name`. All kinds also accept `needs`, a
list of component names, and `meta`, a portable map. `params` is optional and
defaults to `%{}`.

| `kind` | Target fields | Other fields |
| --- | --- | --- |
| `:step` | `action` | `params` |
| `:subflow` | `flow` | `params` |
| `:choice` | `action` inside each option and the fallback | `options`, `fallback` |
| `:map` | `action` | `collection`, `params`, `on_error` |
| `:reduce` | `action` | `collection`, `initial`, `params` |
| `:iterate` | `action` | `params`, `state`, `completion`, `max_iterations` |
| `:dispatch` | `decision`, `expander` | `params` |

List order matters for Choice options, which are tested in order. Component
list order does not create dependencies; result references and `needs` do.

A map definition never infers a child Flow. Use `kind: :subflow` with a `flow`
field for a child Flow module, and `kind: :step` with an `action` field for an
Action. See [Nested Flows](nested-flows.livemd).

The examples below use these Actions:

```elixir
defmodule MyApp.Actions.Route do
  use Jido.Action, name: "route"

  @impl true
  def run(params, _context), do: {:ok, params}
end

defmodule MyApp.Actions.Add do
  use Jido.Action, name: "add"

  @impl true
  def run(%{total: total, value: value}, _context), do: {:ok, %{total: total + value}}
end

defmodule MyApp.Actions.Increment do
  use Jido.Action, name: "increment"

  @impl true
  def run(%{count: count}, _context), do: {:ok, %{count: count + 1}}
end
```

### Choice

Each option has a `name`, a `condition`, an `action`, and `params`. The
`fallback` has an `action` and `params`. A condition is a Boolean, a reference,
or a `Jido.Expr` operation.

```elixir
{:ok, router} =
  Flow.new(%{
    name: "route_by_priority",
    components: [
      %{
        kind: :choice,
        name: "route",
        options: [
          %{
            name: "urgent",
            condition: Jido.Expr.new!(:>=, [Ref.input(:priority), 90]),
            action: MyApp.Actions.Route,
            params: %{queue: :urgent}
          }
        ],
        fallback: %{action: MyApp.Actions.Route, params: %{queue: :standard}}
      }
    ],
    output: Ref.result("route")
  })

{:ok, %{queue: :urgent}} = Jido.Exec.run(router, %{priority: 95})
{:ok, %{queue: :standard}} = Jido.Exec.run(router, %{priority: 10})
```

### Map

`collection` must resolve to a list. `on_error` is `:fail_fast`, the default,
or `:collect_errors`.

```elixir
{:ok, tagger} =
  Flow.new(%{
    name: "tag_ids",
    components: [
      %{
        kind: :map,
        name: "tagged",
        collection: Ref.input(:ids),
        action: MyApp.Actions.Route,
        params: %{id: Ref.item(), index: Ref.item_index()}
      }
    ],
    output: %{tagged: Ref.result("tagged")}
  })

{:ok, %{tagged: [%{id: :a, index: 0}, %{id: :b, index: 1}]}} =
  Jido.Exec.run(tagger, %{ids: [:a, :b]})
```

### Reduce

`initial` is the first accumulator. It must be a map. Each call returns the
next accumulator.

```elixir
{:ok, summer} =
  Flow.new(%{
    name: "sum_values",
    components: [
      %{
        kind: :reduce,
        name: "sum",
        collection: Ref.input(:values),
        initial: %{total: 0},
        action: MyApp.Actions.Add,
        params: %{total: Ref.accumulator(:total), value: Ref.item()}
      }
    ],
    output: Ref.result("sum")
  })

{:ok, %{total: 6}} = Jido.Exec.run(summer, %{values: [1, 2, 3]})
```

### Iterate

The data form differs from the DSL:

- `completion` is a stop condition. The loop stops when it is `true`. It is
  checked before each call.
- A DSL `while condition` is the same as `completion: not condition`.
- A DSL `repeat n` is the same as
  `completion: iteration_index() >= n` with `max_iterations: n`.
- `state` is a map with `schema` (optional, default `[]`), `initial`
  (required), and `update` (required). The DSL fills in `update` for you; the
  data form does not.
- `max_iterations` is required, from 1 through 10,000. If `completion` is
  still `false` at the bound, the Iterate fails.

```elixir
{:ok, counter} =
  Flow.new(%{
    name: "count_to_three",
    components: [
      %{
        kind: :iterate,
        name: "counter",
        action: MyApp.Actions.Increment,
        params: %{count: Ref.state(:count)},
        state: %{
          schema: Zoi.object(%{count: Zoi.integer()}),
          initial: %{count: 0},
          update: %{count: Ref.body_result(:count)}
        },
        completion: Jido.Expr.new!(:>=, [Ref.state(:count), 3]),
        max_iterations: 10
      }
    ],
    output: %{count: Ref.result("counter", [:state, :count])}
  })

{:ok, %{count: 3}} = Jido.Exec.run(counter, %{})
```

See [Iterate And State](flow-iterate-state.livemd) for the State rules.

### Dispatch

A Dispatch has `decision`, `expander`, and `params`. A Flow can contain one
Dispatch. It must be the single final component, and the Flow output must be
its complete result. See [Dynamic Flows](dynamic-flows.md).

## References And Expressions

Build references with `Jido.Flow.Ref`: `input/1`, `context/1`, `result/2`,
`select/2`, `item/1`, `item_index/0`, `item_id/0`, `accumulator/1`, `state/1`,
`iteration_index/0`, and `body_result/1`. The constructors do not validate;
`Jido.Flow.new/1` validates every path and scope. See
[References And Data](flow-references.livemd).

Build operations with `Jido.Expr.new/2`, `Jido.Expr.new!/2`, or the `expr/1`
macro. See [Expressions](flow-expressions.md).

Ordinary maps and lists stay literal data. Jido never treats a literal map as
an operation or reference because of its keys.

## Reuse An Inline Step

A compiled Flow module exposes each Step's Action through `step_action/1`.
Supply new params, dependencies, and metadata when you reuse it:

```elixir
defmodule MyApp.Flows.NormalizePerson do
  use Jido.Flow, name: "normalize_person"

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    output result("normalize")
  end
end

names =
  Flow.new!(%{
    name: "normalize_names",
    components: [
      %{
        kind: :map,
        name: "names",
        collection: Ref.input(:people),
        action: MyApp.Flows.NormalizePerson.step_action("normalize"),
        params: %{name: Ref.item()}
      }
    ],
    output: %{names: Ref.result("names")}
  })

{:ok, %{names: [%{name: "Ada"}, %{name: "Grace"}]}} =
  Jido.Exec.run(names, %{people: [" Ada ", "Grace "]})
```

Data definitions accept compiled Action modules. They do not accept inline
body code, anonymous functions, or MFA targets.

## Stored Or AI-Generated Definitions

An Elixir data definition contains trusted modules and references. Do not
build one from untrusted input. For JSON from storage, another service, or an
AI model, use `Jido.Flow.Codec.decode/2` with a host-owned
`Jido.Flow.Registry`. The Registry maps approved identifiers to modules,
schemas, and atoms; input strings never create atoms or module names. See
[Store Flows As JSON](flow-storage.md).

## Canonical Graph Shape

This section is advanced and for inspection only. Author with the module DSL
or component maps, not with this internal shape.

`Jido.Flow.new/1` normalizes the component list into a map keyed by component
name, stored in the `components` field of `%Jido.Flow{}`. The map has no order;
dependencies define the graph order.

A Step and a Subflow both normalize to a `:call` node. An inert
`Jido.Instruction` template holds the target and its kind:

```elixir
%{kind: :call, needs: [], meta: %{}, call: {template, params}} =
  flow.components["send"]

%Jido.Instruction{
  kind: :action,
  target: MyApp.Actions.SendNotice,
  params: %{},
  context: %{}
} = template

%{address: %Jido.Flow.Ref{}} = params
```

Choice, Map, Reduce, Iterate, and Dispatch use the same
`{instruction_template, params}` tuple for each Action they call. The Dispatch
expander stores `nil` as its params because it receives the decision result.
A template holds no bound params or context; `Jido.Exec` evaluates the params
and binds runtime data when it runs the call.

Use `Jido.Flow.to_map/1` for a deterministic inspection view and
`Jido.Flow.Codec` for storage.

## Migrate From Builder

`Jido.Flow.Builder` was removed in the V3 beta. Replace its pipeline with one
complete definition map and `Jido.Flow.new/1`:

- Replace reference helpers with `Jido.Flow.Ref`.
- Replace condition helpers with `Jido.Expr`.
- Replace Choice helpers with option and fallback maps.
- Use an explicit `:subflow` component for a child Flow.
