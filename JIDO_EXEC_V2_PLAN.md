# Jido Exec V2 Rebuild Plan

## Branch state

This branch is a hard reset of `Jido.Exec`. It starts from the local
`release/v3` commit `57642cb`.

The old `Jido.Exec` source, its application supervisor, and its dedicated test
directory were removed. The package does not compile in this state. Existing
Action, Instruction, Flow, property, and system tests remain. They contain
useful integration cases, but some of them specify the old Exec API.

This plan replaces the old Exec architecture rules in `AGENTS.md` for this
branch. The other package, quality, and test rules still apply.

## Objective

Build `Jido.Exec` as a small execution boundary around `Jido.Instruction`.

An Exec invocation executes one continuation edge. It does not follow a
continuation inside the same call. The caller sees and can store every edge
before it starts the next edge.

The primary model is:

```text
Jido.Instruction
    |
    v
Jido.Exec invokes one Action
    |
    v
Action result
    |
    +-- terminal success
    +-- terminal error
    +-- next Jido.Instruction
```

## Existing primitives

Use the package primitives directly:

- `Jido.Action` defines one validated unit of work.
- `Jido.Instruction` contains one target, params, context, and metadata.
- `Jido.Expr` contains restricted declarative expressions for Flow control.
- `Jido.Flow` contains the declarative program and owns Flow state.
- Runic provides the derived runnable graph for a Flow.
- `Jido.Exec` invokes one Instruction edge and owns its process boundary.

Do not create another target, invocation, transition, or executable-value
model when an Instruction already contains the required data.

## Package boundary

`jido_action` owns in-memory execution and replayable values. It does not own a
database, durable queue, retry service, distributed lease, or recovery worker.

Exec must return enough data for a higher-level durable orchestrator to store
an edge and resume it in a new BEAM process. The durable orchestrator owns the
storage transaction and the decision to continue.

## Public execution contract

The first public operation is:

```elixir
@spec invoke(Jido.Instruction.t(), keyword()) :: Jido.Action.result()
def invoke(instruction, opts \\ [])
```

The first implementation accepts a resolved Action Instruction. Add Flow
dispatch only after the Action boundary is complete. Flow can keep a separate
public entry point and call Exec for each Action Instruction.

Do not add convenience forms for an Action module, params, and context during
the first implementation. Callers can build or resolve an Instruction before
they invoke it. Add convenience forms only when current call sites show a clear
need.

Do not add `run_async`, `await`, `cancel`, `start`, `continue`, `ready`, `step`,
or native inspection to the first public API. Add each operation only after a
current caller and a contract test require it.

## Action results and continuations

Change the Action continuation result to contain one complete Instruction:

```elixir
{:continue, %Jido.Instruction{} = next_instruction}
```

This replaces:

```elixir
{:continue, input, target}
```

No compatibility form is required.

The next Instruction can target the same Action, another Action, or a Flow.
The next step must not depend on a PID, reference, task, monitor, process
dictionary, mailbox message, closure, or private Exec state.

State required by the next step belongs in the next Instruction params or
context. Descriptive and tracing data belongs in Instruction metadata. Flow
location data can also use Instruction metadata. Do not hide executable state
in metadata.

Exec validates the returned continuation before it returns it. At minimum, it
must be a resolved Instruction with a supported target and valid map context
and metadata.

## Durable edge rule

Each Action invocation is one durable edge:

```text
invoke I3
  -> Action returns {:continue, I4}
  -> Exec returns {:continue, I4}
  -> caller stores "I3 complete, I4 next"
  -> caller can stop
  -> a new process loads and invokes I4
```

Exec must never invoke `I4` before it returns the continuation to the caller.

A loop of five continuations is five Action invocations. Each loop iteration
must return and stop. If the caller pauses after iteration 3, the stored value
is the complete Instruction for iteration 4.

The Instruction continuation must round-trip through the supported durable
encoding. Define that encoding before the durability acceptance test is
complete. It must not create atoms from untrusted input. Module targets need a
caller-supplied registry or another explicit safe resolution rule.

## Delivery semantics

Exec can provide an at-least-once invocation boundary. It cannot provide
exactly-once external effects.

A process can fail after an Action changes an external system and before the
caller stores the next Instruction. An Action with external effects must use a
stable idempotency key. The durable orchestrator must keep that key stable
across retries.

Recommended Instruction metadata fields are:

- execution ID
- logical instruction ID
- parent instruction ID
- Flow location, when applicable

The durable orchestrator owns attempt numbers and retry policy. Do not change
the logical instruction ID when it retries the same edge.

## Action invocation behavior

One invocation performs these operations:

1. Confirm that the Instruction has an Action target.
2. Validate and normalize Action input.
3. Call the Action in the owned process boundary.
4. Validate a normal Action output.
5. Validate a continuation Instruction.
6. Normalize callback exceptions, throws, exits, and invalid returns.
7. Return the terminal result or continuation unchanged in meaning.
8. Stop and clean all processes that belong to this invocation.

