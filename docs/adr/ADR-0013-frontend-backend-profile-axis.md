# ADR-0013 — frontend|backend profile as an orthogonal compose-overlay axis

**Status:** accepted
**Date:** 2026-06-14
**Reversibility:** one-way — the `.claude/swarm-profile` marker and the
engineering-cto-only / label-only-backend contract become a stamped interface
that future doctrine and stamped swarms depend on; once swarms carry markers,
changing the storage model or folding profile into the archetype enum is a
migration across every stamped repo, not a local edit.
**Escalated:** yes (blocking) — the five modeling/scope decisions below were
surfaced to the operator and resolved before any build.

---

## Context

Swarms already have one role-shaping axis: **archetype** (`engineering-cto` /
`cpo` / `company-brain`), a single-valued enum stored in the per-repo
`.claude/swarm-type` marker, resolved by `swarm_type_of()` and dispatched on at
manifest selection, required-doctrine, launch brief, and launch effort. Each
archetype value swaps the *whole* doctrine/manifest/brief.

We need a second distinction — **frontend vs backend** — for engineering-cto
swarms. But frontend and backend are *both* engineering-cto swarms: they share
`TEAM_LEAD.md`, the spec, the test gate, the CPO bus, `/effort ultracode`, and
the entire doctrine spine. They differ only in stack-specific guidance. Modeling
them as new archetype values would force duplicating the whole engineering-cto
overlay per value (overlay explosion + drift) and is wrong, because a profile
does not *replace* the role — it *refines* it. So the axis is genuinely
orthogonal to archetype, and the design question (and its blast radius once
swarms are stamped) is what forced this record.

A repository map + adversarial review (2026-06-14) confirmed: no profile/flavor
concept existed; the manifest is a static TSV with zero variable expansion (so a
profile source cannot be declared on a manifest line); and `test-doctrine-compose.sh`
re-implements `cat` rather than calling the real compose pipeline.

## Decision

We add **profile** as an orthogonal axis layered on top of the engineering-cto
archetype, modeled to **compose** (append an overlay) rather than **replace**.

1. **Storage: a per-repo `.claude/swarm-profile` marker**, resolved by a new
   `swarm_profile_of()` mirroring `swarm_type_of()`. *Not* a sixth `swarm.conf`
   column.
2. **Scope (v1): the composed `CLAUDE.md` overlay only.** `swarm_launch_brief`,
   `swarm_required_doctrine`, and `swarm_effort_for` are **not** touched.
3. **Engineering-cto only.** A profile against any other archetype is refused
   with a clear error (`swarm-init` does the authoritative refusal against the
   repo's resolved type; `swarm-add`/`swarm-new` do a fail-fast flag-level
   check). A "frontend cpo" is meaningless.
4. **Value set `{frontend, backend}`, no `fullstack`.** Today's default
   engineering-cto *is* the backend case, so **`backend` carries zero behavioral
   divergence in v1 — it is a label only.** It is a known, valid profile that
   stamps the marker but ships **no** overlay fragment, so its composed
   `CLAUDE.md` is byte-identical to a pre-profile swarm. `frontend` is the only
   profile with real overlay content.
5. **Retrofit: additive-only for new swarms.** No existing swarm is
   retro-assigned a profile. An **absent marker resolves to the empty profile**
   (NOT mirroring `swarm_type_of`'s default-to-a-value), so a markerless swarm
   composes byte-identically to today.

Mechanically, the overlay is injected by `manifest_apply_compose` in
`swarm-lib.sh`: when the composed target is `CLAUDE.md`, the resolved type is
`engineering-cto`, and the resolved profile has an overlay fragment on disk at
`templates/engineering-cto/profiles/<profile>/CLAUDE.md`, that fragment is
appended as the **final** compose source. This is the **one** dynamically-sourced
compose input — every other source is the static `+`-joined list declared on the
manifest line, which stays profile-agnostic. Three states fall out of one guard:
absent profile → nothing appended; a label-only profile with no fragment
(`backend`) → nothing appended; a profile with a fragment (`frontend`) →
appended.

The `frontend` overlay encodes exactly two frontend-specific rules (it references
rather than restates the base doctrine): a **visual-surface boundary** (writes
confined to the presentational layer — the component library and design
token/theme files; the data layer, `lib/`, API routes, and business logic are
off-limits, and work needing them is mis-scoped → escalate) and a
**preview-in-review** amendment (the convergence adversarial review must check
the rendered preview-deployment URL, not the diff alone).

## Reversibility & cost of change

One-way once swarms are stamped. While the axis is additive and an absent marker
is a no-op (so adopting it costs nothing for existing swarms), the *storage model*
(`.claude/swarm-profile` marker), the *engineering-cto-only* constraint, and the
*label-only-backend* contract become an interface: stamped markers and any future
doctrine that reads the profile would all have to be migrated to change them.
Folding profile back into the archetype enum, or moving storage to a `swarm.conf`
column, would touch every stamped swarm. The compose-injection plumbing itself is
two-way (it is contained to `manifest_apply_compose`), but the data contract is
not — hence one-way and recorded here.

## Consequences

- **Easier:** a frontend swarm gets stack-specific doctrine without duplicating
  the engineering-cto overlay; new profiles are a fragment dir + one entry in
  `swarm_known_profiles`; the no-op default means zero migration for the existing
  swarms (MEMORY `sync-not-live` / robustness-adoption do-not-propagate posture
  is respected — nothing is re-composed for markerless swarms).
- **Harder / the costs, honestly:** the CLAUDE.md compose target now has **one**
  input that is *not* visible on its manifest line — a reader of `manifest.tsv`
  must know the overlay is injected in `swarm-lib.sh` (documented in the manifest
  header comment, `_base/README.md`, and README §6). This is a deliberate, single
  exception to the "add an artifact in ONE place: the manifest" rule. The
  trailing-newline invariant now binds `engineering-cto/CLAUDE.md` (it became a
  non-final source under a profile); the no-op path must stay byte-identical to
  the existing fixture or `test-doctrine-compose.sh` breaks.
- **Committed to:** a marker can drift from the repo's real type the same way
  `swarm-type` can (no `swarm.conf` cross-check) — the engineering-cto-only guard
  in compose is the backstop. Switching a swarm's profile is unsupported (same
  refuse-to-switch guard as archetype).

## Alternatives considered

- **New archetype enum values (`frontend`, `backend`)** — rejected: they don't
  replace the engineering-cto role, so it would duplicate the entire overlay per
  value and invite drift; the shared spine (TEAM_LEAD, spec, gate, bus, effort)
  would have to be kept identical by hand across archetypes.
- **A sixth `swarm.conf` column** — rejected: the parser only *tolerates* a 6th
  field via a discarded `_rest` catch-all (no accessor); it would need an arity
  bump + a new `SWARM_CONF_F_PROFILE` + example-conf + every conf reader/writer to
  move together, and the value would not survive a conf-row rewrite. The marker is
  consistent with `.claude/swarm-type`, is read identically by sync/up, and
  survives rewrites.
- **A CLI-only `--profile` sub-flag with no marker** — rejected: it would be
  invisible to `swarm-sync` and `swarm-up`, which key off the in-repo marker, never
  CLI args — so the overlay could never be re-stamped on sync or gate-checked at
  launch.
- **An empty `backend` overlay fragment** — rejected: it would duplicate the base
  (an empty/whitespace file is still a compose seam to maintain and a fixture to
  freeze) for zero divergence. Treating `backend` as label-only (a valid known
  profile with no fragment) is cleaner and makes the no-op guarantee structural:
  backend composes to the *existing* base fixture, proven by test.
