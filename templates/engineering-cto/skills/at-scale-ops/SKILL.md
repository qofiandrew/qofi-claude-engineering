---
name: at-scale-ops
description: Playbook for at-scale / batch data operations — the four hard requirements (idempotency, resumability/checkpointing, per-item status tracking, stream-don't-slurp), structured logging & observability at volume (JSON logs, correct levels, per-item-WARN-aggregated, correlation/run-ids, per-run summary), and the operability controls a batch tool ships (operator tier: rerun/resume/status/manual-intervention; customer-support tier: per-item lookup + fix/reinstate; audit from day one). Invoke when planning, building, or reviewing anything that could run against millions of items — a batch job, queue worker, bulk import/export, or large backfill. This is the on-demand concretion of CLAUDE.md §Error handling (at-scale block), §Logging & observability, and §Operability; those floor sections keep the DoD hooks (DoD-4 Operability, DoD-5 Scale) and still govern. It is on-demand, NOT a floor: inert (zero context) when the work is not at scale — a single-request handler, a one-off script, a small in-memory transform — output nothing.
---

# at-scale-ops — at-scale / batch-operation playbook (on-demand)

This is an **on-demand companion** to the always-loaded doctrine, not a
replacement for it. The **DoD hooks stay on the floor** and still govern:
`CLAUDE.md` §*Definition of done* item **4 (Operability built)** and item **5
(Scale rules met)** enforce everything below, and §*Error handling* /
§*Logging & observability* / §*Operability* point here for the detail. Where this
skill and `CLAUDE.md` overlap, `CLAUDE.md` wins. This file is only the *how* for
work that is actually at scale.

## When this skill applies (and when it is inert)
- **Applies** when the answer to *"could this run against millions of items?"* is
  yes — a batch job, queue/stream worker, bulk import/export, large backfill, or
  any operation whose volume makes per-item cost and failure matter.
- **Inert otherwise.** A single-request handler, a one-off diagnostic, a small
  in-memory transform that can't grow — **produce no output, don't impose batch
  ceremony on work that isn't at scale.** (Same on-demand,
  zero-context-elsewhere posture as `ts-node-stack` / `dead-code-scan`.) The
  general error-handling classes (fatal-vs-per-item, never-swallow,
  validate-at-boundary, don't-handle-impossible-states) live on the floor and
  apply everywhere; only the *at-scale* requirements are here.

## The four hard requirements (non-negotiable at scale)
A batch operation lacking these is **broken**, not stylistically different. The
CTO verifies they're in the plan before approval (`CLAUDE.md` §*Error handling*):

- **Idempotency.** Re-running is safe; reprocessing a completed item is a no-op.
  The job survives a half-finished kill.
- **Resumability / checkpointing.** A job that dies mid-run resumes from the last
  checkpoint without redoing completed work.
- **Per-item status tracking.** Retries touch only the failures; a "retry" that
  re-runs the whole job is a defect.
- **Stream, don't slurp.** Never load the entire dataset into memory. Batch with
  an explicit page/cursor; respect backpressure and provider rate limits.

These are what make the operability controls below *possible* — they exist so
rerun/resume/status can work.

## Logging & observability at volume
On every at-scale job the **hard requirement** is: structured logs + correct
levels + run-IDs + per-run summary. Bigger observability infrastructure
(dashboards, distributed tracing, metrics pipelines) is a CTO escalation when the
operation warrants it — traceability and the per-run summary are floor, not
ceiling.

- **Structured logs only** — JSON or key=value, never freeform concatenated
  `print` / `console.log` strings. Logs at volume must be queryable and
  aggregatable.
- **Use levels correctly.**
  - `ERROR` — needs attention; a human will look at this.
  - `WARN`  — recoverable / degraded; aggregated, not flooded.
  - `INFO`  — lifecycle milestones (job start, job end, phase change).
  - `DEBUG` — off in normal operation; on only when diagnosing.
- **Per-item failures are `WARN` and aggregated, not `ERROR` per item.** A
  million-row job at 0.1% failure is 1,000 entries — `ERROR` per item is a log
  explosion that buries the real signal.
- **Never log secrets or PII.** Token, key, password, email, address, raw user
  content — none of it (`CLAUDE.md` §*Secrets*).
- **Correlation IDs.** A batch run has a **run-id**; every item carries the same
  run-id (plus its own item-id), so one job is traceable end-to-end across
  whatever services it touches.
- **Per-run summary** — at job end, one summary entry: counts (total / success /
  failure), failure breakdown by category, duration, throughput. The artifact ops
  looks at first.

## Operability controls a batch tool ships
Every at-scale tool ships its **support controls as part of being done** — built
per-module while context is fresh, not deferred to a sweep that never comes. The
form (CLI / API / admin surface) is the CTO's call per module; the substrate is
non-negotiable (`CLAUDE.md` §*Operability*, DoD-4).

- **Operator tier**: rerun (failed items or whole job), resume from checkpoint,
  query run/item status, manual intervention (skip a poison item, force-complete,
  requeue, replay a range). Rides on the four hard requirements above.
- **Customer-support tier**: a surface where support can look up a customer's or
  item's current state and failure reason, and manually fix or reinstate a stuck
  flow — so support resolves issues without paging engineering.
- **Audit (hard requirement from day one)**: every support-tier manual
  intervention writes an audit entry — who acted, on whose data, when, why. Built
  in *now*, even while access is developer-only; retrofitting it is much harder.
- **Bulk-scope default is single-customer / single-item.** Bulk actions (replay
  10,000 items, force-complete a range) are operator/CTO actions. Soft guideline
  now; a hard requirement once real user or support access lands.
- **Future-proof for an authz layer.** User access, roles, and permission
  enforcement are a known future addition. Build admin and support surfaces so an
  authz layer can sit in front of them later — don't hardcode wide-open access.
  Do **not** build the permission system now unless the spec calls for it.

## Definition of done for an at-scale operation
Everything in `CLAUDE.md` §*Definition of done* still applies. Concretely (DoD-4
+ DoD-5): idempotent, resumable, per-item status tracked, fails safe on
fatal / continues on per-item, structured logs with correlation ids and a per-run
summary, and the operator + customer-support + audit controls exist and work. A
batch operation missing any of these is not done — it's broken.
