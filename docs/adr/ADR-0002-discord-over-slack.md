# ADR-0002 — Discord bridge over Slack

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** two-way — the bridge is swappable, but enough setup lock-in to record.
**Escalated:** no — decided during the design conversation.

## Context

The control plane must let the operator hold a long design conversation with one
*persistent* CTO and approve decisions from a phone. The official Claude Code Slack
integration is the wrong shape: it spins up an ephemeral cloud session per task —
"tag @Claude, get a PR" — with no persistent entity to accumulate vision. An
existing Discord fork already provides a persistent per-channel relay plus the
`yes/no` permission-reply intercept.

## Decision

We will use the Discord `discord-b2b` bridge, one bot identity per repo channel, as
a thin relay into each persistent CTO session. We will not use the official Slack
integration.

## Reversibility & cost of change

Two-way: the bridge is a thin layer the launcher configures. Moving to Slack later
is possible but means rebuilding the same persistent-relay + permission-intercept
behavior DIY — net-new work, not a config flip.

## Consequences

Free, unlimited message history (useful for an always-on, chatty system), trivial
one-bot-per-repo setup, and remote permission approval out of the box. Cost: it's a
self-maintained fork, not an official integration.

## Alternatives considered

- **Official Slack → Claude Code on the web** — rejected: ephemeral, one-repo-per-
  task, no persistent CTO to spec with.
- **DIY Slack bridge** — rejected for v1: would reproduce what the Discord fork
  already does. Reconsider only if the operator genuinely lives in Slack.
