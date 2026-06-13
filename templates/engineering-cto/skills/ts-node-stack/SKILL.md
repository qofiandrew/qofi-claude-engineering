---
name: ts-node-stack
description: Stack playbook for TypeScript/Node services on BullMQ + Drizzle + Postgres — concrete conventions for queues, migrations, schema ownership, testing (vitest), and tsconfig. Load when implementing or reviewing TS/Node code on this stack. This is the stack-specific concretion of the always-loaded doctrine (CLAUDE.md), which still governs; it is intentionally an on-demand skill, not a floor, so it costs no context in repos whose stack doesn't match.
---

# ts-node-stack — TypeScript/Node + BullMQ + Drizzle + Postgres playbook

This is an **on-demand companion** to the always-loaded doctrine, not a
replacement for it. Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins;
this file only adds the stack-specific *how*. It is a starting playbook — the CTO
pins exact versions and repo-specific choices in `PROJECT_SPEC.md` / ADRs and may
extend it as the repo's conventions settle.

## TypeScript / Node
- **`strict` on, always.** `tsconfig.json` runs `"strict": true` (plus
  `noUncheckedIndexedAccess`, `noImplicitOverride`). A new repo never starts
  loose "to move fast" — retrofitting strictness later is the expensive path.
- **ESM, `NodeNext` resolution.** `"module": "NodeNext"`, `"moduleResolution":
  "NodeNext"`; import with explicit extensions where the resolver needs them.
- **Validate at the edge, trust inside.** Parse external input (HTTP bodies, queue
  payloads, env) at the contract surface with a schema validator (e.g. `zod`);
  inside the validated boundary, trust the type — don't re-check (`CLAUDE.md`
  §*Error handling* "don't handle impossible states").
- **No `any` at contract surfaces.** An `any` crossing a module boundary defeats
  the one-contract-surface rule (`CLAUDE.md` §*Modular design*). Use `unknown` +
  a narrowing parse instead.

## Testing (vitest)
- **vitest is the runner**; `.claude/test-cmd` / `CLAUDE_TEST_CMD` resolves to the
  suite the test-gate runs. Keep it green — the gate blocks done on red.
- **Apply the four-case mocking policy** (`CLAUDE.md` §*Testing strategy*) on this
  stack:
  - In-repo collaborator, cheap → use the real thing.
  - External API (Stripe, Resend, QBO, …) → `vi.mock` at the contract boundary,
    payloads mirroring the provider's real shapes.
  - Heavy substrate (a real Postgres/DDL cascade across unrelated suites) → mock
    the contract module, not the DB, to avoid the substrate sweep.
  - Not-yet-built internal dep → temporary mock, replaced when the module lands.
- **TDD by default** (`CLAUDE.md` §*Test-driven by default*): the failing test
  lands before the implementation for feature work.
- Prefer testing **through the contract surface**, not internals; if a unit can't
  be tested without spinning up an unrelated peer, the boundary is leaky.

## BullMQ (queues)
- **A queue/topic IS a contract surface** (`CLAUDE.md` §*Modular design*). Document
  the job name, payload shape, and idempotency key in `modules/<module>.md` —
  producers and consumers depend on it.
- **Jobs are idempotent and resumable** (`CLAUDE.md` §*Error handling* at-scale
  rules): reprocessing a completed job is a no-op; a job that dies mid-run resumes
  without redoing work. Carry a stable `jobId` / dedup key.
- **Per-item failure isolation**: one bad message is logged compactly (`WARN`,
  aggregated) and skipped — it never aborts the worker. Use a DLQ /
  `attempts` + backoff; surface the per-run summary.
- **Adding** a job type or queue is additive/safe; **changing** an existing
  payload's shape is a breaking contract change → CTO sign-off (`CLAUDE.md`
  §*Backward compatibility*).

## Drizzle + Postgres
- **Single-owner tables** (`CLAUDE.md` §*Data ownership*): each table is owned by
  exactly one module; only the owner writes it. Peers read via the owner's
  contract surface, never with a cross-module `SELECT` into its tables.
- **Migrations are files, run in order, with a tested rollback** (`CLAUDE.md`
  §*Data migrations*). Use `drizzle-kit generate` to produce a numbered migration;
  commit it. Never hand-type `ALTER` against a live DB.
- **Expand–contract for any shape change** — add column → backfill (batched,
  idempotent) → switch reads → drop old, each a separate deployable migration.
- **Agents run migrations against dev/local only.** A prod migration is
  operator-only (`CLAUDE.md` §*Data migrations* — same tier as a `main` push).
  Destructive/irreversible migration *design* needs operator approval before
  commit, even though the operator runs it.
- **Test migrations on a representative copy**, never real data; "worked on 100
  rows" isn't proven for 100M.

## Observability (this stack)
- Structured logs (`pino` or equivalent), JSON, correct levels; per-item failures
  are `WARN` + aggregated, not `ERROR` per item (`CLAUDE.md` §*Logging &
  observability*). Carry a run-id across a batch; emit a per-run summary.
- Never log secrets/PII — token, key, raw user content (`CLAUDE.md` §*Secrets*).

## Definition of done on this stack
Everything in `CLAUDE.md` §*Definition of done* still applies. On this stack that
concretely means: vitest green, the queue/table/endpoint you touched documented in
`modules/<module>.md`, migrations committed with a tested rollback, operability
(rerun/resume/status) built for any at-scale worker, and the six `[DoD-*]`
affirmations in the task-closing commit.
