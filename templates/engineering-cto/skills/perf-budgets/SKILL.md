---
name: perf-budgets
description: Performance-budget playbook for UI products (web/mobile front-ends, e.g. press-web, qofi-ios-app) — how to declare per-product budgets (bundle/payload size, interaction/route latency, Core Web Vitals LCP/INP/CLS), measure the before/after delta on a perf-affecting change, and report it against the budget. Invoke when implementing or reviewing a UI change that could move those numbers; a regression past a ceiling escalates the same class as a failing test. This is the on-demand concretion of CLAUDE.md §Performance budgets (the always-loaded floor, which still governs and carries the DoD hook). It is on-demand, NOT a floor or a standing gate: inert (zero context) in a non-UI repo — no front-end, no rendered UI surface, no declared budget — output nothing and do not improvise a measurement.
---

# perf-budgets — performance-budget playbook for UI products (on-demand)

This is an **on-demand companion** to the always-loaded doctrine, not a
replacement for it. The floor requirement lives in `CLAUDE.md` §*Performance
budgets* and still governs: a perf-affecting UI change **reports the measured
before/after delta against the declared budget, and a regression past a ceiling
is a flag the same class as a failing test — it escalates rather than ships
silently.** That gate is on the floor by design. This skill only adds the
stack-specific *how*. Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins.

## When this skill applies (and when it is inert)
- **Applies** to a **UI product** — a web front-end or mobile app with a rendered
  user-facing surface (e.g. `press-web`, `qofi-ios-app`) that has, or should
  have, a declared performance budget.
- **Inert otherwise.** A backend service, library, or CLI with no rendered UI has
  no user-experienced latency budget of this kind — **produce no output, do not
  improvise a perf harness for code that has no UI surface.** (Same on-demand,
  zero-context-elsewhere posture as `ts-node-stack` / `dead-code-scan`.)
- It is **on-demand, not an always-on gate.** It is invoked for UI work that
  could move the numbers — not a standing agent, not a check on every commit. The
  CTO calls for the measurement when a change warrants it; routine non-UI work
  doesn't pay this cost.

## Budgets are declared per product (numeric, written down)
A budget that isn't measured isn't real — like a coverage floor. Budgets are
declared **per product**, in the spec (`PROJECT_SPEC.md`) or a perf doc it points
to, as **numeric ceilings** on what degrades the experience:

- **Bundle / payload size** — JS/CSS shipped to the client, initial route
  payload, image weight. A ceiling in KB (gzipped/brotli), per route or per
  bundle.
- **Interaction / route latency** — time to interactive, key interaction
  response time, route-transition / navigation latency. A ceiling in ms.
- **Core Web Vitals** (web) — **LCP** (Largest Contentful Paint), **INP**
  (Interaction to Next Paint), **CLS** (Cumulative Layout Shift). Ceilings at the
  field-data thresholds the product targets.
- **Mobile equivalents** (native) — cold/warm start time, frame-drop / jank rate,
  memory ceiling, app/binary size.

Exact thresholds are **per-product**, not set here; what's doctrine is that
they're **written down and numeric**. If the product has no declared budget and
the change is perf-affecting, surface that gap (build log / `§Conflict handling`)
— an unmeasured budget is the defect, not a reason to skip the measurement.

## Report before/after on a perf-affecting change
A change that touches a budgeted dimension **measures and reports the delta**:

1. **Measure the baseline** — the budgeted dimension *before* your change
   (current `main`/`dev` state), with the product's own tooling: the bundle
   analyzer it already uses, a Lighthouse / Web Vitals run for web, the
   instrumentation/profiler for native. Don't add a new measurement dependency
   just to run this (`CLAUDE.md` §*Dependencies*) — use what the repo declares.
2. **Measure after** — the same dimension with your change applied, same method,
   same conditions (same device/profile, same network throttle, same build mode).
   A delta measured two different ways is noise, not signal.
3. **Report the delta in the change summary** — `before → after` against the
   budget ceiling, e.g. `route bundle: 182KB → 191KB (budget 200KB, OK)` or
   `LCP: 2.1s → 2.7s (budget 2.5s, OVER — escalating)`.

**A regression past a ceiling is a flag, the same class as a failing test, and
escalates rather than ships silently** (`CLAUDE.md` §*Performance budgets* —
the floor hook). It does not "ship and we'll fix it later." Surface it per
`§Conflict handling`; the CTO decides whether the regression is acceptable
against the budget or the change reworks to fit.

## Output shape (what to hand back)
A compact before/after report attached to the change summary:

```
perf-budgets (UI change, measured delta vs declared budget):
  bundle (route /feed):  182KB → 191KB   [budget 200KB gz — OK]
  LCP (lab, 4x CPU):     2.1s  → 2.7s    [budget 2.5s — OVER, escalating]
  INP:                   180ms → 175ms   [budget 200ms — OK]
NOTE: a dimension OVER its ceiling is a flag the same class as a failing test
(CLAUDE.md §Performance budgets) — it escalates, it does not ship silently.
```

## Definition of done for an invocation
This skill performed correctly when, for a perf-affecting UI change, it produced
the before/after delta against the declared budget with a consistent measurement
method, and surfaced any over-ceiling regression as an escalation rather than
shipping it silently. Everything in `CLAUDE.md` §*Definition of done* still
applies; this only adds the measurement discipline for the budgeted dimensions.
A change that moved a budgeted number without measuring it is not done.
