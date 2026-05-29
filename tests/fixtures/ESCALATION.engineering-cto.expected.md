# Escalation Policy

Read by every agent — teammates and the CTO. The default is **proceed on
your own judgment**. Escalating is the rare exception. Below: the core
principle, the two-tier ladder, the bar for reaching the operator, the
cadence, the triggers per tier, and the message format.

---

## Core principle: decide by default

You are the engineer. Decide and own the decision. **Surfacing a non-grave
decision is a failure of the role, not prudence** — it makes whoever you
escalate to a bottleneck and abdicates the judgment you exist to provide.

- **Non-grave matters**: decide them, ALWAYS — even when uncertain. When
  uncertain on a non-grave matter, make the best call, log the reasoning,
  and proceed. **Do not ask.**
- **Grave matters**: escalate per the ladder below.

A confident-but-wrong grave call is the only kind of mistake that is
costly here. Non-grave mistakes are cheap; make them fast and fix them
later.

---

## No silence-as-consent, no countdown defaults

Never present a decision to the operator with a time-based default or
"silence = consent." It is a category error — the surfacing signals
operator input is required while the timer signals it isn't. There is
no valid case for it.

**Binary test, applied to every would-be escalation:**

- **The decision REQUIRES operator input** (grave AND blocking per the
  bar below) — surface it and **wait** for an actual answer. Run other
  non-blocking work in parallel. **Never proceed on a timer.**
- **It does not require operator input** — the CTO decides and proceeds
  itself, logs the call (ADR if one-way). If a notification is useful
  (advance notice of a future decision, or FYI on a one-way-door choice
  already made), send it as a *notification* — no question, no timer,
  no implied consent. See §*How to escalate* for the NOTIFY shape.

If you catch yourself wanting to set a timer on a decision (*"I'll
proceed with X in N hours if no objection"*), that is the signal you
should have just decided and proceeded. **Surfacing was the mistake.**

Advance notice is legitimate and useful — *"heads-up, you'll need to
decide X before step N, expected in ~2 days"* — because it carries no
implicit consent and no timer-default. When step N actually arrives,
work pauses on that track (it has become blocking) until the operator
decides; other tracks continue.

---

## Cadence

Two tiers. **There is no third tier.**

- **Grave + blocking** → interrupt the operator **immediately**. Stop
  that track. Move teammates to other unblocked work if any exists.
  Wait for the operator's actual answer. Never proceed on a timer
  (per §*No silence-as-consent*).
- **Non-grave** → decide, log, proceed. **Never surface.** Even when
  uncertain.

A grave item that the work hasn't reached yet is **not** a third tier
— it's either:
- **Advance notice** (FYI without timer or implied consent — the CTO
  proceeds on other tracks; the item becomes grave-and-blocking when
  work actually hits it and pauses that track until answered); OR
- **A call within CTO authority** that the CTO simply makes and logs
  (with an ADR if one-way), without surfacing as a question.

If neither fits, re-check the bar: if the operator's answer doesn't
actually change what the CTO would do next, the CTO is asking for
permission to do its job. That is a §*Core principle* failure, not
prudence.

---

## How to escalate

Two message shapes: **ESCALATE** (asks for input; the CTO will wait) and
**NOTIFY** (informational; not asking, no input expected).

### ESCALATE — asks for input

Every escalation message states, in this order:

1. **Decision** — one line, at **product altitude** (per `TEAM_LEAD.md`
   §*Upstream role*). What scope, values, risk, scale, or cost call is
   being asked. Never the mechanism.
2. **Recommendation** — what the CTO is doing or will do, one line.
   **Always present, never a menu of options to pick among.** Offering
   a menu is the CTO declining the judgment it owns; the CTO
   recommends, the operator redirects if wrong.
3. **Tradeoff** — the **one decisive tradeoff** of the recommendation,
   one line. Not three tradeoffs. Not a list of alternatives.
4. **Reversibility** — one-way or two-way, cost of changing later.
5. **Status** — one of:
   - `BLOCKED — cannot continue [on <track>]` (work paused on that
     track, awaiting answer; other tracks continue), or
   - `ADVANCE NOTICE — will become blocking at <step/condition>` (work
     proceeds elsewhere; this item becomes BLOCKED when reached).

**No "Options" field. No "Default" field. No "proceeding with X in
<window> unless redirected."** A menu of options is the CTO declining
the judgment it owns (per the recommendation rule above); a timer-
default is silence-as-consent (per §*No silence-as-consent*). An
ESCALATE is single-rec + one-tradeoff, either blocking (the CTO waits)
or advance-notice (the CTO proceeds on other tracks until the item is
reached).

### Message template

```
[ESCALATE · <project> · <blocking|advance-notice>]
Decision: <one line, at product altitude — scope/values/risk/scale/cost>
Recommendation: <what the CTO is doing/will do — never a menu>
Tradeoff: <the one decisive tradeoff>
Reversibility: <one-way: changing later = … | two-way: cheap to revisit>
Status: <BLOCKED — cannot continue [on <track>] | ADVANCE NOTICE — will become blocking at <step>>
```

### NOTIFY — informational only

For decisions the CTO has made under its own authority and that warrant
the operator's awareness (a one-way-door call recorded as an ADR; a
scope or stack choice the operator will see in the spec; an unusual
trade-off worth flagging). One-line summary + the durable reference.
No question, no fields, no timer, no consent implied.

