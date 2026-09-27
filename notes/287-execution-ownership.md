# Issue 287: Execution Ownership

The final design removes per-Action isolation, guards for worker lifetime,
the telemetry tracker, delivery process, delivery guard, and all execution ETS
tables. It uses the V2 pattern: supervised workers, monitors, and explicit
termination. It adds no public mode or global service. Runic is unchanged.

| Call | Process that runs user code | Deadline owner | Abrupt process death |
| --- | --- | --- | --- |
| Sync, infinity | Caller | None | User code stops with the caller. |
| Sync, finite | One supervised execution worker | Existing caller | Work may continue if the caller dies. |
| Async | One supervised execution worker | Existing async controller | The live controller cancels work if the handle owner dies. Work may continue if the controller itself dies. |
| Serial Flow | Current execution process | Outer call, if finite | Same as the outer call. No process per Action. One revision helper protects a Flow mutation. |
| Concurrent wave | Supervised workers, bounded by max_concurrency | Outer call, if finite | Work may continue if the scheduler dies. |
| Nested Flow | Current execution process or admitted wave worker | Same complete-call deadline | Serial child work shares its parent worker. Existing nested concurrency limits remain. |
| Continuation | Same execution worker or direct caller | Original complete-call deadline | No new boundary at a continuation. |
| Paused step/wave/continue | Caller for serial work; wave workers for concurrent work | None | Revision helper marks an interrupted mutation indeterminate. Concurrent workers may continue if the caller dies. |

A managed controller holds its worker PID, monitor, deadline, and active child
PIDs. A concurrent scheduler uses its existing active-worker map. Each loop
iteration cleans up its current active workers if an exception escapes. Normal
completion and handled errors remove monitors and result messages. A living
controller kills and waits for workers on timeout or cancellation, including
callbacks that trap exits. There is no reverse lifetime guarantee after that
controller dies. Links and try/after do not provide one.

Supervisor lookup and startup use ordinary synchronous OTP calls, as in V2.
A blocked host registry or supervisor can delay the timeout or cancellation
response. The deadline starts before startup and is not reset. After startup,
the controller checks the deadline before it permits the worker to run.
Concurrent workers notify the controller directly before callbacks start, so
explicit cancellation can stop them. The startup monitor ends before the
callback runs. This adds no process or table.

Telemetry handlers run synchronously with their work. The controller or
scheduler keeps open span records in a map and emits terminal errors after
worker failure, timeout, or cancellation. No telemetry helper or delivery queue
remains. A blocked cleanup handler can delay the controller's response. This
is an accepted V2-style limit. Consumers must move slow handler work to their
own processes. Internal reply aliases discard late messages after a call ends.

Expected framework starts (existing supervisors and user processes excluded):

| Call | Before issue 287 | After |
| --- | ---: | ---: |
| Simple sync Action | 2 | 0 |
| Simple timed Action | 7 | 1 |
| Simple async Action | 8 | 2 |
| Serial three-Action Flow, infinity | 7 | 1 |
| Serial three-Action Flow, finite | 12 | 2 |

These are total starts, not peak live counts. A concurrent wave starts one
worker per admitted runnable. A nested Flow can add a revision helper.

Direct code shares the caller's process dictionary, flags, mailbox, Logger
metadata, and group leader. Serial Actions in managed calls share those values
within their execution worker. Catchable raises, throws, and exits still become
structured errors. Uncatchable worker death is an execution-level internal
error; concurrent worker death is a Flow runnable failure. Adapters must close
per-invocation resources on normal return. Numeric timeout zero remains an
immediate timeout. Validation, effects, supervisor routing, canonical result
order, and one deadline across the complete execution remain. Startup and
telemetry delivery have the synchronous limits described above.
