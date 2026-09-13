# Building DSLs With Inline Actions

This advanced guide describes the public `Jido.Action.Inline` host API. A
downstream package must adopt this API before its own compile-time DSL can
provide inline Actions. For normal Flow authoring, start with
[Inline Actions](inline-actions.md).

An inline body compiles to an ordinary Action. It uses the normal `Jido.Exec`
input validation, output validation, errors, telemetry, timeout, cancellation,
and concurrency rules. It does not add a runtime function target or store code
in a Flow. A downstream DSL can use `Jido.Action.Inline` without Flow.

## Select The Input Mode

The host slot selects the mode. A malformed header does not switch modes.

| Mode | Header | Parameters passed to the Action |
| --- | --- | --- |
| Bound | `value <- source` | `%{value: resolved_source}` |
| Bound | `[left <- source, right <- other]` | An atom-keyed map of resolved values. |
| Bound | `%{name: name} <- source` | The complete resolved source map. |
| Bound | `[]` | `%{}` |
| Callback | `params` | The incoming parameter map, with no source mapping. |
| Callback | `%{name: name}` | The incoming map matched by the pattern. |

Do not mix a map binding with named bindings. A map binding must be the only
binding. Duplicate names, bare `_`, pins, header guards, and top-level struct
patterns are not supported. Callback headers do not accept `<-`.

A `do` body of only `->` clauses compiles to several owner-function heads over
the validated parameter map. One Action identity and one schema still apply.
Clause heads may use `when`, `_`, a named variable, or a map pattern. Pins and
top-level structs stay illegal. A callback clause body omits the header
pattern. A bound clause body keeps its source bindings and matches the
resolved map produced by those bindings. Do not mix `->` heads with an
expression body.

```elixir
# A callback host passes nil when clause heads provide the input patterns.
action "divide", nil,
  schema: Zoi.object(%{operand: Zoi.number()}), context: ctx do
  %{operand: operand} when operand == 0 ->
    {:error, Jido.Action.Error.validation_error("Cannot divide by zero")}

  %{operand: operand} ->
    {:ok, %{value: ctx.total / operand}}
end
```

Shared Action options are `name`, `description`, `schema`, `output_schema`,
`context`, and the required `do` body. Omitted schemas are `[]`. No field,
type, or default is inferred from a binding or pattern. Schemas validate the
resolved bound parameters or the incoming callback parameters. Defaults are
applied before the body matches its input. Metadata and schemas use the same
configuration and static-schema rules as `use Jido.Action`.

`context: ctx` binds the actual second callback argument. It does not add a
parameter or a schema field. Use one named variable that does not occur in
the input pattern. In contrast, a Flow binding such as `ctx <- context()` adds
a `:ctx` parameter. Reusing that target requires a new `:ctx` input value.

The body keeps the owner's private helpers, aliases, available imports,
declaration-time attributes, and `__MODULE__`. It does not capture runtime
variables outside the declaration. A normal success result is a map. Use
`Jido.Action.Output` for an intentional non-map value. A Flow discards Action
return extras. A continuation is valid only from a root Action or a terminal
Dispatch expander, not from an ordinary Step or Dispatch decision.

## Flow Boundary

Jido Flow uses this API for direct inline Step bodies only. A Flow Step can
set Action options through `inline:`. Map, Reduce, Choice targets, Iterate,
and Dispatch use Action modules. See [Inline Actions](inline-actions.md).

This Flow boundary does not restrict downstream packages. A downstream DSL
can define bound or callback slots, its own macro names, and its own typed
host paths through the public API described below.

Flow Steps use one binding argument and an ordinary expression body. The
shared host API still supports clause bodies in bound and callback modes.

A downstream package owns its formatter rules. Add its macro names and arities
to `locals_without_parens`, and export those entries for consumers. For the
host below, use `[action: 3, action: 4]`. Importing the Jido formatter rules
alone does not configure a downstream DSL.

## Build A Non-Flow Host

This complete host uses only public Action and Expr APIs. It owns a small
`field(:key)` reference and a separate source index. The shared parser owns
binding patterns. `Jido.Expr` owns operators. The host validates field scope
before it calls `compile!`; it does not copy the operator table.

First define the host. Both action macro arities support a `do` block, with
or without additional Action options.

