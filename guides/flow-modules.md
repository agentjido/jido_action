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
    step "greet", name <- input(:name), meta: %{owner: "communications"} do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output result("greet")
  end
end
```

The DSL validates syntax, Flow structure, reference scope, graph cycles, and
target contracts during compilation. Compile errors use DSL source locations.
This inline form requires `3.0.0-beta.5` or later.

An inline body becomes an ordinary Action. The Flow owns the body, so it can
call the module's private helpers. Headers use data expressions; the body is
normal Elixir. See [Steps And Output](flow-steps.livemd) for the full syntax.

## Format The DSL

Add `:jido_action` to the `import_deps` list in your project's `.formatter.exs`.
Keep all existing formatter options and imported dependencies.

```elixir
[
  import_deps: [:jido_action],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

The package exports `locals_without_parens` for Flow declarations and block
fields. Standard `mix format` then keeps forms such as `step "greet", ...`
and `output result("greet")`. No formatter plugin is required.

Reference calls such as `input(:name)`, `result("greet")`, and `state(:count)`
keep their parentheses. The formatter also preserves explicit parentheses on
declarations. Remove those parentheses once if you want the form shown above.

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
MyApp.Flows.Greeting.step_action("greet")
MyApp.Flows.Greeting.run(%{name: "Ada"}, %{})
```

`flow/0` returns the same canonical value for the life of the loaded module
version. Put changing values in input or context, not in module construction.

`compiled/0` returns derived `Jido.Flow.Compiled` data. It includes a native
Runic workflow and the source map. It is not a storage format.

`run/2` delegates to `Jido.Exec.run/4` with default options. Use `Jido.Exec`
directly when you need runtime options.

## Reuse A Step Target

`step_action/1` returns the Action module for an inline or explicit
Action-backed Step. It accepts an atom or string name. Invalid or unknown
names and non-Step components, including Subflows, raise `ArgumentError`.
Lookup does not execute the body or create atoms.

The helper returns only the target. It does not copy the Step's parameters,
`after`, or `meta`. Supply those fields for the new graph. Call the helper
after its Flow module has compiled, not from that module's unfinished `flow`
block. See [Builder reuse](flow-builder.md#reuse-an-inline-step) and
[JSON storage](flow-storage.md#store-a-compiled-inline-step).

Context bindings are also Step parameters. For example, `ctx <- context()`
puts the Flow context in the generated Action's `:ctx` parameter. If you call
that Action directly, supply `:ctx` in its input map. Passing only the Exec
context does not recreate the binding. Reuse through a new Step also needs an
explicit context reference in that Step's parameters.

## Convert An Action To An Inline Step

Inline Steps reduce source code for small transformations. They do not infer
field types or defaults from the bindings. A generated Action has empty input
and output schemas. It does not inherit the owning Flow's schemas or the
validation hooks of an Action that it replaces.

Keep a named Action when callers need field validation, defaults, output
validation, custom hooks, or a separate public API. Keep it when a tool or
router needs to derive named arguments from its schema. Inline binding names
do not provide that schema.

The owning Flow still validates its input and final output. Those schemas do
not validate each intermediate Step result. Calling an extracted target with
`step_action/1` also bypasses the owning Flow's validation and defaults. A
missing binding can then fail as a function-clause error during execution.

Moving a direct Action call into a Flow also changes how its return extras
reach the caller. This rule applies to explicit and inline Steps. See
[Results And Errors](execution.md#results-and-errors).

## Source Metadata

The compiler stores file, line, and available column data in a source map
outside the canonical Flow value. Component `meta` remains portable author
data. This separation keeps direct, Builder, DSL, and Codec values equal.

Inline body warnings and errors retain source locations. Runtime stacktraces
include the body in its owning Flow module. Do not depend on the generated
function or Action module names; they are internal.

## Deploy Inline Steps

Normal source compilation writes the owner and generated Action BEAM files.
Deploy them together in the same application build. Lookup, Flow inspection,
Codec operations, and execution do not compile stored code.

The target identity depends on the owner module and Step name, not the body.
A body-only edit can keep the same semantic Flow identity. That identity
describes graph data, not a code version or a durable code snapshot. Use an
application release version when you need to identify deployed behavior.

## Use The Flow Facade

Inspection functions belong to `Jido.Flow`, not to each generated module.

```elixir
flow = MyApp.Flows.Greeting.flow()

Jido.Flow.validate(flow)
Jido.Flow.dependencies(flow)
Jido.Flow.explain(flow)
Jido.Flow.semantic_identity(flow)
```
