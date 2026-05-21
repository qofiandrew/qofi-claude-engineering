# ADR-0005 — Deterministic quality gates via hooks

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** two-way — hooks are config; add/remove freely.
**Escalated:** no — decided during the design conversation.

## Context

Autonomous building produces confident, plausible, sometimes subtly-wrong code, and
the operator reviews scope rather than lines. Verification therefore can't depend on
the model remembering to test or document — it needs a floor that fires regardless
of the agent's judgment.

## Decision

We will enforce two deterministic gates with Claude Code hooks: a `TaskCompleted`
hook (`test-gate.sh`) that blocks closing a task while tests are red, and a
`TeammateIdle` hook (`docs-check.sh`) that blocks idling when source changed but no
docs did. Both block via exit code 2 and feed the reason back to the agent.

## Reversibility & cost of change

Two-way: hooks live in `settings.json` and can be tuned, scoped, or removed per
repo without touching anything else.

## Consequences

The test gate and docs floor hold even on an unattended run. Cost: the test gate
runs the suite on every task completion, so slow suites need `CLAUDE_TEST_CMD`
pointed at a fast subset; the docs check is deliberately blunt and may need its path
patterns tuned per repo. Both are floors, not substitutes for the CTO's reviewer
pass.

## Alternatives considered

- **Instruction-only enforcement** (just tell the agents to test/document) —
  rejected: not deterministic; the whole point is a gate that doesn't rely on
  goodwill.
