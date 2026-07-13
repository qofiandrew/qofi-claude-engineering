# Project Spec — hybrid engineering swarm

> The system that lets one operator run Claude Code or OpenAI Codex as an autonomous engineering
> org. This is the spec CC builds the system itself against. It is also the
> reference implementation of the very practice it ships: a real spec plus ADRs,
> kept reconciled with the code.

**Status:** operational; hybrid-engine hardening verified locally
**Last updated:** 2026-07-13

---

## 1. Problem & goal

An operator wants to direct software work the way a founder directs an engineering
org: hold a product-design conversation, say "go build," and have a CTO agent turn
that vision into docs, coordinate a team that builds end-to-end, and surface only
the decisions that genuinely need a human. The swarm is the thin layer that
makes this real on one Mac mini and subscription-authenticated agent CLIs: a per-repo
operating contract, deterministic quality gates, and a host launcher.

The one sentence the build must not drift from: **the operator gives vision and
approves key decisions; everything else is delegated, gated, and reconciled
automatically.**

## 2. Users & primary use cases

A single technical operator, driving from a phone via Discord. They:
- spec a product conversationally with a CTO agent, then say "go build";
- approve one-way-door decisions and v1/v2 scope calls when pinged;
- approve Claude tool-permission prompts remotely; Codex instead operates inside
  a fixed non-interactive permission profile and OS/runtime capability floor
  (unattended turns intentionally ignore project exec-policy rules);
- run several products over time, one or two live concurrently.

## 3. Scope

### In scope for v1
- The **payload templates** stamped into every product repo: `CLAUDE.md`,
  `ESCALATION.md`, `TEAM_LEAD.md`, `PROJECT_SPEC.template.md`, `ADR.template.md`,
  `settings.example.json`, and the two hooks.
- `bin/swarm-init.sh` — idempotent repo bootstrap.
- `bin/swarm-up.sh` — tmux launcher/supervisor for one CTO lead per repo.
- Engine-specific Discord integration: Claude uses the existing `discord-b2b`
  plugin (including permission prompts); Codex uses its standalone bounded
  daemon (directives/replies/escalations, no interactive permission relay).
- The **CTO-authoring flow**: design conversation → "go build" → author spec+ADRs →
  confirm → decompose → spawn → integrate → reconcile.
- Deterministic gates by substrate: Claude uses `TaskCompleted`/`TeammateIdle`
  hooks; Codex requires direct `.claude/test-cmd` evidence and the trusted Git
  broker's docs-touch policy because repo command hooks are disabled.
- Single Claude team on Max (Agent Teams, in-process teammates); serialized
  Codex turns lease isolated ChatGPT profile homes per swarm.
- A per-row `claude|codex` engine selector with first-class Codex onboarding,
  isolated Discord state/ACLs, resumed threads, bounded serialized execution,
  engine-native policy surfaces, engine-aware lifecycle safety, and a live tmux
  event view.
- Quota-aware Codex profile pools: exclusive-by-default per-swarm leases,
  local-rollout-only 5-hour/weekly telemetry, inclusive configurable soft
  thresholds (95% default), structured hard-limit requeue, boundary-only
  drain/respawn, pool parking, sanitized status, and Discord announcements.
- Symmetric foreign-model adversarial review: Claude-authored work retains the
  Codex companion lane; managed Codex workers receive one terminal,
  capability-minimal Claude Fable 5 MCP tool with bounded data-only input,
  per-swarm budgets, task/profile-scoped canonical verdict artifacts, and no
  merge authority. Hard-limit replay and same-profile retry intake only the
  active attempt's profile-scoped artifact delta without resetting task budget.
- Harness-owned lifecycle parity: both runtimes normalize into one event schema;
  completion requires one final foreign-model artifact and a delivered-or-queued
  stop outcome; idle pings require strict CTO check-ins; roadmap/digests derive
  from events and result sets; corpus-commit context packs and grounding-budget
  gap reports reduce repeated recon. Runtime adapters translate and never own
  policy. Unavoidable control differences are explicit in a parity matrix and
  divergence register (ADR-0023; implemented/tested, not live).

### Explicitly deferred to v2+
- Provider-level wedged detection beyond today's engine-aware activity rails
  (Claude transcript freshness/pane evidence; Codex runtime heartbeat/state).
- A **second concurrent team** and a metered-API overflow path for bursts.
- A Claude-side **Headless Agent SDK** migration for true unattended 24/7 operation.
- A host-owned Codex worktree lifecycle that can provision isolated delegates,
  merge/push, and tear them down without exposing `.git` or mutable repo hooks.
  The exec v1 substrate uses disjoint paths in one checkout plus an
  operator-authorized side-ref branch/commit/retire handoff (→ ADR-0008).
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
- [ ] A Codex row launches only with ChatGPT subscription auth, scrubs metered
      API-key variables, applies an explicit sandbox/network policy, and exposes
      fresh atomic runtime state used by restart/watch/typing/view consumers.
- [ ] One Codex swarm reaching either fresh quota threshold rotates only its own
      profile lease at a task boundary; structured usage-limit/429 failure
      requeues the same task, and null/stale/unknown telemetry never rotates.
- [ ] A managed Codex worker can request a `claude-fable-5` adversarial review
      without granting Claude repository, exec, write, plugin, nested-MCP, or
      recursive-agent capability. Every success/failure is canonical and
      provenance-bearing; unavailable review is pending, never approval.
- [ ] The same parity fixtures pass through Claude and Codex adapters: a task
      cannot stop without a final hash-bound review artifact; stop delivery must
      be delivered or durably queued; bare idle replies fail strict check-in
      validation; grounding-budget overrun emits a pack-gap result; and ordinary
      mid-task review is refused. Roadmap state must derive from normalized
      events/result sets, never worker prose.
- [ ] A Codex engineering turn may edit and verify in one serialized checkout;
      only an allowlisted operator can ask the trusted broker to create a
      non-protected branch and commit the immutable latest-turn delta. Merge,
      push, teammate worktrees, and teardown remain explicit operator/CI work.
- [ ] `swarm-up.sh {down,status,watch}` behave as documented.
- [ ] End-to-end per engine: design conversation → "go build" → CTO authors
      `PROJECT_SPEC.md` + ADRs → operator confirms → build → escalation reaches
      the phone → milestone reported. Claude additionally proves permission
      reply + Agent Teams; Codex proves serialized direct-test evidence.
- [ ] Claude: `TaskCompleted` blocks red tests and `TeammateIdle` blocks
      source-without-docs idle. Codex: direct test evidence and broker docs-touch
      reject the equivalent false completion/commit claims.

## 5. Constraints

- **Subscription lanes stay separate.** Claude rows retain the one-Max-pool
  guidance (ADR-0004); Codex rows use their own ChatGPT login. Neither persistent
  engine may silently fall back to metered API keys.
