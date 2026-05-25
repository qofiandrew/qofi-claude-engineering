# qofi-claude-engineering

Run Claude Code as an autonomous engineering org. You hold a product-design
conversation over Discord, say **"go build,"** and a CTO agent turns the vision
into docs, coordinates a team of in-process teammates that builds end-to-end,
and pings you only for the decisions that genuinely need a human. One Mac
mini, one Claude Max subscription, controlled via Discord.

> **Status:** consolidated and ready for CC to build out v1. Start at
> [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) and [`docs/adr/`](./docs/adr/) — the
> spec and the one-way-door decisions the system was built against;
> [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) is the full map.

## Two halves of the repo

This repo is the **swarm system** plus its **Discord bridge** as a subcomponent.

| Where | What | Read |
| --- | --- | --- |
| `./` (root) | The swarm orchestration system — payload templates, host scripts, governance docs, ADRs, the dogfooded gates. `$SWARM_HOME` points here. | [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md), [`PROJECT_SPEC.md`](./PROJECT_SPEC.md), [`CLAUDE.md`](./CLAUDE.md), [`ESCALATION.md`](./ESCALATION.md), [`TEAM_LEAD.md`](./TEAM_LEAD.md) |
| `./bridge/` | The `discord-b2b` Claude Code plugin — the chat transport / control plane the swarm uses. Self-contained Bun project. | [`bridge/README.md`](./bridge/README.md), [ADR-0002](./docs/adr/ADR-0002-discord-over-slack.md), [ADR-0007](./docs/adr/ADR-0007-monorepo-bridge-as-subcomponent.md) |

## Prerequisites

- macOS (Mac mini), `tmux`, and Claude Code **v2.1.32+**.
- A Claude **Max** login in Claude Code (`/status` should show the
  subscription, not an API key). Do **not** export `ANTHROPIC_API_KEY` in the
  launching shell — the lead must bill against Max, not metered API.
- `bun` (the Discord bridge runtime).
- `$SWARM_HOME` exported in the operator's shell, pointing at the clone of
  this repo. Every script in `bin/` fails loud if it's unset.
- `python3` (ships with macOS) — used by the manifest tooling, the settings
  merger, the dod-affirm hook, and the permission-gate hook.

## 1. What this is

The system has three layers:

- **Doctrine** lives in [`templates/`](./templates/) — `CLAUDE.md`,
  `TEAM_LEAD.md`, `ESCALATION.md`, and the manifest. These are the rules the
  CTO and teammates operate by, the templates a fresh repo gets stamped
  with, and the contract a `swarm-sync` propagates outward.
- **Enforcement** is mechanical: `.claude/hooks/*.sh` (test-gate, dod-affirm,
  docs-check, permission-gate), `.git/hooks/pre-commit`, and the
  `settings.json` hook registrations that wire them in. These are gates the
  agent can't ignore — they block task-completion / commits / dangerous
  permissions, not just suggest.
- **Operator tooling** in [`bin/`](./bin/) — the swarm-* scripts and a pair
  of `launchd` agents that supervise the always-on stack. The scripts share
  a single manifest as their source of truth so first-stamp / upgrade /
  onboard can't diverge.

The unit of operation is a **swarm**: one repo + one dedicated Discord bot +
one Discord channel + one persistent tmux session running a long-lived
Agent Teams **lead** (the CTO). The CTO spawns **in-process teammates**
elastically inside its own session, each working in its own git worktree on
a `worktree-<name>` branch. The CTO owns provisioning, integration merges to
`dev`, and teardown.

A separate launchd watcher posts a per-channel heartbeat in Discord so the
operator can see "this swarm is working" / "ready · waiting for input" /
"STALLED" without attaching to its tmux. A separate persistent process
keeps a Discord typing bubble visible whenever a swarm is actively producing.

