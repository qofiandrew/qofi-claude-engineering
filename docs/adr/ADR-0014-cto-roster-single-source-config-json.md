# ADR-0014 — CTO roster single source of truth: `config.json` `ctoChannels`; doctrine points, never duplicates (cto-roster-single-source-config-json)

**Status:** accepted
**Date:** 2026-06-14
**Reversibility:** two-way (a doc pointer is trivially revertible; no persistent surface, no code change).
**Escalated:** no — decided autonomously (a two-way doc pointer fix; the underlying premise correction is logged here).

---

## Context

The CPO drives each engineering CTO over the bus with a `[<cto-name>]` directive
(`templates/cpo/CPO_BUS_PROTOCOL.md` grammar 1). The set of valid `<cto-name>`
values is **routing data**: the watcher (`cto-watcher`) routes a directive only
if the bracketed name is a key in its `ctoChannels` map, and **fails closed**
otherwise — it does not send, logs the miss, and DMs every operator on
`alertUserIds` (`cto-watcher/routing.js`; `cto-watcher/README.md` rule 2: the
name "is looked up in the **exact** `ctoChannels` map … **Not found:** *fail
closed*"). That map is the live authority the running watcher actually consults.

The same routing data was **also** written out, by hand, as a "Valid
`<cto-name>`" markdown table inside `CPO_BUS_PROTOCOL.md`. A doctrine doc holding
its own copy of operational routing data is a mirror with no enforcement keeping
it in sync — and it **already drifted**:

- **Live `cto-watcher/config.json` `ctoChannels`** (5 keys):
  `reserve-backend-2`, `qofi-ios-app`, `press-backend`, **`press-fileops`**,
  **`deployment-core`**.
- **The CPO doctrine table** listed only 3:
  `reserve-backend-2`, `qofi-ios-app`, `press-backend`.

So `press-fileops` (and `deployment-core`) existed in the live routing config but
were **absent** from the doctrine the CPO reads. A CPO trusting the table would
believe `[press-fileops] …` is an invalid, unroutable name — when in fact the
watcher routes it. The defect class is general: **a doctrine doc that mirrors
routing data is a second copy that drifts the moment the config changes** (here,
when `swarm-add.sh` registered new CTOs into `ctoChannels` — `bin/swarm-add.sh`
phase 4e — without anyone hand-editing the doc table). `config.json`'s
`ctoChannels` is itself seeded from / mirrored against `swarm.conf` (the
operator's per-repo roster; `cto-watcher/README.md`: the example is "pre-filled
… from `../swarm.conf`"), so there is already one operator-owned source of
roster truth — the doctrine table was a *third* hop, the one with no tooling
behind it.

This wasn't trivial to spot because the table *looked* authoritative — it carried
"exact, case-sensitive" and "fails closed" wording — yet nothing read it: the
watcher reads `config.json`, not this markdown.

## Decision

**We will treat `cto-watcher/config.json` `ctoChannels` as the single source of
truth for the valid CTO roster, and make `CPO_BUS_PROTOCOL.md` *point* to it
rather than duplicate it.** The "Valid `<cto-name>`" enumerated table and its
co-located "exact names … fails closed" wording are replaced by a pointer to the
`ctoChannels` map (the authority the watcher actually consults), with the
fail-closed semantics **re-anchored to that config** instead of to the deleted
table. No name list is restated in the doc. Adding or removing a CTO remains an
operator config change to `swarm.conf` → `ctoChannels` (via `bin/swarm-add.sh`),
which is exactly where it already lived; the doctrine no longer needs editing in
lock-step.

The roster authority chain, stated once, here: **`swarm.conf` (operator's
per-repo roster) → `cto-watcher/config.json` `ctoChannels` (the live map the
watcher routes against) → the CPO uses those exact keys in `[name]` tags.**
Doctrine references this chain; it never holds a copy of the keys.

## Reversibility & cost of change

Two-way, and cheap. This is a documentation pointer plus a one-time premise
correction — no code, no schema, no persistent surface. Reverting means pasting
an enumerated table back into `CPO_BUS_PROTOCOL.md` (and re-inheriting the drift
risk this ADR removes). There are no downstream consumers of the doc table —
nothing parses it; the watcher reads `config.json`. The cost of *keeping* the
decision is zero; the cost of *reverting* is re-introducing a hand-synced mirror.

## Consequences

- **Easier:** the CPO's roster knowledge can no longer drift from what the
  watcher routes — there is one place to read (`ctoChannels`) and it is the same
  place the watcher reads. Registering a new CTO via `swarm-add.sh` is now
  sufficient; no parallel doc edit is required to keep doctrine truthful.
- **Harder / honest cost:** the valid names are no longer visible *inline* in the
  doctrine doc — a reader must open `cto-watcher/config.json` (or run the watcher,
  which fails closed and DMs the operator on an unknown name) to enumerate them.
  This is the correct trade: a slightly less self-contained doc in exchange for a
  doc that cannot lie. The fail-closed behavior is the live backstop — an invalid
  `[name]` is caught by the watcher and surfaced to the operator regardless of
  what any doc says.
- **Committed to:** doctrine docs do not mirror routing/operational data that has
  an authoritative config + tooling. Where a doc needs to reference such data, it
  **points** to the source of truth and names the fail-closed/enforcement path,
  rather than restating values.

## Alternatives considered

- **(a) Hand-fix the table to add `press-fileops` + `deployment-core`** — rejected:
  re-syncs the mirror once but leaves the drift-prone duplication in place; the
  next `swarm-add.sh` registration drifts it again. Treats the symptom, not the
  defect class.
- **(b) Generate the table from `config.json` at build/commit time** — rejected:
  premature tooling for a doc nobody parses; adds a generator + a staleness gate
  to maintain, when a plain pointer to the already-authoritative config removes
  the duplication entirely (the `§Greenfield` resist-premature-architecture
  instinct, and the `§Doc map` "build the heavier mechanism only when the minimal
  one stops routing" rule).
- **(c) Make the doctrine table itself authoritative and have the watcher read it**
  — rejected: inverts ownership the wrong way. Routing data belongs in the
  operator-owned config the watcher consumes (`config.json`, seeded from
  `swarm.conf`), not in a template doc; the watcher parsing markdown for routing
  is strictly worse.
- **(d) Point doctrine at `config.json` `ctoChannels` as the single source of
  truth; doctrine references, never duplicates** — **chosen.** Removes the
  duplication and the drift class at once, no new tooling, fully reversible, and
  keeps ownership where it already is.
