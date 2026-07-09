---
name: data-migrations
description: Data-migration playbook — the expand-contract pattern (expand → migrate → switch reads → contract), batched idempotent backfills, at-scale online schema-change patterns (never lock a huge table, never load all rows into memory), and test-on-a-copy discipline. Invoke when planning, writing, or reviewing a schema/data-shape change or a backfill. This is the on-demand concretion of CLAUDE.md §Data migrations, whose SAFETY FLOOR still governs and stays on the always-loaded floor: migrations are versioned/tested with a tested rollback, tested on a copy never real data, agents run them against dev/local ONLY (a prod migration is operator-only, no agent process runs one against prod), and a destructive/irreversible migration DESIGN is grave and needs operator approval before commit. It is on-demand, NOT a floor: inert (zero context) in a repo with no database / no migrations — output nothing, do not improvise a migration tool.
---

# data-migrations — schema & data-shape migration playbook (on-demand)

This is an **on-demand companion** to the always-loaded doctrine, not a
replacement for it. The **safety floor lives in `CLAUDE.md` §*Data migrations*
and still governs** — only the step-by-step *how* moved here. Where this skill
and `CLAUDE.md` overlap, `CLAUDE.md` wins. Re-read the floor before acting; in
particular these floor rules are **not** relaxed by anything here:

- Migrations are **versioned and tested**, with a **tested rollback** — files
  (numbered/timestamped) the migration tool runs in order, never ad-hoc `ALTER`
  typed against a live database.
- **Test on a copy** — a representative dataset, **never real data**.
- **Agents write and run migrations against dev/local ONLY.** A prod migration is
  **operator-only** — same irreversible-action tier as a `git push` to `main`.
  **No agent process runs a migration against prod**; reasoning toward a
  prod-targeted migration command is a stop-and-escalate.
- A **destructive / irreversible migration design** (drop a column/table, narrow
  a constraint that fails on existing rows, in-place irreversible transform) is
  **grave**: the design itself needs operator approval before commit, even though
  the operator runs it.

## When this skill applies (and when it is inert)
- **Applies** to a repo with a database and a migration mechanism — a
  schema/data-shape change, a backfill, or a review of one.
- **Inert otherwise.** No database, no migrations, nothing to migrate → **produce
  no output, do not improvise a migration tool.** (Same on-demand,
  zero-context-elsewhere posture as `ts-node-stack` / `dead-code-scan`.)

## Expand-contract — the pattern for any data-shape change
Every shape change is **four separate, deployable migrations**, so rollback is
always possible because no step is destructive while live consumers still depend
on the old shape:

1. **Expand** — add the new column / table / index. Reads stay on the **old**
   shape; writes go to **both** old and new.
2. **Migrate** — backfill the new shape from the old in **batched, idempotent**
   passes (see at-scale below).
3. **Switch reads** — readers move to the **new** shape; writes still go to
   **both**.
4. **Contract** — once **nothing** reads the old shape, remove it.

Each step ships on its own; never collapse expand+contract into one destructive
migration against a live system.

## At scale (large tables / large backfills)
The `§Error handling` at-scale requirements (idempotency, resumability, per-item
status, streaming) apply to a migration like any batch op — for the at-scale
batch-op detail see the **`at-scale-ops` skill**. Migration-specific:

- **Never `ALTER` a huge table in a way that locks it.** Use online
  schema-change tooling where available (e.g. `pg_repack`, `gh-ost`/`pt-osc`-style
  online changes, or the DB's native concurrent index build) so the table stays
  writable.
- **Never load all rows into memory.** Backfill in **chunked passes with
  checkpoints** — a stable cursor/key range per batch, each batch idempotent so a
  re-run after a crash is a no-op on completed rows and resumes the rest.
- **A migration that succeeded on 100 rows is not proven for 100M.** Test on a
  representative-sized copy (floor rule), and size the batch / measure the lock
  and load against that copy, not the toy dataset.

## Definition of done for a migration
Everything in `CLAUDE.md` §*Definition of done* still applies. Concretely for a
migration: it's a versioned file with a tested rollback, it ran clean against a
representative copy (never real data), the expand-contract steps are each
separately deployable, at-scale passes are batched/idempotent/resumable, and any
destructive/irreversible design was operator-approved before commit. A migration
typed ad-hoc against a live DB, or run by an agent against prod, is a floor
violation — not a successful run.
