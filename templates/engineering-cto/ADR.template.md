# ADR-NNNN — <short decision title>

> Architecture Decision Record. One file per significant decision, numbered
> sequentially, kept in `docs/adr/`. Every decision classified **one-way** in the
> escalation policy gets one of these — it is the audit trail for CTO-level calls
> and the clean place for me to override.

**Status:** proposed | accepted | superseded by ADR-NNNN
**Date:** <date>
**Reversibility:** one-way | two-way
**Escalated:** yes (batched / blocking) | no — decided autonomously

---

## Context

The forces at play. What problem or constraint forced a decision, and what makes
it non-obvious. State it so that someone reading this in six months understands
why this wasn't trivial.

## Decision

The call, stated plainly and in the active voice: "We will …"

## Reversibility & cost of change

Why this is one-way or two-way, and concretely what reversing it would cost later
(rework, migration, breaking consumers). This is the field that drives whether it
should have been escalated.

## Consequences

What becomes easier, what becomes harder, what we're now committed to. Include the
bad parts honestly — an ADR that only lists upsides isn't doing its job.

## Alternatives considered

The realistic options that were rejected, and the one-line reason each lost. This
is what makes the decision auditable rather than asserted.

- **<alternative>** — rejected because …
- **<alternative>** — rejected because …
