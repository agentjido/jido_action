# Flow authoring tests

Run `mix test.authoring` from `jido_action`. These opt-in tests compile source
fixtures only when selected. They check an author's complete path from Action
and Flow source to execution, equivalent Flow authoring forms, stored JSON,
dependency order, Choice routing, nested Flow boundaries, and compile-time
errors. The later source fixtures cover Map, Reduce, Iterate, Subflow, Choice,
Dispatch, inline Steps, expressions, schemas, saved JSON with fixed Registry
IDs, controlled Map completion order, and hostile authoring boundaries. Focused
contract tests remain under `test/jido_action`,
`test/jido_flow`, and `test/jido_exec`.

The adversarial slice runs all 24 declaration orders for one four-Step graph
through the module DSL, direct constructors, Builder, stored JSON, and full and
step-wise execution. It also checks duplicate names, unknown dependencies,
cycles, source error locations, and an untrusted stored Action identifier.

The generated-graph properties build small DAGs with two value inputs per
Step and independent `needs` edges. They compare direct, Builder, and stored
JSON forms with a simple arithmetic model, exact Action calls, and dependency
order. They also mutate graphs to test duplicate names, unknown dependencies,
and cycles. StreamData reports a reduced graph and ExUnit seed on failure.

`mix test.authoring` includes enabled regression tests for `AUTHOR-MAP-01`
(serial Map fail-fast) and `AUTHOR-CODEC-02` (invalid UTF-8 Flow names). Both
tests pass.

Keep each example small and observable through public APIs. Do not repeat the
full unit-test matrix here.