Deferred effects stay in the Action result. Exec carries them as data. It does
not dispatch them.

## Process design

Start with the minimum process boundary that satisfies the contract.

A single Action invocation needs a supervised task when Exec must convert a
crash into a value, apply a timeout, or stop work after caller death. Do not
add a controller, worker registry, execution guard, or private supervisor until
a focused test proves that the smaller boundary cannot satisfy a requirement.

When Flow later starts nested or parallel work, one execution scope can own a
private Task Supervisor. That scope must provide:

- one deadline for the owned execution
- complete child cleanup
- caller-death cleanup
- explicit cancellation
- no live process references in a returned continuation or paused Flow value

The process tree is an implementation detail. Do not expose it in public
result or continuation structures.

## Flow and Runic boundary

Move Flow compilation, validation, scheduling, source maps, collection logic,
and Runic adapters under `Jido.Flow`. Do not rebuild them under
`Jido.Exec.Flow`.

The intended direction is:

```text
canonical Jido.Flow program
    -> Jido.Flow compiles a Runic graph
    -> Jido.Flow selects a ready Instruction
    -> Jido.Exec invokes that Instruction once
    -> Jido.Flow applies the returned result to Flow state
```

Runic is the derived call graph. It is not the public Flow data model. Flow
control remains visible as Flow data. Choice, iteration, reduction, and other
control structures must not be hidden in Action modules.

Flow pause and resume state belongs to `Jido.Flow`. A higher-level durable
orchestrator can store that state at an Instruction edge. Exec does not own a
Flow execution session.

## Initial module budget

The first Action vertical slice should need at most:

```text
Jido.Exec
Jido.Exec.Scope       # only if timeout and cleanup require it
Jido.Exec.Error       # only if existing Action errors cannot express failures
```

Result tuples use `Jido.Action.result()`. Continuations use
`Jido.Instruction`. Do not add `Target`, `Invocation`, `Transition`, `Work`, or
`Execution` structs to the first slice.

## Implementation sequence

1. Search all remaining source and tests for the old Exec API.
2. Classify each use as an Action contract, Flow contract, process contract,
   telemetry contract, or old implementation detail.
3. Update `Jido.Action.result()` and its documentation to use an Instruction
   continuation.
4. Add a focused test for one successful Action Instruction.
5. Implement synchronous `Jido.Exec.invoke/2`.
6. Add input validation, output validation, and invalid-return tests.
7. Add exception, throw, exit, timeout, and cleanup tests.
8. Add continuation validation and durable edge tests.
9. Add a five-step continuation loop and resume it from step 4 in a fresh
   process.
10. Move Flow compiler and runtime responsibilities into `Jido.Flow`.
11. Connect Flow scheduling to `Jido.Exec.invoke/2` one Instruction at a time.
12. Add concurrency and cancellation only after serial Flow execution works.
13. Review surviving public docs and remove the old Exec API descriptions.
14. Run package format, compile, test, and quality checks.

## Required acceptance tests

### One Action

- Valid input produces the validated output.
- Invalid input does not call the Action.
- Invalid output returns a structured error.
- An exception, throw, or exit returns a structured error.
- A timeout stops the Action task.
- Caller death leaves no Action task alive.

### Durable continuation

- An Action returns a complete next Instruction.
- Exec returns it without invoking it.
- The Instruction survives the supported encode and decode round-trip.
- A five-step Action loop can stop after step 3.
- All execution processes can terminate after step 3.
- A new process can load Instruction 4 and finish steps 4 and 5.
- No hidden state from steps 1 through 3 is required.
- A retry keeps the same logical instruction ID and idempotency key.

### Edge failures

- Storage failure after invocation prevents the driver from starting the next
  Instruction.
- Failure after storage and before the next invocation resumes from the stored
  Instruction.
- Failure before storage can retry the current Instruction with at-least-once
  semantics.
- A continuation with a PID, reference, function, or unsupported target fails
  validation before it is returned as durable data.

### Flow integration

- Flow and Runic can schedule an Action Instruction through Exec.
- Every Action edge becomes visible before the next edge starts.
- Choice and iterator semantics stay in Flow.
- Serial and concurrent Flow results are deterministic.
- Cancelling a Flow stops all active Action tasks.
- Paused Flow state contains no process references.

## Explicit exclusions

Do not add these features during the first rebuild:

- automatic continuation following inside `Jido.Exec.invoke/2`
- automatic retry
- durable storage
- distributed coordination
- queues or leases
- exactly-once effect claims
- a public runtime Invocation struct
- a generic executable protocol
- native Runic inspection through Exec
- compatibility wrappers for the deleted API

## Completion criteria

The rebuild is complete when an Action Instruction has one clear execution
path, every continuation is a durable Instruction edge, Flow owns all Runic
logic, process cleanup is proven by tests, and the public API contains no
layer that only repeats Action, Instruction, or Flow data.
