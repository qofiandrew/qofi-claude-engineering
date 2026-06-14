# ADR-0015 — Bus wiring is shared, independently-runnable, and precondition-gated (bus-wiring-shared-runnable-gated)

**Status:** proposed
**Date:** 2026-06-14
**Reversibility:** two-way (extract-and-call refactor + two new standalone scripts; no persistent surface, no data-format change — reverting re-inlines phase 4e).
**Escalated:** no — decided autonomously (a two-way structural refactor of standup tooling; the boundary redraw is logged here).

---

## Context

Bringing a new engineering-cto swarm onto the `#cpo-cto-bus` requires BOTH halves
to be wired, or the CTO silently fails:

1. a `ctoChannels[<name>]` entry in `cto-watcher/config.json`
   (`{channelId, botUserId}`) — the routing authority the running watcher
   consults (ADR-0014), and
2. the cto-watcher bot's own id in that channel's `access.json` `allowFrom` — the
   watcher reposts CPO directives **as itself**, so the new CTO's bridge drops
   them unless the watcher id is allow-listed.

Until now this wiring lived **only** as `bin/swarm-add.sh` **phase 4e** — inline
Python heredocs buried in the middle of a seven-phase interactive standup script.
That coupling produced three concrete problems:

- **Not independently runnable.** Re-wiring an existing swarm (e.g. after a
  `config.json` reset, an `access.json` rebuild, or a bot-id change) meant
  re-running the *entire* `swarm-add` walkthrough with `--skip-walkthrough` and
  the right flags — there was no small, single-purpose "just wire the bus"
  operation. The bus logic was reachable only through the big script.
- **Not assertable.** There was no way to *verify* a swarm was fully wired short
  of reading `config.json`, `access.json`, `tokens.env`, and the repo's doctrine
  by hand. `swarm-up`'s preflight gates check some of this at launch, but there
  was no standalone "is this CTO actually operational?" probe — and partial
  state (config wired but allowFrom missing, or doctrine stamped but token
  absent) could sit undetected.
- **Single-site idempotency.** Phase 4e was idempotent in *effect* but rewrote
  `config.json` on every run even when already current; the no-op was implicit,
  not a first-class, tested contract.

The forces: standup wiring and standup *verification* are two distinct concerns
that were fused into one monolithic script, so neither could be exercised, re-run,
or tested on its own. The `swarm-init` ↔ `swarm-add` line — `swarm-init` stamps a
repo's doctrine/harness; `swarm-add` does Discord-side standup — left bus wiring
welded to the interactive flow with no shared, gateable seam.

## Decision

**We will redraw the standup boundary so bus wiring is SHARED, INDEPENDENTLY
RUNNABLE, and PRECONDITION-GATED:**

1. **Shared (one script).** Extract phase 4e into `bin/swarm-bus-wire.sh`
   `<name> <channel> <bot-user-id>` — the single implementation of both wiring
   halves. `swarm-add.sh` phase 4e becomes a **thin call** into it (passing
   `CTO_WATCHER_CONFIG` / `CTO_BUS_WATCHER_BOT_ID` / `SWARM_ACCESS_FILE` through
   so it resolves the exact same paths), with **no behavior change** — the
   resulting `config.json` / `access.json` are byte-identical to the pre-refactor
   effect. One definition of "wired", consumed by both the standup flow and a
   standalone re-wire.

2. **Independently runnable.** `swarm-bus-wire.sh` is invocable on its own to
   wire or re-wire a single swarm, and is **idempotent**: a re-run on an
   already-wired swarm is a safe no-op — `ctoChannels` reports "already current"
   and rewrites nothing material; the watcher id is appended to `allowFrom`
   **at most once**. An empty `<bot-user-id>` (a re-run with no id on hand)
   skips Half 1 and still runs Half 2 — mirroring phase 4e's original re-run
   path exactly.

3. **Precondition-gated.** `bin/swarm-doctor.sh` `<name>` asserts the full
   operational set for an engineering-cto swarm that has a `swarm.conf` row and
   **BLOCKS on ANY gap** (exit 1) — no partial state passes silently. It checks:
   doctrine stamped (required files present **and**
   `enabledPlugins["discord-b2b@qofi-swarm"] === true`); bot token **PRESENT**
   (presence only — the value is never read, printed, or logged); `config.json`
   `ctoChannels` wired (matching `channelId` + non-empty `botUserId`); and
   `access.json` `allowFrom` wired. It reads `config.json` `ctoChannels` as the
   authority and **never consults any roster table**. It emits the standing flag
   that **restarting the cto-watcher is operator-manual** — `swarm-doctor` does
   not and cannot restart it.

**Relationship to ADR-0014.** ADR-0014 established `config.json` `ctoChannels` as
the single routing authority and made doctrine *point* at it rather than
duplicate it. Both new scripts honor that: `swarm-bus-wire` *writes* the
authority (Half 1), and `swarm-doctor` *reads* it as the source of truth for the
wiring assertion — never a roster mirror. This ADR depends on ADR-0014's premise
but introduces no new authority and does not modify it.

## Reversibility & cost of change

Two-way. Reverting means re-inlining `swarm-bus-wire.sh`'s body back into
`swarm-add.sh` phase 4e and deleting the two new scripts + their tests. There is
no persistent state, no data-format change, and no consumer contract to migrate —
`config.json` and `access.json` shapes are unchanged. The only new surface is two
operator-facing CLIs and their env-override seams (already mirrored from
`swarm-add`), all additive.

## Consequences

- **Easier:** re-wiring one swarm is a single small command, not a re-run of the
  whole interactive standup. Verifying a CTO is operational is one `swarm-doctor`
  call that fails loud on any gap, instead of a manual four-file read. The wiring
  logic is now unit-tested in isolation (idempotency + gap detection) rather than
  reachable only through the monolith.
- **Harder / accepted costs:** there are now two more scripts in `bin/` to keep
  consistent with `swarm-add`'s path/env conventions; a drift between
  `swarm-bus-wire`'s defaults and `swarm-add`'s would reintroduce the very
  divergence this consolidates (mitigated by `swarm-add` passing its resolved
  paths through, and by both deriving the same defaults from `SWARM_HOME`). The
  watcher-restart-after-wiring step remains **operator-manual** — neither script
  restarts the watcher; `swarm-doctor` only flags it. That is a deliberate
  non-goal here (restart is a separate operability surface), not an oversight.
- **Committed to:** "wired" now has one definition (`swarm-bus-wire`) and one
  assertion (`swarm-doctor`); a future change to what bus-wiring means lands in
  one place and its gate updates alongside.

## Alternatives considered

- **Leave phase 4e inline; add only `swarm-doctor`** — rejected: the wiring would
  still be reachable only through the full `swarm-add` walkthrough, so the
  "independently runnable re-wire" need stays unmet and the doctor would assert a
  state no small command can produce.
- **Fold wiring + verification into one `swarm-doctor --fix`** — rejected:
  conflates assertion with mutation. A precondition gate that also writes is no
  longer a trustworthy *check* (it can't be run read-only in CI / preflight), and
  it muddies `swarm-add`'s thin-call seam. Keep wire (mutate) and doctor (assert)
  as separate single-responsibility scripts.
- **Put the wiring in `swarm-lib.sh` as a sourced function** — rejected for now:
  the wiring is an operator-runnable *operation* (it has a CLI contract, exit
  codes, and stands alone), not a parsing helper the readers share. A standalone
  script matches the sibling `bin/` convention (`swarm-init`, `swarm-provision-
  tokens`) and is directly invocable; promoting shared internals into the lib is
  a separate call if a second in-process caller ever appears.
