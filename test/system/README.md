# In-memory system verification

Run `mix test.system` from `jido_action`. This opt-in suite exercises a real
composed Flow with concurrent Steps and Map work. Held workers use explicit
ready and release messages. Fault cases cover a returned failure, cancellation,
timeout, owner death, and Task.Supervisor shutdown. Tests check exact work,
result order, terminal telemetry, worker exits, and owned Task cleanup.

This suite tests only `Jido.Exec` in memory. It does not test durable recovery,
storage, Signals, Agents, or Topology. Focused unit tests remain under
`test/jido_exec`.
