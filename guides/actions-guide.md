# Actions

<!-- covers: jido_action.action.effect_boundary_guidance -->

**Prerequisites**: [Getting Started](getting-started.md) • [Your Second Action](your-second-action.md)

Actions are the core building blocks of Jido Action - self-contained modules that define validated, observable operations with clear input/output contracts.

## Action Anatomy

Every action has the same basic structure:

```elixir
defmodule MyApp.Actions.Example do
  use Jido.Action,
    # Required metadata
    name: "example_action",
    description: "What this action does",
    
    # Parameter validation
    schema: [
      input: [type: :string, required: true],
      options: [type: :map, default: %{}]
    ]

  # Required: core execution logic
  @impl true
  def run(params, context) do
    {:ok, %{result: "processed"}}
  end
end
```

## Purity and I/O

`Jido.Action` modules are reusable execution units. `run/2` may be pure or effectful depending on what the step needs to do.

If the action needs data back now, doing I/O in `run/2` is fine. HTTP requests, database calls, and file system operations are all reasonable there when they are part of the action's job. If the effect should instead be owned by a runtime or integration layer, hand it off there rather than doing it inline.

When you use actions inside `jido`, keep the purity guarantee attached to the agent or strategy `cmd/2` boundary. An individual action may still perform side effects when the runtime invokes it behind that boundary.

## Schema Definition