Everything runs on one Mac and one Claude Max pool. Plan for 1–2 concurrent
teams (see [§7 Architecture — the Max pool ceiling](#the-max-pool-ceiling)).

## 2. Concepts

- **Swarm** — one repo + one Discord bot + one channel + one tmux session
  (`swarm-<name>`). Registered as a line in `$SWARM_HOME/swarm.conf`:
  `name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID`.
- **Lead / CTO** — the long-lived Agent Teams agent running inside the
  swarm's tmux session. Reads `CLAUDE.md` / `TEAM_LEAD.md` / `ESCALATION.md`
  / `PROJECT_SPEC.md` at session start; operates per `TEAM_LEAD.md`. Owns
  authoring docs from the design conversation, decomposition, spawning,
  review, integration merges to `dev`, and worktree teardown.
- **In-process teammates** — the CTO spawns these inside its own Agent
  Teams session for parallel work. **RAM-only**: they don't survive a
  session restart. The CTO must re-spawn after `/resume` or any cycle.
- **Per-teammate worktree** — `.claude/worktrees/<name>/` on branch
  `worktree-<name>`, created by the CTO **before** spawning that teammate
  (per `TEAM_LEAD.md` §*Pre-spawn provisioning* and §*Worktree teardown*).
  Each teammate commits only there; the CTO merges to `dev`. Worktree dirs
  are gitignored.
- **Doctrine** — `CLAUDE.md`, `TEAM_LEAD.md`, `ESCALATION.md` (plus the
  ADR + spec templates). The rules of operation. Lives in `templates/`;
  `swarm-init` / `swarm-sync` stamp/refresh it into stamped repos.
- **Enforcement** — `.claude/hooks/*.sh` + `.git/hooks/pre-commit` +
  `settings.json` registrations. Mechanical gates: tests must pass before
  task completion, DoD affirmation must appear in the commit summary, docs
  must be touched per commit, high-confidence secret patterns block commit,
  hard-floor commands (push, sudo, rm -rf, .env) are denied at the
  permission layer. See [§8 Enforcement](#8-enforcement--mechanical-vs-probabilistic).
- **The bridge** — `bridge/` is the `discord-b2b` Claude Code plugin: a
  self-contained MCP server that connects to Discord, applies the
  per-channel access policy (`access.json`), and exposes
  `mcp__plugin_discord-b2b_discord__reply` (plus `react`, `edit_message`,
  `fetch_messages`, `download_attachment`) to the lead. The lead only sees
  Discord *through* the bridge.

## 3. Command reference

### Operator commands (the things you type)

| Command | Does | When to use |
| --- | --- | --- |
| `swarm-add.sh <name> <repo> [<channel>] [--rotate-token] [--skip-walkthrough]` | Complete 8-phase interactive standup for a NEW swarm: Discord portal walkthrough → silent token capture → `tokens.env`/`swarm.conf` writes → `swarm-init` → `access.json` group → `enabledPlugins` verify → verification checklist. Idempotent on re-run. | Stand up a new swarm from scratch. |
| `swarm-onboard.sh <repo> [--force-docs] [--force-hooks] [--force-precommit] [--force] [--check]` | Stamp the swarm operating system into a PRE-EXISTING real codebase. Refuse-and-report by default on collisions; per-concern force flags to override; atomic apply with rollback on mid-write failure. Does **not** add the repo to `swarm.conf` (use `swarm-add` separately) and does **not** fake the docs-mirror-code skeleton. | Onboarding an existing codebase to the swarm system. |
| `swarm-init.sh <repo> [--force]` | Thin wrapper around `manifest_apply REPO init`. First-stamp semantics: refresh-class artifacts always written, seed-class only if absent, settings structured-merged, pre-commit marker-aware. Called internally by `swarm-add`. | Rarely direct; usually invoked via `swarm-add`. |
| `swarm-sync.sh [<name>\|<path>] [--check] [--force]` | Bring stamped repo(s) up to current templates via the manifest. `--check` is a per-repo drift report (no writes). Refuses dirty trees without `--force`. Refuses detached HEAD. Names committed branch in output and commit message. Ad-hoc path supported for auditing repos not in `swarm.conf`. | Propagate template changes to stamped swarms. |
| `swarm-restart.sh <name> [--force]` | `swarm-up.sh down <name>` + `swarm-up.sh up <name>`. No sync. Safety rail: refuses if `repo_activity` shows transcript writes within `${SWARM_STALE_SECONDS:-300}` s, unless `--force`. Ends with a reminder for the racy dev-channels prompt. | Reload a running swarm from current on-disk state. |
| `swarm-update.sh <name> [--force]` | `swarm-sync.sh <name>` + `swarm-restart.sh <name>` bundled. Aborts BEFORE restart if sync exits non-zero. Same safety rail; re-checked post-sync inside the restart step. | "Make this swarm fully current with templates" — the propagation-and-reload command. |
| `swarm-attach.sh [<name>]` | Attach (or launch-then-attach) the swarm's tmux session. With no arg, attaches the single configured swarm or lists if 0/2+. Validates `<name>` is in `swarm.conf` before doing anything. | Watch a swarm live. |
| `swarm-remove.sh <name>` | Unregister: kill *only* that swarm's tmux session, remove its `swarm.conf` row (atomic rewrite preserving comments), optionally clean its `access.json` group and heartbeat state. Does NOT touch `tokens.env` (a token may be reused) and does NOT touch the target repo. | Decommission a swarm. |
| `swarm-up.sh {up [name]\|down [name]\|status\|watch\|attach <name>}` | Multi-command lifecycle entrypoint. `up`/`down` accept an optional name filter (no-arg = all); `watch` is a foreground supervisor relaunching dead leads every 30s; `attach` exits 1 if the session is down (use `swarm-attach.sh` to attach-or-launch). | Direct lifecycle control; or via `swarm-attach` / `swarm-restart` which call it. |

### Sourced helper (not executed)

| File | Does |
| --- | --- |
| `bin/swarm-aliases.sh` | Add `source /Users/.../bin/swarm-aliases.sh` to `~/.zshrc`. On source, it reads `swarm.conf` and defines generic aliases plus three per-swarm aliases for every conf row. Re-source after `swarm-add` to pick up new swarms. |

### Generic aliases (after sourcing `swarm-aliases.sh`)

| Alias | Equivalent |
| --- | --- |
| `swarm-attach <name>`  | `swarm-attach.sh <name>` |
| `swarm-restart <name>` | `swarm-restart.sh <name>` |
| `swarm-update <name>`  | `swarm-update.sh <name>` |
| `swarm-up`             | `swarm-up.sh up` (all) |
| `swarm-down`           | `swarm-up.sh down` (all) |
| `swarm-status`         | `swarm-up.sh status` |
| `swarm-sync`           | `swarm-sync.sh` |
| `swarm-watch-log`      | `tail -F ~/.config/swarm/watch.log ~/.config/swarm/watch.err` |

### Per-swarm aliases (generated from every `swarm.conf` row)

For a swarm named `foo`, sourcing the aliases file gives:

| Alias | Does |
| --- | --- |
| `swarm-foo`         | attach-or-launch `swarm-foo` |
| `swarm-restart-foo` | restart it (safety-railed) |
| `swarm-update-foo`  | sync + restart it (safety-railed) |

### launchd-supervised (you don't invoke these — launchd does)

| Process | Cadence | Does |
| --- | --- | --- |
| `bin/swarm-watch.sh` (via `launchd/com.qofi.swarm-watch.plist.template`) | one-shot, `StartInterval=90s` | Reads `swarm.conf`, posts a per-channel heartbeat for each swarm with one of five statuses: ⚪ down · 🟡 starting · 🟢 working · 🟢 ready · waiting for input · 🔴 STALLED. Pins the message on first post; edits in place after. Uses each swarm's own bot token. |
| `bin/swarm-typing.sh` (via `launchd/com.qofi.swarm-typing.plist.template`) | persistent, `KeepAlive=true`, internal loop ~8s | Keeps a Discord typing bubble visible for each swarm that is currently WORKING (matches the watcher's 🟢 working predicate). `curl --max-time 5` on every call so a stuck Discord request can't wedge the loop. |

Install the launchd jobs with `bin/swarm-launchd-install.sh` — it renders the committed `launchd/*.plist.template` files (substituting `$SWARM_HOME`, `$HOME`, and the tmux path) into `~/Library/LaunchAgents/` and bootstraps them. Re-run it after editing a template or moving `$SWARM_HOME`. Logs land in `~/.config/swarm/{watch,typing}.{log,err}`.

## 4. Standing up a swarm

Two entry points, chosen by what the target repo already has:

- **`bin/swarm-add.sh <name> <repo> [<channel>]`** — for a **new** swarm. The
  script walks you through every step: creating the Discord application,
  enabling the privileged `MESSAGE CONTENT INTENT`, the full OAuth permission
  set, inviting the bot, finding the channel ID via Developer Mode, capturing
  the bot token via a silent prompt, writing the host config, stamping the
  repo, registering the access policy, and verifying that the bridge plugin
  is enabled (the trap that broke `reserve-backend-2`'s first bringup —
  silent failure mode when `enabledPlugins["discord-b2b@qofi-swarm"]` isn't
  `true`). Ends with a verification checklist for the operator to run.

- **`bin/swarm-onboard.sh <repo>`** — for stamping the swarm system into a
  **pre-existing real codebase** (the kind that already has its own code, its
  own history, possibly its own `CLAUDE.md` or `.git/hooks/pre-commit`).
  Default policy is **refuse-and-report on every collision**; per-concern
  force flags (`--force-docs`, `--force-hooks`, `--force-precommit`, or
  `--force` for all) let the operator opt into specific overwrites. Atomic:
  if anything goes wrong mid-apply, the repo is rolled back to its starting
  state. Stops at doctrine + enforcement; intentionally does **not** create a
  `modules/` skeleton (the CTO bootstraps that from the real code as a first
  task — see `TEAM_LEAD.md`).

Neither walkthrough is duplicated here; the scripts hold the canonical
exact-instructions form, including the racy dev-channels prompt clear and
the full TROUBLESHOOTING block keyed to known failure modes.

## 5. The propagation model — SYNC ≠ LIVE

This is the most important operational concept in the system.

**Templates are the source of truth.** When you change something under
`templates/`, the change is *on disk in `$SWARM_HOME`* — nothing else has
moved. `swarm-sync` propagates the file into each stamped repo. **Restart**
reloads the running session from those files.

Different layers reload on different cadences (verified against the actual
invocation paths):

| Layer | Where on disk | Reloads when | Why |
| --- | --- | --- | --- |
| Hook **scripts** | `<repo>/.claude/hooks/*.sh` | next time the hook fires | `settings.json` registers each hook as `bash "$CLAUDE_PROJECT_DIR/.claude/hooks/<name>.sh"`. Bash reads the script fresh on each invocation. Updates take effect on the next hook event. |
| Hook **registrations** | `<repo>/.claude/settings.json` (the `hooks` block) | next session start | Claude Code reads `settings.json` at session start. A registration change requires the lead to restart. |
| Doctrine | `<repo>/CLAUDE.md` · `TEAM_LEAD.md` · `ESCALATION.md` | next session start | The lead reads these into context at session start. New content does not reach a running lead until the session is cycled. |
| Git pre-commit | `<repo>/.git/hooks/pre-commit` | next commit | Git reads the hook fresh on every commit. No restart needed. |
| Manifest itself | `templates/manifest.tsv` | next `swarm-sync` / `swarm-init` / `swarm-onboard` run | The scripts read it at invocation time. |

The exact text appears in `bin/swarm-sync.sh`'s end-of-run reminder:

> *"A running lead has already read its CLAUDE.md / TEAM_LEAD.md /
> ESCALATION.md into context AND Claude Code loaded its settings.json +
> hooks at session start. Live sessions continue on the OLD policy until
> cycled."*

So the three verbs:

| Verb | Sync? | Restart? | Use for |
| --- | --- | --- | --- |
| `swarm-sync` | yes | **no** | Just write to disk. Useful when you want to inspect what would land before cycling anything, or when multiple swarms need writes batched before the operator decides which to restart. Ends with the SYNC ≠ LIVE reminder + the list of affected swarms with live tmux sessions. |
| `swarm-restart` | **no** | yes | Reload one swarm's session from current on-disk state without re-applying the manifest. Useful when you've edited the repo directly (a hook script change, a hand-edited doc) and want the lead to pick it up. |
| `swarm-update` | yes | yes | The bundle. The intended verb for "make this swarm fully current with templates" — closes the gap where an operator runs `swarm-sync` and forgets to cycle the lead, leaving the running session on stale doctrine. If sync exits non-zero, **aborts before restart** (the running session keeps its current state, which is safer than landing partway through a half-synced upgrade). |

### The WORKING safety rail

`swarm-restart` and `swarm-update` both consult `repo_activity()` (in
`swarm-lib.sh`, the same signal `swarm-watch` uses for the heartbeat)
before taking the session down. If the swarm has produced a transcript
write within `${SWARM_STALE_SECONDS:-300}` seconds — meaning the lead or
any teammate is actively producing — the script **REFUSES** with an
explicit warning and exits 2. `--force` overrides.

The reason: **in-process teammates are RAM-only** (`TEAM_LEAD.md`
§*Operational discipline*: *"In-process teammates do not survive
`/resume`; if you try to message one that's gone, just spawn a new one."*).
A restart kills the tmux session and with it every teammate that hadn't
committed yet. The lead itself rebuilds from disk — `CLAUDE.md`,
`TEAM_LEAD.md`, `PROJECT_SPEC.md`, plus whatever the teammates committed to
their `worktree-<name>` branches — but uncommitted teammate progress is
gone. The safety rail makes that a deliberate `--force` choice, not an
accident.

`swarm-update` re-checks activity twice: once up front (refuse early if
the swarm is already busy) and again inside the restart step after sync
completes (sync takes time; status may have changed in the interval).

## 6. The manifest

[`templates/manifest.tsv`](./templates/manifest.tsv) is the single source of
truth for what a fully-stamped repo contains. `swarm-init.sh`, `swarm-sync.sh`,
and `swarm-onboard.sh` all consume it via `manifest_walk` in `swarm-lib.sh`,
so first-stamp / upgrade / onboard cannot diverge. To add a new artifact to
every swarm: add the line to `manifest.tsv` — that's it.

Each line is `behavior | template-path | target-path`. There are six
behavior classes (each implemented as `manifest_apply_<class>` in
`swarm-lib.sh`):

| Class | Semantics |
| --- | --- |
| `refresh` | Overwrite unconditionally; idempotent if `cmp`-equal. Used for the operating-contract files: doctrine docs and the four `.claude/hooks/*.sh`. |
| `seed` | Copy only if absent; per-repo content the operator (or the CTO) authors after stamping. `--force` to `swarm-init` re-seeds. Used for `PROJECT_SPEC.md` and `docs/adr/ADR.template.md`. Sync NEVER seeds. |
| `seed-text` | Same as `seed` but the "template" is the literal inline text in the manifest field. Used for `.claude/test-cmd`. |
| `settings` | Structured-merge swarm registrations into the existing `.claude/settings.json`. Additive; dedup-by-command; foreign hook entries preserved. Atomic write. |
| `git-hook` | Marker-aware install of `.git/hooks/pre-commit`. Install if absent or existing has the SWARM-MANAGED marker; refuse / warn / collide if foreign (mode-dependent). Recognizes a `pre-commit (anti-secret-only — tooling/source repo variant)` marker as a deliberately-preserved variant; never clobbers it. |
| `gitignore` | Append the line idempotently to `.gitignore`. Used for `.claude/worktrees/`. |

The current manifest carries 13 entries spanning all six classes — see the
file for the canonical list. `swarm-sync.sh --check` reports per-artifact
drift state (`OK` / `OUTDATED` / `MISSING` / `MERGE_NEEDED` / `FOREIGN` /
`MISSING_LINE`) without writing.

## 7. Architecture

### Always-on stack (launchd)

Two `launchd` agents under [`launchd/`](./launchd/) supervise the system:

- **`com.qofi.swarm-watch.plist`** — `RunAtLoad=true`, `StartInterval=90`.
  Fires `bin/swarm-watch.sh` once every 90 seconds. The script sweeps every
  swarm in `swarm.conf`, computes a status, and posts (or edits in place,
  with a sticky pin) a per-channel heartbeat using that swarm's own bot
  token. The five status states are explicit (see §3's table).
- **`com.qofi.swarm-typing.plist`** — `RunAtLoad=true`, `KeepAlive=true`,
  `ThrottleInterval=10`. A persistent process, not a periodic one: it loops
  internally on ~8s (Discord's typing API expires at ~10s) and pings
  `/channels/<id>/typing` for each swarm that's actively WORKING. `curl
  --max-time 5` defends against a stalled request wedging the loop.

The two run as separate processes deliberately — the watcher's 90s cadence
is incompatible with typing's ~10s expiry. The watcher runs with
`SWARM_ENABLE_TYPING=0` in its plist so they don't double-fire.

### The liveness signal

Lives in `swarm-lib.sh` as `repo_activity()`. Given a repo path, a Claude
projects dir (`~/.claude/projects`), and a staleness threshold, it
recursively scans `*.jsonl` mtimes across:

- the lead's own project transcript dir (Claude Code encodes the repo's
  `cwd` by replacing `/` and `.` with `-`), AND
- every per-teammate worktree subdir matching `<lead-encoded>--claude-worktrees-*`
  (covers the `subagents/` subdir where teammate transcripts live). A
  teammate transcript dir whose corresponding `<repo>/.claude/worktrees/<name>`
  has been torn down is skipped — defense-in-depth against the
  TEAM_LEAD.md §Worktree teardown step that removes both.

Returns `<newest_age_seconds>|<active_teammate_count>`. The age is
**always** numeric — when no transcript exists at all (or the scan hits
an unrecoverable error) it returns the sentinel `SWARM_NO_TRANSCRIPT_AGE`
(`9999999`, ~115 days), comfortably larger than any plausible
`STALE_SECONDS`. Threshold-based callers (the typing pinger, the
heartbeat predicate) treat it as stale automatically; the watcher
compares against the sentinel only to render the more-specific "🟡
starting (no transcript yet)" state. The function never returns blank —
fail-safe for typing/heartbeat is **silence**, and a sentinel age makes
that automatic. The watcher and the typing pinger consume this same
signal so heartbeat status, typing bubble, and the WORKING safety rail
can never drift apart. Default threshold: `SWARM_STALE_SECONDS=300`
(5 minutes).

### The bridge

`bridge/` is the `discord-b2b` MCP plugin: a Bun-based Discord client
exposed to the lead via Claude Code's plugin marketplace mechanism. Two
things have to be true for it to actually load in a lead's session:

1. `.claude/settings.json` has `enabledPlugins["discord-b2b@qofi-swarm"] : true`.
   If missing or `false`, the plugin never spawns and the lead launches
   with no Discord tools — the silent failure mode that broke
   `reserve-backend-2`'s first bringup. `swarm-add.sh`'s Phase 5 verifies
   this and offers to repair it in place.
2. The lead was launched with `--dangerously-load-development-channels
   plugin:discord-b2b@qofi-swarm` (`swarm-up.sh launch_one` does this).
   The `qofi-swarm` marketplace is self-published, not on Anthropic's
   approved allowlist, so `--channels` alone isn't enough.

Discord intents requested by the bridge (`bridge/server.ts:83–89`):
`Guilds`, `GuildMessages`, `DirectMessages`, `MessageContent`. Of these,
**only `MessageContent` is privileged** (requires the portal toggle); the
other three are non-privileged and just need to be in the code.

### Per-channel access control

`~/.claude/channels/discord/access.json` (managed locally — NOT in this
repo) controls who the bridge accepts messages from:

```json
{
  "dmPolicy": "pairing" | "allowlist" | "disabled",
  "allowFrom": ["<owner-discord-id>"],
  "groups": {
    "<channel-id>": { "requireMention": true, "allowFrom": ["<owner-id>"] }
  },
  "pending": { ... }
}
```

`swarm-add` pre-writes the owner group for the new swarm's channel with
`requireMention: true` and `allowFrom: [owner]`, so the lead only acts on
messages from the operator that explicitly `@`-mention its bot — no
ambient chatter triggers the agent.

### tmux + state paths

| Path | Holds |
| --- | --- |
| `$SWARM_HOME/swarm.conf` | One line per swarm: `name \| repo \| TOKEN_VAR \| CHANNEL_ID`. |
| `$SWARM_HOME/tokens.env` | `export BOT_<NAME>="..."` per swarm. Gitignored, chmod 600, fail-loud during `swarm-add` if not in `.gitignore`. |
| `$SWARM_HOME/.claude/settings.json` | This repo's own Claude Code settings (the source repo, not a stamped swarm). |
| `~/.claude/channels/discord/access.json` | Per-channel access policy (see above). |
| `~/.claude/projects/<encoded-path>/...` | Lead + teammate transcript jsonls. The liveness signal scans these. |
| `~/.config/swarm/` | launchd job logs, heartbeat state. |
| tmux session `swarm-<name>` | The lead's session. `swarm-attach`/`swarm-up.sh attach <name>` to attach. |

### The Max-pool ceiling

Everything rides one Claude Max pool, shared across the operator's chat and
code usage. Plan for **1–2 concurrent teams**; 5–7 × 24/7 is API-scale
([ADR-0004](./docs/adr/ADR-0004-max-capacity-ceiling.md)). Prove the loop on
one repo, watch `/cost`, and let that number decide whether a second team
fits Max or wants metered API.

## 8. Enforcement — mechanical vs probabilistic

The system has two layers of discipline. Be honest about the line — over-
claiming the mechanical layer is what turns gates into theater.

### Mechanical (the agent cannot complete the task / commit / call the tool)

| Gate | Where | What it enforces |
| --- | --- | --- |
| `test-gate.sh` on `TaskCompleted` | `.claude/hooks/` + `settings.json` | Runs the resolved test command (`CLAUDE_TEST_CMD` → `.claude/test-cmd` → autodetect). Blocks task completion (exit 2) on red tests. Fails CLOSED if no test command is resolvable — an ungated done is not done. |
| `dod-affirm.sh` on `TaskCompleted` | `.claude/hooks/` + `settings.json` | Scans the task-summary event + HEAD commit message for the six `[DoD-N] <label>: yes \| n/a:<reason>` lines on their own lines. Blocks completion if any are missing or malformed. Mechanically enforces the *presence* of the affirmation — not its truth (that's CTO review's job, the boundary §Honesty draws). |
| `docs-check.sh` on `TeammateIdle` | `.claude/hooks/` + `settings.json` | If a teammate has changed source but staged no docs, blocks them from going idle (exit 2). Idempotent: any `*.md` / `docs/*` touch clears it. |
| `pre-commit` docs-touch | `.git/hooks/pre-commit` (standard variant) | A commit that stages any source file MUST also stage at least one doc/markdown file. Source-only commits are rejected. Interim "any src + any doc" floor; refinement to module-specific mapping is deferred. |
| `pre-commit` anti-secret | `.git/hooks/pre-commit` (both variants) | Scans staged adds for high-confidence secret shapes (Discord/AWS/GitHub/Slack tokens, PEM private keys, JWT-shaped). Blocks commit on a hit; deliberately conservative to avoid false positives. |
| `permission-gate.sh` on `PermissionRequest` | `.claude/hooks/` + `settings.json` | Tool-call gate. Three outcomes per call: ALLOW (auto-approve known-safe), DENY (hard-floor), or defer (gray-zone → operator approval prompt). |

Permission-gate hard floors (deny — verified against the 22-case matrix in commit `ec6cdd6`):
- `git push` (anything) — `main`-push is operator-only; even `dev`-push is CTO-approved
- `sudo` (any)
- `rm -[rf]` recursive/forced delete
- Pipe-to-shell (`curl|wget … | sh|bash|zsh`)
- `npm publish` / `yarn publish` / `deploy` / `--prod` / `production` (case-insensitive)
- File access matching `.env` / `/.ssh/` / `credential` / `secret` / `api[_-]?key` / `token`
- Path traversal (`..`) in `Edit`/`Write` paths
- `Edit`/`Write` to a path outside the project `cwd`

Permission-gate narrow allowances added in `ec6cdd6` for CTO routine work
(symmetric to `TEAM_LEAD.md` §*Worktree teardown*):
- `git branch (-d|-D|--delete) worktree-<name>` — and ONLY that pattern.
  `git branch -D dev`, `-D main`, `-D <anything-else>` all defer.
- `git worktree (add|remove|list|prune)` — the four routine subcommands.
  `move` / `lock` / `unlock` / `repair` defer.

Anything else falls through to the gray-zone defer (operator decides).

### Probabilistic (judgment doctrine; hooks CAN'T enforce these)

These live in `templates/CLAUDE.md` and `templates/TEAM_LEAD.md`. They're
real rules — the CTO is responsible for catching violations at review —
but they're not mechanically enforced and an agent can violate them in
the moment.

- **§Honesty** — no fabrication. *"A truthful 'not done, here's why' always
  beats a fabricated 'done.'"* The hook checks the presence of the DoD
  affirmation; it cannot check whether `[DoD-1] Contract: yes` is true.
  Hook-bypass via vacuous always-pass tests or one-character doc touches
  is named explicitly as the gravest violation in the doctrine.
- **§Conflict handling / hold-ground** — when a request contradicts
  doctrine, the agent surfaces the conflict instead of silently resolving
  it. Doctrine outranks a conflicting instruction. Only operator approval
  overrides; not the CTO's judgment.
- **CTO §Adversarial review** — read the diff, not the summary; hunt for
  the blind spots a teammate would share (edge cases not tested,
  interface mismatches, happy-path-only handling).
- **§Modular design / §Data ownership / §Backward compatibility** — one
  responsibility per module, one contract surface, single-owner tables,
  additive-by-default contract changes.
- **§Testing strategy (mocking policy)** — mock at the seam against the
  real contract for external services or heavy substrate; use the real
  collaborator for cheap internal ones. The CTO decides per-dependency at
  plan-approval.
- **CTO §Plan-approval gate** — one-way doors get an ADR and a confirm-
  with-operator round-trip before any code lands.
- **CTO §Context self-management** — proactive `/compact` at clean phase
  boundaries with preservation instructions; durable state on disk before
  any long/risky operation (so a context loss is recoverable).

## 9. Operating notes / gotchas

- **`SWARM_HOME` must be exported.** Every `bin/swarm-*.sh` script fails
  loud with a clear remediation line if it's missing or wrong. Export it
  in `~/.zshenv` (or the launchd plists, for the always-on stack).
- **The racy dev-channels prompt.** `swarm-up.sh` polls for the
  `--dangerously-load-development-channels` interactive prompt and sends
  `Enter` automatically. The poll can race with a slow CLI start. If the
  prompt is still waiting when you attach, clear it manually:
  ```
  tmux send-keys -t swarm-<name> Enter
  ```
  Both `swarm-attach.sh` and `swarm-restart.sh` print this reminder.
- **tmux discipline.** Inside a swarm session: `Ctrl-b d` to detach
  (keeps the lead running); `Esc` to interrupt a claude turn in flight;
  **never `Ctrl-C`** — that kills the `claude` process, which closes the
  pane, which kills the tmux session.
- **Re-source aliases after `swarm-add`.** The per-swarm aliases
  (`swarm-<name>`, `swarm-restart-<name>`, `swarm-update-<name>`) are
  generated from `swarm.conf` at source time. A shell opened before you
  ran `swarm-add` won't have the new aliases until you `source ~/.zshrc`
  (or open a new terminal).
- **`SWARM_HOME` uses the anti-secret-only pre-commit variant.** The
  standard pre-commit's docs-touch leg would misfire on routine tooling
  commits (e.g. `bin/swarm-*.sh` edits with no doc change), so this repo
  installs `templates/git-hooks/pre-commit-anti-secret-only` instead.
  The variant carries a distinct marker (`SWARM-MANAGED pre-commit
  (anti-secret-only — tooling/source repo variant)`); `swarm-lib.sh`
  recognizes it and refuses to clobber it back to the standard hook.
- **`SWARM_HOME` is the source repo, not a stamped swarm.** Its `CLAUDE.md`
  / `TEAM_LEAD.md` / `ESCALATION.md` are intentionally divergent from the
  fleet templates. **Do not run `swarm-sync` against `SWARM_HOME`** —
  that would overwrite its brief doctrine with the full template version.
  Surgical hand-copies into `SWARM_HOME/.claude/hooks/` are how this
  repo's runtime stays consistent with the templates it ships (see
  commits `bc8e06d` and `7aa7f89` for the pattern).
- **In-process teammates die on restart.** The lead rebuilds from disk
  on relaunch — `CLAUDE.md`, `TEAM_LEAD.md`, `PROJECT_SPEC.md`, committed
  `worktree-<name>` branches — but anything a teammate hadn't committed
  is gone. The WORKING safety rail makes that a deliberate `--force`
  choice rather than an accident.
- **Updating doctrine in a running lead.** `swarm-sync` writes the new
  doctrine to the repo's `CLAUDE.md` / `TEAM_LEAD.md` / `ESCALATION.md`
  on disk, but the running lead has them in memory from session start.
  Use `swarm-update` (sync + restart) when you actually want the lead to
  pick up the change; or `swarm-sync` followed by `swarm-restart` if you
  want to inspect what synced before cycling.
- **The lead picks up hook *script* changes immediately**, even without
  restart, because the hook is invoked as `bash <path>` each time the
  registered event fires (see §5). What requires a restart is changes to
  the hook *registrations* in `settings.json` (e.g. adding a new event
  binding or changing a timeout).
- **Don't push from agent processes.** Hard-floor: `git push` is denied
  by `permission-gate.sh` for any agent (lead or teammate). Push to
  `main` is operator-only; push to `dev` is CTO-approved-then-operator-
  executed. The single hard rule that doesn't bend.
