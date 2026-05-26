# <Product> — Decisions

> DEFINITION: append-only, bounded record of ratified product calls for this
>   product. One record per decision. Each captures: the decision, the date, the
>   rejected alternative(s), and the WHY. This is where rejected paths and rationale
>   survive (so the CPO can say "you dismissed this in <month> — what changed?")
>   WITHOUT keeping a sprawling raw transcript.
> ROUTES HERE: every ratified call (from conversation or a ratified CTO interrupt),
>   refined to a compact record.
> GREP FOR: "why did we choose X for product-N?", "have we rejected Y before?",
>   "when was Z decided?"
> WRITE CLASS: auto (append). Bounded by nature — decisions are discrete events.

One file per decision, named: `YYYY-MM-DD-<slug>.md`
Record shape:
  - Decision: <what was chosen>
  - Date / source: <when, from conversation or which CTO interrupt>
  - Rejected: <what was considered and not chosen>
  - Why: <the reasoning — the durable part>