- **Agent Teams is experimental**: flag-gated (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`),
  requires Claude Code v2.1.32+, and in-process teammates do not survive `/resume`.
- **macOS bash 3.2** — host scripts must avoid bash-4 features.
- The Claude bridge requires the `discord-b2b` plugin and its Bun runtime.
  Codex uses the separate standalone `codex-bridge` daemon; it does not load
  the Claude marketplace plugin.

## 6. Architecture overview

Six layers — control (phone) → engine adapter → host (tmux) → execution →
guardrails/memory → observability. Full writeup in `docs/ARCHITECTURE.md`.
Load-bearing decisions:

- Orchestration: Agent Teams, hierarchical lead + teammates (→ ADR-0001)
- Bridge: Discord, with Claude plugin and standalone Codex daemon adapters
  (→ ADR-0002, ADR-0019)
- Deconfliction: Claude uses per-teammate worktrees; Codex v1 uses serialized
  disjoint-path ownership and an operator Git handoff (→ ADR-0008)
- Capacity: single Max pool, 1–2 teams (→ ADR-0004)
- Gates: runtime-blind harness lifecycle policy plus substrate-specific safe
  adapters and Git controls (→ ADR-0005, ADR-0019, ADR-0023)
- Process: CTO authors docs from the conversation (→ ADR-0006)
- Runtime: engine-aware Codex App Server bridge + read-only native TUI with a
  truthful persisted fallback (→ ADR-0019, ADR-0020)

## 7. Verification plan

- The existing hooks and Git controls remain active. ADR-0023's common
  completion/check-in/roadmap/grounding boundary must pass both runtime fixtures
  and an operator shakedown before adoption; CI green remains the merge gate.
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
- ADR-0019 — Initial first-class Codex exec runtime and truthful fallback view
- ADR-0020 — Brokered global Codex App Server and filtered native TUI exposure
- ADR-0021 — Quota-aware isolated Codex profile rotation scoped per swarm
- ADR-0022 — Terminal Claude Fable 5 adversarial reviewer for Codex workers
- ADR-0023 — Harness-enforced lifecycle, evidence visibility, and runtime parity
  (draft; implemented/tested, not live)

## 9. Open questions

- [ ] (acceptance) Complete the live shakedown of the implemented ADR-0020 global
      App Server manager and per-swarm read-only facades. Production Discord
      turns now use the manager, and `swarm-view.sh` opens the native
      `codex --remote` TUI when its runtime/endpoint/thread proofs pass, with the
      persisted event/status view as a fail-safe fallback. The remaining gate is
      the real Discord/provider/native-TUI round trip plus the full Claude/Codex
      regression run; local mocks must not close that external acceptance item.
- [ ] (non-blocking) Design a host-owned Codex worktree/merge/push lifecycle with
      an authority surface as narrow and auditable as the current side-ref branch/commit/retire
      broker. Until then, operator/CI performs integration and Codex doctrine
      explicitly overrides the Claude-only substrate clauses.
- [ ] (non-blocking) Measure real token burn for one team through a full build to
      calibrate whether a second concurrent team fits the Max pool (feeds ADR-0004).
- [ ] (non-blocking) Run the end-to-end shakedown once for each configured engine
      (see `docs/SHAKEDOWN.md`) — unit and shell integration tests do not prove a
      real Discord → provider → Discord round trip.

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
  verified unchanged. The transient adoption handover tracked the then-open
  work: regenerate the 3 stale fixtures
  (CLAUDE/ESCALATION/TEAM_LEAD engineering-cto) and green `test-doctrine-compose.sh`
  (currently RED — fixtures stale by design); build the mechanism (quality
  PostToolUse hook, Stop-phase session-summary hook, hook runtime controls with
  the never-env-switchable permission-gate guard, harness-audit preflight,
  gitleaks/semgrep wiring, `LEARNINGS.md` seed, Codex-lane subscription-auth
  integration, per-stack skill fragments) with manifest lines + tests; then
  operator full-diff review → compose green → canary reserve-backend-2 →
  `swarm-update`. Per-product CI referee + branch protection + Railway staging is
  a separate operator-run per-repo checklist. The handover was removed after
  the adoption work landed; this build-log entry remains the historical record.
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
- `2026-06-14` — **Rotation hardening** (branch `rotation-harden`). Four safety
  gaps in the live account-rotation chain closed; synthetic-fixture tests only,
  nothing rotated. (1) **Auth-check hole closed.** The credswap VERIFY default was
  `claude --version` — proves the binary runs, not that the credential
  authenticates, hollowing out restore-on-failure. New `bin/swarm-auth-probe.sh`
  is now the default `SWARM_CREDSWAP_AUTHCHECK_CMD`: a REAL credential-exercising
  probe with a **3-way verdict** — (a) authenticates → exit 0; (b) auth FAILS
  (bad/expired) → exit 1 → credswap RESTORES the backup (exit 4); (c)
  authenticates BUT is rate-limited → exit 75 → credswap KEEPS the swap and exits
  **7** (ring-exhaustion signal — restoring would thrash to the also-capped prior
  account). The (b)-vs-(c) split is the crux and is proven by test. (2) **Real
  rate-limit detector.** The authoritative on-limit signal IS observable here:
  the watcher already reads it via `pane_state` rc=2 (paused-limit). New
  `bin/swarm-limit-detect.sh` turns "any live swarm pane shows a known limit
  message" into the poller's AT verdict; `--or-poll` makes the real signal the
  hard stop and delegates to the burn-proxy poller (kept as the NEAR early
  warning) otherwise. (3) **Observe/calibrate mode** (`swarm-rotate-tick.sh
  --observe`): logs estimated-burn-vs-budget + the real signal each tick and
  rotates NOTHING, so budgets can be tuned before going live. (4)
  **Ring-exhaustion terminal state**: credswap 7 → rotate **6** (fleet NOT
  relaunched on a capped account) → tick **6** — a LOUD, terminal stop that
  escalates via `SWARM_ATTENTION_CMD` instead of thrash-rotating. New tests
  `test-swarm-auth-probe.sh`, `test-swarm-limit-detect.sh`; augmented
  `test-swarm-credswap.sh`, `test-swarm-rotate.sh`, `test-swarm-rotate-tick.sh`.
  `swarm-usage-poll.sh` and the credswap secret-handling left untouched.

  **Operator runbook delta (rotation).**
  - **New env vars:**
    - `SWARM_CREDSWAP_AUTHCHECK_CMD` — now defaults to `bin/swarm-auth-probe.sh`
      (was an internal `claude --version`). Override only if you have a cheaper
      credential-exercising auth ping; it MUST exit 0/1/75 per the 3-way contract.
    - `SWARM_AUTH_PROBE_CMD` — the actual probe CALL `swarm-auth-probe.sh` runs
      (default: a cheap `claude -p` round-trip). Wire to your cheapest
      credential-touching call. `SWARM_LIMIT_PATTERNS` / `SWARM_AUTH_FAIL_PATTERNS`
      tune the capped-vs-bad classification (limit patterns shared with
      `pane_state`).
    - `SWARM_POLL_CMD='…/swarm-limit-detect.sh --or-poll'` — set the tick's poll
      seam to this to make the REAL limit signal authoritative (burn proxy stays
      the NEAR warning). Leave unset to keep the proxy-only behavior.
    - `SWARM_LIMIT_DETECT_CMD` — the real-limit detector the tick consults in
      `--observe` (default `bin/swarm-limit-detect.sh`).
    - `SWARM_ATTENTION_CMD` — escalation hook for **ring exhaustion** (every
      account capped). Run with the reason in `$1`; wire to a notifier or to
      `bin/swarm-attention.sh` from inside a swarm session. Unset → ring
      exhaustion is still terminal (exit 6) and loud on stderr, just not flagged.
  - **observe → calibrate → enable sequence (do this BEFORE live rotation):**
    1. **Observe** — run `swarm-rotate-tick.sh --observe` on the live cadence
       (e.g. the launchd interval), logging to a file, for a few days. Each tick
       emits one greppable line, e.g.:
       `swarm-rotate-tick: OBSERVE ts=2026-06-14T19:40:02Z proxy_verdict=NEAR proxy_exit=10 five_hour_pct=98 weekly_pct=41 worst_pct=98 worst_window=5h threshold_pct=95 account=max-a real_signal=OK real_exit=0 would_rotate=yes (NOT rotating: observe-mode)`.
    2. **Calibrate** — compare `would_rotate`/`proxy_verdict` against
       `real_signal`. Tune `SWARM_5H_TOKEN_BUDGET` / `SWARM_WEEKLY_TOKEN_BUDGET`
       (and `SWARM_ROTATE_THRESHOLD_PCT`) so NEAR fires shortly BEFORE the real
       limit (`real_signal=AT`), not long after or far too early.
    3. **Enable** — only then drop `--observe` and wire `SWARM_CREDSWAP_CMD` (live
       rotation still refuses without it). Keep `SWARM_ATTENTION_CMD` wired so a
       fully-capped ring escalates to your phone instead of looping. On a ring
       exhaustion alert: add a fresh account to `SWARM_ACCOUNTS` or wait for a
       window reset, then clear the attention flag.
- `2026-06-15` — **Hybrid multi-account: partition + cap-triggered failover**
  ([ADR-0018](./docs/adr/ADR-0018-hybrid-account-partition-failover.md),
  supersedes ADR-0016, amends ADR-0004). Built the substrate to pin each swarm to
  an account (throughput) and to move only a capped account's swarms to a
  non-capped one (resilience). **Ships INERT:** every path is gated on a non-empty
  6th `swarm.conf` field `ACCOUNT`; the real rows ship empty, so an all-empty fleet
  is byte-for-byte today's single-account-plus-rotation. Phases 1–3 (v1); the
  lowest-USE telemetry selector is the Phase-4 seam (not built). Pieces:
  (1) **Substrate** — `swarm_account_resolve` (sole constructor of every
  `~/.claude` path; empty label = default, byte-identical) + `swarm_conf_set_account`
  (atomic, arity-safe field-6 rewrite). All ~10 consumers thread the resolver
  per-swarm; a malformed label fails SAFE on the WORKING rail (skip / treat-as-working
  / refuse — Phase-2 Finding 1). (2) **`bin/swarm-account.sh`** — the per-swarm swap
  actuator: validate → provision-check → **auth-probe the target** (reusing
  `swarm-auth-probe.sh`'s 0/1/75 verdicts; never move onto a dead or capped token) →
  checkpoint → atomic rewrite → restart, with **revert on a clean-boundary refusal**
  and a `--reset` escape hatch. (3) **`swarm-limit-detect.sh --by-account`** — groups
  live swarms by account, reports each account's cap verdict (an account is capped if
  ANY of its swarms shows a limit pane). (4) **`bin/swarm-failover-target.sh`** — the
  v1 FALLBACK selector (least-recently-capped round-robin among non-capped accounts;
  never targets a capped one; ring-exhaustion terminal), behind
  `SWARM_FAILOVER_TARGET_CMD` so Phase 4 swaps in the lowest-use selector additively.
  Hysteresis lives behind the unwired `SWARM_ACCOUNT_HEADROOM_CMD` headroom seam and
  **never blocks an evacuation** (the carve-out, pinned by test). (5) **Router** —
  `swarm-rotate-tick.sh --failover`: detect → select → swap, spreading a capped
  account's swarms across targets; the legacy global-clock whole-fleet path is
  byte-unchanged (default mode). New tests `test-swarm-account.sh`,
  `test-swarm-failover-target.sh`, `test-swarm-failover-tick.sh`,
  `test-conf-rewrite-account.sh`; extended `test-swarm-limit-detect.sh`. Adversarial
  review gate (per the dangerous WORKING-rail path) before merge.

  **Operator runbook delta (multi-account — terms-gated, do NOT skip).**
  - **Activation is a terms-cleared, operator-only act** — running more than one real
    Max subscription in concurrent automation is what ADR-0004 flagged. The build
    never crosses it. To go live: (a) put a `<label>` in a swarm's `ACCOUNT` field;
    (b) create that account's isolated config dir `~/.claude-accounts/<label>`;
    (c) add `OAUTH_TOKEN_<LABEL_UPPER>` to `tokens.env`. Until all three exist for a
    label, that swarm stays on the default account.
  - **F1 per-pane token isolation — CLOSED (see the 2026-06-15 F1 build-log entry).**
    `launch_one` no longer blanket-sources the vault; each pane gets only its own
    `DISCORD_BOT_TOKEN` (+ labeled: its `CLAUDE_CODE_OAUTH_TOKEN`) via a scoped
    subshell source. **This is a LIVE change** — merge then RESTART the fleet to take
    it effect before provisioning any real `OAUTH_TOKEN_*`.
  - **New env seams:** `SWARM_FAILOVER_TARGET_CMD` (selector, default
    `bin/swarm-failover-target.sh`), `SWARM_ACCOUNT_CMD` (swap actuator, default
    `bin/swarm-account.sh`), `SWARM_ACCOUNT_CAPS_DIR` (per-account last-capped LRC
    markers, default `~/.config/swarm/account-caps`), `SWARM_ACCOUNT_HEADROOM_CMD`
    (Phase-4 headroom signal, unwired), `SWARM_HYSTERESIS_PCT` (default 15).
  - **Drive failover from the tick:** `swarm-rotate-tick.sh --failover` (add `--force`
    to move a working swarm, `--dry-run` to log the plan). It is additive — the
    global-clock `swarm-rotate-tick.sh` (no flag) is unchanged.
  - **`swarm-account.sh <name> <account>`** swaps one swarm by hand;
    `swarm-account.sh --reset` restores the pre-failover split from the gitignored
    `.swarm-accounts-default` snapshot (churn-free; captured at the first failover).
  - **Co-location caveat (ADR-0018):** after an account's first cap, its swarms
    spread to whatever targets were least-recently-capped and STAY there. Intentional
    co-location dissolves on the first cap; `--reset` is the only way back.
- `2026-06-15` — **F1 per-pane token isolation CLOSED** (ADR-0018 §Consequences;
  the hard go-live prerequisite). The fleet used to `set -a; . '$TOKENS'` — auto-
  exporting the WHOLE shared vault (every swarm's `BOT_*` and every account's
  `OAUTH_TOKEN_*`) — so every pane could read every token. `bin/swarm-up.sh`
  `launch_one` now isolates each pane through THREE layers: (1) the launcher no
  longer sources the vault into its own process (a cold-start `tmux new-session`
  starts the server as a CHILD of the launcher, so that would have leaked the vault
  into panes by INHERITANCE — the first adversarial pass found exactly this, my
  initial send-keys-only scoping did NOT close it); (2) the pane env line SCRUBS any
  inherited `BOT_*`/`OAUTH_TOKEN_*` first (`unset IFS; for v in $(env|sed …); do
  unset "$v"; done` — POSIX, IFS-robust, bash/zsh/sh); (3) each token is derived via
  a SCOPED subshell source `export DISCORD_BOT_TOKEN="$(. '$TOKENS'; printf '%s'
  "$<tokvar>")"` (same for a labeled account's `CLAUDE_CODE_OAUTH_TOKEN`), captured
  by the assignment so the literal never enters the send-keys string or scrollback.
  A companion sink was closed: `swarm_conf_parse_line` now charset-validates field-3
  (`TOKEN_VAR_NAME`), blanking a non-identifier so a hostile `swarm.conf` (e.g.
  `BOT_X[$(...)]`) can't execute in the launcher and re-exfiltrate the vault.
  Blast-radius re-audited: the only in-pane vault consumers are `DISCORD_BOT_TOKEN`
  (bridge MCP) and `CLAUDE_CODE_OAUTH_TOKEN` (claude); `cto-watcher` reads
  `BOT_CPO_CTO_BUS` but is OUT-of-pane (own env), unaffected. Tests:
  `tests/test-swarm-pane-token-isolation.sh` runs the REAL extracted launch line under
  a CONTAMINATED env (vault inherited, no `env -i`, incl. a hostile-`IFS` case) and
  asserts siblings/other-accounts scrubbed; INJ-1 block in
  `tests/test-conf-parse-arity.sh` proves the field-3 validation blanks-without-
  executing. Two adversarial-review passes (the second a real-`tmux` cold-start
  repro) confirm closure; the first pass is why this entry has three layers, not one.
  **NOT INERT — a LIVE change:** the operator must merge AND **restart the fleet** to
  take effect, BEFORE any real `OAUTH_TOKEN_*` enters `tokens.env`. Gate green:
  bun 142/0, shell 39/39 under bash 3.2.
