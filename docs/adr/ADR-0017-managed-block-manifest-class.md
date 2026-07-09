# ADR-0017 — A managed-block manifest class for partially-portable CI (`ci.yml`)

**Status:** proposed
**Date:** 2026-06-14
**Reversibility:** one-way — a new behavior class becomes part of the manifest
contract that `swarm-lib.sh` and every archetype's `manifest.tsv` depend on, and
its managed-region markers get stamped into target files across every stamped
repo. Retracting it after it has spread means de-marking files in N repos and
removing a class others may have started using.
**Escalated:** yes (blocking) — this is authored as a PROPOSAL for the operator to
rule on. Nothing is implemented: `swarm-lib.sh` is untouched, no `ci.yml` is
stamped. The ADR is the deliverable; the build waits on the ruling.

---

## Context

CI is currently captured only as a per-repo reference doc (`docs/CI-PROMOTION.md`).
The manifest stamps **no** `ci.yml`, so every engineering-cto repo hand-copies the
workflow — the press CI work just did it three times. Option 1 (this batch, separate
from this ADR) closes the cheap half by stamping the fully-portable `.gitleaks.toml`
as a `refresh` artifact. What it cannot close is `ci.yml` itself.

The analysis is already written in `docs/CI-PROMOTION.md` §*Recommendation* and the
PORTABLE/PER-REPO split it draws; this ADR **cites** it rather than re-deriving it.
In short: a `ci.yml` is **~60% portable scaffolding + ~40% per-repo run-commands
interleaved in one file** (trigger split / concurrency / gitleaks token+permissions /
the de-injected `notify-on-red` block are portable; the test/build/lint commands and
service containers are authored per stack). **No existing manifest class fits**, because
every class assumes single-owner-per-file and CI violates that:

- **`refresh`** overwrites unconditionally → it would clobber the per-repo run-commands
  on every `swarm-sync`. Unacceptable.
- **`seed`** writes once and never again → a later fix to the portable scaffolding never
  reaches already-stamped repos. That is barely better than the per-repo doc — it defeats
  the point of stamping.
- **`compose`** concatenates **fixed** template sources; the per-repo half of `ci.yml` is
  **authored per stack**, not a fixed fragment, so compose cannot express it.

The single-owner-per-file invariant the whole manifest is built on is exactly what a
partially-portable file breaks.

## Decision

**(PROPOSED — not implemented.)** Introduce a new manifest behavior class —
**`managed-block`** (a fragment-merge class). `swarm-lib.sh` gains
`manifest_apply_managed_block`, which owns a **marker-delimited region** of a target
file and leaves everything outside the markers repo-owned. The portable `ci.yml`
scaffolding (trigger split, `concurrency`, the gitleaks token + `permissions` block,
the de-injected `notify-on-red`) lives inside a `# >>> swarm-managed … / # <<< swarm-managed`
region that sync re-writes from the template; the per-repo run-commands and service
containers live outside it and are never touched. This makes the portable half
swarm-owned and re-fixable on sync while the per-repo half stays local — the only
class that can express a partially-portable file.

## Reversibility & cost of change

One-way once it spreads. The class itself is a localized addition to `swarm-lib.sh`
(`manifest_apply_managed_block` + a dispatcher case), but the moment it is used, two
things become interface: (1) the manifest **contract** every archetype's `manifest.tsv`
and the three apply paths (init / sync / onboard) share now has another class others
will reach for; (2) a **managed-region marker convention** gets stamped into real files
across every repo that adopts it. Backing it out means stripping markers from N repos'
`ci.yml` (and any other managed-block targets) and removing a class consumers may depend
on — a migration, not a local edit. That irreversibility is precisely why it is an ADR
rather than a routine manifest addition (contrast Option 1, which adds one fully-portable
file under the existing `refresh` class — a two-way door, no ADR).

## Consequences

- **Easier:** the portable CI scaffolding becomes propagate-and-re-fixable like
  `CLAUDE.md` and the hooks; a later fix to the trigger split / gitleaks wiring reaches
  every stamped repo on the next sync; the 8.24.3-class footgun stops being hand-copied.
- **Harder / the honest costs:** a new behavior class is new surface on the most
  load-bearing contract in the system — every `manifest_apply_*` path, the manifest
  parser, and the three stamp entrypoints must stay coherent with it, and it must be
  tested against init/sync/onboard the way the existing classes are. Marker drift
  (an edited or deleted marker in a repo) becomes a new failure mode the apply path must
  handle (refuse? re-insert? warn?), analogous to the `git-hook` foreign-marker logic.
  A managed region inside a file the repo also edits invites merge-adjacent confusion if
  a repo author edits near the markers.
- **Committed to:** once any repo carries managed-block markers, the convention and the
  class are an interface — see Reversibility.

## Alternatives considered

- **Status quo — per-repo doc, hand-copy (`docs/CI-PROMOTION.md`).** Rejected as the
  long-term answer: every repo re-copies the portable half and re-acquires its footguns
  (the press work copied the gitleaks subtlety three times). Acceptable only as the
  interim contract it currently is.
- **Option 1 alone — stamp `.gitleaks.toml` (`refresh`), leave `ci.yml` per-repo.**
  Implemented in this batch. It is **complementary, not a substitute**: it propagates the
  fully-portable file but leaves `ci.yml`'s portable scaffolding hand-copied. It closes the
  most error-prone copy without touching the split-ownership problem this ADR exists for.
- **Force `ci.yml` into an existing class (`refresh`/`seed`/`compose`).** Rejected — each
  fails as shown in *Context*; they all assume single-owner-per-file.

**Status: PROPOSED — the operator rules.** Do not add the class, do not touch
`swarm-lib.sh`, do not stamp any `ci.yml` until this is accepted.
