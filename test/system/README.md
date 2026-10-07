# In-memory system verification

Run `mix test.system` from `jido_action`. This opt-in suite exercises a real
composed Flow with concurrent Steps and Map work. Held workers use explicit
ready and release messages. Fault cases cover a returned failure, cancellation,
timeout, owner death, and Task.Supervisor shutdown. Tests check exact work,
result order, terminal telemetry, worker exits, and owned Task cleanup.

This suite tests only `Jido.Exec` in memory. It does not test durable recovery,
storage, Signals, Agents, or Topology. Focused unit tests remain under
`test/jido_exec`.

`invocation_restart_test.exs` tests the optional invocation replay edge across
two fresh VMs. The second VM receives only Flow definition data, call data, and
accepted receipt values. It creates new process references and a new Exec call.
The test proves replay without an Execution snapshot or prior runtime process.
The host fixture is test coordination code. It is not a storage adapter or a
durable runtime.

`resource_ownership_test.exs` exercises a small host-supervised session-owner
example. A separate simulated service retains sessions after client death.
Tests verify release after success, cancellation, complete-call timeout, and
interrupted or timed-out acquisition. Failed and blocked release retain the
session and report cleanup failure without replacing the Action error. This
is adapter guidance, not a new Jido API or a remote-cleanup guarantee.
