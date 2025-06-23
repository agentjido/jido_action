# Jido.Action

[![Hex.pm](https://img.shields.io/hexpm/v/jido_action.svg)](https://hex.pm/packages/jido_action)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_action/)
[![CI](https://github.com/agentjido/jido_action/actions/workflows/elixir-ci.yml/badge.svg)](https://github.com/agentjido/jido_action/actions/workflows/elixir-ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_action.svg)](https://github.com/agentjido/jido_action/blob/main/LICENSE.md)
[![Coverage Status](https://coveralls.io/repos/github/agentjido/jido_action/badge.svg?branch=main)](https://coveralls.io/github/agentjido/jido_action?branch=main)

> **Composable, validated actions for Elixir applications with built-in AI tool integration**

_`Jido.Action` is part of the [Jido](https://github.com/agentjido/jido) project. Learn more about Jido at [agentjido.xyz](https://agentjido.xyz)._

## Overview

`Jido.Action` is a framework for building composable, validated actions in Elixir. It provides a standardized way to define discrete units of functionality that can be composed into complex workflows, validated at compile and runtime using NimbleOptions schemas, and seamlessly integrated with AI systems through automatic tool generation.

Whether you're building microservices that need structured operations, implementing agent-based systems, or creating AI-powered applications that require reliable function calling, Jido.Action provides the foundation for robust, traceable, and scalable action-driven architecture.

## Why Do I Need Actions?

**Structured Operations in Elixir's Dynamic World**

Elixir excels at building fault-tolerant, concurrent systems, but as applications grow, you often need:

- **Standardized Operation Format**: Raw function calls lack structure, validation, and metadata
- **AI Tool Integration**: Converting functions to LLM-compatible tool definitions manually
- **Workflow Composition**: Building complex multi-step processes from smaller units
- **Parameter Validation**: Ensuring inputs are correct before expensive operations
- **Error Handling**: Consistent error reporting across different operation types
- **Runtime Introspection**: Understanding what operations are available and how they work

```elixir
# Traditional Elixir functions
def process_order(order_id, user_id, options) do
  # No validation, no metadata, no AI integration
  # Error handling is inconsistent
end

# With Jido.Action
defmodule ProcessOrder do
  use Jido.Action,
    name: "process_order",
    description: "Processes a customer order with validation and tracking",
    schema: [
      order_id: [type: :string, required: true],
      user_id: [type: :string, required: true],
      priority: [type: {:in, [:low, :normal, :high]}, default: :normal]
    ]

  def run(params, context) do
    # Params are pre-validated, action is AI-ready, errors are structured
    {:ok, %{status: "processed", order_id: params.order_id}}
  end
end

# Use directly or convert to AI tool
ProcessOrder.to_tool()  # Ready for LLM integration
```

Jido.Action transforms ad-hoc functions into structured, validated, AI-compatible operations that scale from simple tasks to complex agent workflows.

## Key Features

### **Structured Action Definition**
- Compile-time configuration validation
- Runtime parameter validation with NimbleOptions
- Rich metadata including descriptions, categories, and tags
- Automatic JSON serialization support

### **AI Tool Integration**
- Automatic conversion to LLM-compatible tool format
- OpenAI function calling compatible
- Parameter schemas with validation and documentation
- Seamless integration with AI agent frameworks

### **Robust Execution Engine**
- Synchronous and asynchronous execution via `Jido.Exec`
- Automatic retries with exponential backoff
- Timeout handling and cancellation
- Comprehensive error handling and compensation

### **Workflow Composition**
- Instruction-based workflow definition via `Jido.Instruction`
- DAG-based pipeline workflows via `Jido.Flow`
- Parameter normalization and context sharing
- Action chaining and conditional execution
- Built-in workflow primitives

### **Comprehensive Tool Library**
- 25+ pre-built actions for common operations
- File system operations, HTTP requests, arithmetic
- Weather APIs, GitHub integration, workflow primitives
- Robot simulation tools for testing and examples

## Installation

Add `jido_action` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_action, "~> 1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### 1. Define Your First Action

```elixir
defmodule MyApp.Actions.GreetUser do
  use Jido.Action,
    name: "greet_user",
    description: "Greets a user with a personalized message",
    category: "communication",
    tags: ["greeting", "user"],
    vsn: "1.0.0",
    schema: [
      name: [type: :string, required: true, doc: "User's name"],
      language: [type: {:in, ["en", "es", "fr"]}, default: "en", doc: "Greeting language"]
    ]

  @impl true
  def run(params, _context) do
    greeting = case params.language do
      "en" -> "Hello"
      "es" -> "Hola" 
      "fr" -> "Bonjour"
    end
    
    {:ok, %{message: "#{greeting}, #{params.name}!"}}
  end
end
```

### 2. Execute Actions with Jido.Exec

```elixir
# Synchronous execution
{:ok, result} = Jido.Exec.run(MyApp.Actions.GreetUser, %{name: "Alice"})
# => {:ok, %{message: "Hello, Alice!"}}

# With validation error handling
{:error, reason} = Jido.Exec.run(MyApp.Actions.GreetUser, %{invalid: "params"})
# => {:error, %Jido.Action.Error{type: :validation_error, ...}}

# Asynchronous execution
async_ref = Jido.Exec.run_async(MyApp.Actions.GreetUser, %{name: "Bob"})
{:ok, result} = Jido.Exec.await(async_ref)
```

### 3. Create Workflows with Jido.Instruction

```elixir
# Define a sequence of actions
instructions = [
  MyApp.Actions.ValidateUser,
  {MyApp.Actions.GreetUser, %{name: "Alice", language: "es"}},
  MyApp.Actions.LogActivity
]

# Normalize with shared context
{:ok, workflow} = Jido.Instruction.normalize(instructions, %{
  request_id: "req_123",
  tenant_id: "tenant_456"
})

# Execute the workflow
Enum.each(workflow, fn instruction ->
  Jido.Exec.run(instruction.action, instruction.params, instruction.context)
end)
```

### 4. Build DAG Pipelines with Jido.Flow

```elixir
# Create a data processing pipeline
flow = Jido.Flow.new("data_processing")
  |> Jido.Flow.add_step(name: "validate", action: MyApp.Actions.ValidateData)
  |> Jido.Flow.add_step("validate", name: "normalize", work: &String.downcase/1)
  |> Jido.Flow.add_step("normalize", name: "process", action: MyApp.Actions.ProcessData)

# Execute with input data
context = Jido.Flow.Context.new(%{raw_data: "Hello World"})
runnables = Jido.Flow.next_runnables(flow, context)

# Process first step
{step, ctx} = hd(runnables)
{:ok, result} = Jido.Flow.run({step, ctx})

# Continue with next steps
next_runnables = Jido.Flow.next_runnables(flow, result)
```

### 5. AI Tool Integration

```elixir
# Convert action to AI tool format
tool_definition = MyApp.Actions.GreetUser.to_tool()

# Returns OpenAI-compatible function definition:
%{
  "name" => "greet_user",
  "description" => "Greets a user with a personalized message",
  "parameters" => %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "description" => "User's name"},
      "language" => %{
        "type" => "string", 
        "enum" => ["en", "es", "fr"],
        "description" => "Greeting language"
      }
    },
    "required" => ["name"]
  }
}

# Use with AI frameworks like OpenAI function calling
# The action can then be executed when the AI calls the tool
```

## Core Components

### Jido.Action
The foundational behavior for defining structured, validated actions. Provides:
- Compile-time configuration validation
- Parameter and output schemas with validation
- Lifecycle hooks for customization
- Automatic AI tool format generation
- JSON serialization support

### Jido.Exec  
The execution engine for running actions reliably. Features:
- Synchronous and asynchronous execution
- Automatic retries with exponential backoff
- Timeout handling and process monitoring
- Comprehensive error handling
- Telemetry integration for monitoring

### Jido.Instruction
The workflow composition system for building complex operations. Enables:
- Multiple input formats (modules, tuples, structs)
- Parameter normalization and validation
- Context sharing across actions
- Action allowlist validation
- Flexible workflow definition patterns

### Jido.Flow
The DAG-based pipeline system for building dataflow workflows. Features:
- Directed Acyclic Graph (DAG) structure for modeling dependencies
- Support for both function-based and Action-based steps
- Rich execution context with metadata and error tracking
- Parallel execution capabilities via customizable runners
- Integration with Jido.Action validation and error handling
- Pipeline introspection and debugging tools

## Bundled Tools

Jido.Action comes with a comprehensive library of pre-built tools organized by category:

### Core Utilities (`Jido.Tools.Basic`)
| Tool | Description | Use Case |
|------|-------------|----------|
| `Sleep` | Pauses execution for specified duration | Delays, rate limiting |
| `Log` | Logs messages with configurable levels | Debugging, monitoring |
| `Todo` | Logs TODO items as placeholders | Development workflow |
| `RandomSleep` | Random delay within specified range | Chaos testing, natural delays |
| `Increment/Decrement` | Numeric operations | Counters, calculations |
| `Noop` | No operation, returns input unchanged | Placeholder actions |
| `Today` | Returns current date in specified format | Date operations |

### Arithmetic Operations (`Jido.Tools.Arithmetic`)
| Tool | Description | Use Case |
|------|-------------|----------|
| `Add` | Adds two numbers | Mathematical operations |
| `Subtract` | Subtracts one number from another | Calculations |
| `Multiply` | Multiplies two numbers | Math workflows |
| `Divide` | Divides with zero-division handling | Safe arithmetic |
| `Square` | Squares a number | Mathematical functions |

### File System Operations (`Jido.Tools.Files`)
| Tool | Description | Use Case |
|------|-------------|----------|
| `WriteFile` | Write content to files with options | File creation, logging |
| `ReadFile` | Read file contents | Data processing |
| `CopyFile` | Copy files between locations | Backup, deployment |
| `MoveFile` | Move/rename files | File organization |
| `DeleteFile` | Delete files/directories (recursive) | Cleanup operations |
| `MakeDirectory` | Create directories (recursive) | Setup operations |
| `ListDirectory` | List directory contents with filtering | File discovery |

### HTTP Operations (`Jido.Tools.ReqTool`)

`ReqTool` is a specialized action that provides a behavior and macro for creating HTTP request actions using the Req library. It offers a standardized way to build HTTP-based actions with configurable URLs, methods, headers, and response processing.

| Tool | Description | Use Case |
|------|-------------|----------|
| HTTP Actions | GET, POST, PUT, DELETE requests with Req library | API integration, webhooks |
| JSON Support | Automatic JSON parsing and response handling | REST API clients |
| Custom Headers | Configurable HTTP headers per action | Authentication, API keys |
| Response Transform | Custom response transformation via callbacks | Data mapping, filtering |
| Action Generation | Macro-based HTTP action creation | Rapid API client development |

### External API Integration
| Tool | Description | Use Case |
|------|-------------|----------|
| `Weather` | OpenWeatherMap API integration | Weather data, demos |
| `Github.Issues` | GitHub Issues API (create, list, filter) | Issue management |

### Workflow & Simulation
| Tool | Description | Use Case |
|------|-------------|----------|
| `Workflow` | Multi-step workflow execution | Complex processes |
| `Flow` | DAG-based pipeline execution | Data processing pipelines |
| `Simplebot` | Robot simulation actions | Testing, examples |

### Specialized Tools
| Tool | Description | Use Case |
|------|-------------|----------|
| Branch/Parallel | Conditional and parallel execution | Complex workflows |
| Error Handling | Compensation and retry mechanisms | Fault tolerance |

## Advanced Features

### DAG Pipeline Workflows with Jido.Flow

Jido.Flow provides a powerful DAG-based pipeline system for complex data processing workflows:

```elixir
# Create a comprehensive data processing pipeline
flow = Jido.Flow.new("nlp_pipeline")
  |> Jido.Flow.add_step(name: "extract", action: MyApp.Actions.ExtractText)
  |> Jido.Flow.add_step("extract", name: "tokenize", work: &String.split/1)
  |> Jido.Flow.add_step("tokenize", name: "analyze", action: MyApp.Actions.SentimentAnalysis)
  |> Jido.Flow.add_step("analyze", name: "store", action: MyApp.Actions.StoreResults)

# Execute with custom runner for parallel processing
defmodule AsyncRunner do
  @behaviour Jido.Flow.Runner
  
  def run(runnables) when is_list(runnables) do
    tasks = Enum.map(runnables, fn {step, context} ->
      Task.async(fn -> Jido.Flow.Step.execute(step, context) end)
    end)
    
    results = Task.await_many(tasks)
    {:ok, results}
  end
end

# Execute pipeline steps
context = Jido.Flow.Context.new(%{document: "Large text document..."})
runnables = Jido.Flow.next_runnables(flow, context)
{:ok, results} = AsyncRunner.run(runnables)
```

#### Flow Features:

- **Mixed Step Types**: Combine Actions and functions in the same pipeline
- **Error Context**: Rich error tracking and recovery mechanisms
- **Metadata Support**: Track execution context throughout the pipeline
- **Parallel Execution**: Custom runners for different execution strategies
- **Pipeline Introspection**: Analyze flow structure and dependencies

```elixir
# Pipeline analysis
steps = Jido.Flow.steps(flow)
order = Jido.Flow.topological_order(flow)
is_valid = Jido.Flow.acyclic?(flow)

# Add metadata to track pipeline versions
flow = Jido.Flow.put_meta(flow, :version, "2.1.0")
version = Jido.Flow.get_meta(flow, :version)
```

### Error Handling and Compensation

Actions support sophisticated error handling with optional compensation:

```elixir
defmodule RobustAction do
  use Jido.Action,
    name: "robust_action",
    compensation: [
      enabled: true,
      max_retries: 3,
      timeout: 5000
    ]

  def run(params, context) do
    # Main action logic
    {:ok, result}
  end

  # Called when errors occur if compensation is enabled
  def on_error(failed_params, error, context, opts) do
    # Perform rollback/cleanup operations
    {:ok, %{compensated: true, original_error: error}}
  end
end
```

### Lifecycle Hooks

Customize action behavior with lifecycle hooks:

```elixir
defmodule CustomAction do
  use Jido.Action, name: "custom_action"

  def on_before_validate_params(params) do
    # Transform params before validation
    {:ok, transformed_params}
  end

  def on_after_validate_params(params) do
    # Enrich params after validation
    {:ok, enriched_params}
  end

  def on_after_run(result) do
    # Post-process results
    {:ok, enhanced_result}
  end
end
```

### Telemetry Integration

Actions emit telemetry events for monitoring:

```elixir
# Attach telemetry handlers
:telemetry.attach("action-handler", [:jido, :action, :complete], fn event, measurements, metadata, config ->
  # Handle action completion events
  Logger.info("Action completed: #{metadata.action}")
end, %{})
```

## Testing

Test actions directly or within the execution framework:

```elixir
defmodule MyActionTest do
  use ExUnit.Case

  test "action validates parameters" do
    assert {:error, _} = MyAction.validate_params(%{invalid: "params"})
    assert {:ok, _} = MyAction.validate_params(%{valid: "params"})
  end

  test "action execution" do
    assert {:ok, result} = Jido.Exec.run(MyAction, %{valid: "params"})
    assert result.status == "success"
  end

  test "async action execution" do
    async_ref = Jido.Exec.run_async(MyAction, %{valid: "params"})
    assert {:ok, result} = Jido.Exec.await(async_ref, 5000)
  end
end
```

## Configuration

Configure defaults in your application:

```elixir
# config/config.exs
config :jido_action,
  default_timeout: 10_000,
  default_max_retries: 3,
  default_backoff: 500
```

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

Copyright 2024 Mike Hostetler

Licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md) for details.

## Links

- **Documentation**: [https://hexdocs.pm/jido_action](https://hexdocs.pm/jido_action)
- **GitHub**: [https://github.com/agentjido/jido_action](https://github.com/agentjido/jido_action)
- **AgentJido**: [https://agentjido.xyz](https://agentjido.xyz)
- **Jido Workbench**: [https://github.com/agentjido/jido_workbench](https://github.com/agentjido/jido_workbench)
