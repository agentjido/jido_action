# Configuration

`jido_action` no longer owns execution policy configuration. Runtime policy is Runic policy.

Use `Jido.Flow.policy/3`, workflow scheduler policies on the underlying `Runic.Workflow`, or runtime `:scheduler_policies` when calling `Jido.Exec.run/3`.

```elixir
flow =
  Jido.Flow.new(:checkout)
  |> Jido.Flow.step(:reserve_inventory, MyApp.Actions.ReserveInventory)
  |> Jido.Flow.policy(:reserve_inventory, %{
    max_retries: 1,
    backoff: :none,
    timeout_ms: 2_000
  })

{:ok, result} =
  Jido.Exec.run(flow, %{cart_id: "cart_123"},
    run_context: %{_global: %{request_id: "req_123"}}
  )
```
