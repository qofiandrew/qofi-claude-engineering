# Project Spec — <project name>

> **This is a template, not a real spec.** The CTO authors the actual spec from
> the design conversation with the operator when they say "go build" — it does not
> exist before then. Once authored and confirmed, it becomes the source of truth
> the build is checked against and what lets a long run resume after a context
> reset. Keep it current as decisions land — it is not a write-once document.
> See `TEAM_LEAD.md` for the authoring flow.

**Status:** template | draft | approved-for-build | building | shipped
**Last updated:** <date>

---

## 1. Problem & goal

What are we building and why. One paragraph. The single sentence that, if the
build drifts from it, means we've gone wrong.

## 2. Users & primary use cases

Who uses this and the 2–4 concrete things they do with it. Concrete enough that
"is this done?" has a real answer.

## 3. Scope

This is the most important section and the one I (the human) care most about.
Be explicit; do not leave the v1/v2 line to inference.

### In scope for v1
- …

### Explicitly deferred to v2+
- … (listed so the agent doesn't "helpfully" build them — see ESCALATION.md, scope)

### Non-goals (not building, ever, for this project)
- …

## 4. Success criteria / acceptance

How we know v1 is done. Where possible, phrased as checkable conditions that map
to tests:
- [ ] …
- [ ] …

## 5. Constraints

Tech, time, cost, compliance, existing-system constraints the build must respect.

## 6. Architecture overview

*(Filled in by the agent after the one-way-door decisions are made and recorded as
ADRs. Should be a short map of the system — components and how they talk — not a
restatement of the code.)*

- Stack: … (→ ADR-NNNN)
- Data model: … (→ ADR-NNNN)
- Key boundaries: …

## 7. Verification plan

How correctness is guaranteed without line-by-line human review:
- Test strategy: … (unit / integration / e2e split)
- CI gate: must be green before merge
- Self-review: agent checks the build against §3 and §4 before declaring done

## 8. Key decisions

Index of ADRs for this project (see `ADR.template.md`):
- ADR-0001 — …
- ADR-0002 — …

## 9. Open questions

Live list, cleared as resolved. Each tagged blocking or non-blocking per
ESCALATION.md.
- [ ] (non-blocking) …
- [ ] (BLOCKING) …

## 10. Build log

Running, append-only narrative the agent maintains as it works — what got built,
what changed, what was discovered. This is the memory that survives context resets
and the window into progress without interrupting the run.

- `<date>` — …
