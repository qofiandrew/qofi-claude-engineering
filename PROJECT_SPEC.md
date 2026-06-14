# Project Spec — claude-swarm

> The system that lets one operator run Claude Code as an autonomous engineering
> org. This is the spec CC builds the system itself against. It is also the
> reference implementation of the very practice it ships: a real spec plus ADRs,
> kept reconciled with the code.

**Status:** approved-for-build
**Last updated:** 2026-05-21

---

## 1. Problem & goal

An operator wants to direct software work the way a founder directs an engineering
org: hold a product-design conversation, say "go build," and have a CTO agent turn
that vision into docs, coordinate a team that builds end-to-end, and surface only
the decisions that genuinely need a human. `claude-swarm` is the thin layer that
makes this real on one Mac mini and one Claude Max subscription: a per-repo
operating contract, deterministic quality gates, and a host launcher.

The one sentence the build must not drift from: **the operator gives vision and
approves key decisions; everything else is delegated, gated, and reconciled
automatically.**

## 2. Users & primary use cases

A single technical operator, driving from a phone via Discord. They:
- spec a product conversationally with a CTO agent, then say "go build";
- approve one-way-door decisions and v1/v2 scope calls when pinged;
- approve tool-permission prompts remotely (the `yes/no` reply intercept);
- run several products over time, one or two live concurrently.

## 3. Scope

### In scope for v1
- The **payload templates** stamped into every product repo: `CLAUDE.md`,
  `ESCALATION.md`, `TEAM_LEAD.md`, `PROJECT_SPEC.template.md`, `ADR.template.md`,
  `settings.example.json`, and the two hooks.
- `bin/swarm-init.sh` — idempotent repo bootstrap.
- `bin/swarm-up.sh` — tmux launcher/supervisor for one CTO lead per repo.
- Integration with the existing **Discord bridge** (the `discord-b2b` plugin):
  one bot identity per repo channel, directives down, escalations + permission
  prompts up.
- The **CTO-authoring flow**: design conversation → "go build" → author spec+ADRs →
  confirm → decompose → spawn → integrate → reconcile.
- Deterministic gates: `TaskCompleted` test gate, `TeammateIdle` docs check.
- Single team on Claude Max (Agent Teams, in-process teammates).

### Explicitly deferred to v2+
- A **heartbeat health monitor** that detects a wedged-but-alive lead (v1 liveness
  is "tmux session exists," which only catches a dead one).
- A **second concurrent team** and a metered-API overflow path for bursts.
- **Headless Agent SDK** migration for true unattended 24/7 operation.
- Richer pooled-worktree provisioning for ephemeral fan-out beyond the basic
  recycled pool (→ ADR-0008).
- Richer reconciliation tooling (automated spec-vs-code drift reports).

### Non-goals
- A hosted, multi-tenant, or multi-user service.
- Replacing CI — the gate runs the project's own test suite.
- Non-macOS hosts in v1 (scripts stay bash-3.2-clean, but only macOS is targeted).

## 4. Success criteria / acceptance

- [ ] `swarm-init.sh <repo>` writes the full skeleton, refreshes policy docs every
      run, and never clobbers a real `PROJECT_SPEC.md`.
- [ ] `swarm-up.sh up` launches one lead per `swarm.conf` entry, each with its own
      `DISCORD_BOT_TOKEN`, with `ANTHROPIC_API_KEY` unset (runs on Max).
- [ ] `swarm-up.sh {down,status,watch}` behave as documented.
- [ ] End-to-end: design conversation → "go build" → CTO authors `PROJECT_SPEC.md`
      + ADRs → operator confirms → team builds → escalation reaches the phone →
      permission reply works → milestone reported.
- [ ] `TaskCompleted` hook blocks completion on red tests; `TeammateIdle` hook
      blocks idle when source changed but docs didn't.

## 5. Constraints

- **One Max pool** feeds everything — realistically 1–2 concurrent teams (see
  ADR-0004). Concurrency is capped by the subscription, not the hardware.
