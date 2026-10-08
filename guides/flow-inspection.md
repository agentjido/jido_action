# Inspect Flows

`Jido.Flow` has functions that inspect a Flow without running it. They read
the canonical `%Jido.Flow{}` value, so they work the same for Flow modules, map
definitions, and decoded JSON.

## Define A Flow To Inspect

```elixir
defmodule MyApp.Actions.Echo do
  use Jido.Action, name: "echo"

  @impl true
  def run(params, _context), do: {:ok, params}
end

defmodule MyApp.Flows.Inspected do
  use Jido.Flow, name: "inspected"

  flow do
    step "load", action: MyApp.Actions.Echo, params: %{id: input(:id)}
    step "audit", action: MyApp.Actions.Echo, params: %{checked: true}

    step "save",
      action: MyApp.Actions.Echo,
      params: %{id: result("load", :id)},
      needs: ["audit"]

    output result("save")
  end
end

flow = MyApp.Flows.Inspected.flow()
```

## Validate Structure Or Targets

`Jido.Flow.validate/1` checks schemas, components, expressions, references,
dependencies, and cycles. It does not load Action targets:

```elixir
{:ok, ^flow} = Jido.Flow.validate(flow)

{:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
  Jido.Flow.validate(%{flow | output: Jido.Flow.Ref.result("missing")})
```

`Jido.Exec.compile/2` also checks that each target is a valid Action or Flow
module, and builds the executable workflow:

```elixir
{:ok, _workflow} = Jido.Exec.compile(flow)
```

Neither function runs Action work.

## Read Dependencies

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)

%{
  "save" => %{needs: ["audit"], references: ["load"], effective: ["audit", "load"]},
  "load" => %{needs: [], references: [], effective: []}
} = dependencies
```

Each component entry lists its explicit `needs`, the components it reads
through result references, and the `effective` union of both. See
[Dependencies And Parallel Work](flow-dependencies.livemd).

## Explain A Flow

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)

%{
  version: 1,
  kind: :flow,
  name: "inspected",
  components: [_audit, _load, _save],
  dependencies: %{"save" => %{effective: ["audit", "load"]}},
  identity: %{algorithm: :sha256}
} = explanation
```

The explanation is versioned author data. Its keys are `version`, `kind`,
`name`, `description`, `schema`, `output_schema`, `components`,
`dependencies`, `output`, and `identity`. It contains no runtime state.
Components appear as plain maps, such as
`%{kind: :step, name: "audit", action: MyApp.Actions.Echo, params: %{checked: true}, needs: [], meta: %{}}`.

## Compare Semantic Identity

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)
%{algorithm: :sha256, digest: _digest, uuid: _uuid} = identity
```

The identity is a SHA-256 digest and a UUID derived from the canonical Flow
definition. Two Flows with the same definition have the same identity.
Runtime context, execution state, and source locations do not change it. The
identity describes graph data, not deployed code; an inline body edit can keep
the same identity.

## Get A Semantic Map

```elixir
map = Jido.Flow.to_map(flow)
["audit", "load", "save"] = Enum.map(map.components, & &1.name)
```

`to_map/1` returns a deterministic map with components in dependency order,
then by name. Use it for inspection and tests. Use `Jido.Flow.Codec` for
storage, because Codec records a version and replaces modules and atoms with
Registry identifiers. See [Store Flows As JSON](flow-storage.md).

## Inspect The Executable Workflow

`Jido.Exec.compile/2` and a Flow module's `compiled/0` return the workflow that
`Jido.Exec` runs. It is derived runtime data; do not store it as a Flow
definition. See [Debug Flows](debugging-flows.md) for how to read it.