```elixir
defmodule InlineHostGuide.Field do
  defstruct [:key]
end

defmodule InlineHostGuide.DSL do
  alias Jido.Action.Inline
  alias InlineHostGuide.Field

  defmacro __using__(options) do
    Module.put_attribute(__CALLER__.module, :guide_mode, Keyword.fetch!(options, :mode))
    Module.put_attribute(__CALLER__.module, :guide_fields, Keyword.get(options, :fields, []))
    Module.register_attribute(__CALLER__.module, :guide_sources, accumulate: true)

    quote do
      use Jido.Action.Inline
      import unquote(__MODULE__), only: [action: 3, action: 4]
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro action(name, header, options) do
    declaration(name, header, options, __CALLER__)
  end

  defmacro action(name, header, options, body) do
    declaration(name, header, options ++ body, __CALLER__)
  end

  defmacro __before_compile__(env) do
    sources = env.module |> Module.get_attribute(:guide_sources) |> Map.new()
    mode = Module.get_attribute(env.module, :guide_mode)

    quote do
      def action_target(name) do
        Jido.Action.Inline.target!(__MODULE__, unquote(__MODULE__).path(name))
      end

      def action_source(name), do: Map.fetch!(unquote(Macro.escape(sources)), name)

      def action_params(name, input) do
        unquote(__MODULE__).resolve(unquote(mode), action_source(name), input)
      end
    end
  end

  def path(name), do: [host: __MODULE__, declaration: name, role: :action]

  def run(owner, name, input, context \\ %{}) do
    with {:ok, params} <- owner.action_params(name, input) do
      Jido.Exec.run(owner.action_target(name), params, context)
    end
  end

  def resolve(:callback, _source, params), do: {:ok, params}

  def resolve(:bound, source, input) do
    Jido.Expr.evaluate(source,
      resolve: fn %Field{key: key} ->
        case Map.fetch(input, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:missing_field, key}}
        end
      end
    )
  end

  defp declaration(name, header, options, caller) do
    parsed =
      case Module.get_attribute(caller.module, :guide_mode) do
        :bound -> Inline.parse_bound!(header, options, caller)
        :callback -> Inline.parse_callback!(header, options, caller)
      end

    source = parse_source!(parsed, caller)
    local_name = Macro.unique_var(:declaration_name, __MODULE__)
    path_ast = quote do: unquote(__MODULE__).path(unquote(local_name))

    compiled =
      Inline.compile!(path_ast, parsed, caller,
        default_name: local_name,
        remove_imports: [{__MODULE__, [action: 3, action: 4]}]
      )

    quote do
      unquote(local_name) = unquote(name)
      unquote(compiled.declaration_ast)
      @guide_sources {unquote(local_name), unquote(Macro.escape(source))}
      unquote(compiled.target_ast)
    end
  end

  defp parse_source!(%Inline{mode: :callback}, _caller), do: nil

  defp parse_source!(%Inline{params_ast: ast}, caller) do
    fields = Module.get_attribute(caller.module, :guide_fields)

    with {:ok, source} <- Jido.Expr.parse(ast, leaf_parser: &parse_field/1),
         :ok <-
           Jido.Expr.validate(source,
             validate_leaf: fn %Field{key: key} ->
               if key in fields, do: :ok, else: {:error, {:unknown_field, key}}
             end
           ) do
      source
    else
      {:error, reason} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "invalid host source: #{inspect(reason)}"
    end
  end

  defp parse_field({:field, _, [key]}) when is_atom(key), do: {:ok, %Field{key: key}}
  defp parse_field(_ast), do: :error
end
```

Next define one owner for each mode. Both declare schemas, bind the current
execution context, and use a private helper. The bound form receives the
person field. The callback form receives the incoming map directly.

```elixir
defmodule InlineHostGuide.Bound do
  use InlineHostGuide.DSL, mode: :bound, fields: [:person]

  @description "Create a greeting"
  @schema Zoi.object(%{name: Zoi.string(), suffix: Zoi.string() |> Zoi.default("!")})

  action "greet",
         %{name: name, suffix: suffix} <- field(:person),
         name: "public_greeting",
         description: @description,
         schema: @schema,
         output_schema: Zoi.object(%{message: Zoi.string()}),
         context: ctx do
    {:ok, %{message: ctx.prefix <> ", " <> normalize(name) <> suffix}}
  end

  defp normalize(name), do: name |> String.trim() |> String.upcase()
end

defmodule InlineHostGuide.Callback do
  use InlineHostGuide.DSL, mode: :callback

  @description "Create a greeting"
  @schema Zoi.object(%{name: Zoi.string(), suffix: Zoi.string() |> Zoi.default("!")})

  action "greet", %{name: name, suffix: suffix},
    name: "public_greeting",
    description: @description,
    schema: @schema,
    output_schema: Zoi.object(%{message: Zoi.string()}),
    context: ctx do
    {:ok, %{message: ctx.prefix <> ", " <> normalize(name) <> suffix}}
  end

  action "echo", params do
    {:ok, params}
  end

  defp normalize(name), do: name |> String.trim() |> String.upcase()
end

bound_result =
  InlineHostGuide.DSL.run(InlineHostGuide.Bound, "greet", %{person: %{name: " Ada "}}, %{
    prefix: "Hello"
  })

{:ok, %{message: "Hello, ADA!"}} = bound_result

callback_result =
  InlineHostGuide.DSL.run(InlineHostGuide.Callback, "greet", %{name: " Grace "}, %{prefix: "Hi"})

{:ok, %{message: "Hi, GRACE!"}} = callback_result

{:ok, %{unchanged: true}} =
  InlineHostGuide.DSL.run(InlineHostGuide.Callback, "echo", %{unchanged: true})

target = InlineHostGuide.Bound.action_target("greet")
"public_greeting" = target.name()
{:ok, %{name: "Ada", suffix: "!"}} = target.validate_params(%{name: "Ada"})

{:error, %Jido.Action.Error.InvalidInputError{}} =
  Jido.Exec.run(target, %{name: 42}, %{prefix: "Hello"})

{:ok, %{message: "Reuse, ADA?"}} =
  Jido.Exec.run(target, %{name: "Ada", suffix: "?"}, %{prefix: "Reuse"})
```

