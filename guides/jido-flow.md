# Jido Flow

A flow is a named graph of action calls with one declared return value. Use it
when several actions should run as one data artifact, while keeping each action
small and reusable.

Flows are not policy containers. Retry, timeout, fallback, persistence, and
durable execution belong outside the flow artifact.

## Define The Actions

Flow steps call normal `Jido.Action` modules.

```elixir
defmodule MyApp.Actions.Add do
  use Jido.Action,
    name: "add",
    schema:
      Zoi.object(%{
        value: Zoi.integer(),
        amount: Zoi.integer()
      }),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value, amount: amount}, _context) do
    {:ok, %{value: value + amount}}
  end
end

defmodule MyApp.Actions.Multiply do
  use Jido.Action,
    name: "multiply",
    schema:
      Zoi.object(%{
        value: Zoi.integer(),
        amount: Zoi.integer()
      }),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value, amount: amount}, _context) do
    {:ok, %{value: value * amount}}
  end
end
```

## Define A Flow Module

`use Jido.Flow` gives the module action-compatible metadata and validation
callbacks. The `flow` block lowers into a canonical `Jido.Flow` artifact at
compile time.

```elixir
defmodule MyApp.Flows.DoubleAfterIncrement do
  use Jido.Flow,
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  alias MyApp.Actions.{Add, Multiply}

  flow do
    added = step(:add_one, Add, with: %{value: input(:value), amount: value(1)})

    doubled =
      step(:double, Multiply,
        with: %{value: select(added, :value), amount: value(2)}
      )

    return(doubled)
  end
end
```

Generated helpers:

- `name/0` and `description/0` return flow metadata.
- `schema/0` and `output_schema/0` expose validation schemas.
- `validate_params/1` and `validate_output/1` match the action contract.
- `flow/0` returns the canonical `Jido.Flow` artifact.
- `to_map/1` returns a deterministic map form.
- `compile/0` compiles the flow for graph inspection.
- `run/2` delegates to `Jido.Exec.run/3`.

## Use References

Flow inputs are data expressions, not arbitrary Elixir code.

- `input(:key)` reads from runtime flow input.
- `context(:key)` reads from runtime context.
- `value(term)` embeds a literal value.
- `result(:step_name, :path)` reads a previous step result.
- `select(source, path)` projects nested data from another expression.

```elixir
flow do
  quote =
    step(:load_quote, MyApp.Actions.LoadQuote,
      with: %{id: input(:quote_id), tenant_id: context(:tenant_id)}
    )

  priced =
    step(:price_quote, MyApp.Actions.PriceQuote,
      with: %{quote: quote, currency: value("USD")}
    )

  return(%{
    quote_id: select(quote, :id),
    total: select(priced, [:pricing, :total]),
    tenant_id: context(:tenant_id)
  })
end
```

The return expression may be a single step result, a selected value, or a shaped
map/list containing references and literals. It must include at least one step
result.

## Model Independent Branches

Use `group` and `branch` to express independent static branches. Branch names
are provenance only; dependencies still come from references between steps.

```elixir
flow do
  cart = step(:load_cart, MyApp.Actions.LoadCart, with: %{id: input(:cart_id)})

  group do
    branch :pricing do
      priced = step(:price_cart, MyApp.Actions.PriceCart, with: cart)
    end

    branch :inventory do
      reserved = step(:reserve_inventory, MyApp.Actions.ReserveInventory, with: cart)
    end
  end

  finalized =
    step(:finalize_cart, MyApp.Actions.FinalizeCart,
      with: %{priced: priced, reserved: reserved}
    )

  return(finalized)
end
```

Independent branches run serially by default. Enable concurrent branch execution
at the execution boundary:

```elixir
{:ok, result} =
  Jido.Exec.run(MyApp.Flows.DoubleAfterIncrement, %{value: 3}, %{},
    async: true,
    max_concurrency: 4
  )
```

Run options are supported only for flows.

## Execute Through Jido.Exec

Run a flow module or a flow artifact through `Jido.Exec`.

