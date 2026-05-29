## Source of truth
- `PROJECT_SPEC.md` and the ADRs in `docs/adr/` are authoritative **once they
  exist**. On a new project the spec may be empty or absent — the CTO authors it
  from the design conversation as the first build step (see `TEAM_LEAD.md`). Docs
  are an output of the build, not a prerequisite to it. Once authored, if a
  request contradicts the spec, that's an escalation, not a silent reinterpretation.

## Decisions
- Follow `ESCALATION.md`. Default to action. Decide two-way doors yourself with
  your best judgment — don't ask. Escalate one-way doors, scope (v1 vs v2), and
  spec contradictions.
- Every one-way-door decision becomes an ADR (`ADR.template.md`), whether or not
  it was escalated.
- **Reversible technical ambiguity → proceed and record the assumption; don't
  block.** Where a *technical* point is ambiguous and the call is reversible /
  safe-to-be-wrong, decide, proceed, and append a one-line assumption record —
  **path touched · what was assumed · why · what would falsify it** — to your
  task's commit summary (or task notes). No global `ASSUMPTIONS.md`; the record
  is per-task and append-only, and the CTO folds it into the build log at
  integration (`TEAM_LEAD.md` §*Docs reflect reality*). The *what-would-falsify-it*
  field is mandatory: it is the tripwire that lets a later reader — or the CTO at
  integration — see the assumption was wrong without re-deriving it.
- **This is NOT a consent mechanism.** It applies *only* to reversible technical
  calls. Anything grave or irreversible does **not** get an assumption note — it
  **escalates**: halt that track and wait for an actual answer, no timer, no
  "proceeding unless you object" (`ESCALATION.md` §*No silence-as-consent, no
  countdown defaults* and the ESCALATE/NOTIFY split in §*How to escalate*).
  Silence is never consent. A contradiction with doctrine or the spec surfaces
  per `§Conflict handling` — it is never absorbed into an assumption record.

## Verification (non-negotiable)
- Tests are part of the feature, not a follow-up. Write them as you build.
- CI must be green before merge. Never merge red. Never weaken or delete a test to
  make a build pass — that's a regression, escalate instead.
- Before declaring done or escalating, self-review the work against the spec's
  scope (§3) and acceptance criteria (§4).

## Testing strategy (mocking policy)

The over-engineering trap this section exists to prevent: an agent
faces a dependency whose real substrate would force a 100+ test
cascade (DB DDL collisions, transitive injection sweeps, etc.) and
either (a) builds the heavyweight substrate anyway, burning a session
on the wrong problem, or (b) writes a fictional mock to dodge it.
Neither is the answer. The right answer depends on **what kind of
dependency it is.**

**Four cases, decided per dependency at plan-approval:**

1. **Internal in-repo collaborator, cheap to run for real → use the
   real thing.** Default. A module owned in this repo whose setup is
   cheap (a function call, a small in-process collaborator) is tested
   against the real implementation. Mocking what's already cheap and
   in your tree hides integration bugs — the `$HOME`-pollution class
   of failure is exactly what real-collaborator testing catches and
   mocks paper over.

2. **External service (third-party API: Stripe, Insightful, QBO,
   Resend, SES, etc.) → mock at the contract boundary, permanently.**
   Tests must never hit a live external endpoint. The boundary mock's
   request/response shapes mirror the **provider's real payloads** —
   that's how it stays a faithful contract substitute rather than a
   fiction. This is a legitimate, permanent test strategy, not a
   stopgap.

3. **Heavy cross-module substrate → mock at the contract boundary.**
   The signal: wiring the real collaborator into tests would cascade
   into many unrelated test files (DB DDL collisions, transitive test-
   DB injection, a substrate sweep across the suite). That cascade is
   the cue to mock at the contract surface instead. Reserve-backend-2
   commit `3a1762f` is the precedent: wiring `insightful-sync` for-real
   would have triggered a 115-test substrate cascade; mocking the
   contract (`vi.mock("…/insightful-sync/contract.js")`) in the 10
   affected test files was the right call — **0 substrate growth**,
   the consumer module's contract still proven.

4. **Internal not-yet-built dependency → temporary mock, replaced when
   the real module lands.** The **only** mock that is a stopgap. Build
   the depended-on module first (`TEAM_LEAD.md` §*Dependencies and
   integration order*); once it lands, the consumer's tests move to
   the real contract. A temporary mock that outlives the missing
   module is a defect.

