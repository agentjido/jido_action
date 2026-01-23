# Execution Engine

**Prerequisites**: [Actions Guide](actions-guide.md), [Schemas & Validation](schemas-validation.md)

The execution engine (`Jido.Exec`) provides robust, production-ready action execution with timeouts, retries, telemetry, and proper error handling.

## Setup

Add the Task.Supervisor to your application's supervision tree:

```elixir
# In your application.ex
children = [
  {Task.Supervisor, name: Jido.Action.TaskSupervisor},
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Basic Execution

### Synchronous Execution

```elixir
# Simple execution
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.ProcessData,
  %{data: "input"},
  %{user_id: "123"}
)

# With options
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.ProcessData,
  %{data: "input"},
  %{user_id: "123"},
  timeout: 10_000,          # 10 second timeout (default: 30_000)
  max_retries: 3,           # Retry 3 times on failure (default: 1)
  backoff: 250,             # Initial backoff in ms (default: 250)
  log_level: :debug         # Override log level for this action
)

# Execute from an Instruction struct
instruction = %Jido.Instruction{
  action: MyApp.Actions.ProcessData,
  params: %{data: "input"},
  context: %{user_id: "123"},
  opts: [timeout: 10_000]
}
{:ok, result} = Jido.Exec.run(instruction)
```

### Asynchronous Execution

```elixir
# Start async execution
async_ref = Jido.Exec.run_async(
  MyApp.Actions.LongRunning,
  %{data: "large_dataset"},
  %{user_id: "123"}
)

# Await result (default timeout: 5000ms)
{:ok, result} = Jido.Exec.await(async_ref)

# Await with custom timeout
{:ok, result} = Jido.Exec.await(async_ref, 30_000)

# Cancel if needed
:ok = Jido.Exec.cancel(async_ref)
```

### Instance Isolation (Multi-Tenant)

For multi-tenant applications, route execution through instance-scoped supervisors:

```elixir
# First, add instance supervisor to your supervision tree
children = [
  {Task.Supervisor, name: MyTenant.Jido.TaskSupervisor}
]

# Execute with instance isolation
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.ProcessData,
  %{data: "input"},
  %{user_id: "123"},
  jido: MyTenant.Jido  # Routes to MyTenant.Jido.TaskSupervisor
)

# Async execution also supports instance isolation
async_ref = Jido.Exec.run_async(
  MyApp.Actions.LongRunning,
  %{data: "large_dataset"},
  %{user_id: "123"},
  jido: MyTenant.Jido
)
```

When `jido:` is provided:
- All tasks spawn under the instance-scoped TaskSupervisor
- Complete isolation between tenants (no cross-contamination)
- Raises `ArgumentError` if the instance supervisor is not running (no silent fallback)

## Execution Features

### Timeout Management

```elixir
# Action-level timeout
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.ApiCall,
  %{url: "https://slow-api.com/data"},
  %{},
  timeout: 5000  # Times out after 5 seconds
)

# Handle timeout errors
alias Jido.Action.Error

case Jido.Exec.run(action, params, context, timeout: 1000) do
  {:ok, result} -> 
    handle_success(result)
  {:error, %Error.TimeoutError{timeout: timeout}} -> 
    handle_timeout(timeout)
  {:error, error} -> 
    handle_other_error(error)
end
```

### Retry Logic

The execution engine uses exponential backoff for retries:

```elixir
# Configure retry behavior
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.UnreliableOperation,
  params,
  context,
  max_retries: 5,           # Try up to 5 times (default: 1)
  backoff: 250              # Initial backoff in ms (default: 250)
)

# Retry progression with backoff: 250 doubles each time
# 250ms → 500ms → 1s → 2s → 4s (capped at 30s)
```

### Custom Retry Logic

```elixir
defmodule MyApp.Actions.SmartRetry do
  use Jido.Action,
    name: "smart_retry",
    schema: [operation: [type: :string, required: true]]

  def run(params, context) do
    case perform_operation(params.operation) do
      {:ok, result} -> {:ok, result}
      {:error, :rate_limited} -> 
        # Don't retry rate limit errors immediately
        {:error, Jido.Action.Error.execution_error("Rate limited", retry: false)}
      {:error, :temporary_failure} ->
        # Retry these errors
        {:error, Jido.Action.Error.execution_error("Temporary failure", retry: true)}
      {:error, reason} ->
        {:error, Jido.Action.Error.execution_error("Operation failed: #{reason}")}
    end
  end
end
```

## Chaining Actions

Sequential execution with data flow between actions:

### Basic Chaining

```elixir
# Chain actions with data flow
{:ok, final_result} = Jido.Exec.Chain.chain(
  [
    MyApp.Actions.ValidateInput,
    {MyApp.Actions.ProcessData, %{format: "json"}},  # Merge extra params
    MyApp.Actions.SaveResult
  ],
  %{input: "data"},
  context: %{user_id: "123"}
)

# Data flows: input → validate → process → save → final_result
# Each action's result is merged with params for the next action
```

### Chaining with Interruption

```elixir
# Chain with interrupt check function
# The interrupt check is called between each action
interrupt_check = fn -> 
  System.monotonic_time(:millisecond) > deadline
end

case Jido.Exec.Chain.chain(
  actions,
  initial_params,
  context: %{},
  interrupt_check: interrupt_check
) do
  {:ok, result} -> handle_success(result)
  {:interrupted, partial_result} -> handle_interruption(partial_result)
  {:error, error} -> handle_error(error)
end
```

### Async Chaining

```elixir
# Run chain asynchronously
task = Jido.Exec.Chain.chain(
  actions,
  initial_params,
  async: true,
  context: %{user_id: "123"}
)

