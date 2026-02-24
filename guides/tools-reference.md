# Built-in Tools Reference

**Prerequisites**: [Getting Started](getting-started.md)

Jido Action includes 25+ pre-built tools for common operations. All tools follow the same action patterns and can be used individually or composed into workflows.

## Basic Tools

### Sleep
Pause execution for a specified duration.

```elixir
# Sleep for 1 second
{:ok, result} = Jido.Tools.Basic.Sleep.run(%{duration_ms: 1000}, %{})
# => {:ok, %{duration_ms: 1000}}

# Use in workflows for delays
plan = Jido.Plan.new()
|> Jido.Plan.add("process", MyApp.Actions.ProcessData, %{}, [])
|> Jido.Plan.add("wait", Jido.Tools.Basic.Sleep, %{duration_ms: 5000}, ["process"])
|> Jido.Plan.add("notify", MyApp.Actions.SendNotification, %{}, ["wait"])
```

**Parameters:**
- `duration_ms` (non-negative integer, default: 1000): Milliseconds to sleep

### Log
Log a message with a specified level.

```elixir
{:ok, result} = Jido.Tools.Basic.Log.run(%{level: :info, message: "Hello"}, %{})
# => {:ok, %{level: :info, message: "Hello"}}
```

**Parameters:**
- `level` (atom, default: :info): Log level (:debug, :info, :warning, :error)
- `message` (string, required): Message to log

### Todo
Log a todo item as a placeholder.

```elixir
{:ok, result} = Jido.Tools.Basic.Todo.run(%{todo: "Implement this feature"}, %{})
# => {:ok, %{todo: "Implement this feature"}}
```

**Parameters:**
- `todo` (string, required): Todo item description

### RandomSleep
Introduce a random delay within a specified range.

```elixir
{:ok, result} = Jido.Tools.Basic.RandomSleep.run(%{min_ms: 100, max_ms: 500}, %{})
# => {:ok, %{min_ms: 100, max_ms: 500, actual_delay: 342}}
```

**Parameters:**
- `min_ms` (non-negative integer, required): Minimum sleep duration in milliseconds
- `max_ms` (non-negative integer, required): Maximum sleep duration in milliseconds

### Increment
Increment a value by 1.

```elixir
{:ok, result} = Jido.Tools.Basic.Increment.run(%{value: 5}, %{})
# => {:ok, %{value: 6}}
```

**Parameters:**
- `value` (integer, required): Value to increment

### Decrement
Decrement a value by 1.

```elixir
{:ok, result} = Jido.Tools.Basic.Decrement.run(%{value: 5}, %{})
# => {:ok, %{value: 4}}
```

**Parameters:**
- `value` (integer, required): Value to decrement

### Noop
No operation, returns input unchanged.

```elixir
{:ok, result} = Jido.Tools.Basic.Noop.run(%{foo: "bar"}, %{})
# => {:ok, %{foo: "bar"}}
```

### Inspect
Inspect a value using IO.inspect.

```elixir
{:ok, result} = Jido.Tools.Basic.Inspect.run(%{value: [1, 2, 3]}, %{})
# => {:ok, %{value: [1, 2, 3]}}
```

**Parameters:**
- `value` (any, required): Value to inspect

### Today
Returns today's date in the specified format.

```elixir
{:ok, result} = Jido.Tools.Basic.Today.run(%{format: :iso8601}, %{})
# => {:ok, %{format: :iso8601, date: "2024-01-15"}}

{:ok, result} = Jido.Tools.Basic.Today.run(%{format: :human}, %{})
# => {:ok, %{format: :human, date: "January 15, 2024"}}
```

**Parameters:**
- `format` (atom, default: :iso8601): Format for the date (:iso8601, :basic, or :human)

## Arithmetic Tools

### Add
Add a value to a number.

```elixir
{:ok, result} = Jido.Tools.Arithmetic.Add.run(%{value: 10, amount: 5}, %{})
# => {:ok, %{result: 15}}
```

**Parameters:**
- `value` (number, required): Base value
- `amount` (number, required): Amount to add

### Subtract
Subtract a value from a number.

```elixir
{:ok, result} = Jido.Tools.Arithmetic.Subtract.run(%{value: 10, amount: 3}, %{})
# => {:ok, %{result: 7}}
```

### Multiply
Multiply two numbers.

```elixir
{:ok, result} = Jido.Tools.Arithmetic.Multiply.run(%{value: 6, amount: 4}, %{})
# => {:ok, %{result: 24}}
```

**Parameters:**
- `value` (integer, required): The first number to multiply
- `amount` (integer, required): The second number to multiply

### Divide
Divide one number by another.

