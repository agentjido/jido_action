# Flow Modules And Extensions

A Flow module is the main way to write a Flow in source code. You
`use Jido.Flow` and declare components in a `flow do ... end` block. Jido
compiles the block once, at compile time, to a canonical `%Jido.Flow{}`.

The [DSL field reference](Jido.Flow.html#module-dsl-field-reference) lists
every declaration and field, including Choice targets and Iterate State.

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

{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(MyApp.Flows.Greeting, %{name: "Ada"})
```

`use Jido.Flow` accepts these options:

| Option | Required | Meaning |
| --- | --- | --- |
| `name` | Yes | The Flow name, a string. |
| `description` | No | A string description. |
| `schema` | No | A static Zoi schema for Flow input. Defaults to `[]`, no validation. |
| `output_schema` | No | A static Zoi schema for Flow output. Defaults to `[]`. |
| `extensions` | No | A list of `Jido.Flow.Extension` modules. See below. |

Action and Flow schemas use Zoi. A keyword-list schema fails at compile time
with "must be a Zoi schema".

During compilation, Jido checks the DSL syntax, the Flow structure, reference
scopes, graph cycles, and target Action contracts. Compile errors point to the
DSL source line.

An inline body becomes an ordinary Action owned by the Flow module, so it can
call the module's private functions. See [Steps And Output](flow-steps.livemd)
for the binding syntax.

## Add Authoring Macros

Use a Flow extension when several Flow modules need the same shorthand. An
extension macro must expand to normal Flow declarations.

```elixir
defmodule MyApp.Actions.Notify do
  use Jido.Action, name: "notify"

  @impl true
  def run(%{address: address}, _context), do: {:ok, %{notified: address}}
end

defmodule MyApp.Flows.Helpers do
  use Jido.Flow.Extension

  defmacro notify(name, address) do
    quote do
      step unquote(name),
        action: MyApp.Actions.Notify,
        params: %{address: unquote(address)}
    end
  end
end
```

Add the extension with a static module list:

```elixir
defmodule MyApp.Flows.Welcome do
  use Jido.Flow,
    name: "welcome",
    extensions: [MyApp.Flows.Helpers]

  flow do
    notify("welcome", input(:address))
    output result("welcome")
  end
end

{:ok, %{notified: "ada@example.com"}} =
  Jido.Exec.run(MyApp.Flows.Welcome, %{address: "ada@example.com"})
```

`mix format` keeps parentheses on extension macros. To call them without
parentheses, add them to `locals_without_parens` in your own
`.formatter.exs`.

An extension runs only during compilation. Its macros can expand to any core
declaration, including inline Steps. The expanded declarations get the same
validation, source locations, and execution rules as hand-written ones.

An extension does not add a component type or runtime behavior. Put domain
work in Actions or Flows. Keep runtime values in Flow input or context. The
extension module must compile before each Flow that uses it.

### Use Helpers With Other Authoring Forms

Extensions apply only to the module DSL. Map definitions and Codec documents
never load extensions or run authoring macros.

For map definitions, write ordinary functions that return component maps or
complete definitions, then validate with `Jido.Flow.new/1`. See
[Flow Data Definitions](flow-data.md).

## Format The DSL

Add `:jido_action` to `import_deps` in your project's `.formatter.exs`. Keep
your existing options.

```elixir
[
  import_deps: [:jido_action],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

The package exports `locals_without_parens` for Flow declarations and block
fields. `mix format` then keeps forms such as `step "greet", ...` and
`output result("greet")` without parentheses. Reference calls such as
`input(:name)`, `result("greet")`, and `state(:count)` keep their parentheses.
The formatter keeps parentheses you already wrote on declarations; remove them
once to get the form shown above.

## Generated API

A Flow module defines these functions:

```elixir
MyApp.Flows.Greeting.name()
# "greeting"
MyApp.Flows.Greeting.description()
# "Creates one greeting"
MyApp.Flows.Greeting.schema()
MyApp.Flows.Greeting.output_schema()
MyApp.Flows.Greeting.validate_params(%{name: "Ada"})
# {:ok, %{name: "Ada"}}
MyApp.Flows.Greeting.validate_output(%{message: "Hello"})
# {:ok, %{message: "Hello"}}
MyApp.Flows.Greeting.flow()
# %Jido.Flow{name: "greeting", ...}
MyApp.Flows.Greeting.compiled()
MyApp.Flows.Greeting.step_action("greet")
# the generated Action module
MyApp.Flows.Greeting.run(%{name: "Ada"}, %{})
# {:ok, %{message: "Hello, Ada!"}}
```

`flow/0` returns the same canonical value for the life of the loaded module.
Put changing values in input or context, not in module construction.

`compiled/0` returns the executable workflow that `Jido.Exec` derives from the
Flow. It is not a storage format. See [Inspect Flows](flow-inspection.md).

`run/2` calls `Jido.Exec.run/4` with default options. Call `Jido.Exec.run/4`
directly when you need runtime options such as `max_concurrency`.

## Reuse A Step Target

`step_action/1` returns the Action module of a named Step, inline or explicit.
It accepts a string or atom name. It raises `ArgumentError` for an invalid or
unknown name, or for a component that is not an Action-backed Step, such as a
Subflow. It does not run the body or create atoms.

The function returns only the target. It does not copy the Step's `params`,
`needs`, or `meta`; supply new ones in the new graph. Call it after the Flow
module has compiled, not from inside its `flow` block. See
[data definitions reuse](flow-data.md#reuse-an-inline-step) and
[JSON storage](flow-storage.md#store-a-compiled-inline-step).

A context binding is a parameter of the generated Action. For example,
`ctx <- context()` puts the Flow context in the Action's `:ctx` parameter. If
you call that Action directly, supply `:ctx` in its input map. If you reuse it
in a new Step, add an explicit `context()` reference to that Step's `params`.
The `inline: [context: ctx]` setting binds the execution context without
adding a parameter.

## Convert An Action To An Inline Step

Inline bodies reduce code for small transformations. They do not infer field
types or defaults from bindings. Use `inline:` to declare the Action name,
description, and input and output schemas. An inline Action does not inherit
the owning Flow's schemas, or the hooks of an Action that it replaces.

Tools and routers can read declared Action schemas; binding names alone do not
provide them. Keep a named Action for custom lifecycle hooks or a separate
public module API. See [Inline Steps](inline-actions.md).

The owning Flow validates its input and final output, not each intermediate
Step result. Calling an extracted target directly skips the Flow's validation
and defaults. A missing binding can then fail as a function-clause error,
unless the target's own schema rejects it or supplies a default.

An Action can return deferred effect requests in explicit and inline Steps.
See [Outputs And Effects](action-effects.livemd).

## Source Metadata

The compiler stores file, line, and column data in a source map outside the
canonical Flow value. Component `meta` stays portable author data. Because of
this split, the DSL, map definitions, and Codec can produce equal Flow values.

Inline body warnings, errors, and runtime stacktraces point to the owning Flow
module. Do not depend on generated function or Action module names; they are
internal.

## Deploy Inline Steps

Normal compilation writes BEAM files for the owning module and its generated
Actions. Deploy them together in the same build. Lookup, inspection, Codec
operations, and execution never compile stored code.

A generated Action's identity depends on the owning module and the Step name,
not the body. A body-only edit can keep the same semantic Flow identity. That
identity describes graph data, not a code version. Use your application
release version to identify deployed behavior.

## Inspect A Flow

Inspection functions belong to `Jido.Flow`, not to each Flow module:

```elixir
flow = MyApp.Flows.Greeting.flow()

{:ok, _flow} = Jido.Flow.validate(flow)
{:ok, _dependencies} = Jido.Flow.dependencies(flow)
{:ok, _explanation} = Jido.Flow.explain(flow)
{:ok, _identity} = Jido.Flow.semantic_identity(flow)
```

See [Inspect Flows](flow-inspection.md) for what each function returns.
