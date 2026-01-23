# Configuration Guide

**Prerequisites**: Basic Elixir configuration knowledge

Configure Jido Action's runtime behavior, timeouts, and application-specific settings for your environment.

## Application Configuration

### Basic Setup

Add to your `config/config.exs`:

```elixir
import Config

config :jido_action,
  # Global timeout in milliseconds (default: 30000)
  default_timeout: 30_000,
  
  # Retry configuration
  default_max_retries: 1,       # Default retry attempts
  default_backoff: 250          # Initial backoff in milliseconds (exponential, capped at 30s)
```

### Environment-Specific Configuration

```elixir
# config/dev.exs
import Config

config :jido_action,
  default_timeout: 60_000       # Longer timeouts in dev

# config/test.exs  
import Config

config :jido_action,
  default_timeout: 1_000,       # Faster timeouts in tests
  default_max_retries: 0        # No retries in tests

# config/prod.exs
import Config

config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 3,       # More retries in production
  default_backoff: 500          # Longer initial backoff
```

## Runtime Configuration

### Per-Action Configuration

Actions define compensation settings at compile time:

```elixir
defmodule MyApp.Actions.CriticalOperation do
  use Jido.Action,
    name: "critical_operation",
    description: "An operation with compensation enabled",
    compensation: [
      enabled: true,
      max_retries: 3,
      timeout: 10_000
    ],
    schema: [data: [type: :string, required: true]]

  def run(params, _context) do
    {:ok, %{processed: params.data}}
  end

  # Called when an error occurs and compensation is enabled
  def on_error(failed_params, error, context, opts) do
    # Perform rollback logic
    {:ok, %{rolled_back: true}}
  end
end
```

### Execution-Time Configuration

Override settings when executing actions:

```elixir
# Override timeout and retries for specific execution
{:ok, result} = Jido.Exec.run(
  MyApp.Actions.SlowOperation,
  %{data: "input"},
  %{},
  timeout: 60_000,           # 60 second timeout
  max_retries: 5,            # 5 retries
  backoff: 500,              # 500ms initial backoff (doubles each retry)
  log_level: :debug,         # Override log level
  telemetry: :silent         # Disable telemetry for this call
)
```

**Available execution options:**
- `:timeout` - Maximum time in ms for the action to complete (default: 30000)
- `:max_retries` - Maximum retry attempts on failure (default: 1)
- `:backoff` - Initial backoff time in ms, doubles with each retry (default: 250, capped at 30s)
- `:log_level` - Override Logger level (`:debug`, `:info`, `:warning`, `:error`)
- `:telemetry` - Telemetry mode: `:full` (default) or `:silent`

### Configuration Access

Access configuration in your actions:

```elixir
defmodule MyApp.Actions.ConfigAware do
  use Jido.Action,
    name: "config_aware",
    schema: []

  def run(params, _context) do
    # Get application configuration
    timeout = Application.get_env(:jido_action, :default_timeout, 30_000)
    api_key = Application.get_env(:my_app, :api_key)
    
    # Use configuration in business logic
    case make_api_call(params, api_key, timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Telemetry Integration

### Telemetry Events

Jido Action emits telemetry events under the `[:jido, :action]` prefix using `:telemetry.span/3`:

- `[:jido, :action, :start]` - Action execution begins
- `[:jido, :action, :stop]` - Action execution completes successfully
- `[:jido, :action, :exception]` - Action execution fails

### Custom Telemetry Handlers

Set up telemetry handlers for monitoring:

```elixir
# In your application.ex
def start(_type, _args) do
  # Attach telemetry handlers
  :telemetry.attach_many(
    "jido-action-handlers",
    [
      [:jido, :action, :start],
      [:jido, :action, :stop], 
      [:jido, :action, :exception]
    ],
    &MyApp.Telemetry.handle_event/4,
    %{}
  )
  
  # Start your supervision tree
  children = [
    {Task.Supervisor, name: Jido.Action.TaskSupervisor}
  ]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Telemetry Handler Implementation

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def handle_event([:jido, :action, :start], _measurements, metadata, _config) do
    Logger.info("Action started",
      action: metadata.action,
      params: metadata.params
    )
  end

  def handle_event([:jido, :action, :stop], measurements, metadata, _config) do
    Logger.info("Action completed",
      action: metadata.action,
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
    )
  end

  def handle_event([:jido, :action, :exception], measurements, metadata, _config) do
    Logger.error("Action failed",
      action: metadata.action,
      kind: metadata.kind,
      reason: metadata.reason,
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
    )
  end
