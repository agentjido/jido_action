# Streaming Actions

Actions can return streamable results to handle large datasets efficiently or provide real-time data processing capabilities. The Jido Action framework provides automatic stream detection and Task PID management to ensure robust execution.

## What are Streamable Results?

Streamable results are data structures that can be processed lazily, allowing you to work with large amounts of data without loading everything into memory at once. The framework automatically detects these types:

- `%Stream{}` - Elixir's built-in lazy enumerable
- `%File.Stream{}` - For streaming file contents
- `%IO.Stream{}` - For streaming I/O operations
- `%Range{}` - For numeric ranges
- Functions with arity 2 - Stream functions
- Maps, lists, or tuples containing any of the above

## Creating Streaming Actions

### Basic Stream Action

```elixir
defmodule MyApp.StreamAction do
  use Jido.Action,
    name: "stream_processor",
    description: "Processes data as a stream",
    schema: [
      chunk_size: [type: :integer, default: 100],
      total_items: [type: :integer, default: 1000]
    ]

  def run(%{chunk_size: chunk_size, total_items: total_items}, _context) do
    stream = 
      1
      |> Stream.iterate(&(&1 + 1))
      |> Stream.take(total_items)
      |> Stream.chunk_every(chunk_size)
      |> Stream.map(&process_chunk/1)

    {:ok, %{stream: stream}}
  end

  defp process_chunk(chunk) do
    # Process each chunk of data
    Enum.sum(chunk)
  end
end
```

### File Stream Action

```elixir
defmodule MyApp.FileReaderAction do
  use Jido.Action,
    name: "file_reader",
    description: "Streams file contents line by line",
    schema: [
      filename: [type: :string, required: true],
      encoding: [type: :atom, default: :utf8]
    ]

  def run(%{filename: filename, encoding: encoding}, _context) do
    if File.exists?(filename) do
      file_stream = File.stream!(filename, [], encoding)
      
      processed_stream = 
        file_stream
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.with_index()

      {:ok, %{stream: processed_stream, filename: filename}}
    else
      {:error, "File not found: #{filename}"}
    end
  end
end
```

### Concurrent Stream Processing

```elixir
defmodule MyApp.ConcurrentStreamAction do
  use Jido.Action,
    name: "concurrent_stream",
    description: "Processes stream items concurrently",
    schema: [
      items: [type: {:list, :any}, required: true],
      concurrency: [type: :integer, default: 4]
    ]

  def run(%{items: items, concurrency: concurrency}, _context) do
    # Create background tasks for processing
    supervisor_task = Task.async(fn ->
      items
      |> Task.async_stream(
        &expensive_operation/1,
        max_concurrency: concurrency,
        timeout: 30_000
      )
      |> Stream.map(fn {:ok, result} -> result end)
    end)

    # Return both the stream and the supervisor task
    {:ok, %{
      stream: Task.await(supervisor_task),
      supervisor_task: supervisor_task
    }}
  end

  defp expensive_operation(item) do
    # Simulate expensive processing
    Process.sleep(100)
    String.upcase(to_string(item))
  end
end
```

## Automatic Stream Detection and Task Management

The Jido Action framework automatically detects when your action returns streamable results and provides several benefits:

### Automatic Task PID Detachment

When a streamable result contains Task PIDs (from concurrent processing), the framework automatically detaches them to prevent timeout-related crashes:

```elixir
defmodule MyApp.StreamWithTasksAction do
  use Jido.Action, name: "stream_with_tasks"

  def run(_params, _context) do
    # Create background tasks
    background_tasks = Enum.map(1..3, fn i ->
      Task.async(fn ->
        Process.sleep(1000)
        i * 10
      end)
    end)

    # Create a stream that will be processed later
    data_stream = 1..100 |> Stream.map(&(&1 * 2))

    # Return both - framework will auto-detach task PIDs
    {:ok, %{
      stream: data_stream,
      background_tasks: background_tasks
    }}
  end
end

# Usage
{:ok, result} = Jido.Exec.run(MyApp.StreamWithTasksAction, %{}, %{})
# Tasks are automatically detached, preventing timeout issues
stream_data = Enum.take(result.stream, 10)
```

### Timeout Safety

Streaming actions work safely with timeouts because:

1. The framework detects streamable results automatically
2. Task PIDs are detached to prevent process linking issues  
3. Streams themselves are not consumed during detection

```elixir
# This works safely even with timeouts
{:ok, result} = Jido.Exec.run(
  MyApp.StreamAction, 
  %{total_items: 1_000_000}, 
  %{}, 
  timeout: 5000  # Framework handles this safely
)

# Stream can be consumed after the action completes
processed_data = result.stream |> Stream.take(100) |> Enum.to_list()
```

## Best Practices

### 1. Use Output Schema Carefully

When returning Stream structs, you may need to disable output validation:

```elixir
defmodule MyApp.StreamAction do
  use Jido.Action,
    name: "stream_action",
    output_schema: []  # Disable validation for Stream structs

  def run(_params, _context) do
    stream = Stream.iterate(1, &(&1 + 1))
    {:ok, stream}  # Returns stream directly
  end
end
```

### 2. Handle Resource Cleanup

For streams that use external resources:

```elixir
defmodule MyApp.ResourceStreamAction do
  use Jido.Action, name: "resource_stream"

  def run(%{filename: filename}, _context) do
    try do
      file_stream = File.stream!(filename)
      {:ok, %{stream: file_stream, cleanup: :file_handle}}
    rescue
      e -> {:error, "Failed to open file: #{Exception.message(e)}"}
    end
  end
end
```

### 3. Consider Memory Usage

Streams are lazy, but be mindful of intermediate operations:

```elixir
# Good: Lazy all the way
stream = 
  data
  |> Stream.map(&transform/1)
  |> Stream.filter(&valid?/1)
  |> Stream.take(1000)

# Avoid: Materializes intermediate results
stream = 
  data
  |> Enum.map(&transform/1)  # ❌ Loads everything
  |> Stream.filter(&valid?/1)
```

### 4. Test Stream Actions

```elixir
defmodule MyApp.StreamActionTest do
  use ExUnit.Case

  test "stream action produces expected results" do
    {:ok, result} = Jido.Exec.run(MyApp.StreamAction, %{total_items: 100})
    
    assert %Stream{} = result.stream
    
    # Test by consuming a small portion
    first_items = Enum.take(result.stream, 5)
    assert length(first_items) == 5
    
    # Verify stream is reusable (if needed)
    second_take = Enum.take(result.stream, 3)
    assert length(second_take) == 3
  end
end
```

## Error Handling in Streams

Handle errors gracefully in stream processing:

```elixir
defmodule MyApp.SafeStreamAction do
  use Jido.Action, name: "safe_stream"

  def run(%{items: items}, _context) do
    safe_stream = 
      items
      |> Stream.map(&safe_process/1)
      |> Stream.reject(&match?({:error, _}, &1))
      |> Stream.map(fn {:ok, result} -> result end)

    {:ok, %{stream: safe_stream}}
  end

  defp safe_process(item) do
    {:ok, String.upcase(to_string(item))}
  rescue
    _ -> {:error, :invalid_item}
  end
end
```

## Combining with Explicit Stream Options

You can still use the explicit `streaming: :detach` option for additional control:

```elixir
# Explicit control over detachment behavior
{:ok, result} = Jido.Exec.run(
  MyApp.StreamAction,
  %{},
  %{},
  streaming: :detach,  # Explicit detachment
  timeout: 5000
)
```

The framework's automatic stream detection works alongside explicit options, providing a robust foundation for building streaming actions that scale efficiently and handle concurrent processing safely.