**The principle (one line):** mock at the seam, against the real
payload/contract shape. A boundary mock that mirrors the real contract
is a legitimate, permanent test strategy for external and heavy
dependencies — not a workaround.

**Guard against the opposite failure (over-mocking):** don't mock an
internal owned collaborator that's cheap to test for real. The line is
**mock external + heavy-substrate; use real for internal + cheap.**

**Plan-approval gate (CTO).** Which dependencies are mocked vs. real
is decided at plan-approval — agents do not pick this unilaterally,
because that is where the trap lives (either grow the substrate or
fake the dependency). The decision lands in `modules/<module>.md`
under a *Testing notes* subsection: for each declared dependency, real
or boundary-mock, and (for mocks) why — external or heavy. Mid-
implementation re-classification comes back to the CTO.

§Honesty still applies: a boundary mock that mirrors the real contract
shape is not vacuous. A mock that doesn't mirror the real contract —
shaped to whatever makes tests pass — is still gaming the gate and is
the gravest behavioral violation in this manual.

## Working with existing code (work with the grain)
- Match the existing conventions, structure, and patterns of the repo. Consistency
  beats your preferred style.
- Do **not** perform large unrequested refactors. If the existing structure is
  genuinely blocking the work, propose the refactor as an escalation with scope and
  rationale — don't just do it.

## Greenfield
- Build v1 scope only. Resist premature architecture and gold-plating. Deferred
  (v2+) items are listed in the spec for a reason — don't pre-build them.
- The exception: if you think something belongs in v1 that the spec defers (or
  vice versa), that's a scope escalation — I sometimes want more in v1.

## Modular design
- **Single responsibility.** A module does one thing. If you can't state its
  job in one sentence, it's two modules — split before you build.
- **One contract surface.** Each module exposes exactly one defined contract
  — the agreed way other modules interact with it. The surface can be a
  function/API (sync), a queue/topic/event the module publishes or consumes
  (async), or an internal network interface — all equally valid. "Contract
  surface" ≠ "public/internet endpoint": internal-only is the common case.
- **Document it** in `modules/<module>.md` per module: what it OFFERS (the
  contract surface, fully specified) and what it REQUIRES (every contract
  surface from other modules it consumes).
- **Depend only on contract surfaces, never on internals.** If you find
  yourself reaching into another module's internal file, function, or
  table, the boundary is wrong — escalate.
- **Dependencies point one direction.** No cycles. If A needs B and B needs
  A, the boundary is wrong; surface the shared concern into a third module
  or fix the split. Don't paper over it.
- **Independently testable through the contract.** If you can't test a
  module without spinning up an unrelated peer, the contract is leaky.
  Where the collaborator is external or its real substrate is heavy,
  use a boundary mock that mirrors the real contract (per
  §*Testing strategy*) — that is testing **through** the contract, not
  around it.
- **Where tooling can enforce, use it** — explicit exports, private-by-
  default, import-boundary lint rules. Where tooling can't, the CTO
  verifies boundary-respect at plan-approval and at review.

## Data ownership
- **Default: shared database, single-owner tables.** Each table/schema is
  owned by exactly one module. Only the owner writes it. Other modules
  read via the owner's contract surface — never by touching its tables
  directly. A `SELECT` against a peer module's table is the data-layer
  equivalent of reaching into its internals.
- **DB-per-service is an exception, not a default.** Use it only when a
  module has a *concrete* operational need: independent scaling,
  replicas, isolation, or independent deploy/availability. The CTO
  authors an ADR per-module that names the real need; "feels cleaner"
  doesn't count.
- **When separated**, the ADR states the cross-service read pattern
  (API-call for simple reads, event-driven local read-copy for hot
  paths) and flags any cross-service atomicity need as an explicit
  design problem to solve. Eventual consistency is the accepted cost of
  separation; do not invent implicit cross-service distributed
  transactions.

## Backward compatibility

Contract changes are deliberate and CTO-approved, never incidental.
Default to **additive** — adding to a contract is safe; changing or
removing existing behavior is breaking.