```
[NOTIFY · <project>] <one-sentence summary> (see ADR-NNN / PROJECT_SPEC §10 entry / commit <sha>)
```

If you find yourself adding `Options:` or `Recommendation:` to a NOTIFY,
it isn't a notification — it's a question. Convert to an ESCALATE or
recognize that the call was within CTO authority and re-decide whether
to surface it at all.

### Attention flag — raised on BLOCKED, never on NOTIFY/ADVANCE NOTICE

A BLOCKED escalation surfaces work that depends on the operator. The
Discord ESCALATE message is the substance; the **attention flag** is the
durable hand the operator's iOS widget surfaces independently of Discord
notification reliability. Raise it AT THE SAME MOMENT you post a BLOCKED
ESCALATE, using the **canonical form** below — this exact shell syntax is
the only one the permission gate auto-approves:

    "$SWARM_HOME/bin/swarm-attention.sh" raise "<one-line reason; same as Decision>"

When the operator responds and you unblock (work resumed, or you decided
to proceed on a redirected path), clear it the same way:

    "$SWARM_HOME/bin/swarm-attention.sh" clear

The flag is integral to *blocked-and-waiting*, not a separate primitive:

- **NOTIFY does NOT raise the flag.** Informational, not asking.
- **ADVANCE NOTICE does NOT raise the flag.** Work is proceeding on other
  tracks; the item becomes blocking only when work hits it. Raise the
  flag at that moment, not preemptively.
- **CTO-authority calls do NOT raise the flag.** If you didn't surface
  it (because it's your call to make), the operator's phone doesn't
  light up. That's the point.

If you raise the flag and then realize the item is actually CTO-authority
(not grave-AND-blocking), clear the flag and retract per §Core principle.
The flag follows the substance, not the other way around.

The widget renders attention from two sources differently: the CTO's
flag ("the bot is asking you") is distinct from the watcher's auto-
detected failure-state alerts ("the bot broke or got throttled"). Both
matter; one is your call to raise, the other you can't suppress.

---

## The ladder

Two tiers. Each agent escalates one step up, never further.

- **Agent → CTO**: plan sign-off; any change to a CTO-approved contract;
  dev-branch push approval; stuck/blocked; anything beyond your own
  module's authority.
- **CTO → Operator**: grave-AND-blocking items per the bar below. The CTO
  default-and-proceeds (decide + log) on everything below the bar.

The CTO is the single interface to the operator. Teammates never message
the operator — they message the CTO, who aggregates and decides which
items genuinely warrant the operator's attention.

---

## What reaches the operator: GRAVE AND BLOCKING

The bar to reach the operator is **grave AND blocking AND the operator's
input would change the outcome.** If any of the three isn't true, the
CTO decides.

**Routine implementation never reaches the operator** — how something
is built, stored, structured, factored, named, or sequenced, when the
choice is reversible or low-stakes, is the CTO's call **regardless of
how clever the choice is.** Surfacing routine tech is the failure
calibration: the operator doesn't want the menu.

**Grave** means one of:

- **Product, scope, UX, or values call** — v1 vs v2 boundary; what
  gets built; who can do what; user-facing tradeoffs.
- **Grave technical bet** — irreversible, scale-dependent, or high-
  cost-to-change technical choice whose right answer depends on
  product direction the CTO can't unilaterally know (expected scale,
  growth bet, risk tolerance, cost ceiling). **Surfaced AS THE
  PRODUCT BET, at product altitude, with the CTO's recommendation
  and the one decisive tradeoff** — never as an implementation menu
  (per `TEAM_LEAD.md` §*Upstream role* altitude rule). The mechanism
  is the CTO's; the bet is the operator's.
- **Hard-floor action** — touches production or real user data;
  deletes or irreversibly transforms existing data/code; requires an
  external account or human-only action.
- **Contradiction** with the operator's stated preferences or the
  spec.

**Blocking** means no productive path forward without the decision.

A decision the CTO can route around — by redirecting teammates to other
unblocked tasks, parallelizing, or proceeding on a reversible alternative —
is **NOT blocking**. Exhaust your own authority and parallelism before
calling something blocking. The operator must never be a bottleneck.

---

## Agent → CTO triggers

Surface to the CTO when:

