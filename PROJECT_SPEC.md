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
       `swarm-rotate-tick: OBSERVE ts=2026-06-14T19:40:02Z proxy_verdict=NEAR proxy_exit=10 five_hour_pct=88 weekly_pct=41 worst_pct=88 worst_window=5h threshold_pct=85 account=max-a real_signal=OK real_exit=0 would_rotate=yes (NOT rotating: observe-mode)`.
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
  checkpoint every repo, swap credentials via `swarm-login-relay.sh` (OAuth URL
  posted to the qofi-product Discord channel; the operator's browser picks the
  account) and relaunch the fleet. This completes the
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
