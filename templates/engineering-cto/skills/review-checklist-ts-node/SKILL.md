---
name: review-checklist-ts-node
description: R5 review checklist for TypeScript/Node diffs — the language-specific review pass the reviewer/CTO runs over a TS/Node change, plus the native tools to run (tsc --noEmit, eslint, vitest). Load when reviewing TS/Node code. This concretizes the always-loaded doctrine's review/DoD gates (CLAUDE.md §Definition of done, TEAM_LEAD.md §Independent review & security gates) for this stack; it is an on-demand skill, not a floor, so it costs no context in repos whose stack doesn't match. Inert when there is no package.json / tsconfig.json.
---

# review-checklist-ts-node — TS/Node R5 review pass

An **on-demand companion** to the always-loaded doctrine, not a replacement.
Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins. This is the
*stack-specific concretion* of the independent-review gate (`TEAM_LEAD.md`
§*Independent review & security gates*) and the DoD self-review (`CLAUDE.md`
§*Definition of done*) — what to look at when the diff is TypeScript/Node.

**Inert when the stack doesn't match.** No `package.json` / `tsconfig.json` at
the root → this skill does not apply; produce nothing. (Same zero-context
posture as `ts-node-stack`.)

## Native tools to run first (deterministic, before the human-judgment pass)
Run the repo's own commands — don't invent flags the repo doesn't use:
- **`tsc --noEmit`** (or `npm run typecheck`) — must be clean. A type error in
  the diff is a hard stop, not a nit.
- **`eslint`** (or `npm run lint`) — clean. New disable-directives are a review
  item, not a free pass (see the suppression check below).
- **`vitest`** (or the repo's `.claude/test-cmd`) — green, at/above the
  `quality-bar.md` coverage floor. Never lower the floor to pass (`CLAUDE.md`
  §*Verification*).

## Review checklist (human-judgment pass — what the scanners can't see)
- **No `any` at a contract surface.** An `any` crossing a module boundary defeats
  the one-contract-surface rule (`CLAUDE.md` §*Modular design*); expect
  `unknown` + a narrowing parse instead.
- **External input validated at the edge.** HTTP bodies, queue payloads, and env
  are parsed with a schema (e.g. `zod`) at the contract surface; inside the
  boundary the type is trusted, not re-checked (`CLAUDE.md` §*Error handling*
  "don't handle impossible states").
- **No swallowed errors.** No empty `catch {}`, no ignored rejected promises, no
  floating `async` call without `await`/`.catch`. (R4 semgrep flags the
  mechanical cases — confirm the diff doesn't reintroduce them, and judge the
  cases the rule can't reach.)
- **Async correctness.** Every promise is awaited or its rejection is explicitly
  handled; no `await` inside a hot loop that should be batched; no unbounded
  `Promise.all` over an at-scale collection.
- **Strictness preserved.** The diff doesn't loosen `tsconfig` (`strict`,
  `noUncheckedIndexedAccess`) "to move fast" — retrofitting strictness later is
  the expensive path (`ts-node-stack`).
- **No suppression-to-go-green.** A new `@ts-expect-error`, `@ts-ignore`,
  `eslint-disable`, or non-null `!` that exists only to silence a real failure is
  a regression (`CLAUDE.md` §*Verification* — never weaken a check to pass). Each
  must be justified at its use site or it's a finding.
- **Drizzle / Postgres (if touched).** Migrations are committed files with a
  tested rollback; no hand-typed `ALTER`; single-owner tables (no cross-module
  `SELECT` into a peer's tables) — per `ts-node-stack` and `CLAUDE.md` §*Data
  ownership* / §*Data migrations*.
- **BullMQ (if touched).** Jobs idempotent + resumable, per-item failure isolated
  (`WARN`+aggregated, not `ERROR`-per-item), payload-shape changes treated as
  breaking contract changes (`ts-node-stack`).

## Confidence discipline (carry the gate's rule into the pass)
Report only findings held at **≥80% confidence** (`TEAM_LEAD.md` §*Independent
review*). Consolidate similar findings; order security-first. A flood of
low-confidence nits gets the reviewer tuned out — worse than no reviewer.

## What this skill is not
Not a gate of its own and not a place for logic — it is a *checklist* the
reviewer/CTO applies. The gating authority stays with the DoD and the
independent-review/security passes the CTO runs (`CLAUDE.md` §*Definition of
done* item 7).
