# Jido.Exec

`Jido.Exec` is the public execution boundary. It runs an action module, a
`Jido.Instruction`, a Flow module, or a `%Jido.Flow{}` artifact.

The common entry point is:

```elixir
Jido.Exec.run(executable, input, context, options)
```

Input and context can be maps, keyword lists, or `nil`. Options are supported
only for flows.

## Run An Action Module

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Actions.NormalizeEmail,
    %{email: "ADA"},
    %{default_domain: "example.org"}
  )
```

For an action module, `Jido.Exec`:

1. Builds an instruction.
2. Checks the action callback contract.
3. Validates input params.
4. Calls `run/2`.
5. Normalizes exceptions, throws, and non-standard return values.
6. Validates the successful output.

## Run An Instruction

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.NormalizeEmail,
    params: %{email: "ADA"},
    context: %{default_domain: "example.org"}
  )

{:ok, result} = Jido.Exec.run(instruction)
```

Call-site input and context merge over values that are already in the
instruction:

```elixir
{:ok, result} =
  Jido.Exec.run(instruction, %{email: "GRACE"}, %{request_id: "req-2"})
```

## Run A Flow

Run either a Flow module or its canonical artifact:

```elixir
{:ok, result} = Jido.Exec.run(MyApp.Flows.DoubleAfterIncrement, %{value: 3}, %{})

flow = MyApp.Flows.DoubleAfterIncrement.flow()
{:ok, result} = Jido.Exec.run(flow, %{value: 3}, %{})
```

For a flow, `Jido.Exec`:

1. Validates the Flow structure and action contracts.
2. Validates the Flow input.
3. Compiles the dependency graph to a Runic workflow.
4. Resolves each node input from Flow input, context, literals, and prior node
   results.
5. Validates and runs each action node.
6. Resolves the declared return expression.
7. Validates the Flow output.

## Flow Run Options

Flow execution is serial by default. Use `async: true` to let Runic schedule
independent graph branches concurrently:

```elixir
{:ok, result} =
  Jido.Exec.run(MyApp.Flows.LoadDashboard, input, context,
    async: true,
    max_concurrency: 4
  )
```

The supported options are:

- `:async` is a boolean. The default is `false`.
- `:max_concurrency` is a positive integer.

Options on an action or instruction return a validation error.

## Results And Extras

An action or instruction can return these public results:

- `{:ok, output}`
- `{:ok, output, extras}`
- `{:error, error}`
- `{:error, error, extras}`

`Jido.Exec` preserves extras for direct action and instruction execution. Flow
nodes discard extras because node dependencies use only action outputs.

A normal success output is a map. Use `Jido.Action.Output` for an intentional
raw, stream, batch, or opaque success value.

## Errors

`Jido.Exec` returns Jido Action exceptions for validation, configuration, and
execution failures. If an action returns a non-exception reason, such as an
atom or tuple, `Jido.Exec` converts it to an execution error.

```elixir
case Jido.Exec.run(MyApp.Actions.NormalizeEmail, input, context) do
  {:ok, output} ->
    {:ok, output}

  {:error, error} ->
    {:error, Jido.Action.Error.to_map(error)}
end
```

An exception or throw from action code becomes a structured execution error.
`Jido.Exec` does not add retries, timeouts, persistence, or supervision.

## Telemetry

Every public call emits a `[:jido, :exec, :run]` telemetry span. Metadata
identifies the executable kind and name.

Each Flow node also emits a `[:jido, :flow, :node]` span. Node events can come
from task processes when asynchronous Flow execution is active.
