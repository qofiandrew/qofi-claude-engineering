# ADR-0001 — Agent Teams over a flat peer-bot swarm

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** one-way — the orchestration model shapes everything built on it.
**Escalated:** no — decided during the design conversation.

## Context

The starting point was a Discord bot-to-bot fork where peer agents coordinate by
@mentioning each other in natural language. For an autonomous build system that has
three problems: untargeted runaway loops (A pings B pings A), token cost from
relaying all coordination as prose, and non-determinism that makes failures hard to
trace. We needed a coordination model that parallelizes without those failure modes.

## Decision

We will use Claude Code **Agent Teams**: a hierarchical lead (the CTO) that
decomposes work and spawns teammates, who coordinate through a native shared task
list and mailbox rather than prose chatter. The lead is the single human interface.

## Reversibility & cost of change

One-way in practice: the escalation model, the file-ownership rule, the launcher,
and the CTO brief all assume hierarchy. Switching to a different orchestration
substrate later would mean rewriting the operating contract and the host scripts.

## Consequences

Loops are structurally prevented (teammates cannot spawn teammates). Coordination
rides file state, not tokens. Failures trace to the lead's task list. Cost: Agent
Teams is experimental and token-hungry, and in-process teammates don't survive a
resume — so the lead must respawn them.

## Alternatives considered

- **Flat peer-bot swarm** — rejected: loop, cost, and non-determinism risk.
- **Plain subagents** — rejected: they only report back to the caller and can't
  coordinate as a team, which is exactly what multi-track building needs.
- **Managed Agents multiagent API** — deferred to the headless v2; better for
  unattended/production than for the interactive, watchable v1.
