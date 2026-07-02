# Source-of-truth modes: local-canon vs external-canon

Every stamped engineering-cto swarm runs in exactly one **source-of-truth
mode**, declared by the `.claude/canon-mode` marker in the swarm repo:

| Marker | Mode | Who it's for |
|--------|------|--------------|
| absent / `local` / anything else | **local-canon** (default) | ordinary self-contained repos |
| `external` | **external-canon** | products whose normative product canon lives in a sibling/external product repo |

The axis is orthogonal to swarm type and profile, and follows the same
no-op-default posture as `.claude/swarm-profile` (ADR-0013): a markerless repo
composes and validates **byte-identically** to a pre-canon-mode swarm.
Backward compatibility for existing swarms is that default, not a migration.

## When to use which

**Local-canon (default).** The repo is its own product: `PROJECT_SPEC.md` and
`modules/<module>.md` are the current source of truth; ADRs are the dated
"why" archive unless explicitly promoted. This is the doctrine ordinary
swarms have always had — nothing changes.

**External-canon.** Use it when a product repo (e.g.
`qofi-product/products/<product>`) owns the normative canon — ADRs/decision
records, a requirements ledger, a live technical architecture — and the
implementation repo is a *projection* of that canon. Signals you need it:

- product decisions are made (and recorded) outside the implementation repo;
- the implementation repo's docs keep restating (and drifting from) product
  docs;
- "what is true" questions require reading two repos.

In external-canon mode the in-repo living docs remain the best statement of
*implementation* behavior, but **external canon wins** over module docs, code,
and tests on any disagreement. Code/tests are executable reality — they never
legalize a canon violation.

## How a CPO/CTO enables it

```
bin/swarm-canon-enable.sh <impl-repo> --canon <canon-repo-or-product-path> \
    [--product-path <path-within-canon-repo>] [--modules "m1 m2"]
bin/swarm-sync.sh <swarm-name>      # recompose CLAUDE.md with the overlay
```

The enable script writes the marker, seeds `.claude/canon-binding.md` (the
repo-specific binding: canon repo path, product path, normativity statement —
composed into CLAUDE.md as its final section), and seeds the root docs +
per-module packs (write-if-absent, never clobbering). The sync recomposes
CLAUDE.md as: preamble + `_base` + engineering-cto + (profile overlay) +
`canon/CLAUDE.external-canon.md` + the repo's `.claude/canon-binding.md`.

## What external-canon mode stamps and enforces

Root docs (seeded by the enable script):

- `docs/CANON_SYNC.md` — the sync contract: canon repo + product path,
  **canon commit** synced against, **implementation commit** last reviewed,
  sync date + log.
- `docs/MODULE_INDEX.md` — routing table module → pack → one-line scope.
- `docs/TRACEABILITY_LEDGER.md` — canon ref → module(s) → tests roll-up.
- `docs/GAP_LEDGER.md` — root roll-up of ADR-required / conflict gaps.

Per-module packs at `docs/modules/<module>/`: `README.md`, `CANON_MAP.md`,
`INTERFACES.md`, `INVARIANTS.md`, `OPEN_GAPS.md`, `TEST_MAP.md`,
`CODE_MAP.md`, plus `LIFECYCLE.md` where the module has a stateful lifecycle
(the one optional member; add it by hand from
`templates/engineering-cto/canon/module/`).

**Module docs vs canon.** The packs are *projections*: they **cite** canon
(`CANON_MAP.md` rows point at canon-repo paths/ADR ids) and never restate or
duplicate it as if locally owned. Canon ADR text is never copied into the
implementation repo; the flat `modules/<module>.md` contract docs
(OFFERS/REQUIRES) are unchanged and stay authoritative for contract detail.

**Enforcement** is the `canon-check` TaskCompleted hook (stamped to
`.claude/hooks/canon-check.sh`, wired in settings; a guaranteed no-op in
local mode). It blocks completion when: `CANON_SYNC.md` is missing or carries
placeholder/absent sync metadata; a `src/` module lacks its pack;
`CODE_MAP.md`/`TEST_MAP.md` cite paths that don't exist; an `INVARIANTS.md`
entry has neither `tests:` nor `gap:`; an `[adr-required]` gap is missing
from `docs/GAP_LEDGER.md`; or a root ledger is absent.

**Drift routing.** An implementation discovery that contradicts/exceeds canon
is classified (using the canon repo's governance classes), recorded in the
module's `OPEN_GAPS.md`, rolled up to `docs/GAP_LEDGER.md` when ADR-required,
and escalated so the **canon repo** gets patched. The implementation never
silently becomes the source of truth.

## Scoped reviews without global grep

To review one concern (e.g. "access control only"):

1. `docs/MODULE_INDEX.md` → find the owning module(s);
2. the pack `README.md` → `CANON_MAP.md` → read only the **cited** canon
   sections;
3. `INVARIANTS.md` + `TEST_MAP.md` → what must hold and where it's proven;
4. `CODE_MAP.md` → the exact source files.

No step greps the canon repo or the whole tree; if routing fails, that's an
index/pack defect to fix (same posture as the manifest `covers` map), not a
license to grep wide.

## First instance

`/Users/aschettino/qofirepos/deployment-core` (canon:
`/Users/aschettino/qofirepos/qofi-product/products/deployment-core`) is the
first external-canon swarm and the reference example.