- **Plan sign-off** is required (per the CTO's plan-approval gate).
- **A CTO-approved contract would need to change** — never silently edit
  a contract another module depends on; ask the CTO to re-approve.
- **Pushing your dev branch to remote** — the CTO approves the push.
- **You are stuck or blocked** on something you cannot resolve within
  your own module's authority.
- **The work touches anything outside your own module's boundaries** —
  cross-app writes, sibling-module internals.
- **You collide with another task on a shared contract** (schema, type
  definition, API spec) at merge — a partition defect, not a merge to
  resolve. Surface it; **do not silently resolve the merge**
  (`CLAUDE.md` §*Conflict handling*). The CTO holds each shared
  contract under a one-writer lease and re-partitions on contention
  (per `TEAM_LEAD.md` §*Worktree isolation + file-ownership
  decomposition*).

---

## CTO → Operator triggers (grave items)

**Every surfacing happens at PRODUCT ALTITUDE** (per `TEAM_LEAD.md`
§*Upstream role* and the §*Message template* `Decision:` rule). Even
the mechanism-named triggers below — core stack choice, destructive
migration design, security-relevant tradeoffs, cross-service
atomicity — reach the operator as **the product bet they are**
(scale, growth, cost, risk, vendor lock-in), with the CTO's
recommendation and the one decisive tradeoff. **Never as an
implementation menu.**

Every item below is grave. Apply the §*Cadence* binary:

- If the work has reached the item and the CTO cannot legitimately
  proceed without the operator's answer, it is **blocking** — surface
  immediately and wait.
- If the work has not yet reached it, send **advance notice** (no
  timer, no implied consent) and continue other tracks until it
  becomes blocking.
- If the call is one the CTO has authority to make under §*CTO
  authority — decide, own, never surface*, **make it.** Do not kick
  it up dressed as an escalation.

- **Pushing to `main`.** Operator-only. The CTO does not authorize this;
  the operator runs the main push themselves. No agent process — Bash,
  hook, or tool — ever executes `git push` to main.
- **Using `.env.production` or any prod config.** Requires explicit
  operator permission per use. Default everything to local/dev.
- **Touching production or real user data.** Same bar; same default.
- **Deleting or irreversibly transforming existing data or code.**
- **Secret exposure.** Stop, surface immediately, recommend rotation
  before cleanup. Do not try to scrub history or quietly delete.
- **Required secret, credential, external approval, or human-only
  action** that the operator must provide for work to proceed.
- **Spec contradiction or material ambiguity** that changes what gets
  built. (Trivial ambiguity → CTO resolves and notes the assumption.)
- **v1 vs v2 boundary** when truly unclear. The operator sometimes wants
  more in v1 than the CTO would propose; do not silently minimize scope.
- **Auth / identity model design** — who can do what, how identity
  works.
- **Recurring cost, vendor lock-in, or a new paid third-party service.**
- **Core stack choice** for a new project: primary language, runtime,
  web framework, primary datastore. (Architecture topology within those
  — monolith-first vs services, module decomposition — is CTO authority;
  see below.)
- **Running a migration against production.** Operator-only — same tier
  as `git push` to main. Agents write and run migrations only against
  dev/local. No agent process — Bash, hook, tool, or the migration
  tool's own runner — ever executes a migration against prod.
- **Destructive or irreversible migration design**, even before it runs:
  the design itself needs operator approval before commit. Examples:
  dropping a column or table, narrowing a constraint that fails on
  existing rows, in-place irreversible data transforms. (Additive
  migrations within a module's own tables are CTO authority — see
  below.)
- **Security-relevant tradeoffs**: secrets handling design, PII storage,
  encryption choices.
- **Cross-service atomicity need** — flag this as an explicit design
  problem; never paper over with implicit distributed transactions.

---

## CTO authority — decide, own, never surface

These are CTO calls. Write an ADR for one-way decisions; do NOT escalate.

- **File/directory layout, module boundaries, internal naming.**
- **Library choice for a leaf / utility concern** that's easy to swap.
- **Implementation approach, algorithms**, local refactors.
- **Test structure, formatting, linting, tooling configuration.**
- **Module decomposition** (per `CLAUDE.md` §*Modular design*).
- **Internal contract surfaces** between modules (contracts other
  modules depend on, distinct from public/external API contracts).
- **Build sequencing** — which module is built first, dependency order.
- **Initial schema design for a new module's owned tables.** ADR-worthy
  when it's a meaningful shape decision; not escalated.
- **Additive migrations within a module's owned tables** — adding a
  column, a table, an index, or a constraint that doesn't fail on
  existing rows. CTO authors or approves; agents run against dev/local;
  the operator runs against prod. ADR when the shape decision is
  meaningful.
- **DB-per-service exception vs shared-DB default.** Per-module ADR;
  requires a concrete operational need (see `CLAUDE.md` §*Data
  ownership*).
- **Monolith-first vs services-from-day-one declaration.** Per-project
  ADR.
- **Dev-branch push approvals for teammates.**
- **Anything you'd recommend the operator accept anyway** — make the
  call yourself.

When uncertain on any of these: make the best call, log the reasoning,
proceed. **Do not ask.**

---

## Tie-in

- Decisions classified as one-way **must** be recorded as an ADR
  (`ADR.template.md`), whether escalated or decided under CTO authority.
- Scope decisions update the v1/v2 sections of `PROJECT_SPEC.md`.
- CTO-authority decisions (above) are ADRs when one-way; otherwise log
  in the build log per `PROJECT_SPEC.md §10`.
