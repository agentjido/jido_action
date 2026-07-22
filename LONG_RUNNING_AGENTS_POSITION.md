# Long-Running Agents Need a Runtime, Not Just a Run

LLM agents are already useful enough to do real work. The hard problem is not
whether an agent can complete a task once. The hard problem is whether a team
can safely leave that agent running.

Most agent systems are safe only because the run ends.

A run is a containment boundary. It lets an agent reason, call tools, and take
steps for a while, then stops before uncertainty compounds too far. The context
is reset. Control returns to a human, a scheduler, or another process. The
system avoids the hardest question: what happens when a non-deterministic actor
keeps operating over time?

That question is where demos become production systems.

## Non-Determinism Compounds Into Risk

An LLM decision that is 98% correct sounds reliable. But agents do not make one
decision. They classify, plan, call tools, summarize, update state, retry, hand
off, escalate, and emit side effects. If a workflow needs ten correct
model-mediated steps, 98% correctness per step becomes:

```text
0.98^10 = 81.7%
```

At fifty steps:

```text
0.98^50 = 36.4%
```

The issue is worse than simple multiplication because agent errors are not
cleanly isolated. A bad classification changes the next prompt. A wrong memory
entry biases future decisions. A mistaken state update changes future behavior.
A poor handoff spreads uncertainty to another agent. A bad retry can repeat the
same damage with more confidence.

In short: LLM agents fail in the margins, but production systems break in the
margins.

## The 2% Is Operational Risk

Enterprises already know how to reason about risk. They do not assume every
payment clears, every employee has every permission, every deploy is safe, or
every vendor behaves perfectly. They define controls, approval paths, audit
trails, blast-radius limits, compensating actions, and escalation rules.

Agentic systems need the same treatment. The remaining 2% is not a rounding
error. It is operational risk introduced by non-deterministic judgment inside a
system that can access tools, state, data, and external side effects.

That risk has several forms:

- **Authority risk:** the model asks to do something it should not be allowed
  to do.
- **State risk:** the agent records an incorrect belief and uses it later.
- **Action risk:** a tool call mutates the wrong system, customer, record, or
  workflow.
- **Coordination risk:** one agent hands off flawed context to another agent,
  making the error harder to localize.
- **Cost risk:** routine work is routed to expensive models, or retry loops
  burn spend without improving confidence.
- **Accountability risk:** after the fact, nobody can reconstruct what was
  allowed, what changed, why it happened, or who approved it.

This is the needed perspective for sustainable long-running agents: agent runs
are not just inference sessions. They are risk-bearing operational processes.
The runtime has to manage that risk continuously, not merely record it after
the fact.

## The Run Is a Crude Fuse

Short-lived runs hide this problem. They cap the number of decisions, limit the
amount of state that can drift, and reduce the time an agent has to accumulate
incorrect assumptions. When the run ends, a human or outer system reclaims
responsibility.

That is useful, but it is not production autonomy. It is a manual safety fuse.

If an agent has to stop to remain safe, it cannot truly own long-running work.
It can assist. It can draft. It can execute bounded tasks. But it cannot be
trusted to continuously coordinate work, mutate systems, respond to events, or
operate against real business processes without constant supervision.

The blocker is not intelligence alone. Better models will reduce error rates,
but they will not remove non-determinism. As agents get more capable, the
pressure to give them more authority increases. That makes the remaining error
rate more consequential, not less.

## Long-Running Agents Need Operational Safety

A long-running agent needs a runtime model that assumes uncertainty will appear,
measures the risk attached to each step, and compensates before that risk
compounds.

That means separating reasoning from authority. A model may be able to reason
about an action without being allowed to perform it directly. Capabilities
should be registered, typed, scoped, and reviewable. State should be explicit
and bounded. Effects should be declared before they are executed. Risk should
determine whether work is handled by a cheaper model, escalated to a stronger
model, routed to a human, retried with more context, or blocked entirely.

This is not a new category of enterprise concern. It is the familiar discipline
of operational risk management applied to a new kind of worker: a
non-deterministic, stateful, tool-using process that may run for hours, days, or
months. To make that sustainable, the system must proactively compensate for
uncertainty while work is happening. Controls have to live inside the execution
path, not around a transcript after the run is over.

It also means treating agents as supervised runtime processes, not loose async
loops. Long-running agents need lifecycles, backpressure, restarts, message
routes, state boundaries, and failure handling. Multi-agent systems need
coordination without turning every handoff into an accountability gap.

Finally, observability has to describe what mattered operationally. Token logs
and prompt traces are not enough. Teams need to know what the agent was allowed
to do, which model was chosen, why it escalated, what state changed, what effect
was requested, what policy approved it, what retried, and what human decision
was involved.

## The Product Thesis

Jido makes non-deterministic agents operationally safe enough to leave running.

The goal is not to eliminate non-determinism. Non-determinism is why LLMs are
useful. The goal is to treat the irreducible 2% as managed risk: anticipated,
bounded, routed, observed, and proactively compensated for before it becomes
uncontrolled authority.

Jido's view is that agents should be autonomous in work, not autonomous in
authority. They should be able to respond to signals, coordinate over time, use
tools, and pursue goals. But their authority should remain explicit, scoped,
observable, revocable, and policy-aware.

That requires more than prompts, tools, memory, and a loop. It requires a
governed runtime: typed capabilities, explicit flows, scoped state, declared
effects, policy-routed model calls, supervised processes, and semantic traces.

The next generation of agent infrastructure will not be judged only by whether
an agent can complete a task. It will be judged by whether a responsible team
can approve that agent to keep running after the first task is done.