result = Task.await(task)
```

### Chain Error Handling

```elixir
case Jido.Exec.Chain.chain(actions, params, context: context) do
  {:ok, result} ->
    handle_success(result)
  
  {:error, error} ->
    # Chain stops at first failure
    Logger.error("Chain failed: #{inspect(error)}")
    handle_error(error)
    
  {:interrupted, partial_result} ->
    # Chain was interrupted between actions
    handle_partial_completion(partial_result)
end
```

## Closures

Create reusable execution units with preset context and options:

```elixir
# Create closure with preset context and options
process_closure = Jido.Exec.Closure.closure(
  MyApp.Actions.ProcessData,
  %{user_id: "123"},              # Preset context
  timeout: 10_000                 # Preset options
)

# Execute with params
{:ok, result} = process_closure.(%{data: "input", format: "json"})

# Async closure
async_closure = Jido.Exec.Closure.async_closure(
  MyApp.Actions.LongRunning,
  %{user_id: "123"},              # Preset context
  timeout: 30_000                 # Preset options
)

async_ref = async_closure.(%{data: "large_dataset"})
{:ok, result} = Jido.Exec.await(async_ref)
```

## Telemetry & Observability

The execution engine emits comprehensive telemetry events using `:telemetry.span/3`:

### Built-in Events

```elixir
# Attach telemetry handlers
:telemetry.attach_many(
  "jido-action-handler",
  [
    [:jido, :action, :start],
    [:jido, :action, :stop],
    [:jido, :action, :exception]
  ],
  &handle_telemetry/4,
  %{}
)

def handle_telemetry(event, measurements, metadata, _config) do
  case event do
    [:jido, :action, :start] ->
      Logger.info("Action started", 
        action: metadata.action,
        params: metadata.params,
        context: metadata.context
      )
    
    [:jido, :action, :stop] ->
      Logger.info("Action completed", 
        action: metadata.action,
        duration: measurements.duration
      )
    
    [:jido, :action, :exception] ->
      Logger.error("Action failed",
        action: metadata.action,
        kind: metadata.kind,
        reason: metadata.reason,
        duration: measurements.duration
      )
  end
end
```

### Disabling Telemetry

```elixir
# Run without telemetry events
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.ProcessData,
  params,
  context,
  telemetry: :silent
)
```

### Custom Metrics

```elixir
# In your action
def run(params, context) do
  start_time = System.monotonic_time()
  
  result = perform_work(params)
  
  duration = System.monotonic_time() - start_time
  :telemetry.execute(
    [:my_app, :action, :custom_metric],
    %{duration: duration, size: byte_size(params.data)},
    %{action: __MODULE__, user_id: context.user_id}
  )
  
  {:ok, result}
end
```

## Error Handling

### Error Types

The execution engine uses structured exception types from `Jido.Action.Error`:

```elixir
alias Jido.Action.Error

case Jido.Exec.run(action, params, context) do
  {:ok, result} -> 
    result
  
  {:error, %Error.InvalidInputError{} = error} ->
    handle_validation_error(error)
  
  {:error, %Error.ExecutionFailureError{} = error} ->
    handle_execution_error(error)
  
  {:error, %Error.TimeoutError{} = error} ->
    handle_timeout_error(error)
  
  {:error, %Error.InternalError{} = error} ->
    handle_internal_error(error)
end
```

### Error Recovery

```elixir
defmodule MyApp.RobustExecution do
  alias Jido.Action.Error

  def execute_with_fallback(action, params, context) do
    case Jido.Exec.run(action, params, context, max_retries: 3) do
      {:ok, result} -> 
        {:ok, result}
      
      {:error, %Error.TimeoutError{}} ->
        # Try with longer timeout
        Jido.Exec.run(action, params, context, timeout: 30_000)
      
      {:error, %Error.ExecutionFailureError{}} ->
        # Try fallback action
        Jido.Exec.run(MyApp.Actions.FallbackAction, params, context)
      
      {:error, error} ->
        {:error, error}
    end
  end
end
```

## Performance Considerations

### Resource Management

```elixir
# Pool expensive resources
defmodule MyApp.ResourcePool do
  def execute_with_pool(action, params, context) do
    :poolboy.transaction(:my_pool, fn worker ->
      enhanced_context = Map.put(context, :worker, worker)
      Jido.Exec.run(action, params, enhanced_context)
    end)
  end
end
```

### Async Patterns

```elixir
# Fan-out pattern
defmodule MyApp.FanOut do
  def process_batch(items, context) do
    # Start all async
    async_refs = Enum.map(items, fn item ->
      Jido.Exec.run_async(
        MyApp.Actions.ProcessItem,
        %{item: item},
        context
      )
    end)
    
    # Await all results
    results = Enum.map(async_refs, fn ref ->
      Jido.Exec.await(ref, 10_000)
    end)
    
    {:ok, results}
  end
end
```

## Best Practices

### Timeouts
- Set reasonable timeouts for all operations
- Use shorter timeouts for user-facing operations
- Increase timeouts for background processing

### Retries
- Only retry transient failures
- Use exponential backoff to avoid overwhelming services
- Set maximum retry limits to prevent infinite loops

### Error Handling
- Match on specific error types for appropriate handling
- Log errors with sufficient context for debugging
- Provide meaningful error messages to users

### Async Execution
- Use async for I/O-bound operations
- Limit concurrent async operations to prevent resource exhaustion
- Always await or cancel async operations

## Next Steps

**→ [Instructions & Plans](instructions-plans.md)** - Workflow composition  
**→ [Error Handling Guide](error-handling.md)** - Advanced error patterns  
**→ [Configuration Guide](configuration.md)** - Performance optimization

---
← [Actions Guide](actions-guide.md) | **Next: [Instructions & Plans](instructions-plans.md)** →
