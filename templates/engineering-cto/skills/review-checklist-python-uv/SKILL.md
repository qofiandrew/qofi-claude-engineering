---
name: review-checklist-python-uv
description: R5 review checklist for Python diffs on the uv toolchain — the language-specific review pass the reviewer/CTO runs over a Python change, plus the native tools to run (ruff, mypy/pyright, pytest via uv). Load when reviewing Python code. This concretizes the always-loaded doctrine's review/DoD gates (CLAUDE.md §Definition of done, TEAM_LEAD.md §Independent review & security gates) for this stack; it is an on-demand skill, not a floor, so it costs no context in repos whose stack doesn't match. Inert when there is no pyproject.toml.
---

# review-checklist-python-uv — Python (uv) R5 review pass

An **on-demand companion** to the always-loaded doctrine, not a replacement.
Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins. This is the
*stack-specific concretion* of the independent-review gate (`TEAM_LEAD.md`
§*Independent review & security gates*) and the DoD self-review (`CLAUDE.md`
§*Definition of done*) — what to look at when the diff is Python.

**Inert when the stack doesn't match.** No `pyproject.toml` at the root → this
skill does not apply; produce nothing. (Same zero-context posture as
`ts-node-stack`.)

## Native tools to run first (deterministic, before the human-judgment pass)
This stack standardizes on **uv** for env + runner; run the repo's own commands:
- **`ruff check`** (lint) and **`ruff format --check`** — clean. New `# noqa`
  directives are a review item, not a free pass (see the suppression check).
- **`mypy`** or **`pyright`** (type check, whichever the repo configures) — clean
  under the repo's strictness. A type error in the diff is a hard stop.
- **`uv run pytest`** (or the repo's `.claude/test-cmd`) — green, at/above the
  `quality-bar.md` coverage floor. Never lower the floor to pass (`CLAUDE.md`
  §*Verification*).
- **`uv.lock` committed.** A dependency change without the updated lockfile is a
  finding (`CLAUDE.md` §*Dependencies* — pin versions, commit the lockfile).

## Review checklist (human-judgment pass — what the scanners can't see)
- **Type the contract surface.** Public boundary functions are annotated; an
  untyped `Any`/`object` crossing a module boundary defeats the
  one-contract-surface rule (`CLAUDE.md` §*Modular design*). Validate external
  input at the edge (a `pydantic` model / explicit parse), trust it inside.
- **No bare / swallowing `except`.** No `except:` or `except Exception: pass`
  that drops the cause, no swallowed error, no ignored return. Re-raise with
  context or handle deliberately (`CLAUDE.md` §*Error handling* — never silently
  swallow). (R4 semgrep flags the mechanical empty-except case — confirm the diff
  doesn't reintroduce it.)
- **`async` correctness.** Every awaitable is awaited or explicitly scheduled and
  tracked; no fire-and-forget `asyncio.create_task(...)` whose result/exception
  is dropped; no blocking call inside an event loop.
- **No mutable default arguments.** `def f(x=[])` / `={}` is the classic shared-
  state bug — expect `None` + in-body init.
- **Resource lifetimes.** Files / sockets / DB sessions opened in the diff are
  closed (context managers), not leaked.
- **No suppression-to-go-green.** A new `# type: ignore`, `# noqa`, or broad
  `# pragma: no cover` that exists only to silence a real failure is a regression
  (`CLAUDE.md` §*Verification*). Each must be justified at its use site or it's a
  finding.
- **At-scale ops (if touched).** Batch jobs are idempotent, resumable, per-item
  failure-isolated, and stream rather than slurp the dataset into memory
  (`CLAUDE.md` §*Error handling* hard requirements).

## Confidence discipline (carry the gate's rule into the pass)
Report only findings held at **≥80% confidence** (`TEAM_LEAD.md` §*Independent
review*). Consolidate similar findings; order security-first.

## What this skill is not
Not a gate of its own and not a place for logic — it is a *checklist* the
reviewer/CTO applies. The gating authority stays with the DoD and the
independent-review/security passes the CTO runs (`CLAUDE.md` §*Definition of
done* item 7).
