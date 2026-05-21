# ADR-0003 — File-ownership deconfliction over per-teammate worktrees

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** two-way — revisit if Agent Teams gains native worktree isolation.
**Escalated:** no — decided during the design conversation.

## Context

Native Agent Teams teammates share one working tree; the documented way to avoid
conflicts is to give each teammate a disjoint set of files. Per-teammate git
worktrees would give branch isolation, but only as a *manual* multi-session setup
that forfeits the automated task list and mailbox.

## Decision

We will rely on **file-ownership deconfliction on a shared working tree**: the CTO's
decomposition assigns every task an explicit, non-overlapping set of owned paths.
We keep the native team coordination and accept no per-teammate branches.

## Reversibility & cost of change

Two-way: if the feature later supports worktree-isolated teammates, the CTO brief's
decomposition rule can change without touching the rest of the system.

## Consequences

Clean ownership decomposition becomes mandatory and is the lead's core
responsibility (overlap = corruption). We lose per-teammate branch review/rollback,
which matters less here because the operator is a scope approver, not a line
reviewer, and CI is the real gate.

## Alternatives considered

- **Manual git worktrees per teammate** — rejected: forfeits the automated task
  list/mailbox that make Agent Teams worth using over hand-coordination.