- `2026-06-15` — Activation tooling (ADR-0018, the operator's terms-gated go-live
  path; the build still never crosses the gate). Three CC-tooled scripts + a runbook:
  `bin/swarm-account-provision.sh <label>` idempotently builds an account's ISOLATED
  config-dir skeleton (dir via `swarm_account_resolve` — the sole path constructor;
  qofi-swarm marketplace + `discord-b2b` plugin record; a SYMMETRIC `access.json`, one
  group per `swarm.conf` channel so a failover swap is a field edit + restart with no
  access rewrite) — reads/writes NO token, never runs `setup-token`, prints the
  operator's remaining manual steps. `bin/swarm-account-preflight.sh` is the readiness
  gate: it REFUSES (exit 2) unless the on-disk `swarm-up.sh` IS the F1 launcher (greps
  the scrub loop + scoped derive, rejects a live `set -a`), the substrate is present
  (resolver / 6th field / atomic rewrite / swap actuator), and `tokens.env` holds no
  `OAUTH_TOKEN_*` yet — checked by NAME only, the value is never read (pinned by test).
  `bin/swarm-account-verify.sh` is the read-only independence canary: a structural
  probe (each labeled account resolves a DISTINCT isolated dir + has a token) plus a
  `--baseline`/`--check --moved <label>` pair that PASSes only when exercising one
  account moves ONLY that account's usage; handles a missing token as SKIP, never a
  crash; usage behind the `SWARM_ACCOUNT_USAGE_CMD` seam (ccusage default, degrades to
  INCONCLUSIVE). `docs/ACTIVATION-RUNBOOK.md` is the ordered runbook (restart onto F1 →
  preflight → provision → OPERATOR tokens → ratify+apply labels → restart → verify),
  each step tagged CC-TOOLED or OPERATOR-ONLY, with a DRAFT label-assignment proposal
  to ratify (not applied). FLOORS honored: built/tested against temp HOME + fixtures
  only; no real token read/written, no live restart, no real `~/.claude-accounts`
  touched (verified no leak). Tests: `tests/test-swarm-account-{provision,preflight,
  verify}.sh`. Gate green: bun 142/0, shell 42/42 under bash 3.2.57. Branch merged to
  `dev` (not main); F1 + this tooling land together. Restart is still the operator's —
  merging does NOT make F1 live.
- `2026-06-17` — `swarm-sync.sh` dirty-tree refusal made **operator-owned-aware**.
  Root cause: the CPO continuously writes product specs into `products/` (operator-
  owned), so its tree is near-always dirty; the old refusal blocked ANY non-empty
  `git status`, so every routine sync refused it and it silently stayed on STALE
  doctrine — yet `manifest_apply` SKIPS operator-owned in sync mode and the commit
  set excludes it, so the refusal blocked a sync that provably wouldn't touch the
  dirty files. Change (the dirty-tree block only): classify the dirt against the
  repo's stamped `.claude/operator-owned-paths` via the existing canonical-prefix
  matcher (`_swarm_target_in_oo_subtree`); ALL dirty paths operator-owned → PROCEED
  with a note (sync skips + never commits them); ANY sync-managed path dirty →
  REFUSE as before; `--force` still overrides; `--check` unaffected. Fail-safe: a
  missing OO list yields an empty set, so classification errs to REFUSE. New helpers
  `_swarm_load_oo_from_list` + `swarm_dirty_classify_oo` in `swarm-lib.sh`. Tested
  (`tests/test-swarm-sync-operator-owned-dirty.sh`, 25 assertions: unit classifier +
  end-to-end — products-only-dirty syncs without staging the dirt; a dirty doctrine
  file still refuses; `--force` overrides). Gate green: bun 142/0, shell 43/43 under
  bash 3.2.57. Branch-only (`fix/sync-operator-owned-dirty`); operator merges.
- `2026-06-21` — CPO Stop nudge — the **mechanical backstop** behind the
  doctrine-only "Discord is the only surface" fix (`0158441`). Symptom: the CPO
  still intermittently answered the operator in the pane, not Discord — the
  doctrine was correctly stamped and live, but nothing CAUGHT a missed post. The
  engineering-cto `discord-reply-nudge.sh` exempted the CPO wholesale (its
  silence-by-default toward CTOs made a naïve nudge nag the legitimate silence).
  New `templates/cpo/hooks/discord-reply-nudge.sh` re-introduces the nudge
  CPO-shaped: it anchors the turn on the LAST Discord-framed prompt (the bridge's
  `<channel … chat_id="…">`, isMeta), and fires ONLY when that chat_id ==
  `DISCORD_OPERATOR_CHANNEL` — an **operator-origin** turn — with a substantive
  (≥150-char) final non-sidechain text and NO `reply` tool_use in the window. A
  bus/CTO turn, an unknown/unset operator channel, a delivered reply (CPO or
  teammate-sidechain), short/tool-only output, or any parse error → SILENT
  (fail-open). It changes WHERE operator-facing output goes, never WHEN the CPO
  speaks to a CTO; silence-by-default on the bus is untouched. Never blocks
  (always exit 0). Wired under `hooks.Stop` in `cpo/settings.example.json` +
  manifest `refresh` row (stamped by sync/init/onboard like every other hook).
  Floor doctrine (`_base/CLAUDE.md` §"Reaching the operator") updated — the "CPO
  is exempt" line was now false. Tests: `tests/test-cpo-discord-reply-nudge.sh`
  (14 assertions: operator→nudge, bus→silent, current-turn windowing both
  directions, delivered/short/tool-only/no-anchor/unset-channel/fail-open/
  re-entry); compose fixtures regenerated (3). Gate green: bun 142/0, shell all
  green. Branch-only (`feat/cpo-discord-reply-nudge`); **operator merges AND
  restarts the qofi-product swarm** to make it live (a hook is read at launch).
- `2026-07-02` — **Source-of-truth modes (local-canon | external-canon)** —
  promoted the deployment-core canon-sync/module-doc pattern into the template
  system (`docs/CANON-MODES.md`). New orthogonal `.claude/canon-mode` marker
  (same no-op-default posture as the ADR-0013 profile axis): absent/`local` →
  every existing swarm composes and validates byte-identically; `external` →
  the composed CLAUDE.md appends `canon/CLAUDE.external-canon.md` (external
  canon wins over module docs/code/tests; module docs are scoped projections;
  read-order routing rule; classify-and-route-upstream drift rule) plus the
  repo-local `.claude/canon-binding.md` naming the canon repo. New
  `bin/swarm-canon-enable.sh` seeds `docs/CANON_SYNC.md`, `MODULE_INDEX`,
  `TRACEABILITY_LEDGER`, `GAP_LEDGER`, and per-module
  `docs/modules/<m>/{README,CANON_MAP,INTERFACES,INVARIANTS,OPEN_GAPS,TEST_MAP,
  CODE_MAP}` packs (LIFECYCLE optional). New `canon-check.sh` TaskCompleted
  gate (manifest + settings-merge): blocks on missing/placeholder CANON_SYNC
  metadata, missing packs, dead CODE_MAP/TEST_MAP paths, INVARIANTS entries
  lacking `tests:`/`gap:`, and `[adr-required]` gaps unrouted to GAP_LEDGER;
  guaranteed no-op in local mode. Covered by `tests/test-canon-mode.sh`
  (resolution, live compose injection, every gate failure class, enable-script
  seeding/idempotency). First instance: `deployment-core`, bound to
  `qofi-product/products/deployment-core` (normative canon: product ADRs,
  requirements, live technical architecture).
- `2026-07-08` — **Force-push per-target split + hook-fix upstreaming +
  secret-scan lockfile allowlist** (operator-directed; deployment-core swarm
  friction report). (1) *Permission gate / settings*: the settings deny layer
  still blanket-denied all force-pushes, overriding ADR-0012's 2026-06-14
  relaxation — split by target: canonical force forms to `main`/`dev` denied,
  force to own `worktree-*` auto-allowed, everything else falls to the
  classifier; classifier gains a NEVER-FORCE tier (`PROTECTED ∪ {dev}`) so
  force-to-dev denies even where dev is unprotected; settings merge gains
  `permissions.deny` union + a retired-rule removal channel
  (`templates/settings-retired.conf`) so walked-back rules actually leave
  stamped repos (merge was additive-only). ADR-0012 amendment logged. Tests:
  `test-permission-gate-push-policy.sh` (116), new
  `test-settings-merge-retired.sh` (10). (2) *dod-affirm #54*: the DoD-line
  regex rejected `yes | <detail>` (template's `|` read as separator by agents)
  — now accepts a trailing `| <detail>` after the mandatory leading verdict,
  gate not weakened (new `test-dod-affirm-format.sh`, 9); and the hook now
  resolves the affirming teammate's worktree HEAD from the payload `cwd`.
  (3) *Payload-cwd upstreaming*: deployment-core's CTO fixes (#23/#26 —
  test-gate/docs-check/canon-check/session-summary/quality-check/dod-affirm
  resolve their work tree from the hook payload's `cwd`, fail-closed on the
  two block-gates for unparseable payloads) adopted into the doctrine
  templates verbatim, so the next sync no longer regresses them; the expanded
  six-hook `test-hooks-worktree-resolution.sh` (35) adopted with it.
  (4) *Secret-scan*: `.gitleaks.toml` allowlists npm lockfile SRI values
  (`"integrity": "sha512-…"`, content-bound, `regexTarget = "line"`) — public
  checksums, not credentials; every dep-adding commit had tripped the scan
  into a CTO-sanctioned bypass. CI referee scan unchanged as backstop.
- `2026-07-08` — **Session↔worktree homing — gates resolve the ASSIGNED tree,
  fail-closed (operator ruling)** (deployment-core live incident: harness
  re-homed teammate sessions into sibling worktrees; completion/idle gates
  checked the wrong tree — false-blocking a clean agent against a sibling's
  red tree (active re-fire loop) AND fail-OPEN passing a session homed in a
  clean sibling while its assigned tree held an unverified completion). The
  four gate hooks (test-gate, dod-affirm, canon-check, docs-check) now share
  an assigned-tree resolver: a payload carrying `teammate_name`
  (TaskCompleted/TeammateIdle carry it — verified against the installed CLI's
  event schema) resolves the teammate's ASSIGNED tree — the optional
  `.claude/worktree-assignments.tsv` override (`name<TAB>path`; `.` = main
  tree) else the `.claude/worktrees/<name>` convention — with the main root
  reachable from ANY sibling tree via `git rev-parse --git-common-dir`, else
  `$CLAUDE_PROJECT_DIR`; the session's re-homeable cwd is a hint only (a
  mismatch is surfaced as a re-homing NOTE). Solo/lead events (no
  teammate_name) resolve from payload cwd. EVERY unresolvable case —
  unparseable payload, no tree, no assigned worktree for the named teammate,
  python3 absent — now BLOCKS as cannot-verify: the operator ruling
  supersedes the earlier fail-soft-on-no-cwd posture on test-gate/dod-affirm
  and the fail-open posture on docs-check (session-summary/quality-check stay
  advisory fail-soft). TEAM_LEAD.md §Worktree isolation gains the homing
  discipline (spawn/re-home into the assigned tree; assignments file is
  CTO-owned). Tests: test-hooks-worktree-resolution.sh expanded to 47 —
  assigned-tree kills for both live failure modes, tsv override + `.`
  mapping, provisioning-gap block, CLAUDE_PROJECT_DIR fallback, posture
  flips. Hooks stay bash-3.2-safe (single-quote-free python3 -c resolver).
- `2026-07-09` — **Semgrep local-extension channel — closes the sync-clobber
  gap** (flagged 2026-07-08; deployment-core was unsafe for full swarm-sync
  because the manifest's semgrep `refresh` would clobber its repo-local
  rules). Two-part fix: (1) the generic rule upstreamed —
  `qofi-no-cross-module-private-import` (cross-module `private.ts` import in
  src/ is an ERROR; mechanizes CLAUDE.md §Modular design "depend only on
  contract surfaces"; inert where the convention is unused; origin
  deployment-core, operator decision 2026-07-03) now lives in the doctrine
  ruleset (12 rules). (2) New seed-class manifest artifact
  `.claude/semgrep/qofi-local.yml` (from `qofi-local.template.yml`) — seeded
  once, NEVER refreshed: the CTO's channel for repo-structural rules
  (symbol-keyed guards etc.) that must survive doctrine stamps;
  `bin/security-scan.sh` includes it automatically when present (bash-3.2
  array args). deployment-core reconciled: its symbol-keyed
  `qofi-no-cross-module-private-import-credential-vault` moved to its
  qofi-local.yml, doctrine file reset to template, CI workflow passes both
  configs; verified — 13 rules valid, rule-set identity vs the old combined
  file, CI blocking gate (--severity ERROR --error) green before and after,
  and the apparent WARN delta proven a /tmp-prefix artifact of nosemgrep
  path-derived rule ids, not a behavior change. deployment-core is now SAFE
  for full swarm-sync. Tests: test-security-scan.sh 14 PASS (+3: local
  ruleset passed as extra --config iff present).