```elixir
{:ok, %{value: 8}} = Jido.Exec.run(MyApp.Flows.DoubleAfterIncrement, %{value: 3}, %{})

flow = MyApp.Flows.DoubleAfterIncrement.flow()
{:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3}, %{})
```

Execution validates flow input before running steps and validates the declared
return value against the output schema after execution.

Action extras are intentionally discarded during flow execution. Extras remain
available when running a leaf action or instruction directly.

## Step Through A Flow

`Jido.Exec.start/4` validates the Flow and its input, then pauses before the
first Flow node. It returns an opaque `Jido.Exec.Execution` value.

```elixir
{:ok, execution} =
  Jido.Exec.start(
    MyApp.Flows.DoubleAfterIncrement,
    %{value: 3},
    %{}
  )

:running = Jido.Exec.status(execution)
["add_one"] = Jido.Exec.ready(execution)

{:ok, add_result, execution} = Jido.Exec.step(execution, "add_one")

:ok = add_result.status
%{value: 4} = add_result.output
["double"] = Jido.Exec.ready(execution)

{:ok, double_result, execution} = Jido.Exec.step(execution)

"double" = double_result.node
:succeeded = Jido.Exec.status(execution)
{:ok, %{value: 8}} = Jido.Exec.result(execution)
```

`step/1` executes the first ready node in canonical Flow order. `step/2`
executes the named node only when that node is ready. Each successful operation
returns a new execution value. Always pass the latest value to the next call.
Reusing an older value can run an Action more than once.

A node failure is a valid execution transition. The operation returns an `:ok`
tuple with a node result that has `status: :error`. The updated execution keeps
the error. Dependent nodes are skipped, but independent ready nodes can still
run.

```elixir
{:ok, failed_node, execution} = Jido.Exec.step(execution, "load_account")

:error = failed_node.status
error = failed_node.error
```

After all remaining work finishes, `Jido.Exec.result/1` returns the Flow error.

## Execute One Ready Wave

`Jido.Exec.wave/1` executes the complete set of nodes that is ready when the
wave starts. Nodes that become ready during the wave wait for the next call.

```elixir
{:ok, execution} =
  Jido.Exec.start(MyApp.Flows.LoadDashboard, input, context,
    async: true,
    max_concurrency: 4
  )

["load_account", "load_orders"] = Jido.Exec.ready(execution)

{:ok, node_results, execution} = Jido.Exec.wave(execution)

["build_dashboard"] = Jido.Exec.ready(execution)
```

With `async: true`, independent nodes in the wave can run concurrently.
`max_concurrency` limits the number of Action tasks. The returned node results
remain in canonical Flow order.

Use `Jido.Exec.continue/1` when you want to resume a paused execution and run all
remaining waves:

```elixir
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, dashboard} = Jido.Exec.result(execution)
```

Nested Flows execute as one node in the parent Flow. Step-wise executions are
in-memory values. They are not persistent checkpoints and they do not provide
rewind or exactly-once side-effect guarantees.

## Inspect And Store Flow Maps

`to_map/1` emits a deterministic semantic map. Independent nodes are ordered by
dependency and node name, so equivalent flows compare consistently.

```elixir
%{
  type: :flow,
  version: 1,
  name: "double_after_increment",
  nodes: nodes,
  return: return_ref
} = MyApp.Flows.DoubleAfterIncrement.to_map()
```

Use the stored format when source/provenance needs to round-trip with the flow:

```elixir
actions = %{
  "add" => MyApp.Actions.Add,
  "multiply" => MyApp.Actions.Multiply
}

stored =
  MyApp.Flows.DoubleAfterIncrement.to_map(
    format: :stored,
    actions: actions,
    provenance: true
  )

{:ok, flow} = Jido.Flow.from_map(stored, actions: actions)
```

## Keep Flow Boundaries Small

Prefer flows for explicit action composition:

- Each step is a `Jido.Action`.
- Inputs are declared with data references.
- Dependencies are visible in the graph.
- The flow has one declared return value.

Keep runtime policy outside the flow. If execution needs retries, deadlines,
fallbacks, persistence, or orchestration across processes, layer that behavior
around `Jido.Exec` rather than into `Jido.Flow`.