```elixir
{:ok, result} = Jido.Tools.Arithmetic.Divide.run(%{value: 20, amount: 4}, %{})
# => {:ok, %{result: 5.0}}

# Division by zero returns error
{:error, error} = Jido.Tools.Arithmetic.Divide.run(%{value: 10, amount: 0}, %{})
# => {:error, "Cannot divide by zero"}
```

**Parameters:**
- `value` (integer, required): The number to be divided (dividend)
- `amount` (integer, required): The number to divide by (divisor)

### Square
Square a number.

```elixir
{:ok, result} = Jido.Tools.Arithmetic.Square.run(%{value: 5.0}, %{})
# => {:ok, %{result: 25.0}}
```

**Parameters:**
- `value` (float, required): The number to be squared

## File Operations

### Read File
Read contents from a file.

```elixir
{:ok, result} = Jido.Tools.Files.ReadFile.run(%{path: "/tmp/data.txt"}, %{})
# => {:ok, %{path: "/tmp/data.txt", content: "file contents"}}

# Handle missing files
{:error, error} = Jido.Tools.Files.ReadFile.run(%{path: "/nonexistent.txt"}, %{})
# => {:error, "Failed to read file: :enoent"}
```

**Parameters:**
- `path` (string, required): Path to the file to be read

### Write File
Write content to a file.

```elixir
{:ok, result} = Jido.Tools.Files.WriteFile.run(%{
  path: "/tmp/output.txt",
  content: "Hello, World!",
  create_dirs: true,
  mode: :write
}, %{})
# => {:ok, %{path: "/tmp/output.txt", bytes_written: 13}}
```

**Parameters:**
- `path` (string, required): Path to the file to be written
- `content` (string, required): Content to be written to the file
- `create_dirs` (boolean, default: false): Create parent directories if they don't exist
- `mode` (atom, default: :write): Write mode - :write overwrites, :append adds to end

### Delete File
Delete a file or directory.

```elixir
{:ok, result} = Jido.Tools.Files.DeleteFile.run(%{path: "/tmp/temp.txt", recursive: false, force: false}, %{})
# => {:ok, %{path: "/tmp/temp.txt"}}

# Recursive deletion
{:ok, result} = Jido.Tools.Files.DeleteFile.run(%{path: "/tmp/mydir", recursive: true}, %{})
# => {:ok, %{deleted: ["/tmp/mydir/file.txt", "/tmp/mydir"]}}
```

**Parameters:**
- `path` (string, required): Path to delete
- `recursive` (boolean, default: false): Recursively delete directories and contents
- `force` (boolean, default: false): Force deletion even if file is read-only

### Copy File
Copy a file from source to destination.

```elixir
{:ok, result} = Jido.Tools.Files.CopyFile.run(%{source: "/tmp/a.txt", destination: "/tmp/b.txt"}, %{})
# => {:ok, %{source: "/tmp/a.txt", destination: "/tmp/b.txt", bytes_copied: 1234}}
```

**Parameters:**
- `source` (string, required): Path to the source file
- `destination` (string, required): Path to the destination file

### Move File
Move/rename a file from source to destination.

```elixir
{:ok, result} = Jido.Tools.Files.MoveFile.run(%{source: "/tmp/a.txt", destination: "/tmp/b.txt"}, %{})
# => {:ok, %{source: "/tmp/a.txt", destination: "/tmp/b.txt"}}
```

**Parameters:**
- `source` (string, required): Path to the source file
- `destination` (string, required): Path to the destination file

### Make Directory
Create a new directory.

```elixir
{:ok, result} = Jido.Tools.Files.MakeDirectory.run(%{path: "/tmp/newdir", recursive: true}, %{})
# => {:ok, %{path: "/tmp/newdir"}}
```

**Parameters:**
- `path` (string, required): Path to the directory to create
- `recursive` (boolean, default: false): Create parent directories if they don't exist

### List Directory
List directory contents.

```elixir
{:ok, result} = Jido.Tools.Files.ListDirectory.run(%{
  path: "/tmp",
  recursive: false
}, %{})
# => {:ok, %{entries: ["file1.txt", "file2.txt"]}}

# With pattern matching
{:ok, result} = Jido.Tools.Files.ListDirectory.run(%{
  path: "/tmp",
  pattern: "*.txt",
  recursive: true
}, %{})
# => {:ok, %{entries: ["/tmp/file1.txt", "/tmp/subdir/file2.txt"]}}
```

**Parameters:**
- `path` (string, required): Path to the directory to list
- `pattern` (string, optional): Glob pattern for filtering files
- `recursive` (boolean, default: false): Include subdirectories recursively

## HTTP Tools

### ReqTool (HTTP Request Builder)
A behavior and macro for creating HTTP request actions using the Req library.