- `2026-07-09` — **User-assisted `/login` relay — rotation re-auth without
  credential blobs** (branch `feat/login-relay`). Rotation was blocked on
  credential provisioning: `swarm-credswap-keychain.sh` needs operator-
  provisioned blobs (`SWARM_CREDSWAP_BLOB_FETCH`/`_FILE`), which can't be
  produced automatically — Claude Code auth requires the interactive `/login`
  browser flow. New actuator **`bin/swarm-login-relay.sh [--force] [<swarm>]`**
  replaces the blob-swap model with a user-assisted re-auth: send `/login` to
  the swarm's live pane (default `qofi-product`; one pane re-auths the fleet —
  the default account is SHARED keychain state), scrape the OAuth URL from
  `capture-pane` (method-picker handled with exactly one Enter), post the URL
  to that swarm's Discord channel (the swarm-watch direct-curl pattern; token
  by var name in a scoped subshell, never echoed), wait for the operator's
  browser auth (default 15 min), send Enter to resume, then verify via
  `swarm-auth-probe.sh` and map to the **credswap exit contract**: probe 0 →
  exit 0 (rotate relaunches), probe 75 → exit 7 (ring exhaustion), else exit 4
  (verify failed). Distinct loud codes for every failure leg (3 working-pane
  refusal, 5 URL timeout, 6 Discord post failed, 8 operator timeout); EVERY
  failure path Escapes out of the login UI — the pane is never left wedged in
  a modal nobody knows about, and a post failure aborts the login rather than
  leave an unrelayed link pending. All effects behind seams (tmux, post cmd,
  URL regex, picker/success patterns, both timeouts + poll interval, auth
  probe, tokens file). **Wiring (zero changes to swarm-rotate/tick):**
  `export SWARM_CREDSWAP_CMD="$SWARM_HOME/bin/swarm-login-relay.sh"` — no
  `"$1"` suffix; the account handle is logged but the ACCOUNT CHOICE happens
  in the operator's browser (the relay diagnoses the `"$1"` miswiring
  explicitly). Rotation becomes: checkpoint → login-relay (operator
  authenticates in browser) → fleet relaunch on the fresh shared-keychain
  credential. **Adversarial-review hardening** (12 confirmed findings from a
  5-lens × 3-verifier review, all fixed): (1) STALE-CONTENT discipline — every
  pane detector is freshness-gated against a BASELINE frame captured before
  `/login` (URL = bottom-most match not in the baseline; picker/success fire
  only when matching-line count exceeds the baseline's), closing the
  stale-URL-reposted, phishing-URL-relayed, picker-flag-burned, and
  false-login-success failure modes; (2) narrowed default patterns
  (`select login method`, `login successful|successfully logged in` — bare
  "subscription"/"logged in" match ordinary prose and "NOT logged in") and a
  URL-charset-bounded regex (box-drawing chrome never swallowed into the
  link); (3) single-instance mkdir+PID lock (swarm-watch idiom) — a manual
  relay can't double-drive a tick-relay's open login UI (the pane guard can't
  see one: a login modal reads as idle); (4) step-6 clean-boundary RE-CHECK —
  rotate's guard runs before the minutes-long operator wait and relaunches
  blind on hook-exit-0, so the relay re-verifies the same `repo_activity`
  signal fleet-wide and waits (bounded, `SWARM_LOGIN_IDLE_TIMEOUT`) before
  handing back, warning loud on timeout; (5) `SWARM_LOGIN_POLL_INTERVAL`
  validated (a bad value hot-looped capture-pane for up to 15 min).
  Tests: `tests/test-swarm-login-relay.sh` (87 PASS) — mock tmux (records
  send-keys, serves scripted capture frames), PATH-stubbed curl (records
  payload, scripted HTTP code), stubbed probe; covers the nine directive
  cases incl. picker-once, refuse-before-touching-the-pane, rotate-style
  `sh -c` invocation, token no-leak — plus the staleness/lock/boundary
  closes, with mutation-verified assertions (exact keystrokes, `-J` capture
  argv, curl argv shape, resume-Enter ordering, bottom-most-fresh-URL).
  **Historical transport note:** this first version published the OAuth URL as
  an ordinary channel message. The 2026-07-11 secure interaction design below
  retired that transport; it is not the current operator contract.
- `2026-07-09` — **Fix: `swarm-up.sh` codex-lead access.json seeding routed
  through `swarm_account_resolve`** — `_launch_codex_lead` (61e7156)
  hand-built `$HOME/.claude/channels/discord/access.json`, tripping the
  sole-constructor backstop (`test-account-paths-sole-constructor.sh`) and
  leaving the suite red. Now resolves the DEFAULT account's access file via
  the resolver (codex ignores account labels, so the default is the right
  source) — which also makes the seed honor `SWARM_ACCESS_FILE` uniformly.
- `2026-07-09` — **Rotation ARMED (observe mode) — rotate-tick operator env
  seam + login-relay wiring** (branch `feat/rotate-tick-arming`; arming
  ratified by operator directive). The rendered plist can't be hand-edited
  (`swarm-launchd-install.sh` re-renders would clobber it), so the installer
  gained the out-of-band channel its template comment promised:
  **`SWARM_ROTATE_TICK_ENV`** (default `$SWARM_HOME/launchd/rotate-tick.env.local`,
  GITIGNORED; committed `.example` documents every knob) — `KEY=value` lines
  merged into `com.qofi.swarm-rotate-tick`'s EnvironmentVariables at render
  time. Values are literal + XML-escaped (`& < >` — structure can never be
  injected; round-trip proven via plistlib); render FAILS loud, before any
  file is written, on bad key / missing `=` / empty value / duplicate /
  collision with a template-owned key. Absent/empty file → byte-identical
  render (ADR-0018 inertness, pinned against an independent sed render).
  Reserved key **`SWARM_TICK_OBSERVE=1`** renders `--observe` into
  ProgramArguments (calibration gate; process env overrides file).
  **Adversarial-review hardening** (5 confirmed findings fixed): XML escaping
  moved into sed — `${var//}` replacement semantics differ by bash version
  (5.2 patsub_replacement corrupts values with `>`; 3.2 keeps quoted
  replacements literally); **atomic install** — every plist renders +
  validates in a temp file and only replaces `~/Library/LaunchAgents` after
  ALL checks pass (a failed re-render can no longer leave a bad copy that
  launchd auto-loads at next login); duplicate `SWARM_TICK_OBSERVE` fails
  loud (silent last-wins could flip calibration→live); populated env file
  with no rotate-tick template refuses ("nowhere to land"); control chars in
  values rejected. Tests: `test-launchd-rotate-tick-env.sh` (73 PASS — incl.
  first-`=` split, arming+observe combo, default-path resolution, atomic
  survive-failed-rerender); existing launchd test pinned hermetic
  (`SWARM_ROTATE_TICK_ENV=/dev/null`). **This machine armed** (env
  file, not committed): relay as `SWARM_CREDSWAP_CMD` (no `"$1"`), threshold
  95, nominal ring `max-a max-b`, checkpoint hook with `"$1"`, ccusage probe
  via `SWARM_CCUSAGE_CMD=…/.bun/bin/bunx ccusage` (launchd PATH has no
  ccusage/npx; bunx verified from a minimal PATH), budget SEEDS from observed
  maxima (5h 900M — max block 912.6M; weekly 8B — heaviest week 7.77B),
  `SWARM_TICK_OBSERVE=1`. Verified: adapter emits pct JSON end-to-end; poll
  → NEAR (weekly 97.5% ≥ 95); tick `--dry-run` routes correctly; rotate
  `--dry-run` plans checkpoint → relay → relaunch (and its WORKING guard
  refused un-forced mid-turn, live proof of the rail); rendered plist lints,
  8 keys merged, agent loaded, first observe tick logged
  `proxy_verdict=NEAR … real_signal=AT … would_rotate=yes (NOT rotating:
  observe-mode)`. **Still in OBSERVE mode — going live (SWARM_TICK_OBSERVE=0)
  is the operator's call after calibration** (compare `proxy_verdict` vs
  `real_signal` in `~/.config/swarm/rotate-tick.log`; tune budgets so NEAR
  precedes real AT).
- `2026-07-09` — **Authoritative usage detector — `/usage` TUI scraper replaces
  the ccusage burn proxy** (branch `feat/usage-tui-adapter`). The operator's
  falsifier landed: token counting CAN'T measure the Max cap because CACHE
  READS don't count against it, so the ccusage proxy over-reported wildly
  (proxy said weekly 97.5% while `/usage` said 6%). New
  **`bin/swarm-usage-adapter-tui.sh`** scrapes Anthropic's own percentages from
  the `/usage` panel of an IDLE swarm pane and emits the unchanged
  swarm-usage-poll schema — the exact "real cap-% source appears → swap the
  adapter, nothing else changes" seam the ccusage adapter's header predicted.
  Pane discipline: idle-only (working panes skipped → UNKNOWN, fail-safe),
  freshness-gated against a pre-`/usage` baseline, stale-dialog self-heal, and
  a restore that NEVER interrupts a turn (Escape only when no turn is running;
  C-u otherwise). **The height problem:** the panel is taller than a headless
  80×24 pane so the "% used" bars render above the fold and the dialog doesn't
  scroll — the adapter temporarily grows the idle pane to
  `SWARM_USAGE_TUI_ROWS` (60), scrapes, and restores the exact prior geometry
  via a trap on every exit path (safe because panes are headless — the operator
  surface is Discord, not tmux attach). Weekly = MAX across all weekly sections
  (all-models + per-model). Tests: `test-swarm-usage-adapter-tui.sh` (37 PASS)
  drive a REAL captured `/usage` frame through a mock tmux (records send-keys +
  resize, serves scripted frames); cover parse, distractor-safety, never-touch-
  a-working-pane, resize/restore, self-heal, auto-select, config. Fixed en
  route: a `printf | python3 - <<'PY'` heredoc-vs-pipe bug that fed the parser
  an empty frame. **This machine rewired** (env file): `SWARM_USAGE_PROBE`
  points at the TUI adapter, **pinned `SWARM_USAGE_TUI_SWARM=qofi-product`**
  (the fleet spans >1 account — differing weekly reset dates — so auto-select
  would read a non-deterministic account; qofi-product is the rotation
  reference, the pane login-relay re-auths); ccusage probe + token budgets
  dropped. Verified live end-to-end: the launchd observe tick reads
  `five_hour_pct=33 weekly_pct=7 account=default proxy_verdict=OK`, consistent
  across ticks, pane restored + clean. **Note for the operator:** the
  `real_signal=AT` column is a PRE-EXISTING false positive in
  `swarm-limit-detect.sh` (present on the original ccusage ticks too, while
  `/usage` shows 7% weekly) — harmless in observe mode, but do NOT wire
  `SWARM_POLL_CMD=…limit-detect --or-poll` until that detector is fixed.
