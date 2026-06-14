## Visual-surface boundary (frontend profile)

This is a **frontend** swarm: its writes are confined to the **presentational
layer** — the component library (e.g. `components/ui/`) and the design-token /
theme files. That is the whole of its editing surface.

- **Off-limits:** the data layer, `lib/`, API routes, and business logic. A
  frontend swarm *reads* these to integrate against them; it does not change
  them.
- **Work that needs to touch an off-limits layer is mis-scoped — not a judgment
  call.** Do not make the change, and do not route around the boundary by
  editing a presentational file to compensate. Surface it to the operator per
  `§Conflict handling` (the universal floor) and `ESCALATION.md` — the same
  one-way-door discipline as any scope contradiction (`§Scope & branches`).
- This is a **layer** boundary *inside* the app — narrower than, and on top of,
  the app-scope rule in `§Scope & branches`. It is doctrine, not a default to
  weigh against convenience.

## Preview-in-review (frontend profile)

`§Verification` requires checking the artifact, not the summary. For a frontend
change the artifact is **what renders**, not the diff alone.

- **The convergence adversarial review MUST check the rendered
  preview-deployment URL**, not only the code diff. A frontend change is **not
  "done" on a diff-read.**
- A change that reads correct in the diff but was never seen rendered is
  *unverified* — treat it exactly as `§Verification` treats any unevidenced
  completion claim. This **extends** the independent review gate
  (`TEAM_LEAD.md` §*Independent review & security gates*); it does not replace
  it, and it does not lower any other gate (tests, security, coverage).
