# ADR-0009 — Canonical prod-migration surface so the floor is mechanically gateable

**Status:** accepted
**Date:** 2026-05-29
**Reversibility:** one-way — once products route prod migrations through the
canonical surface and the deny-hook depends on it, changing the surface is a
coordinated migration across every product plus a hook change.
**Escalated:** yes — operator-directed as the follow-up to the doctrine merge
(023a375); the deny it unblocks was held precisely so this surface decision
wasn't invented inside a hook commit.

## Context

The prod-migration floor is operator-only at the same tier as `git push` to
`main` (`CLAUDE.md` §*Data migrations*). But it is **not** mechanically enforced:
the prior pass tried to build a deterministic deny mirroring the `git push` deny
and could not, because the two surfaces are not alike.

The `git push` deny works because **`git push` self-identifies in the command
tokens** the permission-gate hook sees (`permission-gate-policy.sh`): the
dangerous thing is right there in `$CMD`, so a matcher denies it and fails closed.

A prod migration does **not** self-identify. The migration tool is per-product
and unnamed in doctrine ("the project's migration tool runs … in order"), and a
migration's **prod-ness lives in the environment (`DATABASE_URL`, `NODE_ENV`) or
config — never in the command tokens** the hook can see. `npm run migrate`
against a prod `DATABASE_URL` is indistinguishable, token-wise, from the same
command against local. So a token matcher can only:

- blanket-block **all** migration commands — which breaks the normal dev
  cadence (`permission-gate-policy.sh` deliberately allows `npm run …` so
  teammates can run dev migrations); or
- match a literal `--prod`/`production` token — which the policy already does
  and which **misses the env-driven prod migration entirely**.

Neither is a real floor. The deny is impossible until prod migrations run
through a surface the hook *can* match.

## Decision

Prod migrations MUST be invoked through a **single, canonical, self-identifying
surface** the permission-gate hook can match — mirroring the existing
`.claude/test-cmd` convention. Realized as **either** a required wrapper script
**or** a `.claude/prod-migration-cmd` marker (the marker most directly mirrors
`.claude/test-cmd`); the specific realization is finalized when the deny-hook is
built, constrained to whichever cleanly fits the product's tooling. **Anything
that does not go through the canonical surface is, by definition, not an
authorized prod migration** — the floor's whole point.

This ADR fixes the **principle** (a self-identifying surface exists and is
mandatory). The deny-hook that gates it is a separate follow-up, unblocked by
this decision.

## Reversibility & cost of change

One-way in practice. Before the deny-hook and product adoption, the convention
is cheap to revise. Once every product routes prod migrations through the
surface and the hook denies on it, changing the surface means re-routing every
product and re-pointing the hook in lockstep — a coordinated migration, not a
local edit. Hence the ADR.

## Consequences

- Every product in the system routes prod migrations through the canonical
  surface; the deny-hook (separate follow-up) gates that surface and **fails
  closed** on anything ambiguous.
- Dev / non-prod migrations explicitly must **not** go through the surface, so
  they stay unblocked — the dev cadence (`npm run …`) is preserved.
- The `CLAUDE.md` §*Data migrations* floor and the `ESCALATION.md` migration
  trigger can stop describing an unenforced parity and instead cite this ADR as
  the surface the pending deny will gate.
- New cost: products must adopt the convention; a prod migration run outside the
  surface is a doctrine violation even though the hook can't see it until the
  surface is used — the convention is load-bearing.

## Alternatives considered

- **Mandate a `--prod` token on the migration command instead of a dedicated
  surface** — rejected as convention-by-memory: the day someone runs the raw
  tool without the token, the floor silently doesn't apply. A floor that depends
  on remembering to type a flag is not a floor.
- **Blanket-deny every migration command** — rejected: breaks the normal dev
  migration cadence the policy intentionally allows; an over-block that trains
  agents to route around the gate.
- **Leave it prose + circuit-breaker (no mechanical deny ever)** — rejected:
  the project's gate-over-honor-system principle says a declared irreversible
  floor should be mechanically enforced where a surface can be made to exist;
  this ADR makes that surface exist.
