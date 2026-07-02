
## Source-of-truth mode: EXTERNAL-CANON (this repo)

This repo runs in **external-canon mode** (`.claude/canon-mode` = `external`).
A sibling/external **product repo owns the normative product canon** — its
ADRs / decision records, requirements ledger, and live technical architecture.
This implementation repo holds the **executable reality** (code + tests) and
**scoped projections** of that canon (module docs), never canon itself. The
concrete binding — canon repo path, product path, and normativity statement —
is the *Canon binding* section at the end of this manual, mirrored in
`docs/CANON_SYNC.md`.

The local-canon rules earlier in this manual (§*Source of truth
(local-canon)*) are **qualified** here, not repealed:

- `PROJECT_SPEC.md` and module docs remain the best in-repo statement of how
  the *implementation* behaves now — read them first, exactly as before.
- But they are **projections**: where a module doc, the spec, code, or a test
  disagrees with external canon, **external canon wins**. Code and tests are
  executable reality — they prove what the system *does* — but they **never
  legalize a canon violation**; a passing test of canon-violating behavior is
  a defect with a green checkmark.
- The in-repo ADR rules are unchanged for *implementation-local* one-way doors
  (this repo's `docs/adr/`). **Product-level** one-way doors belong to the
  canon repo's decision process, not here — do **not** author product ADRs in
  this repo, and do **not** duplicate canon ADR text into this repo; cite it.

**Agent routing rule (read in this order):**
1. the module's scoped docs (`docs/modules/<module>/`, starting at README) —
   plus `docs/MODULE_INDEX.md` to find the module;
2. the **cited canon** those docs point to (`CANON_MAP.md` citations into the
   canon repo — read the cited sections, not the whole canon);
3. code and tests, to confirm executable reality.

Never start from a global grep of the canon repo; `CANON_MAP.md` exists so a
scoped question ("access control only") is answered by one module pack plus
its citations.

## External canon sync

`docs/CANON_SYNC.md` is the sync contract between the two repos. It MUST name:

- **Canon repo** (absolute or repo-relative path) and **product path** within
  it;
- **Canon commit** — the canon-repo commit this implementation is currently
  synced against;
- **Implementation commit** — the last implementation commit reviewed against
  that canon commit;
- the normativity statement (canon repo ADRs / requirements / live technical
  architecture are normative; this repo's module docs are projections).

Rules:

- **Advance the sync point deliberately.** When new canon lands (new ADRs, a
  live-architecture change), a sync pass updates module `CANON_MAP.md`s and
  `OPEN_GAPS.md`s, then advances the canon commit in `CANON_SYNC.md`. Stale
  sync metadata is a validation failure, not a style issue.
- **Conflict rule (restated as the hard order):** external canon → module
  docs → code/tests. Walk *upward* on disagreement; never silently make a
  lower layer win.
- **Drift rule.** An implementation discovery that contradicts or exceeds
  canon is **classified, then routed upstream — never absorbed silently**:
  1. classify it using the canon repo's governance classes (editorial /
     propagation-only / schema-detail / implementation-choice / semantic
     [ADR-required] / conflict);
  2. record it in the owning module's `OPEN_GAPS.md`;
  3. ADR-required and conflict classes are **also** recorded in the root
     `docs/GAP_LEDGER.md` and escalated so the canon/spec repo gets patched
     (per that repo's propagation process);
  4. only after canon is patched does the implementation change that depends
     on it land. Emergency/security containment may patch first — the ADR and
     ledger entries follow immediately.

## Scoped module documentation

Each src module carries a **scoped doc pack** at `docs/modules/<module>/`:

- `README.md` — what the module is, one screen; entry point of the pack.
- `CANON_MAP.md` — which canon sections/ADRs govern this module, cited by
  path + anchor/ID. This is the scoping mechanism: it replaces global grep.
- `INTERFACES.md` — contract surfaces offered/required (complements the
  existing `modules/<module>.md` contract doc, which stays authoritative for
  OFFERS/REQUIRES; INTERFACES adds canon citations per surface).
- `INVARIANTS.md` — the module's canon-derived invariants. **Every invariant
  entry (`- INV-…`) MUST carry either `tests:` (a real test path) or `gap:`
  (an explicit GAP id)** — untested-and-unacknowledged invariants fail
  validation.
- `OPEN_GAPS.md` — known drift/gaps, classified per the drift rule. Entries
  tagged `[adr-required]` MUST also appear in root `docs/GAP_LEDGER.md`.
- `TEST_MAP.md` — where this module's behavior is tested (real paths).
- `CODE_MAP.md` — where this module lives in `src/` (real paths).
- `LIFECYCLE.md` — where applicable (modules with stateful lifecycles).

Root docs binding the packs together:

- `docs/MODULE_INDEX.md` — the routing table: module → pack → one-line scope.
- `docs/TRACEABILITY_LEDGER.md` — canon requirement → module(s) → tests, for
  cross-module traceability.
- `docs/GAP_LEDGER.md` — the root roll-up of ADR-required / conflict gaps.

These packs are **projections** — they cite canon, they never restate it as
if locally owned, and they never fork it. Keeping them current is DoD-3 work:
a change to a module's code lands with its pack updated, same commit.

**Validation (mechanical, external-canon mode only).** The `canon-check` hook
fails task completion when: `docs/CANON_SYNC.md` is missing or lacks the sync
metadata above; a src module has no doc pack; `CODE_MAP.md`/`TEST_MAP.md`
reference paths that don't exist; an `INVARIANTS.md` entry lacks both `tests:`
and `gap:`; or an `[adr-required]` gap in a module `OPEN_GAPS.md` is absent
from `docs/GAP_LEDGER.md`. In local-canon repos the hook exits 0 untouched.
