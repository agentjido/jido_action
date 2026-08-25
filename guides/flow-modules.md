# Flow Modules

A Flow module is the primary source-code authoring API. Spark parses the DSL at
compile time and lowers it once to a canonical `%Jido.Flow{}`.

## Define A Module

```elixir
defmodule MyApp.Flows.Greeting do
  use Jido.Flow,
    name: "greeting",
    description: "Creates one greeting",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  flow do
    step "greet",
      action: MyApp.Actions.CreateGreeting,
      params: %{name: input(:name)},
      meta: %{owner: "communications"}

    output result("greet")
  end
end
```

The DSL validates syntax, Flow structure, reference scope, graph cycles, and
target contracts during compilation. Compile errors use DSL source locations.

## Generated API

A Flow module exposes the Action-compatible and Flow-specific functions that
an application needs:

```elixir
MyApp.Flows.Greeting.name()
MyApp.Flows.Greeting.description()
MyApp.Flows.Greeting.schema()
MyApp.Flows.Greeting.output_schema()
MyApp.Flows.Greeting.validate_params(%{name: "Ada"})
MyApp.Flows.Greeting.validate_output(%{message: "Hello"})
MyApp.Flows.Greeting.flow()
MyApp.Flows.Greeting.compiled()
MyApp.Flows.Greeting.run(%{name: "Ada"}, %{})
```

`flow/0` returns the same canonical value for the life of the loaded module
version. Put changing values in input or context, not in module construction.

`compiled/0` returns derived `Jido.Flow.Compiled` data. It includes a native
Runic workflow and the source map. It is not a storage format.

`run/2` delegates to `Jido.Exec.run/4` with default options. Use `Jido.Exec`
directly when you need runtime options.

## Source Metadata

The compiler stores file, line, and available column data in a source map
outside the canonical Flow value. Component `meta` remains portable author
data. This separation keeps direct, Builder, DSL, and Codec values equal.

## Use The Flow Facade

Inspection functions belong to `Jido.Flow`, not to each generated module.

```elixir
flow = MyApp.Flows.Greeting.flow()

Jido.Flow.validate(flow)
Jido.Flow.dependencies(flow)
Jido.Flow.explain(flow)
Jido.Flow.semantic_identity(flow)
```
