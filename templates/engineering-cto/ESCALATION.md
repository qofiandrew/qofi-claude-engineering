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
  external account or human-only action; **incurs real external spend or
  real money movement** (running a credit-burning pipeline, turning on a
  billable pipe, payouts, activating a paid service).
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

- **Promotion to `main`.** Operator-only. The CTO does not authorize or perform
  it; promotion is a `dev`→`main` release PR the operator merges by hand, gated
  by branch protection + green required CI. No agent process — Bash, hook, tool,
  or PR action — ever pushes or merges `main`. (The CTO's job ends at
  clean-pushed-`dev` with green referee CI; `CLAUDE.md` §*Promotion to `main`*.)
- **Pushing to a protected or shared-history branch.** Routine push to a
  feature/worktree/topic branch and non-force push to `dev` (staging) are the
  normal cadence — the permission gate auto-approves them, and they are NOT
  escalations (continuous landing is also crash-safety). The hard floor the gate
  DENIES is narrower than "all push": any push whose destination is
  `main`/`master`; any **force-push** (`--force`/`-f`/`--force-with-lease` or a
  `+refspec`); and any **broad/destructive** push (`--mirror`/`--all`/`--delete`/
  `--prune` or a `:ref` deletion). `main` is reached only via the operator's
  release PR (above); a force/destructive push is operator-only. The gate's deny
  list mirrors this floor, but the durable floor is **server-side GitHub branch
  protection on `main`** — set it on every repo (`CLAUDE.md` §*Promotion to
  `main`*; ADR-0012).
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
- **Doctrine-generalization proposal (Tier 2 learning).** When a repo-local
  learning recurs (≥2 incidents or repos) and looks like it should become shared
  doctrine, it is **proposed, never self-applied**: surfaced through the CPO as a
  batched proposal for the operator to ratify (`TEAM_LEAD.md` §*Learning loop*).
  You never promote a learning into `templates/` yourself — a repo-local
  `LEARNINGS.md` entry is your authority; generalizing it is the operator's.
- **Core stack choice** for a new project: primary language, runtime,
  web framework, primary datastore. (Architecture topology within those
  — monolith-first vs services, module decomposition — is CTO authority;
  see below.)
- **Running anything that incurs real spend or real money movement.**
  Hard floor — NEVER without explicit operator approval, regardless of how
  obvious the call looks: burning real API credits via a pipeline, turning
  on a contributor's or third-party billable pipe, triggering a payout or
  money transfer, activating a paid service (`CLAUDE.md` §*Real spend &
  money movement*). When unsure whether an action spends real money, treat
  it as if it does and require approval.
- **Running a migration against production.** Operator-only — same tier
  as `git push` to main. Agents write and run migrations only against
  dev/local; no agent process executes a migration against prod.
  Enforcement is currently prose + circuit-breaker (this rule + escalation),
  **not** a mechanical deny — a deterministic deny is pending the canonical
  prod-migration surface (ADR-0009). Known gap, not silent.
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
- **Merging teammate `worktree-<name>` branches into `dev`, and pushing `dev` to remote.**
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