```elixir
# Define a custom HTTP action module
defmodule MyApp.GetUser do
  use Jido.Tools.ReqTool,
    name: "get_user",
    description: "Fetch a user from the API",
    url: "https://api.example.com/users",
    method: :get,
    headers: %{"Authorization" => "Bearer token123"}
end

# Use the generated action
{:ok, response} = MyApp.GetUser.run(%{id: "123"}, %{})
# => {:ok, %{
#   request: %{url: "https://api.example.com/users", method: :get, params: %{id: "123"}},
#   response: %{status: 200, body: %{"id" => "123", "name" => "John"}, headers: [...]}
# }}

# POST with body
defmodule MyApp.CreateUser do
  use Jido.Tools.ReqTool,
    name: "create_user",
    description: "Create a new user",
    url: "https://api.example.com/users",
    method: :post,
    headers: %{"Content-Type" => "application/json"}
end

{:ok, response} = MyApp.CreateUser.run(%{name: "Jane", email: "jane@example.com"}, %{})
```

**Configuration Options (in `use` statement):**
- `url` (string, required): The URL to make requests to
- `method` (atom, required): HTTP method (:get, :post, :put, :delete)
- `headers` (map, default: %{}): HTTP headers to include
- `json` (boolean, default: true): Whether to parse the response as JSON

**Optional Callback:**
- `transform_result/1`: Override to transform the HTTP response result

## External API Packs

`jido_action` now focuses on core and generic tooling.
For vendor/API-specific tools (GitHub, Weather, etc.), use `jido_lib`.

## Workflow Tools

### ActionPlan
A behavior and macro for creating actions that execute Jido Plans (DAG-based workflows).

```elixir
# Define a workflow action
defmodule MyApp.MyWorkflowAction do
  use Jido.Tools.ActionPlan,
    name: "my_workflow",
    description: "Executes a multi-step workflow"

  @impl Jido.Tools.ActionPlan
  def build(params, context) do
    Jido.Plan.new(context: context)
    |> Jido.Plan.add(:fetch, MyApp.FetchAction, params)
    |> Jido.Plan.add(:validate, MyApp.ValidateAction, depends_on: :fetch)
    |> Jido.Plan.add(:save, MyApp.SaveAction, depends_on: :validate)
  end

  # Optional: transform the result
  @impl Jido.Tools.ActionPlan
  def transform_result(result) do
    {:ok, %{workflow_result: result}}
  end
end

# Execute the workflow action
{:ok, results} = MyApp.MyWorkflowAction.run(%{input: "data"}, %{user_id: "123"})
# => {:ok, %{workflow_result: %{fetch: %{...}, validate: %{...}, save: %{...}}}}
```

**Required Callback:**
- `build/2`: Build a Plan struct from params and context

**Optional Callback:**
- `transform_result/1`: Transform the execution result

### Workflow
A behavior and macro for creating actions that execute sequential workflow steps.

```elixir
defmodule MyApp.MySequentialWorkflow do
  use Jido.Tools.Workflow,
    name: "my_sequential_workflow",
    description: "A workflow that performs multiple steps",
    workflow: [
      {:step, [name: "step_1"], [{LogAction, message: "Step 1"}]},
      {:branch, [name: "branch_1"], [
        true,  # Condition (can override execute_step/3 for dynamic)
        {:step, [name: "true_branch"], [{LogAction, message: "Condition true"}]},
        {:step, [name: "false_branch"], [{LogAction, message: "Condition false"}]}
      ]},
      {:step, [name: "final_step"], [{LogAction, message: "Completed"}]}
    ]
end

{:ok, result} = MyApp.MySequentialWorkflow.run(%{input: "start"}, %{})
```

**Supported Step Types:**
- `:step` - Execute a single instruction
- `:branch` - Conditional branching based on a boolean value
- `:converge` - Converge branch paths
- `:parallel` - Execute instructions in parallel

## Advanced Tools

### LuaEval
Execute Lua code in a sandboxed VM.

```elixir
# Simple arithmetic
{:ok, result} = Jido.Tools.LuaEval.run(%{code: "return 2 + 2"}, %{})
# => {:ok, %{results: [4]}}

# With global variables
{:ok, result} = Jido.Tools.LuaEval.run(%{
  code: "return x + 5",
  globals: %{"x" => 10}
}, %{})
# => {:ok, %{results: [15]}}

# Return first value only
{:ok, result} = Jido.Tools.LuaEval.run(%{
  code: "return 1, 2, 3",
  return_mode: :first
}, %{})
# => {:ok, %{result: 1}}
```

**Parameters:**
- `code` (string, required): Lua code to execute
- `globals` (map, default: %{}): Global variables to inject
- `return_mode` (atom, default: :list): :list returns all values, :first returns only first
- `enable_unsafe_libs` (boolean, default: false): Enable unsafe libs (os/io/package)
- `timeout_ms` (integer, default: 1000): Execution timeout in milliseconds
- `max_heap_bytes` (integer, default: 0): Per-process heap limit (0 = disabled)

