---
modules: [Jido.Exec.Node.Action, Jido.Exec.Validation, Runic.Component.Jido.Exec.Node.Action, Runic.Transmutable.Jido.Exec.Node.Action, Runic.Identity.Projectable.Jido.Exec.Node.Action]
---
# Action execution boundary obligations

## Purpose

Check Action execution through the Jido boundary and its native Runic component.
These obligations refine `ACT-001` through `ACT-004`, `EXEC-001`, `ERROR-001`
and `EFFECT-002`. Runic scheduling remains owned by Runic.
The shared validation module is also checked through its root and nested Flow
callers. This does not establish complete Flow contract coverage.

### jido_action.boundary.I1 — Invalid input stops work before the callback
- **scope:** `Jido.Exec.Node.Action`, `Jido.Exec.Validation`
- **must:** Validate input before Action work in direct and Flow calls. Reject missing and invalid fields and malformed input preparation results without calling run/2. Preserve input error details and unknown root keys permitted by the schema. Shared Action and Flow callback validators must return maps on input success and preserve valid transformations exactly once.
- **kind:** functional
- **status:** active

### jido_action.boundary.I2 — Callback failures retain public failure data
- **scope:** `Jido.Exec.Node.Action`, `Jido.Exec.Validation`
- **must:** Contain callback raises, throws, exits, returned errors and unsupported return shapes as the documented Jido error types. Preserve useful reason, phase, Action and source details and original stacktraces. Failed callbacks expose no executable effects. Only a Dispatch expander can return a continuation.
- **kind:** functional
- **status:** active

### jido_action.boundary.I3 — Output validation follows successful Action work
- **scope:** `Jido.Exec.Node.Action`, `Jido.Exec.Validation`
- **must:** Validate normal output after the callback. Reject invalid callback output before a custom validator can conceal it. Reject invalid output and invalid output validator returns with structured errors, including scalar validator success and malformed envelopes. Discard requested effects on rejection. Preserve valid output and Flow output context without repeating Action work.
- **kind:** functional
- **status:** active

### jido_action.boundary.I4 — Intentional envelopes and effects preserve their meaning
- **scope:** `Jido.Exec.Node.Action`
- **must:** Preserve valid raw, batch, opaque and stream envelopes through direct and Flow calls. Keep streams lazy. Accept an optional proper list of effect requests, retaining order and duplicate requests. Reject raw non-map success and malformed effect lists. Keep output metadata separate from effects.
- **kind:** functional
- **status:** active

### jido_action.boundary.I5 — Native Action components retain their executable identity
- **scope:** `Jido.Exec.Node.Action`, `Runic.Component.Jido.Exec.Node.Action`, `Runic.Transmutable.Jido.Exec.Node.Action`, `Runic.Identity.Projectable.Jido.Exec.Node.Action`
- **must:** Build a native Runic Action component with its exact Instruction, identity, port schemas, Flow context and source data. Connect it as an executable workflow component. Source reconstruction retains equivalent behavior. Runtime context stays outside canonical component identity. Action results use native SingleOutput meaning rather than an error encoded as a successful Fact.
- **kind:** functional
- **status:** active

### jido_action.boundary.I6 — Call options and targets reject malformed policy
- **scope:** `Jido.Exec.compile/2`, `Jido.Exec.run/4`, `Jido.Exec.start/6`, `Jido.Exec.step/2`, `Jido.Exec.resume/4`, `Jido.Exec.result/1`
- **must:** Return structured configuration errors for invalid targets, root component options, concurrency values, Task Supervisor values and managed requests. Preserve the option and rejected value. A missing Task Supervisor cannot start Action work.
- **kind:** functional
- **status:** active

### jido_action.boundary.I7 — Collection Action calls retain ordered values and failure data
- **scope:** `Jido.Exec.Node.Action`
- **must:** Map Action calls preserve input order, duplicate items and their stable item IDs. Collected Action failures retain node, target, item position and retry data without a stacktrace. Reference failures retain their own paths without invented item identity. Failed items expose no effects. Native batch reconstruction retains behavior and keeps shared parent data outside each item Fact.
- **kind:** functional
- **status:** active

### jido_action.boundary.I8 — Dispatch Action calls preserve continuation and effect rules
- **scope:** `Jido.Exec.Node.Action`
- **must:** A Dispatch expander can select a valid Action or Flow target through a continuation. Reject invalid targets with the Dispatch node detail. Returned expander errors keep their reason and expose no effects. Successful expander effects must form a proper list. Reconstructed Dispatch components retain equivalent behavior.
- **kind:** functional
- **status:** active

### jido_action.boundary.I9 — Loop calls retain position and reject invalid state
- **scope:** `Jido.Exec.Node.Action`
- **must:** Reduce and Iterate Action failures retain node and item or iteration position, including item IDs and state revisions. Reject non-enumerable Reduce input and unsupported initial values. Iterate rejects invalid initial State, failed State schemas and exhausted limits. These failures expose no executable effects.
- **kind:** functional
- **status:** active

### jido_action.boundary.I10 — Managed boundaries reject values that cannot be stored
- **scope:** `Jido.Exec.Node.Action`, `Jido.Exec.start/6`
- **must:** Reject process-local input before managed work starts and process-local Action output or effects before persistence. A rejected start closes only the newly created worker and permits a corrected retry. A duplicate start must keep the existing worker intact.
- **kind:** functional
- **status:** active