The final direct call supplies Action parameters, not a `person` source map.
The target retains no original binding expressions. The host resolves those
expressions only when its own `run` function is used. A missing runtime field
returns `{:error, {:missing_field, key}}`. Unknown fields and unsupported calls
fail at compile time, before target creation. The host can also use Expr
operations in sources, such as `value <- field(:count) * 2`, when `:count` is
an allowed field. Flow does not permit operations in inline binding sources,
but a downstream host can choose a different policy. Validation checks all
references, including skipped Boolean branches. The host chooses its runtime
error and input-size policy.

## Host Integration Contract

1. Install owner hooks with `use Jido.Action.Inline`, or call
   `Jido.Action.Inline.setup!(__ENV__)` during module construction. Setup is
   idempotent and can coexist with the host's hooks.
2. Select `parse_bound!/3` or `parse_callback!/3` for the slot. The returned
   `%Jido.Action.Inline{}` contains AST, not runtime data. `params_ast` is `nil`
   only in callback mode. Shared parsing checks shape, not host source scope.
3. In bound mode, parse and validate `params_ast` with the host adapter before
   compilation. Use the public Expr `leaf_parser`, `validate_leaf`, and
   `resolve` callbacks for a host that needs expressions. Do not evaluate
   source calls to make them valid.
4. Call `compile!/4` with path AST, the parsed value, the caller environment,
   and compiler options. `default_name:` is AST for valid Action metadata.
   `remove_imports:` lists only exact declaration imports as
   `[{HostModule, [action: 3, action: 4]}]`. Other imports remain available.
   `compile!/3` requires an explicit Action `name:`.
5. Emit `declaration_ast` before using `target_ast`. Evaluate a declaration
   name once and share it between identity, metadata, and host data. A path is
   registered only when the emitted declaration executes.
6. Keep source mappings in the host model. Store the returned ordinary Action
   target separately. Expose a local lookup that calls `target!/2` after the
   owner compiles.

Malformed headers, options, schemas, paths, duplicate identities, reserved
owner functions, and invalid compilation contexts raise `CompileError`.
The host owns source errors. Lookup raises `ArgumentError` for invalid or
unknown paths, owners without targets, or an owner that is still compiling.
None of these compile-time APIs accepts runtime or stored body code.

## Stable Lookup And Deployment

Identity uses the owner module plus a typed host path. Paths start with
`host:` and end with `role:`. They contain at least one declaration segment.
Each segment has an atom key and a non-nil atom, string, or integer value.
Lookup requires the exact path. It is inert: it creates no atoms, compiles no
code, executes no body, and returns no parameter mapping.

Flow uses `[host: Jido.Flow, step: name, role: :action]` for an inline Step.
Use the Flow's canonical string Step name. `FlowModule.step_action/1` returns
inline and explicit Action-backed Step targets, but not Subflows or other
component targets.

A downstream host defines its own path. It can use several declaration
segments when its DSL has nested roles. Explicit Action `name:` changes public
Action metadata, not host lookup identity.

An extracted target works with direct constructors, Builder, and a trusted
Registry. Supply a new parameter mapping for each host position. Register
the target under an application-owned identifier, not its generated module
name. JSON stores ordinary targets and data, never bodies. Inline Actions add
no Codec version; Expr nodes still follow the existing version 2 rule.

Normal source compilation produces the owner and generated Action BEAM files.
Deploy them together. Generated names and graph identity are not code
versions. A body-only change can keep both target and graph identity. Use the
application release and Registry version to select deployed behavior; this
API does not provide code snapshots or cross-node upgrade guarantees.

Keep a named `Jido.Action` when callers need custom lifecycle hooks, a separate
public module API, or an independent ownership and deployment boundary.
Explicit inline schemas and descriptions can serve typed callers, but they
must be static Action configuration. Bindings never supply schema inference.
