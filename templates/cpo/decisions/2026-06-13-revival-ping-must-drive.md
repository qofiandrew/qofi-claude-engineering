# CPO doctrine — A revival ping must be answered by driving, never by a bare heartbeat re-emit

> Doctrine-level decision record (governs CPO behavior across all products), kept
> beside the doctrine it changes. This is **not** a per-product decision (those
> live in `products/<product>/decisions/`), and it is distinct from the numbered
> CPO decision-record series in the operator-owned qofi-cpo product-vision repo.

- **Date:** 2026-06-13
- **Status:** accepted
- **Scope:** effectiveness fix (CPO doctrine), **not** a safety/health-monitoring
  change. Real CTO-health detection lives in `swarm-watch.sh` / the cto-watcher and
  is explicitly out of scope here — this record does not touch it.

## Decision

When the watcher posts a **revival ping** for a quiet DRIVING loop, the CPO MUST
answer with a **driving action** — re-read that CTO's next drivable step and either
**issue the next directive** (`STATE: <name> DRIVING` + the directive) or **make a
real transition** to `WAITING_FOR_OPERATOR`. A **bare heartbeat re-emit**
(`STATE: <name> DRIVING` unchanged, which "changes nothing") is **NOT** a valid
answer to a ping — it is the "silent-DRIVING" the §*Revival-loop guard (AUTO)*
already forbids.

The heartbeat re-emit remains valid in its proper place: as a clock-reset you emit
**because** you are actively driving a loop you have already evaluated — **never**
as something you emit **instead** of driving in answer to a ping.

## Context — the incident this pins

At **08:16** the cto-watcher posted a revival ping for **`press-backend`**
("DRIVING and quiet ~30m, confirm"). The CPO answered `STATE: press-backend
DRIVING` and did nothing else — re-confirming the watcher's stale guess instead of
driving the CTO forward. The loop stayed silently stuck; the ping accomplished
nothing.

Root cause was a **doctrine contradiction**, not a watcher bug:

- §*Heartbeat = re-emit current state* **permitted** answering a ping with a bare
  `STATE: <cto> DRIVING` that "changes nothing."
- §*Revival-loop guard (AUTO)* **required** a ping to resolve to a definite state
  (issue a directive / transition to `WAITING_FOR_OPERATOR`), "never back to
  silent-DRIVING."

The CPO took the path the heartbeat clause permitted. Both clauses cannot be
right; this record removes the contradiction by **scoping the heartbeat clause out
of the ping case** so the revival-loop guard wins unambiguously.

## What changed

- `templates/cpo/CLAUDE.md` — §*Heartbeat = re-emit current state* retitled and
  scoped to "**NOT a revival-ping answer**": the bare re-emit is valid only while
  actively driving an already-evaluated loop; on a ping it is the forbidden
  silent-DRIVING and the §*Revival-loop guard* resolution is required. Adds the
  framing: a heartbeat is emitted **because** you're driving, never **instead** of
  driving.
- `templates/cpo/CPO_BUS_PROTOCOL.md` — the §STATE heartbeat bullet gets the same
  scoping; §*Liveness* **drops** "a heartbeat (`STATE: <name> DRIVING`)" from the
  list of valid ping answers, leaving only a driving action or a real transition.
  The STATE wire-grammar (enum, declare-before-acting) is unchanged.

No behavioral mechanism changed — only the doctrine the CPO reads. The STATE
grammar the watcher parses is byte-for-byte the same.

## Corroboration

The doctrine **already** encodes the correct behavior for the sibling case: the
§*Liveness* **resume-nudge** (usage-limit-cleared) clause tells the CPO to "re-read
that CTO's next drivable step and resolve to a definite state — issue the next
directive ... or `WAITING_FOR_OPERATOR`." A revival ping and a resume nudge are the
same situation (a quiet loop the watcher is prodding); they should resolve the same
way. This change makes the revival-ping path consistent with the resume-nudge path
that was already right.

## Consequences

- A revival ping now always moves the loop: forward (a directive) or to an honest
  stop (`WAITING_FOR_OPERATOR` surfaced to the operator). No more re-confirming a
  stale guess.
- The heartbeat re-emit is preserved for its real purpose (a mid-drive clock
  reset), so this is a scoping fix, not a ban — the watcher's timer-reset path
  still works for genuinely-driving loops.