- `2026-07-09` — **`/usage` detector reworked to a DEDICATED, ISOLATED probe
  session — never touches a CTO pane** (branch `feat/usage-probe-session`,
  operator-directed). The prior version drove `/usage` in an idle SWARM lead
  pane; the operator flagged the risk of interfering with that lead's Discord
  coordination. Investigation confirmed Discord I/O travels over the MCP channel
  (`bridge/server.ts` — `notifications/claude/channel`), NOT the keyboard, so a
  message can never be lost — but "never interrupt a CTO" must be PROVABLE. So
  `swarm-usage-adapter-tui.sh` now drives `/usage` in its OWN throwaway session
  **`swarm-usage-probe`**: a plain `claude` on the DEFAULT account (the fleet's
  shared credential → identical `/usage` to any default-account lead), never
  bound to a Discord channel, never taking a turn. It's created once and reused
  (~1s/probe), recreated if unhealthy (crash / stale post-rotation credential),
  and is not in `swarm.conf` so a fleet relaunch never kills it. Zero contact
  with any CTO pane — verified live (qofi-product shows no probe residue).
  Removed: idle-pane auto-select, the `SWARM_USAGE_TUI_SWARM` pin, and the
  grow/restore-a-live-pane resize (the probe session is created tall). Launch is
  robust to a detached session capturing BLANK until a redraw (Ctrl-L nudge) and
  to a first-run trust prompt (accepted once; default cwd `$SWARM_HOME` is
  already trusted). **Two consistency-audit fixes folded in** (a 4-lens ×
  2-verifier adversarial audit): (major/UNSAFE) the freshness gate now requires
  BOTH the session AND a weekly header before accepting a panel — a
  half-rendered capture (session drawn, weekly not yet) previously yielded a
  weekly-missing payload that the poll read as weekly=0% → a genuinely-NEAR
  weekly reported OK, no rotation; now it waits or fail-safes UNKNOWN; (minor) a
  MAX weekly window whose own "Resets" line is off-screen no longer inherits a
  following section's reset time. Consistency evidence: parser deterministic
  (10× identical), suite non-flaky (10× 37→31 PASS), 5 launchd-env probes
  identical (75/15), and the live observe log shows a smooth real usage curve
  with `account=default` every tick. Tests: `test-swarm-usage-adapter-tui.sh`
  (31 PASS) rewritten for the dedicated-session lifecycle (create / reuse /
  recreate-and-retry), the partial-panel gate, the reset-hint fix, and an
  isolation assertion (keys only ever target the probe session). Env rewired:
  the `qofi-product` pin dropped (the probe is self-contained). ccusage adapter
  retained as documented legacy.
