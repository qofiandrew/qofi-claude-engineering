# <Product> — Journey

> DEFINITION: the **as-is** state of the product layered over the **should-be**
>   (the operator-written facets). CPO-maintained from CTO reports + operator
>   decisions. Tracks per-spec'd-item state, free-text operator-defined
>   milestones, the critical path, blockers, deferrals, and evidence.
> ROUTES HERE: status of spec'd items (sketched / specced / built / tested /
>   hardened / live), milestone progress, what's blocking what, deferrals + their
>   expiry triggers, evidence references (commits, test artifacts, CTO reports).
> GREP FOR: "is X built yet?", "what blocks v1 prod?", "what was deferred and
>   why?", "what's the critical path right now?"
> WRITE CLASS: **auto** for state updates from CTO reports (CPO-maintained, per
>   `MEMORY.md` §operator-written-vs-cpo-maintained). **gated** when a state
>   update *implies* a roadmap change — the CPO surfaces the implication for
>   operator decision and does not silently rewrite `roadmap.md`.

This file is **CPO-maintained**, not operator-authored. It is the as-is the
CPO holds against the should-be the operator authored elsewhere (vision,
function, requirements, scale, etc.). See decision record `0007`.

It is read on **every journey-loop event and most watch-loop evaluations**, so
it must stay greppable. Compact one-line-per-item shape preferred; expand
only where evidence + reasoning actually warrants it.

## State vocabulary (locked rev 3)

A spec'd item progresses through these **seven** states. The set is locked
(per decision record `0009`'s companion vocabulary lock in rev 3). Use
them consistently; improvising vocabulary breaks grep-as-index the same
way improvising filenames breaks the schema (`constraints.md`
§architectural hard lines).

Monotonically ordered (forward progression):

1. **sketched** — the idea exists in conversation or memory; not yet in a
   spec file.
2. **specced** — written down in a facet file (`vision.md`, `function.md`,
   `requirements.md`, etc.). Defined, but no code yet.
3. **in-progress** — a CTO is actively working on it; commits exist but
   the spec is not yet fully implemented.
4. **implemented** — code exists and the CTO claims completion, but it
   has not been tested against its spec.
5. **tested** — passes its own tests (per `quality-bar.md` test
   requirements). Functional but not soaked.
6. **hardened** — passed real-world soak / failure-mode exercise. The
   routing-safety test having lived through N-concurrent-channel traffic
   is the canonical example.
7. **live** — in production use by the operator (and, in future products,
   by end users).

**Rules.**

- The progression is **monotonic**. State can move forward (e.g.
  `tested → hardened`) and **back** (e.g. `tested → in-progress` if a
  regression is found and rework is needed). It cannot **skip**
  (e.g. `specced → tested` is invalid; the intermediate states must be
  recorded as they are passed). The progression is the *audit trail*,
  not just the snapshot.
- Each state change is **logged with a citation**: which commit, which
  test run, which CTO report, or which operator decision justified the
  transition. Uncited transitions are citation-discipline defects (per
  `EVALUATION.md` §citation discipline + `constraints.md` §behavioral
  hard lines).
- A journey item that is **stale or wrong vs. ground truth** is a
  quality defect (per `quality-bar.md` §journey-state accuracy).

Plus three **flag states orthogonal to the progression** — flags layer on
top of a primary state, they do not replace it:

- **blocked** — progress stopped on a named dependency. Carry the blocker.
- **deferred** — explicit operator/decision-record choice to not pursue
  now. Carry the deferral citation + the reconsideration trigger.
- **unknown** — CPO cannot determine state from available sources. Carry
  what *would* tell, surface to operator. **Never invent state to fill an
  unknown** (per `constraints.md` §behavioral hard lines + `EVALUATION.md`
  §citation discipline).

Other useful flags (non-exhaustive; add per-product as needed):

- **needs-real-world-soak** — at `tested` but the operator has elected to
  hold off declaring `hardened` until a defined soak period (see the
  product's `journey.md` §v1-prod-ready milestone, if defined).

## Per-spec'd-item state

One line per item from `requirements.md`, `function.md`, `quality-bar.md`,
`scale.md`, etc. Cite the spec section the item derives from; carry
evidence reference when state is `built` or later.

```
- <spec-ref> — <item> — <state> [— evidence: <commit / test artifact / CTO report>]
                                 [— blocked-on: <dep>]
                                 [— deferred-by: <decision-ref>, reconsider-on: <trigger>]
```

## Free-text milestones

Operator-defined compound goals (e.g. *"v1 prod release"*,
*"first CTO onboarded"*, *"watch loop end-to-end live"*). Each carries:

- **Definition** — what counts as done.
- **Current state** — where it sits now (likely citing several
  per-spec'd-item entries above).
- **Blockers** — what's in the way, with cross-references.
- **Next step** — the single most important next move toward this
  milestone.

If the definition is `pending operator input`, mark it that way and
surface — do not invent the definition.

## Critical path

The single most important next step right now, and **why**. Cites the
milestone or per-spec'd-item entry it serves. This is what the journey
loop primarily uses to draft directives (see `SURFACING.md`
§journey-loop-directives).

## Deferrals (with expiry triggers)

What was deferred, by what decision (cite the decision record where
possible), and what triggers reconsideration (date / event / dependency-
met). A deferral with no expiry trigger is a hidden permanent decision —
the trigger keeps the deferral honest.

## Cross-reference to `roadmap.md`

Every journey entry that traces to a roadmap item carries the roadmap-
section reference. Every roadmap item that has a corresponding journey
entry is greppable from here. The contract is by convention + grep, not
schema-enforced; honor it so neither file becomes the silent source of
truth for what the other should hold.
