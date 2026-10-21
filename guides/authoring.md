# Authoring Runtime Data

`Jido.Authoring` is the public boundary for stored runtime definitions. It
converts canonical Jido values to JSON-safe documents and back. It also owns
JSON parsing, document limits, codec selection, callback containment, and
ordered validation issues.

Authoring does not run Actions or Flows. It does not load modules from document
strings. A trusted `Jido.Authoring.Registry` controls every code, schema, and
atom reference that a document can select.

## Use The Default Path

`jido_action` starts one asynchronous Discovery task. Discovery scans all
loaded OTP applications and builds the default Registry. Action and Flow
modules publish their stable IDs and versions during this scan.

After Discovery is ready, encode and decode without passing a Registry or
codec:

```elixir
flow = MyApp.HealthFlow.flow()

{:ok, json} = Jido.Authoring.encode_json(flow)
{:ok, %Jido.Flow{} = restored} = Jido.Authoring.decode_json(json)
```

Use the map functions when a database or transport already handles JSON:

```elixir
{:ok, document} = Jido.Authoring.encode(flow)
{:ok, %Jido.Flow{} = restored} = Jido.Authoring.decode(document)
```

The four public operations are:

| Input or output | Encode | Decode |
| --- | --- | --- |
| JSON-safe Elixir map | `Jido.Authoring.encode/2` | `Jido.Authoring.decode/2` |
| JSON string | `Jido.Authoring.encode_json/2` | `Jido.Authoring.decode_json/2` |

`encode_json/2` and `decode_json/2` use Jason. Do not add a second JSON step
around these functions.

## Check Discovery Readiness

Application startup does not wait for the asynchronous scan. Check readiness
in code that can be the first Authoring caller. Later calls normally need no
extra step:

```elixir
if Jido.Discovery.ready?() do
  Jido.Authoring.decode_json(json)
else
  {:error, :authoring_not_ready}
end
```

`Jido.Discovery.registry/0` raises a classified Authoring error when the first
scan is not complete or failed. It does not return an empty Registry.

Applications loaded after the first scan can rebuild the Registry:

```elixir
:ok = Jido.Discovery.refresh()
```

The replacement is atomic. Readers see the old complete Registry or the new
complete Registry. `refresh/0` is synchronous, so setup code can also use it
when the Registry must be ready before that code continues.

## Configure Discovery

The default scan includes all loaded applications. Use an allowlist when an
editor, API, or AI model supplies stored definitions:

```elixir
config :jido_action, Jido.Discovery,
  applications: [:jido_action, :my_app],
  modules: [MyApp.AuthoringVocabulary]
```

An Action or Flow module publishes its own reference. A vocabulary module can
publish other trusted values:

```elixir
defmodule MyApp.AuthoringVocabulary do
  def __jido_authoring__ do
    [
      %{
        id: "my_app/schemas/order-input",
        kind: :schema,
        vsn: 1,
        target: MyApp.OrderFlow.schema()
      },
      %{id: "my_app/atoms/order_id", kind: :atom, vsn: 1, target: :order_id}
    ]
  end
end
```

Each entry has one stable ID, one positive `vsn`, one kind, and one trusted
target. Discovery rejects duplicate references, duplicate typed targets, and
invalid static data.

Use the lookup functions to inspect the active catalog:

```elixir
Jido.Discovery.list(:action)
Jido.Discovery.get("my_app/actions/create-order", 1)
Jido.Discovery.get_by_target(:flow, MyApp.OrderFlow)
```

Discovery is an inventory service. Finding an Action does not grant permission
to run it.

## Inspect A Module Contract

Generated Action and Flow modules have one JSON-safe authoring contract:

```elixir
%{
  "id" => "my_app/actions/create-order",
  "vsn" => 1,
  "kind" => "action",
  "name" => "create_order",
  "input_schema" => input_schema,
  "output_schema" => output_schema
} = MyApp.CreateOrder.authoring_contract()
```

This contract describes the module. It is not a stored Flow document and it
does not execute the module.

## Handle Encode Errors

Encoding returns one classified Splode error. Match on its class module and
stable code:

```elixir
case Jido.Authoring.encode_json(value) do
  {:ok, json} ->
    {:ok, json}

  {:error, %Jido.Authoring.Error.InvalidError{code: code} = error} ->
    {:error, {code, Exception.message(error)}}

  {:error, %Jido.Authoring.Error.InternalError{} = error} ->
    {:error, {:internal, Exception.message(error)}}
end
```

An invalid error means the value, options, Registry references, or generated
document are invalid. An internal error means a codec contract or callback
failed.

## Handle Decode Issues

Decoding returns all independent issues found in the current validation phase.
Issues keep document order and use JSON paths:

```elixir
case Jido.Authoring.decode_json(json) do
  {:ok, value} ->
    {:ok, value}

  {:error, issues} ->
    {:error, Enum.map(issues, &Jido.Authoring.Issue.to_map/1)}
end
```

Each issue has `code`, `path`, `message`, and JSON-safe `details`. Match on the
code and path. Do not match on message text.

## Apply Limits

Authoring applies these default limits before a codec accepts a document:

| Limit | Default |
| --- | ---: |
| JSON bytes | 8 MiB |
| Nesting depth | 100 |
| Items in one map or list | 10,000 |
| Total document nodes | 100,000 |
| Registry entries | 10,000 |

Set the JSON byte limit for the application:

```elixir
config :jido_action, Jido.Authoring,
  maximum_json_bytes: 16_777_216
```

Override it for one call when the transport has a smaller limit:

```elixir
Jido.Authoring.decode_json(json, maximum_json_bytes: 1_048_576)
```

Stored strings never create atoms or module names. The Registry must already
contain every selected target. Apply authorization after decoding and before
execution.

## Continue With Flow Storage

See [Store Flows As JSON](flow-storage.md) for the Flow document format,
tagged values, canonical component records, and compiled inline Steps.
