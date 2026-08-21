# Configuration

Actions and Flow artifacts do not contain runtime policy.

`Jido.Exec` accepts two Flow execution options:

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  async: true,
  max_concurrency: 4
)
```

- `async` enables concurrent execution for independent nodes in one ready wave.
- `max_concurrency` limits those concurrent node tasks.

The current public API does not accept retry, timeout, deadline, persistence,
cancellation, or rewind options. Configure those policies in the caller or a
higher-level runtime package.

See [Executing Flows](flow-execution.md) for the full execution contract.
