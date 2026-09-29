# Manual performance checks

These probes stay outside CI. No timing value is a test pass condition.
Run only one benchmark VM at a time. Use the same host, Elixir/OTP pair,
production environment, scheduler count, dependency locks, and workload.
Repeat in fresh VMs and alternate the before/after order. Keep the raw JSON.

## V2 versus V3 Actions

From each checkout, run the same absolute script path from V3:

```sh
MIX_ENV=prod mix run /absolute/path/to/jido_action/test/bench/v2_v3.exs v2 /tmp/v2.json
MIX_ENV=prod mix run /absolute/path/to/jido_action/test/bench/v2_v3.exs v3 /tmp/v3.json
```

Run the first command from the V2 package and the second from V3. Each
checkout uses its own dependencies. For a source archive without Git metadata,
set `JIDO_COMPARE_REVISION` to its known commit. Unknown source fields are null. The script keeps direct execution,
finite timeout, and async settings equivalent and disables V2 retries.
It checks every result. Timing runs before separate resource probes.
Use `JIDO_COMPARE_FILTER=empty_schema/small` to select that group.
Keep stored-schema and inline-schema results separate: V2 can avoid schema
construction by storing its schema in a module attribute.

Resource probes sample the caller, observed framework processes, and their
owned ETS tables. They exclude the existing supervisor. These are observed
samples, not allocation totals or exact peaks. Shared binary and VM memory
are reported separately. Tracing changes timing; use only untraced timing
samples for speed comparisons. Runic Flow features have no equivalent in V2.

## V3 refinements

```sh
MIX_ENV=prod mix run test/bench/refinements.exs /tmp/refinements.json
MIX_ENV=prod mix run test/bench/refinements.exs /tmp/collectors.json collector
```

This probe checks Map collection, continuation effects, public Flow
compilation, and Map execution with a reused compiled graph. The reuse
adapter is internal benchmark code; it is not a public cached execution API.
Collectors and compilation are focused measurements. A faster collector
does not imply the same improvement for a complete Flow. Effect cases
include opaque list-valued requests and exact order checks.

Use the separate [throughput runner](../load/README.md) for the larger Map
curve and result-checked stress workloads. Heap inspection is opt-in.
