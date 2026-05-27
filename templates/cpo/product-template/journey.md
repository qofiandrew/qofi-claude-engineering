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

## State vocabulary

A spec'd item progresses through these states. Use them consistently;
improvising vocabulary breaks grep-as-index the same way improvising
filenames breaks the schema (`constraints.md` §architectural hard lines).

- **sketched** — idea exists in conversation / decision record; not yet
  captured in a spec facet.
- **specced** — captured in a spec facet (`requirements.md`, `function.md`,
  etc.); not yet built.
- **built** — code or artifact exists; not yet exercised against real input.
- **tested** — exercised against real input or test suite; not yet hardened
  for production load.
- **hardened** — battle-tested at production load / soak-tested; ready to be
  live.
- **live** — running in production for real users.

Plus three flag states orthogonal to the progression:

- **blocked** — progress stopped on a named dependency. Carry the blocker.
- **deferred** — explicit operator/decision-record choice to not pursue
  now. Carry the deferral citation + the reconsideration trigger.
- **unknown** — CPO cannot determine state from available sources. Carry
  what *would* tell, surface to operator. **Never invent state to fill an
  unknown** (per `constraints.md` §behavioral hard lines + `EVALUATION.md`
  §citation discipline).

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
