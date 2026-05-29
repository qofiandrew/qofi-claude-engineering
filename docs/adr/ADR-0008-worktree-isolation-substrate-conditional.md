# ADR-0008 — Per-teammate worktree isolation, substrate-conditional

**Status:** accepted
**Date:** 2026-05-29
**Reversibility:** two-way — the worktree provisioning is the orchestrator's job
and the decomposition rule is unchanged; revisit if a substrate gains native
per-agent isolation.
**Escalated:** no — decided from accumulated build evidence (reserve-backend-2),
reconciling the spec with what we already ship.

## Context

ADR-0003 chose file-ownership deconfliction on a **shared** working tree and
rejected per-teammate worktrees as a manual setup that forfeited the automated
task list and mailbox. Two things changed since.

First, the shipped engineering-cto overlay and its hooks already **mandate**
per-teammate worktrees (`templates/engineering-cto/TEAM_LEAD.md` §*Worktree
isolation + file-ownership decomposition*; `permission-gate-policy.sh` auto-
approves `git worktree` add/remove/list/prune and `worktree-*` branch deletion).
ADR-0003, `PROJECT_SPEC.md` §3/§6, and the root `docs/TEAM_LEAD.md` had drifted
out of sync with what we ship — a violation of our own §*Docs reflect reality*
rule.

Second, we now have evidence. In reserve-backend-2, 4 Phase-1a teammates on a
shared tree produced **2 commit-attribution swaps** (the commit titled X
actually contained Y's files); 9 teammates across per-teammate worktrees in
Phase 3a–3c produced **0**. The race was reproducible under shared trees and
vanished under isolation. The full evidence lives in the overlay's
`TEAM_LEAD.md` §*Worktree isolation + file-ownership decomposition*.

The complication is that "the swarm" is not one substrate. Persistent **Agent
Teams** (→ ADR-0001) run long-lived, named teammates whose commit attribution
matters for the build log and review trail; their concurrency is capped at 1–2
teams on the Max pool (→ ADR-0004). Ephemeral **ultracode fan-out** spawns many
short-lived workers up to a fan-out concurrency cap, then discards them. A
single global worktree model serves neither well.

## Decision

We adopt per-teammate worktree isolation as the model, **conditioned on the
execution substrate**:

- **Persistent Agent Teams → one durable worktree per teammate.** Keep the
  shipped model: the CTO provisions `.claude/worktrees/<name>/` on branch
  `worktree-<name>` before spawn, the teammate commits only there, the CTO owns
  merges into `dev`. This is what preserves clean commit attribution — the
  reserve-backend-2 evidence above is decisive.
- **Ephemeral ultracode fan-out → a recycled worktree pool.** Read-only phases
  share one read-only tree; the write phase draws worktrees from a pool sized to
  the orchestrator's fan-out concurrency cap (≤16 concurrent workers — the
  workflow concurrency ceiling), recycled across waves rather than created per
  worker. The **orchestrator's workflow script provisions and recycles the
  pool** — the platform does not do this natively.
- **No single global model.** The two substrates use the two schemes above; do
  not collapse them into one. Collapsing to a durable worktree per ephemeral
  worker wastes the provisioning cost the pool exists to amortize; collapsing to
  a shared tree reintroduces the attribution race.
- **File-ownership-disjoint decomposition survives, but demoted.** It is no
  longer the sole defense against clobbering (worktree isolation is). Its job is
  now to **reduce merge conflicts** at integration time. Overlapping ownership
  is a merge cost, not a corruption risk — except on a shared *contract*, which
  is held under a one-writer lease (`TEAM_LEAD.md` §*Worktree isolation +
  file-ownership decomposition*); contention there is a partition defect, not a
  merge to resolve.

## Reversibility & cost of change

Two-way. The durable-worktree path is already the shipped overlay; the pool is a
bounded addition to the orchestrator's workflow script, not a structural
rewrite. The decomposition rule is unchanged in substance — only its stated
*purpose* moves from anti-clobber to anti-conflict. If a substrate later gains
native per-agent isolation, the provisioning step can drop out without touching
the rest of the system.

## Consequences

Commit attribution is clean on persistent teams; the sibling-staging race is
structurally gone. Ephemeral fan-out gets isolation without paying to create a
worktree per worker. Cost: the orchestrator now owns worktree provisioning,
teardown, and pool recycling (CTO-level for teams, workflow-script-level for
fan-out) — a real maintenance surface the platform does not cover. The
decomposition discipline stays mandatory even though its failure mode softened,
because merge-conflict churn at integration is still a real cost.

## Alternatives considered

- **Keep ADR-0003's shared tree + file-ownership only** — rejected: the
  reserve-backend-2 commit-attribution swaps show file-ownership alone does not
  prevent the sibling-staging race, and it contradicts the shipped overlay.
- **One global per-worker durable worktree for both substrates** — rejected:
  creating and tearing down a durable worktree per ephemeral fan-out worker
  wastes the provisioning cost the pool exists to amortize.
- **Drop file-ownership decomposition now that worktrees isolate** — rejected:
  it still reduces merge conflicts at integration, and the one-writer lease on a
  shared contract depends on it; demoted, not removed.