### ZoiExample
A production-quality example demonstrating Zoi schema features. Use this as a reference for building actions with complex validation.

```elixir
# Example with nested objects, transformations, and refinements
params = %{
  user: %{
    email: "  JOHN@EXAMPLE.COM  ",  # Will be trimmed and lowercased
    password: "SecurePass123!",
    name: "John Doe"
  },
  priority: :high
}

{:ok, result} = Jido.Exec.run(Jido.Examples.ZoiExample, params)
result.user.email  # => "john@example.com"
result.status      # => :approved
```

See the [Schemas & Validation Guide](schemas-validation.md) for more on Zoi schemas.

## Tool Composition

### Chaining Tools

```elixir
# Chain multiple tools together
{:ok, final_result} = Jido.Exec.Chain.chain([
  # Read data from file
  {Jido.Tools.Files.ReadFile, %{path: "/tmp/input.txt"}},
  
  # Process with custom action
  {MyApp.Actions.ProcessText, %{}},
  
  # Write result to new file
  {Jido.Tools.Files.WriteFile, %{
    path: "/tmp/output.txt", 
    create_dirs: true
  }}
], %{}, %{user_id: "123"})
```

### Parallel Tool Execution

```elixir
# Create a workflow action for parallel execution
defmodule MyApp.NumberPipeline do
  use Jido.Tools.ActionPlan,
    name: "number_pipeline",
    description: "Run arithmetic steps in parallel then aggregate"

  @impl Jido.Tools.ActionPlan
  def build(_params, _context) do
    Jido.Plan.new()
    |> Jido.Plan.add(:a, Jido.Tools.Arithmetic.Add, %{value: 2, amount: 3})
    |> Jido.Plan.add(:b, Jido.Tools.Arithmetic.Multiply, %{value: 4, amount: 5})
    |> Jido.Plan.add(:final, MyApp.Actions.Aggregate, depends_on: [:a, :b])
  end
end

{:ok, results} = MyApp.NumberPipeline.run(%{}, %{})
```

### Conditional Tool Usage

```elixir
defmodule MyApp.Actions.ConditionalFileOp do
  use Jido.Action,
    name: "conditional_file_op",
    description: "Read or delete a file based on operation",
    schema: [
      file_path: [type: :string, required: true],
      operation: [type: {:in, [:read, :delete]}, required: true]
    ]

  def run(params, context) do
    case params.operation do
      :read ->
        Jido.Tools.Files.ReadFile.run(%{path: params.file_path}, context)
      
      :delete ->
        Jido.Tools.Files.DeleteFile.run(%{path: params.file_path, recursive: false, force: false}, context)
    end
  end
end
```

## Error Handling with Tools

All built-in tools follow consistent error handling patterns:

```elixir
case Jido.Tools.Files.ReadFile.run(%{path: "/nonexistent.txt"}, %{}) do
  {:ok, result} -> 
    handle_success(result)
  
  {:error, %{type: :execution_error} = error} ->
    Logger.error("File operation failed: #{error.message}")
    handle_file_error(error)
  
  {:error, error} ->
    handle_other_error(error)
end
```

## AI Integration

All tools automatically work with AI systems:

```elixir
# Get tool definitions for AI
tools = [
  Jido.Tools.LuaEval.to_tool(),
  Jido.Tools.Files.ReadFile.to_tool(),
  Jido.Tools.Arithmetic.Add.to_tool()
]

# Tools are now available to AI for function calling
# The AI can invoke: lua_eval, read_file, add
```

## Best Practices

### Tool Selection
- **Right Tool for Job**: Choose the most specific tool available
- **Composition**: Combine tools for complex operations
- **Error Handling**: Always handle tool errors gracefully
- **Context Propagation**: Pass context through tool chains

### Performance
- **Parallel Execution**: Use plans for independent operations
- **Resource Management**: Be mindful of file handles and network connections
- **Caching**: Cache expensive operations when appropriate
- **Timeouts**: Set appropriate timeouts for external tools

### Security
- **Path Validation**: Validate file paths in file operations
- **Input Sanitization**: Sanitize inputs to external services
- **Credential Management**: Handle API keys and tokens securely
- **Access Control**: Restrict tool usage based on user permissions

## Next Steps

**→ [AI Integration](ai-integration.md)** - Using tools with AI systems  
**→ [Instructions & Plans](instructions-plans.md)** - Composing tools into workflows  
**→ [Actions Guide](actions-guide.md)** - Creating your own tools

---
← [Security Guide](security.md) | **Next: [AI Integration](ai-integration.md)** →
