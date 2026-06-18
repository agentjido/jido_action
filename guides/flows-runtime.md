# Flows & Exec

`Jido.Flow` composes leaf actions. `Jido.Exec` executes those flows through
Runic.

The boundary stays strict:

- an action module's `run/2` computes one leaf result.
- `Jido.Flow` describes composition.
- `Jido.Exec` drives the Runic execution loop and returns `Jido.Exec.Result`.

## Action Steps

Create a flow with `new/1` and add action steps with `step/4`.

```elixir
flow =
  Jido.Flow.new(:checkout)
  |> Jido.Flow.step(:price, MyApp.Actions.PriceCart)
  |> Jido.Flow.step(:tax, MyApp.Actions.CalculateTax, after: :price)
  |> Jido.Flow.step(:receipt, MyApp.Actions.BuildReceipt, after: :tax)

{:ok, result} = Jido.Exec.run(flow, %{cart_id: "cart_123"})
```

Each step wraps one `Jido.Instruction`. Static params can be supplied when the
step is declared:

```elixir
flow =
  Jido.Flow.new(:notify)
  |> Jido.Flow.step(:email, MyApp.Actions.SendEmail, params: %{template: "welcome"})
```

`after:` declares dependency edges. With one parent, the downstream action
receives the upstream result as its input fact. With multiple parents, Runic
joins the upstream values and the downstream action receives them as
`%{input: values}`.

## A Concrete Example

`Jido.Examples.FlowExample` is a runnable checkout flow:

```elixir
{:ok, result} = Jido.Examples.FlowExample.run_checkout("cart_123")

receipt = result.results.build_receipt |> List.first()
receipt.total_cents
#=> 6062
```

The flow does this:

1. `:load_cart` receives `%{cart_id: "cart_123"}`.
2. `:price_cart` and `:reserve_inventory` both consume the loaded cart.
3. `:reserve_inventory` intentionally fails once; Runic retries the flow step.
4. `:calculate_tax` consumes the priced cart.
5. `:build_receipt` fan-ins tax and inventory results through a Runic join.

The result can be inspected without reaching into private state:

```elixir
Jido.Exec.summary(result)
Jido.Exec.results(result)
Jido.Flow.graph(result.workflow)
```

`Jido.Flow.graph/1` returns component metadata plus structural edges, so it is a
small projection for tests, diagnostics, or developer tooling.

## Native Runic Components

Use `component/4` when the flow needs native Runic stateful behavior, such as an
accumulator or state machine.

```elixir
counter =
  Runic.accumulator(0, fn value, state -> state + value end, name: :counter)

flow =
  Jido.Flow.new(:counter)
  |> Jido.Flow.component(:counter, counter)

{:ok, result} = Jido.Exec.run(flow, 2)
{:ok, result} = result.workflow |> Jido.Flow.from_workflow() |> Jido.Exec.run(3)
```

`component/4` is intentionally an advanced escape hatch. Prefer `step/4` for
ordinary action composition.

## Runtime Execution

`Jido.Exec.run/3` runs a flow to quiescence in the current process:

```elixir
{:ok, result} =
  Jido.Exec.run(flow, params,
    max_cycles: 100,
    run_context: %{request_id: request_id}
  )
```

`:max_cycles` bounds the number of runnable generations. Use it for reactive
flows that may continue producing work.

Managed execution delegates to `Runic.Runner`:

```elixir
{:ok, _pid} = Runic.Runner.start_link(name: MyApp.FlowRunner)
{:ok, _worker} =
  Runic.Runner.start_workflow(MyApp.FlowRunner, :checkout, Jido.Flow.to_workflow(flow))

:ok = Runic.Runner.run(MyApp.FlowRunner, :checkout, %{cart_id: "cart_123"})
{:ok, results} = Runic.Runner.get_results(MyApp.FlowRunner, :checkout)
{:ok, workflow} = Runic.Runner.get_workflow(MyApp.FlowRunner, :checkout)
```

Use `Runic.Runner.checkpoint/2` when the configured Runner store supports
persistence and `Runic.Runner.stop/3` when the managed flow should shut down.

## Loops

Arbitrary cyclic graph edges are not the first Jido API. Model loops through:

- repeated calls to `Jido.Exec.run/3` or `Jido.Exec.resume/3`
- Runic stateful components such as accumulators and state machines
- bounded reactive execution with `:max_cycles`

This keeps actions as leaves while still allowing stateful flow behavior.

## Migration From `jido_runic`

`jido_runic` is deprecated as a separate bridge. Move composition code to
`jido_action`:

- replace program/workflow bridge usage with `Jido.Flow`
- use `Jido.Exec` for local flow execution and `Runic.Runner` for managed flow execution
- keep action calls represented by `Jido.Instruction`
- keep retries, timeouts, fallback, scheduling, and durable execution in Runic
- keep direct action calls as plain validation plus `run/2`

Do not move agent strategy, signals, child workers, or directive execution into
this layer.
