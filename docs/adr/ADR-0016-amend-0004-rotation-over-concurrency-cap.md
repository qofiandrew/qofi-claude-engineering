# ADR-0016 — Amend ADR-0004: rotation over concurrency cap

**Status:** superseded by ADR-0018
**Date:** 2026-06-14
**Reversibility:** two-way — a posture/knob change, not baked into the code.
**Escalated:** no — decided autonomously (operator-set rotation model).
**Amends:** ADR-0004
**Superseded-by:** ADR-0018

---

## Context

ADR-0004 set a conservative posture: design for **1–2 concurrent teams on Max
20x**, treating the rolling 5-hour window and weekly caps as a concurrency ceiling
to be protected by running few teammates at once. That posture made sense when the
mental model was "spread one quota thin across many simultaneous teams, and don't
trip the weekly limit."

The operating reality has since settled into a different shape: **a single active
Max account plus rotation**. When the active account hits its 5-hour or weekly
limit, we rotate to a fresh account and the previous one cools down. The limit is
therefore a **duration** problem (how long until the window resets / we rotate),
not a **concurrency** problem (how many teammates can run at once). Under that
model, holding concurrency low to "save" headroom leaves capacity on the table:
the headroom we were protecting is reclaimed by rotation, not by throttling.

The single-pool fact in ADR-0004 still holds — at any given moment one Max account
backs the work, and the token budget is still real and still finite within the
active window. What no longer holds is the *inference* that the right response to a
finite window is a low concurrency cap.

## Decision

We will **maximize concurrency within the active Max account** and **absorb the
5-hour / weekly usage limit through rotation (duration) plus per-task effort
routing**, rather than protecting a low concurrency cap.

Concretely:

- The single active-account fact from ADR-0004 stands; this ADR **amends** that
  ADR's *concurrency posture*, it does not retire it. (See ADR-0004's header
  `**Amended-by:** ADR-0016`.)
- Run as many teams/teammates as the active account's window will bear; do not
  hold concurrency artificially low to preserve weekly headroom.
- When a window is exhausted, **rotate** to a fresh active account. The usage limit
  is paid in time (rotation + cooldown), not in withheld concurrency.
- **Per-task effort routing** (e.g. low-effort archetypes on cheap launches,
  ultracode where it earns its cost) does the fine-grained budget shaping that a
  blanket concurrency cap used to do bluntly.
- The token budget remains a real constraint inside the active window — effort
  routing, not a concurrency ceiling, is the lever that respects it.

### Convention — supersession / amendment headers

This ADR also establishes the house convention for recording any future ADR that
overturns an earlier one. The convention exists so the archive stays an immutable
dated record while still being navigable in both directions:

- The **old** ADR keeps its body **immutable** — its rationale was true on its
  date and must not be rewritten. Only a single header **pointer** is added:
  - `**Amended-by:** ADR-NNNN` when the decision is *partially* changed (some of
    the original still holds), or
  - `**Superseded-by:** ADR-NNNN` when the decision is *fully* replaced.
- The **new** ADR carries the reciprocal header line:
  - `**Amends:** ADR-NNNN`, or
  - `**Supersedes:** ADR-NNNN`.
- A superseding ADR should also reflect its relationship in `**Status:**` per the
  template (`superseded by ADR-NNNN` lives on the *old* ADR's status line; the new
  one is `accepted`).

Living docs (PROJECT_SPEC, READMEs) remain the single source of truth for *current
behavior*. ADRs — including this one — are the immutable dated "why" archive and
are never read to learn what the system does today, only why a call was made.

## Reversibility & cost of change

Two-way. The posture is a runtime/operational knob (how many teams we launch, when
we rotate, how effort is routed), not a structural commitment. Reverting to the
conservative cap means launching fewer teams and rotating less aggressively — no
code migration, no breaking consumers. The header-convention is likewise additive:
backing it out is deleting a pointer line.

## Consequences

- **The bottleneck moves.** Concurrency is no longer the limiting resource;
  **CTO review-bandwidth and context budget** become the new ceiling. More teams
  running means more work arriving at a single reviewing throat to choke — the gate
  and the review queue, not the subscription, now bound throughput.
- **Rotation has a state cost.** Rotating the active account is effectively a
  restart of the running instances bound to it — **in-RAM state is lost** at the
  rotation boundary (live context, un-checkpointed working memory). Work must be
  durable to disk/branch before a rotation, or it evaporates.
- **Effort routing becomes load-bearing.** With the blunt concurrency cap gone,
  per-task effort routing is the only thing shaping spend inside a window. Mis-routing
  (ultracode on trivial work) now burns the window faster with no cap to catch it.
- **Upside:** within an active window we get the full capacity we are paying for;
  headroom is reclaimed by rotation rather than left idle behind a protective cap.
- We remain N-repo-capable exactly as ADR-0004 stated; nothing structural changed.

## Alternatives considered

- **(a) Keep the conservative 1–2 team cap (ADR-0004 unchanged)** — rejected: it
  protects headroom that rotation already reclaims, leaving paid-for capacity idle.
- **(b) Retire ADR-0004 entirely** — rejected: the single-active-pool fact and the
  real token budget it records still hold; only the concurrency *posture* changed,
  so this is an amendment, not a supersession.
- **(c) Multiple simultaneous active accounts (true concurrency multiplication)** —
  rejected: that is concurrency, not rotation; it multiplies coordination and
  billing surface and re-raises the per-member-limits concern ADR-0004 flagged.
- **(d) Pure metered API to sidestep windows** — rejected: same reason as ADR-0004;
  Max's predictable flat cost is the default, API stays the overflow valve.
- **(e) Keep the conservative cap but raise it by a fixed step** — rejected: a
  larger-but-still-static cap still treats a duration limit as a concurrency
  ceiling; effort routing + rotation shape spend better than any fixed number.
