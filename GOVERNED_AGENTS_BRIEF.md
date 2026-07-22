# Jido Product Strategy Brief: Governed Agents

Status: draft
Date: 2026-07-08

## Position

Jido offers governed agents: stateful actors that can act autonomously while
remaining constrained, inspectable, and policy-aware at every level.

Most agent frameworks optimize for maximum capability first. They give agents
tools, prompts, memory, loops, and broad execution freedom, then try to recover
control through monitoring, evals, or approvals after the fact. Jido should take
the opposite position: direct control first, with LLM non-determinism admitted
and bounded inside explicit runtime contracts.

## Why This Matters

LLMs are useful because they are flexible and non-deterministic. That same
property makes them risky when they are allowed to directly shape behavior,
call tools, mutate state, or emit side effects without a governed execution
model.

The product opportunity is not to remove non-determinism. The opportunity is
to surround it with constraints:

- Actions define typed capabilities with schemas, policies, and clear names.
- Flows define constrained reactions that compose only approved actions.
- Agents define state scopes, signal routes, lifecycle, and reply behavior.
- Directives declare effects for the runtime to execute intentionally.
- Runic provides graph execution, scheduling, stepping, retries, and traceable
  runtime mechanics.
- Jido ties these layers together into a single reviewable control plane.

## Product Thesis

Jido should make it practical for developers and LLMs to author useful agent
behavior without granting arbitrary code execution.

Flow Script is central to that thesis. It is not valuable because it is a
general scripting language or a replacement for the BEAM. It is valuable because
it is a constrained behavior language for Agent reactions. A Flow Script can be
parsed, validated, inspected, policy-checked, visualized, traced, and rejected
before it runs.

That turns generated behavior from opaque code into governed behavior data.

## Strategic Differentiation

Embedded scripting systems such as Lua can let users customize behavior, but
they still express behavior as imperative code. Jido should differentiate on a
different axis: agent-native governance.

The goal is not "users can write scripts." The goal is:

> Teams can build agents that act autonomously without acting unconstrained.

This creates a sharper value proposition for production agent systems:

- Developers keep direct control over capabilities and state boundaries.
- LLMs can propose or generate bounded reaction logic.
- Reviewers can inspect action usage, emitted directives, state transitions,
  and required capabilities before execution.
- Operators can attach runtime policy and observability to the same semantic
  units the developer authored.

## Product Implications

Jido should treat governance as a vertical design principle, not a feature
bolted onto agents later.

The framework should make the controlled path the natural path:

- Register capabilities before they can be used.
- Validate all inputs, action params, outputs, and state transitions.
- Route signals explicitly to constrained reactions.
- Accumulate side effects as directives rather than executing them inline.
- Keep Agent state changes explicit and scoped.
- Make execution traceable through the Flow graph and Runic runtime.
- Support human review and policy approval for higher-risk capabilities.

## Summary

Jido's compelling product identity is governed autonomy.

Agents should be able to respond to signals, use tools, coordinate work, and
act over time. But every layer should preserve developer control: what the
agent can call, what state it can touch, what effects it can request, how work
is scheduled, and how behavior can be reviewed.

That is the elevator pitch:

> Jido is a framework for governed agents: autonomous actors constrained by
> typed actions, explicit flows, scoped state, declared directives, and
> policy-aware execution.