- **Agent Teams is experimental**: flag-gated (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`),
  requires Claude Code v2.1.32+, and in-process teammates do not survive `/resume`.
- **macOS bash 3.2** — host scripts must avoid bash-4 features.
- The bridge requires the `discord-b2b` plugin and its `bun` runtime.

## 6. Architecture overview

Five layers — control (phone) → Discord bridge → host (tmux) → per-repo CTO team →
guardrails + memory. Full writeup in `docs/ARCHITECTURE.md`. Load-bearing decisions:

- Orchestration: Agent Teams, hierarchical lead + teammates (→ ADR-0001)
- Bridge: Discord, persistent session (→ ADR-0002)
- Deconfliction: per-teammate worktrees, substrate-conditional; file ownership
  reduces merge conflicts (→ ADR-0008)
- Capacity: single Max pool, 1–2 teams (→ ADR-0004)
- Gates: deterministic hooks (→ ADR-0005)
- Process: CTO authors docs from the conversation (→ ADR-0006)

## 7. Verification plan

- The two hooks are the automated gate; CI green is the merge gate.
- A manual **shakedown** on a throwaway repo verifies the directive lifecycle
  end-to-end (see §9 open item, and the README's first-run checklist when written).
- Self-review against §3 scope and §4 acceptance before declaring v1 done.

## 8. Key decisions

- ADR-0001 — Agent Teams over a flat peer-bot swarm
- ADR-0002 — Discord bridge over Slack
- ADR-0003 — File-ownership deconfliction over per-teammate worktrees (superseded by ADR-0008)
- ADR-0004 — Single Max pool; 1–2 concurrent teams; API for overflow
- ADR-0005 — Deterministic quality gates via hooks
- ADR-0006 — The CTO authors docs from the conversation
- ADR-0007 — Monorepo with the bridge as a `bridge/` subcomponent
- ADR-0008 — Per-teammate worktree isolation, substrate-conditional
- ADR-0009 — Canonical prod-migration surface (makes the D floor gateable)

## 9. Open questions

- [ ] (non-blocking) Verify the exact mechanism for handing a launched lead its
      brief — `send-keys` after a sleep works, but a native initial-prompt flag
      would be cleaner. Confirm against the installed Claude Code version.
- [ ] (non-blocking) `jq -s '.[0] * .[1]'` settings merge replaces arrays; confirm
      the hooks block survives a merge into a repo with existing hooks.
- [ ] (non-blocking) Measure real token burn for one team through a full build to
      calibrate whether a second concurrent team fits the Max pool (feeds ADR-0004).
- [ ] (non-blocking) Run the first end-to-end shakedown (see `docs/SHAKEDOWN.md`
      once written) — exercises the §4 directive-lifecycle acceptance criterion
      that the unit gates can't cover.
- [ ] (v2) Wedged-but-alive lead detection — design the heartbeat.

## 10. Build log

- `2026-05-21` — Repo consolidated from the design conversation. Payload templates,
  host scripts, governance docs, and six ADRs in place. CTO-authoring refinement
  applied to `TEAM_LEAD.md` and the `swarm-up` handoff. Ready for CC to build out v1.
- `2026-05-21` — Monorepo consolidation. The Discord bridge plugin (previously at
  repo root) was moved to `bridge/` via `git mv` (history preserved); the
  `claude-swarm/` subdir was promoted to repo root. Bridge install switched to
  `/plugin marketplace add <repo>/bridge` (single-plugin marketplace; no
  `.claude-plugin/marketplace.json` introduced). New top-level `README.md`
  authored; `docs/README.md` removed (superseded). CTO-authoring drift fixed in
  `CLAUDE.md`, `templates/CLAUDE.md`, `templates/PROJECT_SPEC.template.md`, and
  `bin/swarm-init.sh`'s closing message. `docs/ARCHITECTURE.md`'s on-disk-layout
  block updated to show `bridge/`. Root `.gitignore` merged with swarm's. Decision
  recorded as [ADR-0007](./docs/adr/ADR-0007-monorepo-bridge-as-subcomponent.md).
- `2026-05-21` — Both runtime gates verified live: `bun` boots the MCP server clean
  from `bridge/`, and the A2 install path (`/plugin marketplace add <repo>/bridge`
  → `/plugin install discord-b2b@bridge`) loads the plugin with
  `--channels plugin:discord-b2b` attaching as expected. ADR-0007 stands as
  accepted; no A3 fallback needed. Migration committed as `3266f09`.
- `2026-05-21` — Housekeeping pass post-migration. ADR-0007 body reconciled to
  reflect that A2 and bun boot were verified live (not merely proposed) and that
  A3 remains the documented regression fallback. §9 gained an open item for the
  first end-to-end shakedown; §4's directive-lifecycle acceptance is intentionally
  unchecked until that shakedown runs. Note for future archaeologists: the
  bridge `README.md`'s pre-move history is reachable via `git log README.md`, not
  `git log --follow bridge/README.md` — git's rename heuristic attributed path
  continuity to the root `README.md` (which got rewritten as the whole-system
  README in the same commit) rather than to `bridge/README.md`.
- `2026-05-29` — Worktree contradiction resolved (ADR-0008). ADR-0003 superseded;
  §3/§6/§8 and root `docs/TEAM_LEAD.md` reconciled to per-teammate worktrees
  (substrate-conditional: durable per-teammate for persistent teams, recycled
  pool for ephemeral fan-out); file-ownership decomposition demoted to
  merge-conflict reduction. Same change harvested ephemeral-sibling doctrine
  gaps into the engineering-cto templates: a one-writer contract lease +
  contention-is-a-partition-defect rule, a per-task assumptions record folded
  into this build log at integration (no silence-as-consent), prod-migration
  floor raised to push-to-main parity, skill-promotion standards, simplicity
  scoping + surgical-hygiene + beyond-ask disclosure, and a route-before-scan
  doc map (manifest `covers` column).
- `2026-06-12` — Engineering Robustness Program doctrine migrated into the
  engineering-cto fragments (six operator-ratified 2026-06-12 decision records in
  `qofi-product/products/qofi-claude-engineering/decisions/`). DOCTRINE PROSE
  landed: `CLAUDE.md` gained the release-PR-on-`main` model (§Scope & branches,
  new §Promotion to `main`, §Clean-dev update), §Test-driven by default, §Search
  first, §Conventional commits, §Session summary on stop, §Learnings, and a DoD
  item-7 gate reference (the `[DoD-1..6]` block left untouched for `dod-affirm.sh`);
  `TEAM_LEAD.md` gained §Independent review & security gates, §Codex contrarian
  review lane, §Learning loop, plus the release-PR merge-ownership update;
  `ESCALATION.md` got the Promotion-to-`main` trigger reword + a Tier-2
  learning-proposal trigger. Operator-only-`main` and Type-2 real-spend floors
  preserved verbatim; `permission-gate-policy.sh` deliberately UNCHANGED (still
  denies push entirely — correct, since the release PR is the operator's GitHub
  merge, not an agent push). CPO product-vision facets (`quality-bar`,
  `reliability`, `roadmap`, `constraints`) also updated; `requirements.md`
  verified unchanged. STILL OPEN, handed to a Claude Code session (see
  `HANDOVER-robustness-adoption.md`): regenerate the 3 stale fixtures
  (CLAUDE/ESCALATION/TEAM_LEAD engineering-cto) and green `test-doctrine-compose.sh`
  (currently RED — fixtures stale by design); build the mechanism (quality
  PostToolUse hook, Stop-phase session-summary hook, hook runtime controls with
  the never-env-switchable permission-gate guard, harness-audit preflight,
  gitleaks/semgrep wiring, `LEARNINGS.md` seed, Codex-lane subscription-auth
  integration, per-stack skill fragments) with manifest lines + tests; then
  operator full-diff review → compose green → canary reserve-backend-2 →
  `swarm-update`. Per-product CI referee + branch protection + Railway staging is
  a separate operator-run per-repo checklist.
- `2026-06-14` — frontend|backend **profile axis** added (ADR-0013), an
  orthogonal selector layered on top of the engineering-cto archetype. New
  per-repo `.claude/swarm-profile` marker + `swarm_known_profiles` /
  `swarm_profile_is_known` / `swarm_profile_of` in `swarm-lib.sh` (the resolver
  defaults to EMPTY, deliberately NOT mirroring `swarm_type_of`'s
  default-to-a-value, so markerless swarms are untouched). The overlay is
  injected by `manifest_apply_compose` as the final compose source for
  `CLAUDE.md` only — the ONE dynamically-sourced compose input; the manifest
  `CLAUDE.md` line is unchanged (header comment documents it). `--profile` is
  threaded through `swarm-init` (authoritative validation: engineering-cto-only
  against the repo's resolved type + refuse-to-switch) and
  `swarm-add`/`swarm-new` (fail-fast flag check + passthrough). Scope is
  CLAUDE.md-only: `swarm_launch_brief` / `swarm_required_doctrine` /
  `swarm_effort_for` are untouched. Value set `{frontend, backend}`: `backend`
  is **label-only** (today's engineering-cto IS the backend case — no overlay
  fragment, composes byte-identically to base, proven by test); `frontend`
  carries the only overlay — a visual-surface boundary (presentational layer
  only; data/`lib/`/API/business logic off-limits → escalate) and a
  preview-in-review amendment (the convergence review checks the rendered
  preview URL, not the diff alone). Additive-only: no existing swarm
  retro-assigned. New test `test-swarm-profile-dispatch.sh` (CLI contract +
  real-pipeline byte-identity) and a frontend round-trip in
  `test-doctrine-compose.sh`; new fixture
  `CLAUDE.engineering-cto.frontend.expected.md`. Docs: README §6,
  `_base/README.md`, manifest header.
