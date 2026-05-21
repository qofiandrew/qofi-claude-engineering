# ADR-0006 — The CTO authors docs from the conversation

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** two-way — a process choice in the CTO brief and the launch handoff.
**Escalated:** no — operator UX decision.

## Context

The operator's workflow is to spec a product conversationally — often for an hour —
and then say "go build." Requiring a written spec to exist *before* the CTO engages
would defeat that UX. The CTO must be able to start from raw vision.

## Decision

The CTO holds the design conversation with no docs assumed. On "go build," its first
act is to **author** `PROJECT_SPEC.md` plus the one-way-door ADRs from the
conversation and **confirm** them with the operator before spawning any teammate.
The CTO also owns ongoing **reconciliation** — keeping the docs true to the
implementation — rather than trusting each teammate to update only its own slice.

## Reversibility & cost of change

Two-way: this lives in `TEAM_LEAD.md` (lifecycle steps 0–1, reconciliation duty) and
the `swarm-up.sh` handoff prompt. Changing the process is an edit to those two
places.

## Consequences

The operator can work from vision; docs are an output, not a prerequisite. A
confirmation checkpoint catches misunderstanding before any code is written, and the
reconciliation duty keeps docs from rotting. Cost: a deliberate beat between "go
build" and the first teammate spawning — the authoring-and-confirm step.

## Alternatives considered

- **Require the operator to write the spec first** — rejected: defeats the
  conversational UX that is the whole point.
- **Build immediately on "go build," document later** — rejected: skips the
  confirmation checkpoint and invites drift from the start.