- **Adding** a field, endpoint, event type, or queue topic: safe; ship it.
- **Changing** an existing field's shape, semantics, or default: breaking;
  needs CTO sign-off (per `ESCALATION.md` agent → CTO triggers).
- **Removing** an existing field, endpoint, or event: breaking; same gate.

**In-repo breaking change**: landed **atomically** — the contract change
and every consumer's adaptation are in the same coordinated landing. No
broken intermediate state where consumers still expect the old shape.
The CTO sequences this (see `TEAM_LEAD.md` §*Dependencies and integration
order*).

**Separated-service breaking change** (the `§Data ownership` DB-per-service
exception, or any service the project doesn't atomically deploy): requires
a **versioning / deprecation path** — old and new contracts coexist,
consumers migrate, old is retired. Atomic landing isn't possible across
deploy boundaries.

**Explicit interface versioning** (e.g. `v1`/`v2` prefixes, schema
versions) is required for separated services. For in-repo modules,
versioning adds ceremony without value — don't introduce it.

## Data migrations

- **Versioned and tested**, with a tested rollback. Migrations live as
  files (numbered or timestamped) the project's migration tool runs in
  order — never as ad-hoc `ALTER` typed against a live database.
- **Expand-contract pattern** for any data-shape change:
  1. **Expand** — add the new column / table / index. Reads still go
     to the old shape; writes go to both.
  2. **Migrate** — backfill the new shape from the old in batched,
     idempotent passes.
  3. **Switch reads** — readers move to the new shape; writes still go
     to both.
  4. **Contract** — once nothing reads the old shape, remove it.
  Each step is a separate, deployable migration. Rollback is always
  possible because no step is destructive while live consumers depend
  on the old shape.
- **Test on a copy** — representative dataset, never real data. A
  migration that succeeded on 100 rows of test data isn't proven for
  100M.
- **At scale** — never `ALTER` a huge table in a way that locks it, and
  never load all rows into memory. Use batched / online migration
  patterns (chunked backfill with checkpoints, online schema-change
  tools where the database has them). The `§Error handling` at-scale
  hard requirements (idempotency, resumability, per-item status,
  streaming) apply to the migration the same as any other batch op.
- **Agents write and run migrations against dev/local only.** Running
  a migration against production is operator-only — same hard-floor
  tier as `git push` to `main`. **No agent process ever runs a
  migration against prod** — not via Bash, not via a hook, not via a
  tool, not via the migration tool's own runner. If you find yourself
  reasoning toward a prod-targeted migration command, stop and escalate.
- **Destructive or irreversible migration design** (drop a column, drop
  a table, narrow a constraint that fails on existing rows, in-place
  irreversible data transform) is **grave**: the design itself needs
  operator approval before commit, even though the operator runs it.

## Error handling
Distinguish two error classes; treat them differently.

- **Fatal / systemic** — invalid config, dependency unreachable, auth failed,
  contract violated. **Fail fast, fail safe.** Default to deny/stop, never
  permissive. Surface immediately with full context (the inputs, source
  location, cause). Don't start or continue a doomed run.
- **Per-item** — one file/record/row in a batch fails. **Isolate, log
  compactly (id + error class + one-line reason), continue the batch.** A
  single bad item never aborts the whole job. Aggregate failures into an
  end-of-run summary: counts, failures by category, list of failed ids
  for retry.
- **Never silently swallow errors.** No empty `catch`, no ignored return
  codes, no `try { ... } catch {}` that drops the cause.
- **Never silently leave corrupt or half-written state.** A failed item is
  marked failed and skipped — not partially written.
- **Validate at contract surfaces.** Don't trust callers. Garbage in at
  the boundary becomes garbage at the storage layer.

**Hard requirements for at-scale data operations** (CTO verifies these are
in the plan before approval):

- **Idempotency.** Re-running is safe; reprocessing a completed item is
  a no-op. The job survives a half-finished kill.
- **Resumability / checkpointing.** A job that dies mid-run resumes from
  the last checkpoint without redoing completed work.
- **Per-item status tracking.** Retries touch only the failures; a
  "retry" that re-runs the whole job is a defect.
- **Stream, don't slurp.** Never load the entire dataset into memory.
  Batch with explicit page/cursor; respect backpressure and provider
  rate limits.

A batch operation lacking these is broken, not stylistically different.
The test for "at scale" is "could this run against millions of items" —
if yes, the four hard requirements are non-negotiable.

## Logging & observability
- **Structured logs only** — JSON or key=value, never freeform `print` /
  `console.log` strings concatenated together. Logs at volume must be
  queryable and aggregatable.
- **Use levels correctly.**
  - `ERROR` — needs attention; a human will look at this.
  - `WARN`  — recoverable / degraded; aggregated, not flooded.
  - `INFO`  — lifecycle milestones (job start, job end, phase change).
  - `DEBUG` — off in normal operation; on only when diagnosing.
- **Per-item failures are `WARN` and aggregated, not `ERROR` per item.**
  A million-row job with 0.1% failure is 1,000 entries — `ERROR` per
  item is a log explosion that buries the real signal.
- **Never log secrets or PII.** Token, key, password, email, address,
  raw user content — none of it goes into logs. (See `§Secrets`.)
- **Correlation IDs.** A batch run has a run-id; every item in that run
  carries the same run-id (plus its own item-id). One job's behavior
  is traceable end-to-end across whatever services it touches.
- **Per-run summary** — at job end, emit one summary entry: counts
  (total / success / failure), failure breakdown by category, duration,
  throughput. This is the artifact ops looks at first.

**Hard requirement**: structured logs + correct levels + run-IDs + per-run
summary, on every at-scale job. Bigger observability infrastructure —
dashboards, distributed tracing, metrics pipelines — is a CTO escalation
when the operation warrants it, not a default. But traceability and the
per-run summary are floor, not ceiling.

## Operability
Every at-scale tool or module ships its **support controls as part of
being done** — built per-module while context is fresh, not deferred to a
later sweep that never comes. The form (CLI / API / admin surface) is the
CTO's call per module; what's non-negotiable is the substrate.

- **Operator tier**: rerun (failed items or whole job), resume from
  checkpoint, query run/item status, manual intervention (skip a poison
  item, force-complete, requeue, replay a range). All of this rides on
  the `§Error handling` idempotency + checkpoint + per-item-status
  requirements — they exist *so* this tier is possible.
- **Customer-support tier**: a surface where support can look up a
  customer's or item's current state and its failure reason, and
  manually fix or reinstate a stuck flow — so support resolves customer
  issues without paging engineering.
- **Audit (hard requirement from day one)**: every support-tier manual
  intervention writes an audit entry — who acted, on whose data, when,
  why. Even while access is developer-only, the audit log is built in
  *now*. Retrofitting audit later is much harder than building it in.
- **Bulk-scope default is single-customer / single-item.** Bulk actions
  (replay 10,000 items, force-complete a range) are operator/CTO
  actions. Soft guideline now; becomes a hard requirement when real
  user or support access lands.
- **Future-proof for an authz layer.** User access, roles, and
  permission enforcement are a known future addition. Build admin and
  support surfaces so an authz layer can be added in front of them
  later — don't hardcode wide-open access. Do **not** build the
  permission system now unless the spec calls for it.

## Scope & branches
- **Stay in your app.** In a monorepo, your writes are scoped to `apps/<app>/`
  (or the repo root for a single-app repo). Don't touch sibling apps. If your
  work genuinely needs a cross-app change, that's a CTO call — escalate.
- **Work in your own worktree, on your own branch.** The CTO created
  `.claude/worktrees/<your-name>/` on branch `worktree-<your-name>` for
  you. All your commits land there. If you find yourself in an empty or
  missing worktree at session start, that is a CTO provisioning gap —
  surface it, do not bootstrap silently and do not land work in the wrong
  tree (`§Conflict handling`).
- **Never commit directly to the integration branch `dev`** (nor to
  `main`). The CTO owns merges from `worktree-<name>` branches into `dev`.
  Parallel commits in separate worktrees are fine; parallel merges are
  not — that's why merging is centralized on the CTO.
- **Push your `worktree-<name>` branch to remote only with CTO approval.**
  Don't push on your own. Pushes of `dev` are the CTO's call.
- **Pushing to `main` is operator-only.** Not even the CTO authorizes a main
  push; the operator runs it themselves. **No agent process ever executes
  `git push` to `main`** — not via Bash, not via a hook, not via a tool. If
  you find yourself reasoning toward a main-push command, stop and escalate.
- Descriptive commits. Don't bundle unrelated changes.

## Documentation
- Keep docs current as you go — README, API docs, and the spec's architecture
  section. Stale docs are a defect.
- Maintain the build log in `PROJECT_SPEC.md` §10 as you work.

## Dependencies

External third-party libraries are a long-term commitment — security
surface, transitive bloat, abandonment risk. Each one is a deliberate
decision.

- **New external dep needs CTO approval.** Where possible, the
  plan-approval step declares the intended deps and the CTO approves
  the set up front. A mid-implementation switch or new dep also goes
  back to the CTO (not the operator).
- **Prefer stdlib and existing deps.** Don't add a library for what's
  already available — the existing tools are already in the bundle,
  already audited, already understood.
- **Justify every dependency.** "It looked convenient" is not a
  justification. The plan / commit message names what the dep does
  and why stdlib or an existing approach won't.
- **Pin versions.** Commit the lockfile (`package-lock.json`,
  `bun.lock`, `Cargo.lock`, `poetry.lock`, etc.). Reproducible builds;
  no floating versions; no surprise upgrade between sessions.
- **CTO sanity-checks new deps** at approval — maintained (recent
  commits), not abandoned, no known critical vulnerabilities. License
  vetting is deferred for now.

## Definition of done

A module or task is **done** only when **every** item below is true.
The agent self-affirms items 1–6 in the commit summary; the CTO
verifies all seven at review (see `TEAM_LEAD.md` §*Lead review of
teammate output*). "The code works" is not done. An agent claiming
done without addressing an item is an immediate flag.

1. **Contract satisfied.** Does what `modules/<module>.md` promises,
   input-to-output. Internal in-repo collaborators tested for real;
   external services and heavy substrates exercised via boundary mocks
   that mirror the real contract shape, per §*Testing strategy*. Never
   a mock the agent invented to dodge a real-but-cheap collaborator.
2. **Tests pass.** Agent's unit + integration suite green.
   Mechanically enforced by the `TaskCompleted` hook.
3. **Docs current.** Module doc + affected architecture/API docs are
   accurate and committed with the code. Mechanically enforced by
   the `TeammateIdle` hook.
4. **Operability built.** Per `§Operability` — operator-tier controls
   (rerun / resume / status / manual intervention) and customer-
   support-tier controls (per-item lookup + manual fix/reinstate)
   exist and work, with audit logging from day one.
5. **Scale rules met (if at-scale).** Per `§Error handling` and
   `§Logging & observability` — idempotent, resumable, per-item
   status tracked, fails safe on fatal / continues on per-item,
   structured logs with correlation ids, per-run summary.
6. **No silent conflicts.** Any contradiction between the work and
   the spec, an ADR, a contract another module depends on, or any
   other piece of doctrine has been surfaced per `§Conflict
   handling` — not silently resolved.
7. **CTO-reviewed.** Plan was approved, summary verified against the
   contract, CTO accepted. The CTO marks done after review, not the
   agent on its own claim.

Items 2 and 3 are mechanically enforced by hooks. Items 1, 4, 5, 6
cannot be hook-enforced and depend on the agent's honest affirmation
plus the CTO's review.

### Commit-summary template (required)

Every commit that closes a task ends with this six-line affirmation
block, verbatim format. The `TaskCompleted` hook (`dod-affirm.sh`) scans
your task summary and the HEAD commit message for these lines and blocks
the task from completing if any are missing or malformed. **Restate
them each commit — that is the point.** Re-reading the checklist at
the point of use is what fights context decay over a long session.

```
[DoD-1] Contract: yes | n/a:<reason>
[DoD-2] Tests: yes | n/a:<reason>
[DoD-3] Docs: yes | n/a:<reason>
[DoD-4] Operability: yes | n/a:<reason>
[DoD-5] Scale: yes | n/a:<reason>
[DoD-6] No conflicts: yes | n/a:<reason>
```

Use `yes` when the item is satisfied. Use `n/a:<one-line reason>` when
the item doesn't apply to this task — e.g.
`[DoD-4] Operability: n/a:doc-only change, no module surface`,
`[DoD-5] Scale: n/a:not an at-scale operation`. Bare `n/a` without a
reason is rejected by the hook. **Never `yes` if it isn't true** —
that is the §Honesty violation that corrupts everything downstream.
