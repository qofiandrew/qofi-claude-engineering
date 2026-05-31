# CPO doctrine — Money-path floor replaced by a two-type rule

> Doctrine-level decision record (governs CPO behavior across all products), kept
> beside the doctrine it changes. This is **not** a per-product decision (those
> live in `products/<product>/decisions/`), and it is distinct from the numbered
> CPO decision-record series (`0001`–`0009`) in the operator-owned qofi-cpo
> product-vision repo — a numbered companion there may be warranted; see
> *Placement* below.

- **Date:** 2026-05-30
- **Status:** ratified doctrine change (reverses a previously hard-set floor)

## Decision

The prior **money-path floor** — *"anything touching billing / pricing / payouts
/ quota = risk floor HIGH, automatic FRICTION, always stop"* — is **REPLACED** by
a **two-type rule**:

- **Type 1 — billing / accounting STRUCTURE** (how money is *modeled*: GL-account
  structure, line-item scoping, positive-only-for-v1, billing-model design):
  **follows the AND gate** like any product decision. No special floor. Obvious
  calls → decide + notify + keep building; large-and-unclear calls → escalate.
- **Type 2 — real SPEND / real money MOVEMENT** (running an API-credit-burning
  pipeline, turning on a contributor's pipe, triggering payouts, activating a paid
  service): a **HARD explicit-approval floor**. NEVER without explicit operator
  approval — the AND gate does not apply, even when the call is obvious. The floor
  binds **both sides**: the CPO must not *issue a directive* that would cause
  Type-2 spend without approval, and the CTO must not *execute* Type-2 spend
  without approval (`engineering-cto` §*Real spend & money movement*).

Classification test: does the action — or a directive it would send — cause real
money to be spent or real cost/payout incurred? Yes → Type 2. Unsure → Type 2.

## Rejected alternatives

- **Keep the blanket "all money stops" floor.** Rejected: it over-escalated on
  harmless accounting-*structure* calls (e.g. "absorbed pay-only costs get their
  own GL account," "line items positive-only for v1"), training the operator to
  tune the CPO out — the over-escalation failure the disposition shift fixes.
- **Remove the money floor entirely** (let the AND gate handle everything).
  Rejected: dangerously permits *autonomous real spend* whenever a spend looked
  "obvious" — exactly the case where a hard floor must hold.

## Why

The two-type split puts the hard floor **exactly where irreversible cost lives**
— real spend / activation / money movement — while letting reversible *modeling*
decisions flow through the CPO's normal decide-and-notify judgment. It removes the
over-escalation without opening the autonomous-real-spend hole. Recorded because
it **reverses a previously hard-set floor**, so the change is auditable and a later
reader can see it was a conscious decision, not drift.

## Where this lands in doctrine

- `EVALUATION.md` §*The single escalation test* (the AND gate + the two money
  types; dim 3, the two scalars, the surfacing tiers, worked example B).
- `ESCALATION.md` §*Money — two types, opposite treatment* (replaces the old
  §*Money-path floor (automatic FRICTION)*) and the §*CPO overlay* register map.
- `CLAUDE.md` §voice and the WAITING_FOR_OPERATOR state (money no longer a blanket
  flag; Type-2 is the hard stop).
- Defense-in-depth pair on the engineering side: `engineering-cto` §*Real spend &
  money movement* (`CLAUDE.md`, `TEAM_LEAD.md`, `ESCALATION.md`).

## Placement (flag for the operator)

This record is authored in `templates/cpo/decisions/` — adjacent to the doctrine
it governs, in the doctrine-authoring repo. It is **not** synced to live swarms
(the cpo manifest does not list this path). The canonical numbered CPO
decision-record series (`0001`–`0009`) lives in the **operator-owned qofi-cpo
product-vision repo**; fabricating into that repo is out of scope here. If the
operator wants this reversal in that series too, it should be landed there as the
next number (e.g. `0010`) referencing this record.