Actions support two schema formats: [NimbleOptions](https://hexdocs.pm/nimble_options) and [Zoi](https://hexdocs.pm/zoi) (recommended for new code).

### NimbleOptions Schema

```elixir
schema: [
  # Basic types
  name: [type: :string, required: true],
  age: [type: :integer, min: 0, max: 150],
  active: [type: :boolean, default: true],
  
  # Collections
  tags: [type: {:list, :string}, default: []],
  config: [type: :map, default: %{}],
  
  # Custom validation
  email: [
    type: :string,
    required: true,
    doc: "User's email address"
  ],
  
  # Enums and choices
  status: [
    type: :atom,
    in: [:pending, :active, :inactive],
    default: :pending
  ]
]
```

### Zoi Schema (Recommended)

Zoi schemas provide richer validation with built-in transformations:

```elixir
use Jido.Action,
  name: "create_user",
  schema: Zoi.object(%{
    email: Zoi.string() |> Zoi.trim() |> Zoi.email(),
    age: Zoi.integer() |> Zoi.min(0) |> Zoi.max(120),
    name: Zoi.string() |> Zoi.min_length(1) |> Zoi.max_length(100),
    role: Zoi.enum([:admin, :user, :guest]) |> Zoi.default(:user)
  })
```

**Zoi advantages:**
- Built-in transformations (trim, downcase, coerce)
- Rich refinements for custom validation
- Better error messages
- Type coercion out of the box

### Schema Features

**Type Safety**: Validates parameter types at runtime  
**Required Fields**: Ensures critical parameters are provided  
**Default Values**: Sensible defaults for optional parameters  
**Constraints**: Min/max values, string patterns, list lengths  
**Documentation**: Built-in parameter documentation for AI tools

## Lifecycle Hooks

Extend action behavior with optional lifecycle callbacks:

```elixir
defmodule MyApp.Actions.ProcessData do
  use Jido.Action, 
    name: "process_data",
    schema: [data: [type: :string, required: true]]

  # 1. Pre-validation hook (before schema validation)
  @impl true
  def on_before_validate_params(params) do
    # Normalize or enrich parameters before validation
    normalized = Map.update(params, :data, "", &String.trim/1)
    {:ok, normalized}
  end

  # 2. Post-validation hook (after schema validation)
  @impl true
  def on_after_validate_params(params) do
    # Further processing after validation
    {:ok, params}
  end

  # 3. Main execution (required)
  @impl true
  def run(params, context) do
    processed = expensive_operation(params.data)
    {:ok, %{result: processed, processed_at: DateTime.utc_now()}}
  end

  # 4. Post-execution hook - receives {:ok, result} or {:error, reason}
  @impl true  
  def on_after_run({:ok, result}) do
    # Log, cache, or enrich the result
    Logger.info("Data processed successfully")
    {:ok, Map.put(result, :logged, true)}
  end

  def on_after_run({:error, _} = error), do: error

  # 5. Error compensation (called when compensation is enabled)
  @impl true
  def on_error(failed_params, error, context, opts) do
    # Clean up resources, send alerts, etc.
    cleanup_temp_files(failed_params.data)
    {:ok, %{cleanup_performed: true}}
  end
end
```

### Available Lifecycle Hooks

| Hook | Called | Purpose |
|------|--------|---------|
| `on_before_validate_params/1` | Before schema validation | Normalize/enrich input params |
| `on_after_validate_params/1` | After schema validation | Post-process validated params |
| `on_before_validate_output/1` | Before output validation | Pre-process action output |
| `on_after_validate_output/1` | After output validation | Post-process validated output |
| `on_after_run/1` | After action execution | Receives `{:ok, result}` or `{:error, reason}` |
| `on_error/4` | On error (when compensation enabled) | Cleanup/rollback on failure |

### Hook Execution Order

```
Parameters → on_before_validate_params → Schema Validation → on_after_validate_params → run
                                                                                         ↓
Result ← on_after_validate_output ← Output Validation ← on_before_validate_output ← on_after_run
                                                                                         ↓
                                                                                 Error → on_error
```

## Compensation & Error Recovery

Enable compensation for critical operations:

```elixir
defmodule MyApp.Actions.CreateOrder do
  use Jido.Action,
    name: "create_order",
    compensation: [enabled: true, max_retries: 3],
    schema: [
      user_id: [type: :string, required: true],
      items: [type: {:list, :map}, required: true]
    ]

  def run(params, context) do
    with {:ok, user} <- validate_user(params.user_id),
         {:ok, order} <- create_order_record(params.items),
         {:ok, _} <- charge_payment(order) do
      {:ok, order}
    end
  end

  # Compensation runs on error
  def on_error(failed_params, error, context, opts) do
    case error.type do
      :execution_error ->
        # Clean up any partial state
        cancel_pending_order(failed_params.user_id)
        refund_payment_if_charged(failed_params.user_id)
        {:ok, %{compensated: true}}
      
      _ ->
        {:ok, %{compensated: false}}
    end
  end
end
```

## Output Validation

Validate action outputs for consistency:

```elixir
defmodule MyApp.Actions.GenerateReport do
  use Jido.Action,
    name: "generate_report",
    schema: [type: [type: :atom, in: [:summary, :detailed]]],
    # Validate output structure
    output_schema: [
      title: [type: :string, required: true],
      content: [type: :string, required: true],
      generated_at: [type: :string, required: true],
      metadata: [type: :map, default: %{}]
    ]

  def run(params, _context) do
    {:ok, %{
      title: "#{params.type} Report",
      content: generate_content(params.type),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: %{type: params.type}
    }}
  end
end
```

## AI Tool Integration

Actions automatically convert to AI-compatible tool definitions:

```elixir
# Get tool definition
tool_def = MyApp.Actions.ProcessData.to_tool()

# Returns LangChain-compatible tool definition:
%{
  name: "process_data",
  description: "Processes input data",
  function: #Function<...>,  # Executable function
  parameters_schema: %{
    "type" => "object",
    "properties" => %{
      "data" => %{"type" => "string", "description" => "Input data"}
    },
    "required" => ["data"]
  }
}

# Execute from AI tool call (handles string keys and type conversion)
{:ok, result} = Jido.Action.Tool.execute_action(
  MyApp.Actions.ProcessData,
  %{"data" => "input from AI"},
  %{}
)
```

## Advanced Patterns

### Context-Aware Actions

```elixir
def run(params, context) do
  # Access execution context
  user_id = context[:user_id]
  request_id = context[:request_id]
  
  # Use context for business logic
  result = process_for_user(params, user_id)
  {:ok, Map.put(result, :request_id, request_id)}
end
```

### Dynamic Configuration

```elixir
defmodule MyApp.Actions.ConfigurableProcessor do
  use Jido.Action,
    name: "configurable_processor",
    schema: [
      data: [type: :string, required: true],
      # Configuration from application environment
      timeout: [type: :integer, default: Application.get_env(:my_app, :default_timeout, 5000)]
    ]
end
```

### Resource Management

```elixir
def run(params, _context) do
  # Acquire resources
  {:ok, connection} = Database.connect()
  
  try do
    result = Database.query(connection, params.query)
    {:ok, result}
  after
    # Always clean up
    Database.disconnect(connection)
  end
end
```

## Best Practices

### Design Principles
- **Single Responsibility**: One action = one operation
- **Clear Contracts**: Use comprehensive schemas  
- **Idempotency**: Safe to retry when possible
- **Context Isolation**: Use context for cross-cutting concerns only

### Performance
- **Lazy Loading**: Load resources only when needed
- **Timeouts**: Set reasonable timeouts for external calls
- **Resource Pooling**: Reuse expensive resources like DB connections
- **Telemetry**: Instrument critical paths

### Error Handling
- **Structured Errors**: Use `Jido.Action.Error` helpers
- **Meaningful Messages**: Provide actionable error messages
- **Graceful Degradation**: Handle partial failures elegantly
- **Compensation**: Implement cleanup for critical operations

## Next Steps

**→ [Schemas & Validation](schemas-validation.md)** - Deep dive into NimbleOptions and Zoi schemas  
**→ [Execution Engine](execution-engine.md)** - Robust action execution  
**→ [Instructions & Plans](instructions-plans.md)** - Workflow composition  
**→ [Error Handling Guide](error-handling.md)** - Advanced error patterns

---
← [Your Second Action](your-second-action.md) | [Next: Schemas & Validation →](schemas-validation.md)
