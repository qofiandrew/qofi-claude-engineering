# ADR-0004 — Single Max pool; 1–2 concurrent teams; API for overflow

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** two-way — a billing/scale knob, not baked into the code.
**Escalated:** no — operator constraint ("must use Max").
**Amended-by:** ADR-0016, ADR-0018

## Context

The aspiration was 5–7 product teams running 24/7. A single Claude Max plan is one
user's quota, shared across chat and Claude Code, governed by rolling 5-hour
windows, weekly caps, and a soft ~50-sessions/month ceiling. Agent Teams is
token-hungry (each teammate is a full instance), and concurrent sessions all week
can hit even the weekly Opus limit. 5–7 × 24/7 is genuinely API-scale, not a single
subscription.

## Decision

We will design for **1–2 concurrent teams on Max 20x**, with the usage-credit /
metered-API path as the overflow valve for bursts. The architecture stays
N-repo-capable; concurrency is gated by the subscription, not the code.

## Reversibility & cost of change

Two-way: scaling concurrency is a matter of adding `swarm.conf` entries plus
budget — provided the usage math supports it. No structural change required.

## Consequences

Concurrency is capped by the subscription, not the Mac mini. We must measure real
per-team token burn (see PROJECT_SPEC §9) before adding a second live team. The
launcher unsets `ANTHROPIC_API_KEY` so leads bill against Max, not metered API, by
accident.

## Alternatives considered

- **Multiple Max accounts to multiply quota** — rejected: against the spirit of
  per-member limits; not a foundation to build on.
- **Pure metered API from day one** — rejected: the operator specifically wants
  Max's predictable flat cost; API is the overflow, not the default.
