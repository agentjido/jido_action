# Action Catalogs

**Prerequisites**: [Actions](actions-guide.md) • [Schemas & Validation](schemas-validation.md)

Action catalogs are local, value-level registries for discovering and selecting actions. They describe action-compatible modules with normalized metadata and deterministic search, without introducing an LLM dependency or a process-backed registry.

Catalogs are intentionally plain data structures. Build them, pass them through your own runtime, replace them between turns, or wrap them in a higher-level package such as `jido_ai` or `jidoka`.

## Local Action Compatibility

A catalog entry points at a local compiled module. The module must expose the same core action shape:

- `name/0`
- `schema/0`
- `run/2`

Modules created with `use Jido.Action` satisfy this contract. Higher-level packages may also provide modules that follow the same shape, such as a local `Jidoka.Tool` wrapper.

Remote catalogs are not supported. If the action code is not available locally, the catalog cannot safely describe or execute it.

## Building a Catalog

Build a catalog from existing actions:

```elixir
{:ok, catalog} =
  Jido.Action.Catalog.from_modules(
    [
      MyApp.Actions.SearchUsers,
      MyApp.Actions.SendEmail
    ],
    id: "app-actions",
    name: "App Actions"
  )
```

Entries are derived from action metadata and schemas:

```elixir
[entry | _] = Jido.Action.Catalog.list(catalog)

entry.name
#=> "search_users"

entry.input_schema["type"]
#=> "object"
```

## Registering Entries

Register modules directly:

```elixir
catalog =
  Jido.Action.Catalog.new!(id: "runtime-actions")
  |> Jido.Action.Catalog.register!(MyApp.Actions.SearchUsers,
    namespace: "accounts",
    capabilities: ["lookup"],
    read_only?: true
  )
```

You can also register a prebuilt entry:

```elixir
entry =
  Jido.Action.Catalog.Entry.new!(
    id: "send-email",
    module: MyApp.Actions.SendEmail,
    name: "send_email",
    risk: :medium
  )

catalog = Jido.Action.Catalog.register!(catalog, entry, visibility: :internal)
```

## Fetching Entries

Fetch by stable entry id or unique action name:

```elixir
{:ok, entry} = Jido.Action.Catalog.fetch(catalog, "send_email")
```

If multiple entries share the same action name, name lookup returns an ambiguous result. Use stable ids for catalogs that intentionally contain multiple versions or variants of the same action.

## Merging Catalogs

Merge catalogs when different layers contribute local actions:

```elixir
{:ok, merged} =
  Jido.Action.Catalog.merge(
    base_catalog,
    runtime_catalog,
    id: "app-runtime-actions"
  )
```

Merging is canonical and idempotent. Duplicate entry ids are accepted only when the entries are exactly equal. If two different entries use the same id, merge returns an error instead of choosing a side.

When you do not pass an `:id`, the merged catalog id is derived from the sorted merged entry ids, so compatible merges are order-independent.

## Searching

Search is deterministic and LLM-free:

```elixir
{:ok, hits} = Jido.Action.Catalog.search(catalog, "email")

Enum.map(hits, & &1.entry.name)
#=> ["send_email"]
```

Search supports exact filters and metadata filters:

```elixir
{:ok, hits} =
  Jido.Action.Catalog.search(catalog,
    text: "users",
    namespace: "accounts",
    tags: ["users"],
    capabilities: ["lookup"],
    filters: %{"risk" => "low"}
  )
```

By default, search only returns public entries. Include additional visibility values explicitly:

```elixir
Jido.Action.Catalog.search(catalog, visibility: [:public, :internal])
```

An empty visibility list matches no entries.

## Execution

This first catalog layer does not execute actions. It selects and describes local action-compatible modules. Once a caller selects an entry, execution should still go through the normal action execution path for the calling layer, such as `Jido.Exec`, `Jido.Action.Tool`, or a higher-level runtime.

Keeping execution outside the catalog keeps this layer serializable, testable, and independent of runtime policy.