end
```

## Task Supervisor Setup

Async action execution requires a Task.Supervisor in your supervision tree:

```elixir
# In your application.ex
def start(_type, _args) do
  children = [
    {Task.Supervisor, name: Jido.Action.TaskSupervisor}
    # ... other children
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Instance Isolation (Multi-Tenant)

For multi-tenant applications, create instance-scoped supervisors:

```elixir
# In your application.ex or dynamic supervisor
def start(_type, _args) do
  children = [
    # Global supervisor (always required)
    {Task.Supervisor, name: Jido.Action.TaskSupervisor},
    
    # Instance-scoped supervisors for tenant isolation
    {Task.Supervisor, name: TenantA.Jido.TaskSupervisor},
    {Task.Supervisor, name: TenantB.Jido.TaskSupervisor}
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Execute actions with instance isolation:

```elixir
# Routes to TenantA.Jido.TaskSupervisor
{:ok, result} = Jido.Exec.run(MyAction, params, context, jido: TenantA.Jido)

# Routes to TenantB.Jido.TaskSupervisor
{:ok, result} = Jido.Exec.run(MyAction, params, context, jido: TenantB.Jido)
```

**Key behaviors:**
- When `jido:` is absent or `nil`, uses global `Jido.Action.TaskSupervisor`
- When `jido: MyApp.Jido` is provided, uses `MyApp.Jido.TaskSupervisor`
- Raises `ArgumentError` if instance supervisor is not running (no silent fallback)

## Environment Variables

Support runtime configuration via environment variables:

```elixir
# config/runtime.exs
import Config

config :jido_action,
  default_timeout: String.to_integer(System.get_env("JIDO_DEFAULT_TIMEOUT", "30000")),
  default_max_retries: String.to_integer(System.get_env("JIDO_MAX_RETRIES", "1")),
  default_backoff: String.to_integer(System.get_env("JIDO_DEFAULT_BACKOFF", "250"))

# Application-specific configuration
config :my_app,
  database_url: System.get_env("DATABASE_URL"),
  api_key: System.get_env("API_KEY")
```

### Environment Variable Validation

Validate required environment variables:

```elixir
defmodule MyApp.Config do
  def validate_config! do
    required_env_vars = [
      "DATABASE_URL",
      "API_KEY"
    ]
    
    missing = Enum.filter(required_env_vars, fn var ->
      System.get_env(var) == nil
    end)
    
    unless Enum.empty?(missing) do
      raise "Missing required environment variables: #{Enum.join(missing, ", ")}"
    end
    
    :ok
  end
end

# In application.ex
def start(_type, _args) do
  MyApp.Config.validate_config!()
  # ... rest of startup
end
```

## Custom Configuration Modules

Create configuration modules for complex settings:

```elixir
defmodule MyApp.Config.Actions do
  @default_timeout 30_000
  @default_retries 1

  def get_timeout(action_module) do
    case action_module do
      MyApp.Actions.SlowOperation -> 60_000
      MyApp.Actions.QuickCheck -> 5_000
      _ -> Application.get_env(:jido_action, :default_timeout, @default_timeout)
    end
  end

  def get_retries(action_module) do
    case action_module do
      MyApp.Actions.CriticalOperation -> 5
      MyApp.Actions.BestEffort -> 0
      _ -> Application.get_env(:jido_action, :default_max_retries, @default_retries)
    end
  end
end
```

## Testing Configuration

### Test-Specific Settings

```elixir
# test/support/test_config.ex
defmodule MyApp.TestConfig do
  def setup_test_env do
    # Override configuration for tests
    Application.put_env(:jido_action, :default_timeout, 1_000)
    Application.put_env(:jido_action, :default_max_retries, 0)
    
    # Mock external services
    Application.put_env(:my_app, :api_base_url, "http://localhost:4002")
  end
end

# In test_helper.exs
MyApp.TestConfig.setup_test_env()
```

### Configuration in Tests

```elixir
defmodule MyApp.Actions.ConfigurableTest do
  use ExUnit.Case
  
  setup do
    # Save original config
    original_timeout = Application.get_env(:jido_action, :default_timeout)
    
    on_exit(fn ->
      # Restore original config
      Application.put_env(:jido_action, :default_timeout, original_timeout)
    end)
    
    %{original_timeout: original_timeout}
  end
  
  test "respects custom timeout configuration" do
    # Set test-specific timeout
    Application.put_env(:jido_action, :default_timeout, 100)
    
    # Test action behavior with short timeout
    assert {:error, %Jido.Action.Error.TimeoutError{}} = 
      Jido.Exec.run(MyApp.Actions.SlowOperation, %{}, %{})
  end
end
```

## Configuration Reference

### Application Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:default_timeout` | integer | 30000 | Default action timeout in milliseconds |
| `:default_max_retries` | integer | 1 | Default number of retry attempts |
| `:default_backoff` | integer | 250 | Initial backoff time in ms (exponential) |

### Action Compensation Config

Defined at compile time in `use Jido.Action`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:enabled` | boolean | false | Enable compensation on error |
| `:max_retries` | integer | 1 | Compensation retry attempts |
| `:timeout` | integer | 5000 | Compensation timeout in ms |

### Execution Options

Passed to `Jido.Exec.run/4`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:timeout` | integer | 30000 | Action timeout in milliseconds |
| `:max_retries` | integer | 1 | Number of retry attempts |
| `:backoff` | integer | 250 | Initial backoff in ms |
| `:log_level` | atom | :info | Logger level override |
| `:telemetry` | atom | :full | `:full` or `:silent` |
| `:jido` | atom | nil | Instance name for multi-tenant isolation |

## Best Practices

### Configuration Organization
- **Environment Separation**: Different configs for dev/test/prod
- **Validation**: Validate required configuration at startup
- **Defaults**: The library provides sensible defaults

### Performance
- **Timeouts**: Set appropriate timeouts for different environments
- **Retries**: Configure retries based on expected failure rates
- **Backoff**: Use exponential backoff to avoid thundering herd

### Deployment
- **Runtime Config**: Use `config/runtime.exs` for environment variables
- **Task Supervisor**: Ensure `Jido.Action.TaskSupervisor` is in your supervision tree

## Next Steps

**→ [Testing Guide](testing.md)** - Testing configurations and environments  
**→ [Error Handling Guide](error-handling.md)** - Error handling patterns

---
← [Error Handling Guide](error-handling.md) | **Next: [Testing Guide](testing.md)** →
