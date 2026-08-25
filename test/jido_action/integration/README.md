# Jido Action Integration Pressure Tests

Run this suite with:

```sh
mix test.integration
```

Normal `mix test` runs exclude tests with the `:integration` tag. Add this tag
to each module in this directory.

Keep each test deterministic and observable through return values or explicit
process messages. Do not use Logger output as an assertion. Do not use sleeps
or scheduler timing as synchronization. For concurrent cases, use unique
references, process monitors, and explicit ready/release messages.

Grow the suite in small groups. The planned groups are:

- Action result forms and output envelopes.
- Input, output, and context validation failures.
- Exceptions, throws, exits, and unsupported callback results.
- Caller timeouts and interrupted execution.
- Flow references, choices, collections, iteration, and nested Flows.
- Step-wise and run-to-completion result parity.
- Bounded concurrent work, worker cleanup, and mailbox isolation.
- Large Flow determinism and repeated execution.
- Telemetry event balance and correlation.

Each new edge case must first state the public contract that it tests. Prefer a
small test-only Action or Flow over shared state. If a test needs concurrency,
make the process handshake visible in the test.
