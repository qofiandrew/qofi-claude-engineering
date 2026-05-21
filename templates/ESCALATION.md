# Escalation Policy

This document defines when you (the agent) stop and ask, versus when you proceed
on your own judgment. The default is **proceed**. Stopping is the exception, and
it has explicit triggers listed below. When in doubt, the test is reversibility,
not difficulty or importance.

---

## The test: one-way doors vs. two-way doors

Before pausing to ask, classify the decision:

- **Two-way door** — reversible within a single PR's worth of effort if it turns
  out wrong. → **Decide it yourself, proceed, and log it if it's notable.** Do not
  ask. This is the large majority of decisions, including most things you'd
  instinctively want to confirm.
- **One-way door** — expensive or slow to reverse once built on top of (days of
  rework, data migration, breaking changes for consumers). → **Escalate before
  committing to it,** even when your recommendation is strong and would normally be
  accepted.

A confident-but-wrong one-way-door call is the only kind of mistake that is
costly here. Two-way-door mistakes are cheap; make them fast and fix them later.

---

## Always escalate (one-way doors + hard blockers)

**One-way doors — escalate before building on the decision:**

- Data model / schema design, and any later migration that reshapes existing data
- Public or cross-service API contracts (routes, request/response shapes, any
  breaking change to something already consumed)
- The authentication and authorization model (who can do what, how identity works)
- Core stack choices: primary language, runtime, web framework, primary datastore
- Infrastructure topology, deployment target, and anything that incurs **recurring
  cost** or **vendor lock-in**
- Adding a new paid third-party service or a dependency that is hard to remove later
- Security-relevant tradeoffs: secrets handling, PII storage, encryption choices

**Hard blockers — escalate because progress is physically impossible without me:**

- Anything that **deletes or irreversibly transforms** existing data or code
- Anything touching **production** or **real user data**
- A required secret, account, credential, external approval, or human-only action

**Scope and spec — escalate because these are mine to call, not yours:**

- **v1 vs. v2 boundary.** When you're unsure whether something belongs in this
  version or should be deferred, ask. I will sometimes want *more* in v1 than you'd
  propose — do not silently minimize scope to ship faster.
- A genuine **contradiction or material ambiguity in the spec** that changes what
  gets built. (Trivial ambiguity → resolve it yourself and note the assumption.)

---

## Never escalate (proceed, log if notable)

- File and directory layout, module boundaries, internal naming
- Library choice for a leaf/utility concern that's easy to swap later
- Implementation approach, algorithms, refactors local to a function or file
- Test structure, formatting, linting, tooling config
- Anything reversible in a single PR
- A recommendation you'd expect me to accept anyway — just make the call. My default
  is to trust your engineering judgment on two-way doors; asking only adds latency.

---

## How to escalate

Match the interruption to the urgency:

- **Non-blocking escalations → batch them.** Collect open questions and surface
  them at a milestone or PR boundary as a numbered list. Keep working on
  everything not gated by them. For each, **state a default and proceed on
  silence**: "Proceeding with X unless you redirect." Silence = consent; work does
  not stall.
- **Blocking escalations (one-way doors that gate further work, or hard blockers)
  → interrupt immediately and stop on that track.** These hard-block: do not pick a
  default and proceed. Switch to other unblocked work if any exists.

Every escalation message states, in this order:
1. **Decision** — one line, what's being decided.
2. **Options** — the realistic choices.
3. **Recommendation** — your pick and a one-line why.
4. **Reversibility** — one-way or two-way, and the cost of changing later.
5. **Default** — what you'll do if I don't answer (or "BLOCKED — need your input
   to continue").

### Escalation message template

```
[ESCALATE · <project> · <blocking|batched>]
Decision: <one line>
Options: A) … B) … C) …
Recommendation: <A/B/C> — <one-line reason>
Reversibility: <one-way: changing later = … | two-way: cheap to revisit>
Default: <proceeding with X in <window> unless redirected | BLOCKED — cannot continue>
```

---

## Tie-in

- Decisions classified one-way **must** be recorded as an ADR (see
  `ADR.template.md`), regardless of whether they were escalated or not.
- Scope decisions update the v1/v2 sections of `PROJECT_SPEC.md`.
