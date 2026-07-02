# CANON_SYNC — external-canon binding and sync point

This repo runs in **external-canon mode**. The repo named below owns the
normative product canon; this implementation repo's module docs are scoped
projections of it, and code/tests are executable reality that never legalizes
a canon violation. See CLAUDE.md §*External canon sync*.

## Binding

- **Canon repo:** `<absolute-or-relative-path-to-canon-repo>`
- **Product path:** `<path-within-canon-repo, e.g. products/<product>>`
- **Implementation repo:** `<this repo's path>`

**Normativity:** the canon repo's ADRs / decision records, requirements
ledger, and live technical architecture are **normative canon**. This repo's
per-module doc packs (under `docs/modules/`) are **projections**, not canon.

## Sync point

- **Canon commit:** `<canon-repo commit hash this implementation is synced against>`
- **Implementation commit:** `<last implementation commit reviewed against that canon commit>`
- **Synced:** `<YYYY-MM-DD>`

Advance this block deliberately: a sync pass updates module `CANON_MAP.md` /
`OPEN_GAPS.md` files first, then moves the commits here. Stale metadata fails
the `canon-check` validation gate.

## Sync log

| Date | Canon commit | Implementation commit | Notes |
|------|--------------|-----------------------|-------|