- `2026-07-09` — **Limit detector hardened + made authoritative (`--or-poll`
  wired live)** (branch `feat/limit-detect-robust`). Root-caused the standing
  `real_signal=AT` false positive: `pane_state()` (swarm-lib.sh) grep'd the whole
  pane for bare "usage limit", which matches Claude Code's GLOBAL informational
  banner "▎ Through <date>, you can use up to 50% of your weekly usage limit on
  Fable 5" (present in every pane) and the leads' own rate-limit conversation —
  so every pane read as paused-limit. Fix: the default patterns are narrowed to
  cap-HIT phrasing ("...limit reached", "reached your usage limit", "rate limit
  exceeded", "you have hit your", "run out of"), and a benign-notice EXCLUSION
  layer (`_swarm_default_limit_exclude_patterns`, default "you can use up to",
  overridable via `SWARM_LIMIT_EXCLUDE_PATTERNS`) drops allowance notices — a
  genuine cap line still WINS when a benign notice is also on screen (all
  matching lines scanned, not `-m1`). Blast radius is only `swarm-limit-detect`
  and the disabled `swarm-watch` (both on the shared default). New
  `tests/test-pane-state-limit.sh` (12 PASS) pins the robustness matrix: real
  cap-hit → rc=2, the Fable notice → not a cap, conversation "usage limit"/"rate
  limit" → not a cap, real-wins-over-benign, plus override coverage —
  `pane_state`'s grep had zero prior test coverage. Live: the fleet scan and
  `swarm-limit-detect` now return OK; the observe tick logs `real_signal=OK`
  (was permanently AT). **Swapped live:** the gitignored env now wires
  `SWARM_POLL_CMD=…/swarm-limit-detect.sh --or-poll`, making the real cap signal
  the authoritative hard stop with the `/usage` percentages as the delegate —
  verified end-to-end (a genuine 95% 5h state this session drove
  `proxy_verdict=NEAR`, `real_signal=OK`, `would_rotate=yes`, still NOT rotating
  under observe mode). Going fully live (`SWARM_TICK_OBSERVE=0`) remains the
  operator's call.
- `2026-07-09` — **Rotation LIVE — the operator dropped the calibration gate.** The
  observe run met the enable criteria (`real_signal=OK` on a smooth 5h/weekly
  curve, `would_rotate=no`, `account=default`), so the operator flipped
  `SWARM_TICK_OBSERVE=0` in the gitignored `launchd/rotate-tick.env.local`. The
  installer re-rendered `com.qofi.swarm-rotate-tick.plist` WITHOUT `--observe`
  (6 operator env keys merged, `plutil -lint` OK, atomic install) and reloaded
  the agent. `com.qofi.swarm-rotate-tick` now runs the full loop every 300s:
  poll → route → on NEAR/AT invoke the actuator (`swarm-rotate.sh`) to
  checkpoint every repo, swap credentials via the then-current
  `swarm-login-relay.sh` (at that time the OAuth URL was posted to the
  qofi-product Discord channel; the operator's browser picked the account) and
  relaunch the fleet. The later no-restart actuator and 2026-07-11 private
  interaction flow supersede both that actuator and its public-link transport.
  This completed the
  observe → calibrate → enable sequence begun earlier today.
  **Verification.** A kickstarted live tick logged the non-observe path
  (`verdict OK (exit 0) — headroom remains; no rotation`; 5h=9% weekly=2%), the
  loaded launchd job shows zero `--observe` arguments, and the full suite is
  green (55/55). The actuator path a NEAR tick *would* take was pre-flighted
  with `swarm-rotate.sh --dry-run`: the ring resolved (`<unset>` → `max-a`) and
  the clean-boundary guard correctly REFUSED (exit 3) because `deployment-core`
  was mid-turn — demonstrating live that a rotation waits for an idle fleet
  rather than restarting working leads (in-process teammates are RAM-only and do
  not survive relaunch). The isolated `swarm-usage-probe` session remains the
  only pane the detector touches.
  **Disarm.** Set `SWARM_TICK_OBSERVE=1` (or delete `rotate-tick.env.local`) and
  re-run `bin/swarm-launchd-install.sh`; deleting the file reverts to a
  byte-identical unwired plist, which `swarm-rotate.sh` refuses to act on. Never
  hand-edit the installed plist — the installer owns it (ADR-0018 discipline).
- `2026-07-10` — **No-restart in-place re-auth (the operator's redesign of rotation).**
  The operator ruled: one `/login` covers the fleet (shared keychain), so rotation
  must not restart any lead, must not guard for inactivity, and must fire from a
  dedicated session the moment the 95% threshold trips. Built as four pieces:
  (1) `swarm-login-relay.sh --dedicated` — `/login` runs in an ISOLATED throwaway
  session (`swarm-login-probe`, the usage-probe pattern: plain claude, default
  account, created/reused/recreated), never a CTO pane; the step-1 clean-boundary
  guard and step-6 fleet-idle re-check are SKIPPED in this mode (they existed to
  protect a CTO pane and a relaunch that no longer happen). Default mode unchanged.
  (2) NEW `bin/swarm-reauth.sh` — the no-restart actuator in the tick's
  `SWARM_ROTATE_CMD` seam (tick unchanged): runs the relay `--dedicated`, remaps
  relay 7→6 (ring exhaustion) while collapsing the relay's own 6 (Discord-post
  fail) to 5 so it can never masquerade as exhaustion; `--next` prints nothing
  (the browser picks the account — no ring); on success recycles the /usage probe
  so the next poll reads the NEW account (a long-lived claude may not adopt a
  rotated credential in place — an unrecycled probe would re-trigger re-auth
  forever). No checkpoint (nothing restarts → nothing to save).
  (3) NEW `bin/swarm-reauth-verify.sh` — the fail-loud net the operator chose over
  guards: every live tick it scans CTO panes; one PARKED on a cap banner while the
  account has headroom (verdict OK/NEAR) = a lead that missed the in-place re-auth
  → ONE deduped Discord alert naming it; suppressed on AT/UNKNOWN; read-only.
  (4) `swarm-rotate-tick.sh` — a `SWARM_TICK_ALERT_CMD` standing step, before
  routing (so it fires on OK — the stuck-pane case), dry-run-skipped, best-effort,
  default-unset no-op.
  **Trigger reversal (operator-confirmed):** the percentage poll is the sole
  re-auth trigger; the cap banner is demoted from authoritative (`--or-poll`) to
  ALERT-ONLY — under no-restart a stuck pane's banner would otherwise loop the
  re-auth every tick. `.example` documents Model A (no-restart) vs Model B
  (legacy restart) and the do-not-wire-`--or-poll`-under-A rule.
  **Verification:** 4 new test files (83 assertions: dedicated isolation invariant
  — no key ever reaches a CTO pane; exit-code remap incl. the 6/5 collision; alert
  dedup/headroom-gate/non-interference; tick alert ordering incl. fires-on-OK);
  full suite 59/59. Adversarial review (5 lenses → 17 findings → 3 refuters each):
  ZERO survived; two truthful-but-harmless notes fixed anyway (the
  `SWARM_LOGIN_RELAY_DEDICATED=false` footgun now normalizes OFF-spellings; probe
  header comments no longer claim `swarm-up down` can't kill the probes — it can,
  harmlessly: they're stateless throwaways).
- `2026-07-10` — **Pane-notice trigger (the operator's fallback ask) + signature
  latch.** Root cause of the missed 95% trigger: the fleet's shared keychain item
  is last-writer-wins across processes' token refreshes, so with mixed-account
  processes running, the /usage probe read a DIFFERENT account than the leads
  were burning (weekly % non-monotonic across ticks; keychain mdat rewritten with
  nobody logging in) — and the one account near its cap was invisible to the
  percentage poll. Fix: `swarm-limit-detect --or-poll` gains a PANE-NOTICE tier —
  the yellow "You've used N% of your <t> limit · resets O" / "Approaching <t> ·
  resets O" warning is PER-LEAD ground truth, immune to the probe split-brain. At
  N ≥ threshold it fires NEAR ahead of the delegated poll; a cap banner still
  outranks (AT). Matching is ERE and shaped against quoted text (digits+%
  required; Approaching form requires "· resets"; labels matched generically —
  v2.1.206 emits session/weekly/Opus/Sonnet/"Fable 5" variants, verified in the
  binary). BOTH pane tiers go through a SIGNATURE LATCH (anti-loop, the reason
  pane text was previously alert-only): fire once per window signature
  (percent-stripped matched lines), pending → latched only when swarm-reauth
  SUCCEEDS; latched is an epoch-stamped SET (subset-suppression, 7d TTL) so
  shrinking unions/notice-cap alternation never re-prompt an answered window; an
  unanswered prompt re-prompts hourly (SWARM_PANE_REPROMPT_COOLDOWN), not every
  tick; an unwritable latch dir fails toward the poll, never spams. Live ticks
  now log a `tick ts=` line.
  **Review:** adversarial workflow (operator-stopped mid-verify; all 5 lenses +
  52/93 refuter votes harvested from the journal): 31 raw findings, 2 refuted,
  14 survived full panels — all survived findings fixed, incl. two the tests
  themselves caught: the reauth suite was mutating the REAL ~/.config/swarm
  latch, and `${VAR:-default}` silently truncated the regex default at its first
  `}` (hoisted). Cap-tier "near-dead on v2.1.206" was disproven in the binary
  ("limit reached" matches both current banners). Tests: notice tier 41 asserts
  incl. a REAL-grep-path case via a fake tmux (patterns+exclusions exercised, not
  seam-bypassed); reauth 41. Suite 60/60.
- `2026-07-10` — **Transcript tier: the durable limit record replaces the visual
  lottery as the primary trigger.** Second missed limit (deployment-core): its
  session logged API `rate_limit` events at 11:03Z and 11:51Z (`"error":
  "rate_limit","isApiErrorMessage":true,"apiErrorStatus":429`, top-level keys in
  the session jsonl) while every 300s pane sample all day showed nothing — the
  TUI's status strip is a transient RENDERING (cycles/clears; the notice also
  never persists into scrollback), so pane capture is a sampling lottery. The
  lead's transcript is the RECORD. New highest-priority tier in
  `swarm-limit-detect --or-poll`: scan each swarm's newest transcript tails
  (lead dir + worktree dirs, the `repo_activity` naming convention) for a
  top-level rate_limit event younger than `SWARM_XSCRIPT_LIMIT_WINDOW` (900s)
  → AT. Top-level-key JSON parsing means a lead merely *writing about* rate
  limits can never trip it. Same latch machinery, signature = swarm + UTC hour
  bucket (one prompt per swarm-hour; re-prompt cooldown bounds the rest).
  `SWARM_XSCRIPT_TAIL_BYTES` (default 4MB) sizes the tail scan — the first live
  proof missed 22MB-deep events with a 256KB tail, so the knob is generous and
  the failure mode is pinned by test. Hermetic: an injected pane stub disables
  the tier unless forced; the real-grep test now pins CLAUDE_PROJECTS_DIR.
  **Retro-proof:** with the window widened over today, the tier fires exactly
  on the missed event (`AT — deployment-core … rate_limit at 11:51:06Z`).
  Also observed in transcripts: `authentication_failed` burst on
  phase2-extraction at Jul 9 14:28Z — the didn't-adopt-credential scenario is
  real; the stuck-pane alerter remains its net. Tests: 15 new (top-level vs
  nested, window, latch bucket, re-prompt, tail knob both directions,
  hermeticity). Suite 61/61.
- `2026-07-10` — **Live drill caught a URL-truncation defect; fixed + gated.**
  First end-to-end drill of the notification pipeline (operator-approved): the
  relay created the isolated session, captured "the URL", posted to Discord —
  and the operator's browser rejected it ("Missing state parameter"). The real
  OAuth URL is ~450 chars; the TUI HARD-wraps it at pane width into separate
  drawn rows (`capture-pane -J` cannot rejoin hard wraps), and the relay posted
  the first 200-col row. Fix: (1) the dedicated probe session is created 800
  cols wide (`SWARM_LOGIN_PROBE_COLS`, ~2× the observed URL) so the URL renders
  unwrapped; (2) a COMPLETENESS gate (`SWARM_LOGIN_URL_REQUIRE`, default
  `state=` — the URL's last parameter) — a candidate lacking it is treated as
  not-yet-rendered, and the relay times out LOUD (Escape, exit 5, truncation
  warning naming the fix) rather than ever posting a broken link again. Gate
  protects the legacy CTO-pane mode too, where the width is not ours to set.
  Drill value proven twice over: the pipeline delivered a Discord post within
  seconds of firing (delivery works), and it surfaced a defect no stubbed test
  could see (the mock frames never hard-wrapped). Pinned: `-x 800` in the
  create argv; truncated-URL → exit 5 + zero Discord posts. Suite 61/61.
  This drill describes the retired public-link transport. URL completeness and
  fresh-pane detection remain enforced, but the complete URL now crosses only
  private host state into an owner-only ephemeral interaction.
- `2026-07-10` — **Drill #2: full happy path proven live — with one flow
  discovery.** Post-fix re-run: 450-char URL captured intact (state= present),
  posted to Discord; operator authenticated; success detected → resume Enter →
  auth probe verified → /usage probe recycled → latch armed → exit 0. Zero CTO
  panes touched; no restart. Credential now support@qofi.ai (operator's browser
  choice, per the model). **Discovery:** the "just press Enter" behavior the
  relay was built against is LOCATION-DEPENDENT. Same-machine /login uses a
  localhost OAuth callback (code auto-delivered). A RELAYED URL opened on
  another device uses the paste-back variant (redirect_uri=platform.claude.com/
  oauth/code/callback): the browser shows a CODE the user must paste into the
  pane. The relay is one-way (posts to Discord, cannot read replies), so a
  fully remote login cannot complete unaided — this drill's code was
  hand-carried into the pane via send-keys. The proposed raw-channel v2 — poll
  for a code-shaped reply and type it into the pane — was rejected and is
  superseded by the 2026-07-11 host-owned interaction flow below. A code in an
  ordinary channel is already disclosed to history and model ingress; asking
  the product swarm to repeat it would add no authentication property and has
  the shape of credential exfiltration.
- `2026-07-11` — **Secure two-path Claude auto-rotation authentication.** The
  exact consumer is Claude Code `/login` running in the isolated
  `swarm-login-probe` tmux session. Its completion mode is location-dependent:
  when the authorizing browser can reach Claude Code's localhost callback the
  credential arrives automatically and the relay resumes the TUI; a remote
  browser instead displays an `authorization#state` value for the fresh Claude
  prompt. The public channel now receives only a generic secure-control button.
  The canonical owner (pinned by the private ACL's `loginControlOwnerId` and
  required in both the top-level and target-channel ACLs)
  receives the OAuth URL through an ephemeral interaction and, only for the
  remote case, submits the value through an owner-only modal. Interaction
  events are handled by the bridge control plane and never become
  `messageCreate`, MCP notifications, transcript/model input, or a request for
  the swarm to echo the credential.

  The host protocol is v1 and fail-closed: before touching `/login`, the relay
  requires a fresh readiness record bound to the exact channel and bot from a
  live updated bridge. Each private request/response is owner-held, bounded,
  nonce-bound to owner/channel/message/bot/expiry, and single-use; the modal
  response is atomically published and replay-refused. The relay waits for a
  fresh Claude paste prompt before piping the response directly into a named
  tmux buffer via stdin, without a shell variable, argv, environment entry, or
  log. Automatic callback success wins the race and discards an unused modal
  response. Every completion/failure path removes the generic control and
  private request/response records; timeout also Escapes the login UI. The
  permission gate denies model tools access to `login-control`, including
  canonicalized/symlinked paths, and attachment snapshots reject link tricks
  that could expose private control-state inodes. This replaces public OAuth
  links and raw-channel paste-back without changing Claude's default-pane or
  no-restart dedicated semantics.

  Final audit hardening removed the deployment-specific owner literal:
  provisioning now pins `loginControlOwnerId` in the private ACL, with a
  single-principal legacy fallback and fail-closed ambiguity. Missing state is
  created privately; legacy owner-held non-writable `0755` Discord state stays
  compatible while `login-control` remains exact `0700`; unsafe control setup
  disables re-auth readiness without taking normal Discord chat offline.
  Symlinked account/config ancestors, writable or ACL-bearing state, incomplete
  request writes, replay, and temp-file residue are rejected. Labeled ACCOUNT
  rows are refused because this actuator changes only the shared default Claude
  credential. Agent permission gates deny invocation of `swarm-login-relay` and
  `swarm-reauth` themselves, preventing hermetic test seams from becoming a
  model-controlled redirect. Verification: 377/377 Bun tests, all 76 canonical
  shell suites, bridge bundle, `git diff --check`, and both production dependency
  audits pass with zero reported vulnerabilities.

  A reported post-switch 95% miss was traced to the deliberate live-scheduler
  `bootout` used during this security rollout, not threshold math: the prior
  account fired at exactly 95%; the new browser-selected account was sampled at
  weekly 93%, 93%, then 94%, after which no tick ran. A regression now proves
  that a fresh post-reauth pane latch cannot mask the independent percentage
  poll when a newly selected account moves 90% → exactly 95% (`NEAR`, exit 10).

  The first secure live retry then exposed an independent launchd verifier
  defect: `/login` completed, but the installed tick job had no `PATH` entry and
  Claude existed only at `~/.local/bin/claude`, so the old auth probe returned 1
  before exercising the credential. The default probe now resolves an explicit
  absolute `SWARM_CLAUDE_BIN`, then PATH, then the native install path, and
  invokes the resolved executable directly rather than interpolating it through
  a shell. Post-login verdict 1 is retried for a bounded five attempts at two-
  second intervals to cover credential-visibility handoff; capped verdict 75 and
  unexpected verdicts remain immediate, and persistent failure still fails
  closed. The exact minimal-launchd environment now authenticates. Focused
  verification: auth probe 22/22, relay 130/130, dedicated relay 38/38, and the
  tick→reauth→secure-relay chain 31/31.
- `2026-07-11` — **First codex-engine lead live: press-backend.** Operator trial
  of the codex bridge: swarm.conf row gained `| codex` (field 7) and the single
  swarm was cycled. First launch FAILED — `_launch_codex_lead` typed one
  ~800-char line (doctrine inline) into the pane and the tty mangled it; the
  daemon never started. The codex launch path had zero test coverage. Fix: the
  program now lives in a generated `$state_dir/launch.sh` (mode 700, no
  secrets — the bot token rides the engine-neutral pane env line) and the tty
  receives one short source line; the launcher `exec`s the daemon (pane
  process IS bun, verified). New test pins: doctrine in the file never the
  tty, all send-keys short, exec line, mode, no-token, access.json seeding
  (15 asserts; suite 62/62). Gateway-connected wait 30→75s (bun cold-start +
  Discord handshake overran 30s → false-negative WARN). Live: `gateway
  connected as press-backend-bot#3377`, bound to its channel, using the early
  classic workspace-write sandbox. The initial operator note assumed Claude transcript/pane
  detectors would be inert for Codex. The parity audit later that day disproved
  that assumption: false-idle status could make restart/rotation unsafe. That
  claim is superseded by the engine-aware runtime-state work below. Round-trip
  (operator message → Codex reply in-channel) remained pending at this point.
- `2026-07-11` — **First-class Codex hardening and Claude-preserving lifecycle.**
  Added the engine-aware row schema/dispatch without changing blank/Claude
  semantics; a dedicated hidden macOS account, root-attested exact runner argv,
  fixed Node/Codex/Bun/npm/npx toolchain, subscription-only auth, inode-bound
  workspace authority journals, bounded serial Discord turns, canonical live
  ACL reauthorization, retry notices, attachments, operator Git broker, runtime
  state, and a full-screen redacted event view. Registration, migration,
  removal, launch, attach, and sync now serialize their destructive boundaries,
  account for shared physical repos, fail closed on aliases/replacements, roll
  back uncommitted AGENTS/runtime authority, and preserve Claude account/TUI/
  hooks/worktree behavior. The native Codex TUI is still not shared: that
  requires the deferred App Server + `codex --remote` single-writer protocol.
  Security review also closed wildcard sudo argv, Directory Services rollback,
  ACL, stale-process, config-CAS, filesystem TOCTOU, partial-index sync, and
  path-form engine-authority findings. Final local verification: canonical
  `npm test` exit 0 (311 Bun tests across 32 files plus all 73 shell suites,
  including the 6-test trusted-helper and 32-test runtime-provisioning Python
  suites); both Bun bridges bundle from frozen locks; both production audits
  report no vulnerabilities. A real Discord→provider→Discord shakedown remains
  deliberately open for each engine and is not implied by mocks.
- `2026-07-11` — **Final Codex/Claude integration audit closed.** The follow-up
  adversarial pass made release linearization crash-safe with an exact atomic
  exchange protocol for lifecycle, daemon, and repository locks; malformed,
  live-owner, pre-exchange, exchanged, and finalized evidence now fails closed
  or recovers only through its bound receipt. Privileged workspace preparation
  now rejects cross-device entries, hard-linked/duplicate regular inodes,
  foreign owners, and set-id/sticky regular files before mutation. Root runner,
  lifecycle, attestation, sudoers, and toolchain authority is installed and
  invoked only through ACL-free root-controlled chains. The compatibility
  Codex reviewer retains Claude's historical contrarian lane without exposing
  shell/tools or accepting loose `~/.codex/auth.json` state. Malformed engine
  rows are rejected before restart, rotation, login relay, launch, or removal;
  Codex onboarding preserves `--engine codex`; and launch fixtures no longer
  write fake toolchains into the real user home. The supported Codex view is a
  full-screen read-only redacted event/status view. Native `codex --remote`
  remains deliberately gated on ADR-0020's global App Server manager,
  connection-bound lease, and per-swarm filtering gateways. Final verification:
  canonical `npm test` exit 0 (359 Bun tests across 34 files plus all 75 shell
  suites, including 188 Codex-launch, 123 recovery, and 44 privileged-runtime
  cases); Claude-focused regression audit found no remaining high/medium issue;
  all three Bun entry points bundle; both production dependency audits report
  no vulnerabilities; shell/Python syntax and `git diff --check` are clean.
  Real Discord→provider→Discord and native multi-client App Server shakedowns
  remain explicit external acceptance work, not claims made by local mocks.
- `2026-07-11` — **Live hidden-user bootstrap race closed.** The first privileged
  press-backend install exposed an asynchronous macOS launchd boundary:
  `bootstrap user/502` returned at 21:37:01.658, the one-shot `asuser` UID proof
  ran 5 ms later while launchd was still in bootstrap mode, and the domain
  became ready at 21:37:01.740. Marker-bound rollback removed the user domain and
  withheld every root execution authority; because the exact Qofi-marked user and
  group predated that transaction, it intentionally retained them for verified
  idempotent reconciliation instead of deleting pre-existing state. The error was
  blank because it printed successful-bootstrap stderr rather than the failed
  proof's output. Bootstrap readiness now retries only the fixed read-only UID
  proof for at most five seconds and emits bounded control-stripped diagnostics.
  The retry then exposed the deeper macOS 26 rule: `asuser` switches bootstrap/
  audit context but not credentials, and a pre-exec drop to uid 502 made every
  attempt fail `Could not switch to audit session ... Operation not permitted`.
  Both root lifecycle and runner now execute root `asuser` first, followed by the
  same shell-free `/usr/bin/python3 -I -S` trampoline: exact bidirectional pwd
  mapping, nonzero UID/GID, `initgroups` -> `setgid` -> `setuid`, real/effective
  credential and no-root-group proof, then exact absolute-argv `execve`. Lifecycle
  login retains its terminal; runner process-group cleanup uses
  `start_new_session=True`. The next live precommit proof exposed one remaining
  duplicated parser: the runner treated `IsHidden` as a generic scalar and
  rejected macOS's normal `dsAttrTypeNative:IsHidden: 1` rendering. Its dedicated
  boolean reader now matches the lifecycle's exact allowlist (direct/native key;
  `1`/`YES` true and `0`/`NO` false) while rejecting standard aliases, coercion,
  and extra fields. Verification: 55/55 privileged provisioning tests,
  91/91 Codex account-lifecycle assertions, 26/26 runtime-state assertions, and
  Python source/syntax checks pass. The remaining acceptance step is a privileged
  installer rerun proving the live root-asuser handoff on this host.
- `2026-07-11` — **Normal pnpm hard links and the press-backend toolchain are
  first-class.** The next live install reached workspace capture and rejected
  four esbuild inode pairs (eight names) produced by pnpm entirely beneath
  `node_modules/.pnpm`. The global hard-link guard remains: a package inode is
  exempt only when a complete descriptor-bound scan observes every alias,
  every name stays in the ordinary `node_modules` tier, observed aliases equal
  `st_nlink`, and the operator-owned ACL-free inode is runtime-readable,
  executable when needed, and not group/world writable. Proven inodes are
  never chmodded, chgrped, or journaled; surrounding directories remain managed
  so pnpm can replace entries atomically. Outside, cross-tier, mutable, foreign,
  partial, special, set-id, ACL-bearing, and cross-device aliases still fail
  before root mutation. The daemon repeats the same closed-set proof. Because
  press declares `pnpm@9.12.3`, the global root toolchain now copies that exact
  already-populated Corepack cache with its audited locator/integrity record and
  invokes it only through fixed Node plus direct `pnpm.cjs`; root/runtime never
  dispatch Corepack. Installer, host preflight, runner, and daemon isolation all
  enforce the singleton version. npm-only reinstalls preserve it, while pnpm
  home/store/XDG state is private per turn and automatic manager downloads are
  disabled. Claude paths and ambient developer toolchains are unchanged.
  Read-only validation of the real press tree scanned 29,786 journalable entries
  and omitted exactly the eight proven hard-link names. Focused verification:
  61 privileged provisioning tests, host-preflight/Python-source suites, and 53
  dedicated-runtime/toolchain/Codex Bun tests pass. The privileged live rerun
  remains the next external acceptance step.
- `2026-07-11` — **Press runtime installation committed; pre-login is now an
  explicit safe state.** The live verifier exposed macOS `fwalk` classifying
  pnpm directory symlinks (first `node_modules/typescript`) in `dirs` while
  `O_DIRECTORY|O_NOFOLLOW` returns `ENOTDIR`. Verification now double-lstats and
  skips only a stable nofollow symlink; every nonlink is descriptor-bound back
  to its device/inode/type, so a directory substitution still fails closed. A
  read-only press scan skipped 1,083 proven symlinks, opened 25,330 nonlinks,
  and reported no failures. The next install committed the exact hidden user,
  toolchain, sudoers, attestation, registry, and workspace authority with no
  credential present, which is the intended install→login transition. Missing
  auth previously leaked a raw `FileNotFoundError`; lifecycle, runner, host
  preflight, and daemon validation now report the terminal login remediation.
  Operator-side checks use metadata only and cannot read auth contents. Root
  login/runner checks bind a private parent plus nofollow singleton auth inode,
  enforce the size/owner/mode/ACL boundary, force ChatGPT login, run from the
  hidden private home with no ambient API/access token, and require exact
  `Logged in using ChatGPT` before a final inode recheck. Operator auth is never
  copied or used as fallback. Verification: 68 privileged provisioning tests,
  26 runtime-state tests, host-preflight/Python-source suites, and 53 focused
  Bun tests pass. The remaining live acceptance sequence is idempotent reinstall
  of the final helper, terminal-only login, refreshed tmux credentials, verify,
  then a real press-backend Discord round trip.
- `2026-07-11` — **Security.framework backing storage is opaque; authentication
  remains file-only.** The live rerun showed that macOS creates a private
  platform-UUID subtree beneath the hidden user's `Library/Keychains` while
  the user keychain search list is still empty. Lifecycle and runner now bind
  and validate the runtime-owned, ACL-free, non-writable directory boundary
  without enumerating, reading, deleting, copying, or requiring emptiness of
  its contents. Install and pre-login clear and prove the hidden search list;
  login proves it again after exact ChatGPT status; the fixed runner proves it
  before every unattended child. Every auth-bearing and turn invocation also
  pins `forced_login_method="chatgpt"` plus
  `cli_auth_credentials_store="file"`, leaving the hardened singleton
  `.codex/auth.json` as the only accepted provider authority. Because the old
  fixed lifecycle rejects the OS-created subtree before reaching self-update,
  an explicit, attested, locked, transactional `refresh-lifecycle` operation
  may replace that one root file; the ordinary idempotent installer must then
  update and re-attest the runner before login. Verification: 70 privileged
  provisioning tests, the Python-source/host-preflight contracts, 61 focused
  bridge tests, 71 Codex-review assertions, and 188 Codex launch assertions
  pass. Live refresh, reinstall, terminal login, and final press-backend verify
  remain the external acceptance sequence.
- `2026-07-12` — **Live press-backend daemon shakedown reached the privileged
  sandbox boundary and closed seven host-integration gaps.** Login and the full
  v2 root authority verify succeeded. The first launch then showed that macOS
  ships `/usr/bin/sudo` root:wheel mode 04511, so host preflight now admits only
  that exact execute-only system binary while every other unreadable wrapper
  still fails shebang inspection. The generated `env -i` launcher now carries
  the same validated Discord operator/bus role set as its response boundary;
  tests execute both engineering and CPO launchers and inspect the final daemon
  environment. Because Bun/Node omit a live supplemental group and cannot
  `realpath` through the intentionally narrow hidden-home ACL on this host, the
  daemon proves inherited groups with fixed isolated system Python and uses
  lexical/no-symlink hidden-directory checks while leaving descriptor/content
  authority with the root runner. Isolation probes now run from the canonical
  workspace. Dedicated tool resolution prefers the direct root-owned Command
  Line Tools Git instead of Apple's `/usr/bin/git` xcrun shim, avoiding an
  ambient `/var/folders` cache capability. Finally, the initialized user domain
  legitimately retains one `/usr/sbin/distnoted agent`; lifecycle and runner
  treat quiescence as zero payload processes and exempt only one stable
  PID-1/session-0/process-group-leader instance with exact saved credentials,
  libproc path, argv, and SIP-restricted image metadata. Verification: 72
  privileged provisioning tests, Python-source/host-preflight contracts, 61
  focused Bun tests, 71 Codex-review assertions, 193 launch assertions, and 71
  usage-threshold/account-switch assertions pass. The installed lifecycle and
  runner must be refreshed/re-attested once more before resuming the live
  sandbox and Discord round trip.
- `2026-07-12` — **First-class App Server/native-view implementation passed its
  final local release gate.** A real manager-backed review exposed that Codex
  0.144.1 rejects `runtimeWorkspaceRoots` unless initialize explicitly opts in
  to `experimentalApi`; only the global manager client now advertises that
  capability, while generic clients and attestation remain default-off. A
  definitive registration-free review rejection now retires the suspect
  generation before restoring readiness, while registered workspace ambiguity
  remains blocked. Replacement of the affected legacy manager is authorized
  only by the fixed root helper after exact root admission, process credential/
  parent/group/argv, launcher-flock, socket-inode, kernel-peer, stopped-health,
  runner-lock, and hidden-UID quiescence proofs; install/uninstall hold the
  launcher then runner locks across manager authority mutation. Tmux names never
  authorize termination. The operator view now explains why it selected its
  redacted fallback and opens the pinned read-only native TUI once the configured
  channel has a persisted thread and healthy facade. The late aggregate gate
  also closed a `review-runner` deadline/output-cap classification race.
  Verification: 485 Bun tests across 41 files plus all 79 canonical shell suites
  pass; the privileged provisioner has 97 cases, replacement wrapper 31, and
  native-view/orchestration 81. The manager bundle reproduced byte-identically
  twice at `44c362b6e25d1e7b57f90595a6150a0a24fcca330bc804a15db1907d275f7dd0`
  (249,903 bytes), all entry points bundle, both production dependency audits
  report no vulnerabilities, and diff/shell/Python syntax checks are clean. The
  remaining external gate is the sudo-backed live install/recovery followed by
  a manager review, press-backend daemon/facade, native TUI, and Discord round
  trip on this host.
- `2026-07-12` — **The live press launch exposed and closed the final Codex
  0.144.1 effective-policy and persisted-thread lifecycle gaps.** The installed
  runtime and press workspace first passed the complete v2
  runner/account/group/toolchain/auth/canary verifier. Daemon registration then
  correctly failed closed because the manager treated the response's legacy
  `sandbox.writableRoots` projection as authoritative. Codex intentionally
  removes the workspace cwd from that compatibility field; the experimental
  `runtimeWorkspaceRoots` and `activePermissionProfile` fields carry the actual
  named-profile authority. The manager now requires exactly one canonical
  registered runtime workspace, both ambient-temp exclusions, and only the
  exact outside-workspace write roots granted to the active turn. The named
  profile explicitly denies `:tmpdir` and `:slash_tmp`, then grants back only
  the private turn directory. It no longer sends a legacy `sandboxPolicy` on
  `turn/start`, because Codex converts that field into a replacement legacy
  profile and would discard protected-path read rules.

  Registration and generation restore also no longer resume persisted threads.
  Codex ignores new permission/config overrides when a subscribed thread is
  already loaded, so readiness now populates the filtered native facade with
  `thread/read(includeTurns:true)`, which preserves full history without loading
  or subscribing. The actual turn performs the only cold resume with the current
  hardened profile; cross-repo stored cwd metadata is refused, and stale rollout
  errors remain eligible for the one bounded fresh-thread fallback. A live
  isolated probe against a copy of the hidden runtime's press rollout proved
  `thread/loaded/list` stayed empty before and after the history read. The
  metadata publisher's final aggregate run also corrected one hermetic
  `/private/tmp` launch fixture so it models a prepared operator-group checkout
  rather than macOS's non-member wheel group; production publication stayed
  strict. Final verification: canonical `npm test` exit 0 with 488 Bun tests,
  2,067 assertions, 41 files, and all 79 shell/Python suites; privileged runtime
  provisioning 97/97; manager control 3/3; recovery wrapper 31/31; launch
  integration 200/200; `git diff --check` clean. The manager bundle reproduced
  byte-identically twice at
  `bd479ac8ef2fa121fe57c6c3ea6a658b98f3843e68b3df8f6f1a6a54620467b1`
  (250,188 bytes). Installing that new root-attested bundle and repeating the
  press daemon/native-TUI/Discord shakedown remain the external completion gate.
- `2026-07-12` — **The press-backend live acceptance round trip passed, and the
  native Codex transcript bootstrap is now protocol-correct.** The final v2
  installer and verifier succeeded on the real press workspace; the global
  Codex 0.144.1 App Server registered exactly one idle swarm and published its
  owner-private per-swarm Unix facade. A real Discord message entered the
  persisted thread, completed through the hidden `_qofi_codex` runtime with no
  workspace changes, returned the exact visible bot reply
  `QOFI_PRESS_BACKEND_OK`, and restored the manager to idle. The native viewer
  launched the pinned full Codex TUI in its separate auth-free,
  navigation-enabled tmux session behind the read-only facade. Its first live
  open exposed two final viewer-only defects. On macOS,
  direct extended-ACL enumeration is unsupported for Unix sockets; socket ACL
  validation now uses bounded fixed `/bin/ls -lde` output between exact inode
  identity checks and still fails closed on every ACL, replacement, or malformed
  result. The TUI then opened with a blank transcript even though the facade had
  both completed turns. Pinned Codex source showed that native resume omits
  `initialTurnsPage` and replays only chronological `thread.turns`; the facade
  had unconditionally done the inverse. It now honors `excludeTurns`
  independently, returns an initial page only when requested, and supplies a
  bounded newest history window in oldest-to-newest order for native replay.
  Tests cover native/default, excluded, paged, combined, and chronological read
  shapes. Final-tree verification: 488 Bun tests, 2,077 assertions, 41 files;
  all 79 canonical shell/Python suites; native-view/orchestration 81/81;
  runtime-state 27/27; clean diff whitespace check. The root manager bundle
  reproduced byte-identically twice at
  `92b9f6dd8f81ab14885271c3a9c52f832d7b9f7563fc62bbc41c0745858e5196`
  (250,262 bytes). The sudo-backed idempotent install then published that exact
  bundle, the verifier repeated the complete v2 authority proof, and a fresh
  native pane visibly replayed both persisted Discord turns in chronological
  order—including `CODEX LIVE OK` and `QOFI_PRESS_BACKEND_OK`—inside the full
  Codex 0.144.1 interface. The external acceptance gate is complete.
- `2026-07-12` — **Every first-class Codex surface is pinned to GPT-5.6-Sol
  Ultra, and the native viewer is scrollable and responsive.** Managed classic
  turns, App Server start/resume, the native facade's model/config contract,
  and the contrarian review lane all use `gpt-5.6-sol` with literal effort
  `ultra`; every historical lower-model route has been removed. Review retains its
  tool-less authority by reaping the shared App Server and invoking the fixed
  hidden-UID root runner through Codex's built-in `review -` mode, whose pinned
  0.144.1 review session disables model-level delegation; shell/unified exec,
  network, MCP, hooks, plugins, and workspace roots remain disabled. The
  privileged workspace grammar now requires both `:tmpdir=deny` and
  `:slash_tmp=deny` in addition to the root/minimal baseline.

  Native `swarm-view` runs inline with `--no-alt-screen`, a 100,000-line tmux
  history, mouse/copy-mode navigation, `window-size latest`, and aggressive
  resize. Live host proof entered copy mode with retained history and propagated
  a 149x47 client to an exact 149x47 pane. The facade—not a tmux read-only
  attach—is the mutation boundary and forwards no viewer writes; a reopened
  viewer replays the newest 512 turns or 8 MiB. The final audit also exposed an
  auto-rotation hang: macOS `security ... -w` can ignore piped stdin while a
  controlling TTY exists. The new bounded no-controlling-TTY helper keeps the
  credential off argv, pins `/usr/bin/security`, reaps on timeout/signals, and
  passed a real synthetic-Keychain PTY round trip with guaranteed cleanup.

  Final-tree verification: canonical `npm test` passed under a live PTY; 494
  Bun tests, 2,162 assertions, 42 files, and all 84 shell/Python suites passed;
  privileged runtime provisioning 98/98; native-view/orchestration 88/88;
  direct review 76/76; manager review 12/12; credential swap 80/80; and
  `git diff --check` is clean. The manager bundle reproduced byte-identically
  twice at
  `a69483e04250a73ab67274ae6890b3fd3b68a8ee904452373672c8f4cd2a44ee`
  (258,237 bytes). The sudo-backed install published that exact hash and the
  complete v2 runtime verifier passed before and after launch. The live native
  pane reported `gpt-5.6-sol ultra`, entered copy mode at scroll position 29,
  and propagated a 149x47 client to an exact 149x47 pane. A fresh Discord turn
  then returned `QOFI_SOL_ULTRA_OK` exactly, restored the manager to idle with
  one registration, left runtime error/queue state empty, and made no workspace
  changes. The external acceptance gate is complete.
- `2026-07-13` — **Managed Codex workers now have an implemented and locally
  tested terminal Claude Fable 5 adversarial reviewer; it is not live.** Recon
  pinned the installed print-mode alias `claude-fable-5` and the existing
  Claude-to-Codex plugin's raw v1 contract. A production normalizer now maps
  those legacy results into the shared
  `qofi-adversarial-review-output/v2` contract without inventing unavailable
  diff provenance. The mirror direction is one root-attested stdio MCP tool:
  bounded diff/file excerpts and context enter only as untrusted stdin data,
  while Fable runs with an immutable doctrine, no tools, no exec, no nested MCP,
  no plugins, and no persistence. Deterministic profile-home rendering and
  byte-identity verification carry the registration into every managed home.

  Manager-derived active-turn scope, task/profile artifact directories,
  durable FIFO budgets, stale-scope revalidation, and a crash-surviving
  process-group/flock supervisor keep the call terminal and per-swarm. Timeout,
  auth, rate-limit, malformed, confidentiality, and invocation failures become
  `review-unavailable`/`review-pending`, never approval. Private artifacts bind
  the exact reviewed-input SHA-256; Discord receives only label-only block
  notices. Provider-token/JWT/opaque-credential fixtures prove suspect bytes
  cannot be returned or persisted while ordinary SHA values and source
  identifiers remain usable. The per-swarm Codex pool and the legacy
  rotation-proxy fallbacks now both default to an inclusive 95 percent trigger;
  all OpenAI model routes remain `gpt-5.6-sol` with `ultra`, with no 5.4 route.

  Final no-spend verification: canonical `npm test` exit 0 with 544 Bun tests,
  2,357 assertions across 44 files, and all 86 shell/Python entrypoint suites;
  Fable shim 25/25; legacy normalizer 11/11; runtime provisioner 110/110;
  template integration 94/94; Claude review 61/61; Codex review 76/76. Both
  production dependency audits report no vulnerabilities, syntax and whitespace
  checks are clean, and the manager bundle reproduced byte-identically twice at
  `a8703b739b09e7e7a669473786c9ad4b02e6187c4409e2722643c61be2affc5a`
  (313,259 bytes). Activation still requires the operator-run privileged
  reinstall and a real managed Codex-to-Fable shakedown; no provider call or
  live Discord/runtime mutation was performed for this delivery.
- `2026-07-13` — **Harness-enforced lifecycle parity and the deferred native-UI
  regression are implemented and tested; the new lifecycle policy is not
  live.** One runtime-blind harness now owns normalized events, final-review
  admission, delivered-or-durably-queued Discord stop outcomes, retry/fallback/
  dead-letter audit, strict provenance-bound CTO check-ins, derived roadmap and
  digest views, corpus-addressed context packs, and grounding-gap metrics. The
  completion policy permits one terminal foreign-model review; active-worker
  Codex review scope and ordinary mid-task review are refused. The managed Codex
  host path reaps the App Server generation, revokes its workspace ACL, snapshots
  the exact final input, obtains one Fable receipt, and requires root-broker
  consumption before cleanup. Secret-bearing summaries and transport errors are
  reduced before durable persistence.

  Parity remains deliberately adoption-off. Native Claude hooks are same-UID
  visibility evidence, not completion authority; a supervised exact-final
  `claude -p` runner is not shipped. The missing descriptor-bound root execution
  wrapper hardblocks conformance admission, and cross-owner roadmap publication
  hardblocks until a descriptor-bound helper can publish without reopening a
  worker-raceable path. The parity matrix records these restrictions instead of
  silently enabling only Codex.

  After that behavior gate was green, live press-backend forensics found why
  `swarm-press-backend` had regressed to the event/status fallback: the installed
  root record still exactly attested Node and Codex 0.144.1, but viewer preflight
  incorrectly required newly added, unrelated Fable-reviewer fields. Viewer
  admission now projects only schema/operator identity and exact Node/Codex
  path/hash authority. The real command immediately reopened the full native
  TUI, replayed prior Discord turns, and displayed `gpt-5.6-sol ultra`. Live copy
  mode reached retained history at scroll position 22; a second 111x37 terminal
  attach produced an exact 111x37 pane with `window-size=latest`, aggressive
  resize, mouse navigation, and a 100,000-line history limit.

  Final verification: canonical `npm test` passes 718 Bun tests with 2,957
  assertions across 69 files plus all 88 shell/Python entrypoint suites; watcher
  tests pass 144/144; Fable shim tests pass 33/33; native-view/orchestration
  passes 88/88; host-preflight capability tests pass; doctrine byte-identity and
  `git diff --check` are clean. Both production dependency audits report no
  vulnerabilities. No provider turn, Discord send, privileged install, commit,
  or push was performed during the UI repair.
- `2026-07-13` — **Legacy-to-Fable runtime installation no longer deadlocks
  before first publication.** The live press runtime carried the valid legacy
  16-field v2 attestation while the newly required root Fable shim, doctrine,
  and schema did not yet exist. The refreshed installer incorrectly demanded
  those outputs before reaching its transaction. Install entry now binds the
  exact root lifecycle alone for that legacy migration; expanded authorities
  and every ordinary lifecycle operation retain the complete Fable proof.
  Root-file publication now identity-binds its staged inode and rolls back both
  absent-target and replacement failures after final validation. Provisioning
  tests cover legacy bootstrap, expanded-authority refusal, rollback to absence,
  post-publication restoration, and cross-UID private-config verification. The
  operator verifier uses metadata plus the deterministic render hash while the
  fixed root runner retains exact private-byte/ACL proof; no runtime ACL was
  widened. The complete 115-test provisioner,
  lifecycle-recovery shell contract, host preflight, and Python source checks
  pass. No privileged install was performed by the test run.
- `2026-07-13` — **Primary Codex CPO workers are now routed to GPT-5.6-Sol at
  medium reasoning effort; implemented and tested, not yet live.** The trusted
  bridge archetype selects effort before manager registration. That immutable
  per-swarm value flows through classic exec, App Server thread configuration,
  effective-authority validation, turn start, re-registration rollback, and the
  read-only native facade. Engineering and unknown/future workers retain the
  fail-safe Sol Ultra route, and the terminal contrarian-review lane remains
  independently Sol Ultra. Registration echoes the exact selected effort and
  the daemon rejects a stale manager that omits or changes it, so mixed-version
  startup fails closed instead of silently falling back to Ultra. Shared
  profile-home configuration was deliberately unchanged so CPO tuning cannot
  silently alter CTO execution.

  The fixed root workspace runner accepts only the managed `medium|ultra`
  pair; its review grammar remains Ultra-only. CPO doctrine now names the
  host-enforced route. Verification passed canonical `npm test`, the full
  Codex bridge suite, focused routing/manager/native/mixed-version suites, all
  115 privileged provisioner tests, 95 Codex template checks, doctrine
  composition, the existing Claude per-archetype effort test, and whitespace
  validation. Activation requires an idempotent privileged runtime install
  followed by restart of an actual Codex-engine CPO swarm; no provider turn,
  privileged install, Discord
  send, commit, or push was performed here.
