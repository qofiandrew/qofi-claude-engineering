# qofi-claude-engineering

Run Claude Code **or OpenAI Codex** as a supervised engineering org. You hold a product-design
conversation over Discord, say **"go build,"** and a CTO agent turns the vision
into docs, coordinates a team of in-process teammates that builds end-to-end,
and pings you only for the decisions that genuinely need a human. One Mac
mini, subscription-authenticated agent CLIs, controlled via Discord.

> **Status:** operational hybrid runtime: existing Claude swarms remain the
> default, and `engine=codex` is a first-class, independently gated path. Start at
> [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) and [`docs/adr/`](./docs/adr/) — the
> spec and the one-way-door decisions the system was built against;
> [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) is the full map.

## Three runtime components

This repo is the **swarm system** plus engine-specific Discord bridges.

| Where | What | Read |
| --- | --- | --- |
| `./` (root) | The swarm orchestration system — payload templates, host scripts, governance docs, ADRs, the dogfooded gates. `$SWARM_HOME` points here. | [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md), [`PROJECT_SPEC.md`](./PROJECT_SPEC.md), [`CLAUDE.md`](./CLAUDE.md), [`ESCALATION.md`](./ESCALATION.md), [`docs/TEAM_LEAD.md`](./docs/TEAM_LEAD.md) |
| `./bridge/` | The `discord-b2b` Claude Code plugin — the chat transport / control plane the swarm uses. Self-contained Bun project. | [`bridge/README.md`](./bridge/README.md), [ADR-0002](./docs/adr/ADR-0002-discord-over-slack.md), [ADR-0007](./docs/adr/ADR-0007-monorepo-bridge-as-subcomponent.md) |
| `./codex-bridge/` | The Codex Discord gateway — channel/ACL gate, bounded FIFO, one resumed Codex thread per chat, lifecycle state, and a redacted live event feed. Private Bun subcomponent. | [`codex-bridge/README.md`](./codex-bridge/README.md), [`docs/CODEX.md`](./docs/CODEX.md) |

## Prerequisites

- macOS (Mac mini), `tmux`, and at least one lead CLI: Claude Code **v2.1.32+**
  or Codex CLI **v0.144.1–0.144.x** (`>=0.144.1,<0.145.0`). A mixed fleet may
  install both. New Codex minors are refused until their sandbox/feature flags
  are re-audited.
- Subscription auth for each selected engine: Claude **Max** (`/status`) or
  Codex ChatGPT in the dedicated hidden runtime account (provisioned through
  `bin/swarm-codex-runtime.sh`; see [Codex setup](./docs/CODEX.md)). API-key environments are rejected for
  persistent leads: do not export `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or
  `CODEX_API_KEY` in the launching shell.
- The operator's Codex bridge-state root must be a real private directory. On a
  clean host create it with `(umask 077; mkdir "$HOME/.codex")`; refuse a
  symlink, remove any extended ACL explicitly (`chmod -N` on macOS), then
  `chmod 700 "$HOME/.codex"`. Verify `stat -f '%Sp %N' "$HOME/.codex"`
  reports `drwx------`. Launch resolves the
  official CLI from fixed validated install roots (including NVM) and, for the
  npm shape, pins absolute Node + canonical `codex.js`; `CODEX_BIN`/ambient PATH
  are not trusted overrides. Unattended subscription auth lives separately in
  the hidden runtime account provisioned by `swarm-codex-runtime.sh`.
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
- **Enforcement** is engine-specific plus Git-native: Claude keeps its existing
  `.claude/hooks`/`settings.json`. Unattended Codex uses a bridge-owned custom
  permission profile, an immutable preamble, direct verification, and a narrow
  operator-authorized Git broker. Its stamped `.codex/hooks.json` is an empty
  neutralizer and its rules are manual-interactive defense in depth only. See
  §8 for the exact mechanical boundary.
- **Operator tooling** in [`bin/`](./bin/) — the swarm-* scripts and a pair
  of `launchd` agents that supervise the always-on stack. The scripts share
  a single manifest as their source of truth so first-stamp / upgrade /
  onboard can't diverge.

The unit of operation is a **swarm**: one repo + one dedicated Discord bot +
one Discord channel + one persistent tmux session running an engine-selected
**lead** (the CTO). Claude uses its native long-lived Agent Teams TUI. Codex uses
a persistent Discord daemon that serializes messages into resumed Codex threads.
The same product, evidence, test, review, and escalation doctrine applies.
Claude retains its native per-teammate worktree/merge/push/teardown lifecycle.
The Codex App Server substrate instead uses disjoint path ownership in one
serialized checkout and a narrow operator-authorized side-ref broker; it
must hand merge/push/integration to the operator or CI and never claim Claude
Git-lifecycle parity.

A separate launchd watcher posts a per-channel heartbeat in Discord so the
operator can see "this swarm is working" / "ready · waiting for input" /
"STALLED" without attaching to its tmux. A separate persistent process
keeps a Discord typing bubble visible whenever a swarm is actively producing.

Everything runs on one Mac. Capacity is enforced per subscription pool; adding a
Codex lead does not increase Claude Max usage, and neither engine may silently
fall back to metered API billing.

## 2. Concepts

- **Swarm** — one repo + one Discord bot + one channel + one tmux session
  (`swarm-<name>`). Registered as a line in `$SWARM_HOME/swarm.conf`:
  `name | repo | TOKEN_VAR | CHANNEL_ID | GUILD_ID | ACCOUNT | ENGINE`.
- **Engine** — field 7 of the row. Empty or `claude` preserves the historical
  Claude path; `codex` selects the Codex bridge. `swarm-add --engine` writes it.
- **Lead / CTO** — the engine-selected lead. Claude is a long-lived Agent Teams
  TUI agent; Codex is a resumed Discord thread executed as serialized turns.
  Both own design docs, decomposition, verification, review, and reporting.
  Only Claude autonomously owns integration merges and worktree teardown today.
- **In-process teammates** — Claude spawns native Agent Teams teammates;
  Codex may use supervised-turn delegates with disjoint path ownership in the
  shared checkout. Both are ephemeral and must be consolidated by the lead.
- **Per-teammate worktree (Claude)** — `.claude/worktrees/<name>/` on branch
  `worktree-<name>`, created by the CTO **before** spawning that teammate
  (per `TEAM_LEAD.md` §*Pre-spawn provisioning* and §*Worktree teardown*).
  Each teammate commits only there; the CTO merges to `dev`. Worktree dirs
  are gitignored.
- **Doctrine** — `CLAUDE.md`, `TEAM_LEAD.md`, `ESCALATION.md` (plus the
  ADR + spec templates). The rules of operation. Lives in `templates/`;
  `swarm-init` / `swarm-sync` stamp/refresh it into stamped repos.
- **Enforcement** — a runtime-blind harness owns stop delivery, completion-review
  evidence, structured check-ins, roadmap derivation, and grounding metrics;
  thin Claude/Codex adapters translate events only. Claude hooks remain where
  in-session control is safe. Unattended Codex keeps its root-deny permission
  profile, bridge-owned controls, direct verification, and trusted broker-side
  Git checks. §8 names every adoption and advisory boundary rather than claiming
  false parity.
- **Claude bridge** — `bridge/` is the `discord-b2b` Claude Code plugin: a
  self-contained MCP server that connects to Discord, applies the
  per-channel access policy (`access.json`), and exposes
  `mcp__plugin_discord-b2b_discord__reply` (plus `react`, `edit_message`,
  `fetch_messages`, `download_attachment`) to the lead. The lead only sees
  Discord *through* the bridge.
- **Codex bridge** — `codex-bridge/` owns the Discord gateway itself, applies a
  per-swarm ACL/channel binding, queues turns in arrival order, resumes one
  thread per chat through the root-attested global App Server manager,
  auto-delivers the final response, publishes a per-swarm read-only native-TUI
  facade, and retains bounded runtime/event state as lifecycle evidence and the
  persisted viewer fallback.

## 3. Command reference

### Operator commands (the things you type)

| Command | Does | When to use |
| --- | --- | --- |
| `swarm-add.sh <name> <repo> [<channel>] [--engine claude\|codex] [--codex-auth-pool <pool>] [--rotate-token] [--skip-walkthrough]` | Complete interactive standup for a new engine-selected swarm: Discord bot/token/config → stamp → engine-specific ACL/preflight → verification. Codex field 8 selects a named ordered profile pool; Claude field 6 and behavior are unchanged. | Stand up a new swarm from scratch. |
| `swarm-codex-runtime.sh {install\|refresh-lifecycle\|login\|verify\|prepare-workspace\|release-workspace\|workspace-journal-evidence\|quiescence-proof\|uninstall} [options]` | Manage the root-attested hidden Codex account, fixed runner/toolchain and one-tool Fable reviewer, global App Server manager launcher/bundle, subscription login, isolated profile homes (`login/verify --profile <handle>`), and per-repo service authority. Manager generations are drained or replaced around privileged lifecycle work. | One-time Codex host bootstrap, profile login, diagnostics, recovery proof, and authority teardown. |
| `swarm-codex-manager.sh {start\|status\|health\|ready\|drain\|resume\|shutdown}` | Control or attest the one global Codex App Server manager. `swarm-up` starts/attests it automatically through the fixed root launcher; repository source is never the production launch target. During replacement, the fixed root helper may retire only an exact stopped, zero-registration ambiguous generation after rebinding its root admission, process identities and argv, singleton launcher lock, control-socket inode and kernel peer PID. It freezes the hidden-runner singleton before the final health proof and holds it through supervised reap/quiescence. Tmux state never authorizes recovery, and registered ambiguity remains blocked. | Manager diagnostics and deliberate host lifecycle work, not ordinary per-swarm viewing. |
| `swarm-onboard.sh <repo> [--engine claude\|codex] [--force-docs] [--force-hooks] [--force-precommit] [--force] [--check]` | Stamp the swarm operating system and the selected engine's repository surfaces into a PRE-EXISTING real codebase (`claude` remains the default). Refuse-and-report by default on collisions; per-concern force flags to override; atomic apply with rollback on mid-write failure. Does **not** add the repo to `swarm.conf` (use `swarm-add` separately with the same explicit engine) and does **not** fake the docs-mirror-code skeleton. | Onboarding an existing codebase to the swarm system. |
| `swarm-init.sh <repo> [--force]` | Thin wrapper around `manifest_apply REPO init`. First-stamp semantics: refresh-class artifacts always written, seed-class only if absent, settings structured-merged, pre-commit marker-aware. Called internally by `swarm-add`. | Rarely direct; usually invoked via `swarm-add`. |
| `swarm-sync.sh [<name>\|<path>] [--check] [--force]` | Bring stamped repo(s) up to current templates via the manifest. `--check` is a per-repo drift report (no writes). Refuses sync-managed dirt without `--force`; stamped operator-owned dirt is preserved and excluded from the managed-only commit even when already staged. Refuses detached HEAD. Names the committed branch. | Propagate template changes to stamped swarms. |
| `swarm-restart.sh <name> [--force]` | `swarm-up.sh down <name>` + `swarm-up.sh up <name>`. No sync. Safety rail: refuses if `repo_activity` shows transcript writes within `${SWARM_STALE_SECONDS:-300}` s, unless `--force`. Ends with a reminder for the racy dev-channels prompt. | Reload a running swarm from current on-disk state. |
| `swarm-update.sh <name> [--force]` | `swarm-sync.sh <name>` + `swarm-restart.sh <name>` bundled. Aborts BEFORE restart if sync exits non-zero. Same safety rail; re-checked post-sync inside the restart step. | "Make this swarm fully current with templates" — the propagation-and-reload command. |
| `swarm-attach.sh [<name>]` | Engine-aware attach (or launch-then-attach). Claude attaches its native lead session; Codex dispatches to the attested read-only-facade native TUI/fallback viewer. With no arg, attaches the single configured swarm or lists if 0/2+. | Primary command to watch either engine live. |
| `swarm-view.sh <name>` | Codex operator view. For a healthy App Server runtime with an exact configured-channel thread, opens the pinned native Codex TUI through the swarm's protocol-filtering facade. The navigation-enabled tmux client runs Codex inline with 100,000 lines of scrollback, mouse/copy-mode access, and latest-client responsive sizing; the facade still rejects every mutation and forwards nothing upstream. If any proof is unavailable, opens the explicitly labeled persisted redacted event/status fallback. Managed turns pin `gpt-5.6-sol`; CPO workers use `medium` effort while engineering/default workers use `ultra`. | Watch Codex turns without creating a competing writer. |
| `swarm-remove.sh <name>` | Unregister: kill *only* that swarm's tmux session, remove its `swarm.conf` row (atomic rewrite preserving comments), optionally clean its `access.json` group and heartbeat state. It never removes repo content or `tokens.env`; removing the final Codex reference first revokes the hidden service account's repo permission metadata. | Decommission a swarm. |
| `swarm-up.sh {up [name]\|down [name]\|status\|watch\|attach <name>}` | Multi-command lifecycle entrypoint. `up`/`down` accept an optional name filter (no-arg = all); `watch` is a foreground supervisor relaunching dead leads every 30s; `attach` exits 1 if the session is down (use `swarm-attach.sh` to attach-or-launch). | Direct lifecycle control; or via `swarm-attach` / `swarm-restart` which call it. |
| `swarm-login-relay.sh [--force] [--dedicated] [<swarm>]` | User-assisted re-auth. Sends `/login` to a pane and captures the OAuth URL into private host state. Discord receives only a generic control button (default channel `qofi-product`); the bound owner sees the URL in an ephemeral interaction. A reachable localhost callback completes automatically; otherwise the owner submits the browser's `authorization#state` value through the private modal. The relay waits up to 15 min, verifies with `swarm-auth-probe.sh`, and maps to the credswap exit contract (0 good / 7 ring-exhausted). The verifier resolves Claude under launchd's minimal environment (PATH, then native `~/.local/bin/claude`, or absolute `SWARM_CLAUDE_BIN`) and retries only an unverified verdict for a bounded 5 attempts/2 seconds before failing closed. One login is enough: the default account is shared keychain state. **Default mode** targets the swarm's CTO pane: refuses mid-turn panes without `--force`, re-checks the fleet's clean boundary before handing back to rotate's relaunch. **`--dedicated` mode** (the no-restart model) runs `/login` in the isolated throwaway `swarm-login-probe` session — no CTO pane is touched, so both guards are skipped. A fresh channel+bot bridge-readiness record is required before `/login`; stale/old bridges fail closed. Single-instance; freshness-gated detectors; control records/message are cleaned up and the login UI is Escaped on failure. | Re-auth the shared credential remotely — standalone, via `swarm-reauth.sh` (no-restart), or as legacy rotation's credential-swap step. |
| `swarm-reauth.sh [--dry-run\|--next\|--force]` | The **no-restart rotation actuator** (wires into the tick's `SWARM_ROTATE_CMD`). On a NEAR/AT verdict it runs the login relay `--dedicated`: Claude Code `/login` runs in `swarm-login-probe`, a generic secure-control button appears in the product channel, and the browser picks the account. The OAuth URL is owner-only and ephemeral; any required paste-back goes through the owner-only modal, never ordinary chat. **Nothing restarts** — no checkpoint, no clean-boundary guard, no account ring. On success it recycles the `/usage` probe session so the next poll reads the new account. Exit: 0 re-authed / 6 ring-exhausted (relay said authed-but-capped) / 5 not completed / 2 config. | Rotation without losing any lead's in-RAM state. Pair with `swarm-reauth-verify.sh`. |
| `swarm-reauth-verify.sh` | The **stuck-pane safety net** (wires into the tick's `SWARM_TICK_ALERT_CMD`; runs every live tick). If a CTO lead is parked on a cap banner while the account has headroom (poll verdict OK/NEAR), it didn't adopt the rotated credential in place — posts ONE deduped alert to the product channel naming the stuck lead(s). Suppressed on AT/UNKNOWN (a park during a genuine cap is expected). Read-only: never restarts, kills, or sends keys to any pane. | Fail-loud detection of a lead that missed an in-place re-auth. |

### Claude re-auth handoff

The prompt asking for a paste-back value belongs to **Claude Code's `/login`**
flow. During no-restart auto-rotation, that command is running in the host's
isolated tmux session named `swarm-login-probe`; neither the Discord bot nor the
product swarm is inventing a second authentication step. Claude Code can finish
through its localhost OAuth callback when the browser can reach the CLI host.
When the link is opened on a phone, across SSH, in a container, or in another
network namespace, that callback is not reachable and the browser instead shows
an `authorization#state` value for the CLI prompt. This location-dependent
behavior is covered by Claude Code's [authentication documentation](https://code.claude.com/docs/en/authentication)
and [remote-login troubleshooting](https://code.claude.com/docs/en/troubleshoot-install#oauth-login-fails-in-wsl2-ssh-or-containers).

Never paste that value into an ordinary Discord message. Ordinary channel
messages are durable chat history and model input, so the swarm is expected to
refuse a request to repeat or consume one. Use **Open secure login** and, only
when the browser displays a value, **Enter paste-back code**. Both actions are
restricted to the canonical owner, who must be present in the top-level and
target-channel ACLs; the URL is visible only ephemerally and the modal submission
bypasses message/model ingress. If a value was already posted in chat, delete the
message for hygiene and start a fresh `/login` request instead of reusing it.

The relay also refuses before touching `/login` unless the exact channel and bot
have a fresh v1 readiness record from the running bridge. Each request is bound
to its owner, channel, message, bot, expiry, and one-use nonce. On success,
timeout, or failure, the relay removes the generic Discord control and its
private request/response records; an unused modal response is discarded when
the automatic callback wins.

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

- **`bin/swarm-add.sh <name> <repo> [<channel>] [--engine claude|codex]`** — for a **new** swarm. The
  script walks you through every step: creating the Discord application,
  enabling the privileged `MESSAGE CONTENT INTENT`, the full OAuth permission
  set, inviting the bot, finding the channel ID via Developer Mode, capturing
  the bot token via a silent prompt, writing the host config, stamping the
  repo, registering the access policy, and verifying that the bridge plugin
  is enabled (the trap that broke `reserve-backend-2`'s first bringup —
  silent failure mode when `enabledPlugins["discord-b2b@qofi-swarm"]` isn't
  `true`). For Codex it instead prepares and verifies the root-attested hidden
  runtime/workspace before committing the row; launch then verifies subscription
  auth, installs the frozen bridge graph, and reconciles a fail-closed per-swarm ACL.
  Ends with an engine-specific verification checklist.

- **`bin/swarm-onboard.sh <repo> [--engine claude|codex]`** — for stamping the swarm system into a
  **pre-existing real codebase** (the kind that already has its own code, its
  own history, possibly its own `CLAUDE.md` or `.git/hooks/pre-commit`).
  The flag selects the repository runtime surfaces and must be repeated on the
  later `swarm-add`; `claude` is the compatibility default.
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
| Codex doctrine/policy | `<repo>/AGENTS.md` · `.codex/` | next Codex invocation | `AGENTS.md` is rediscovered for a new thread. The unattended bridge disables command hooks and ignores project exec-policy rules on every turn; `.codex/hooks.json` stays empty. The stamped rules apply only to a separately trusted manual interactive session. |
| Agent skills | `<repo>/.agents/skills/` | next session/turn discovery | Codex discovers repository skills from its native path; Claude keeps its existing `.claude/skills/` copies. |
| Doctrine | `<repo>/CLAUDE.md` · `TEAM_LEAD.md` · `ESCALATION.md` | next session start | The lead reads these into context at session start. New content does not reach a running lead until the session is cycled. |
| Git pre-commit | `<repo>/.git/hooks/pre-commit` | next commit | Git reads the hook fresh on every commit. No restart needed. |
| Manifest itself | `templates/<archetype>/manifest.tsv` (default `engineering-cto`) | next `swarm-sync` / `swarm-init` / `swarm-onboard` run | The scripts read the per-archetype manifest at invocation time. |

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

`swarm-restart` and `swarm-update` use an engine-aware activity contract before
taking the session down. Claude rows consult `repo_activity()` and transcript
freshness. Codex rows require a fresh, live `runtime.json` heartbeat and refuse
while `active=true` or queued work exists. Missing, malformed, stale, or dead
Codex state fails safe rather than guessing that the lead is idle. An explicit
`--force` remains the operator override.

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

[`templates/engineering-cto/manifest.tsv`](./templates/engineering-cto/manifest.tsv)
is the single source of truth for what a fully-stamped `engineering-cto`
swarm contains. (Future archetypes — `cpo`, `company-brain` — get their own
manifests under `templates/<archetype>/`; `swarm_type_of` in `swarm-lib.sh`
resolves the target's archetype from `.claude/swarm-type`, default
`engineering-cto`.) `swarm-init.sh`, `swarm-sync.sh`, and `swarm-onboard.sh`
all consume the resolved manifest via `manifest_walk` in `swarm-lib.sh`, so
first-stamp / upgrade / onboard cannot diverge. To add a new artifact to
every `engineering-cto` swarm: add the line to that archetype's manifest.

Doctrine files (`CLAUDE.md`, `ESCALATION.md`) are composed at stamp time
from `_base/` (universal spine) plus the archetype's overlay fragments —
the `compose` behavior in the manifest cats `+`-joined sources literally.
See [`templates/_base/README.md`](./templates/_base/README.md) for the
mechanism and the trailing-newline invariant.

**Profile overlay (engineering-cto only, [ADR-0013](./docs/adr/ADR-0013-frontend-backend-profile-axis.md)).**
A second, *orthogonal* axis — `--profile frontend|backend` on
`swarm-new` / `swarm-add` / `swarm-init` — stamps a per-repo
`.claude/swarm-profile` marker (resolved by `swarm_profile_of` — a per-repo
marker read like `swarm_type_of`, but defaulting to **empty**, not to a value,
so markerless swarms are untouched). It does **not** replace the archetype; it
appends a
stack-specific overlay fragment
(`templates/engineering-cto/profiles/<profile>/CLAUDE.md`) onto the composed
`CLAUDE.md`. v1 `backend` is **label-only** — today's engineering-cto already
*is* the backend case, so it ships no fragment and composes byte-identically
to a pre-profile swarm; `frontend` is the only profile with overlay content.
An absent marker is a no-op (existing swarms are untouched). A profile against
a non-engineering-cto type is refused. This overlay is the **one** exception to
"add an artifact in ONE place: the manifest": it is injected dynamically by
`manifest_apply_compose` in `swarm-lib.sh` (the `CLAUDE.md` manifest line stays
profile-agnostic), so look there — not at a manifest line — for where the
`frontend` fragment joins the compose.

Each line is `behavior | template-path | target-path` with an optional
trailing `| covers` note — a terse, hand-written one-liner of what the target
doc answers. That column makes the manifest double as the **route-before-scan
map**: a reader looks up which file covers a topic, opens it, and only greps
the tree as a fallback. It is human/agent-facing only — `manifest_walk` absorbs
it into a catch-all field and ignores it. There are six
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

The manifest carries the shared Git gate plus Claude- and Codex-native doctrine,
hooks, and skills — see the file for the canonical list. `swarm-sync.sh --check` reports per-artifact
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

The shared interface lives in `swarm-lib.sh` and branches on the configured
engine. For Claude, `repo_activity()` takes a repo path, a Claude projects dir
(`~/.claude/projects`), and a staleness threshold, then
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
that automatic. For Codex, `swarm_codex_runtime_read()` validates the bridge's
atomic `codex-bridge-runtime/v1` snapshot, daemon PID, and heartbeat freshness,
then reads `active`, `queue_depth`, and the last completion/error. Restart,
watcher, typing, and operator view consume the same engine-specific state so an
active Codex turn is never inferred from unrelated Claude transcripts. Default
Claude activity threshold: `SWARM_STALE_SECONDS=300` (5 minutes).

### Engine bridges

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

For `engine=codex`, `codex-bridge/daemon.ts` connects to Discord directly. It
binds to the configured channel, applies the reconciled ACL, serializes all
accepted work, submits turns through the root-attested global App Server manager
with an isolated environment and explicit sandbox, and posts the final text with
Discord mention parsing disabled. A per-swarm protocol-filtering facade exposes
only that swarm's registered threads to the read-only native TUI. `runtime.json`
and a bounded/redacted `events.jsonl` remain lifecycle surfaces and the persisted
viewer fallback; neither stores Discord message bodies or secrets.

### Per-channel access control

`~/.claude/channels/discord/access.json` (managed locally — NOT in this
repo) controls who the bridge accepts messages from:

```json
{
  "dmPolicy": "pairing" | "allowlist" | "disabled",
  "loginControlOwnerId": "<owner-discord-id>",
  "allowFrom": ["<owner-discord-id>"],
  "groups": {
    "<channel-id>": { "requireMention": false, "allowFrom": ["<owner-id>"] }
  },
  "pending": { ... }
}
```

`swarm-add` pre-writes the owner group for the new swarm's channel with
`requireMention: false` and `allowFrom: [owner]`, so the lead acts on
every message from the operator in that channel — no `@`-mention
required — while `allowFrom` still keeps other members from triggering
the agent.

Set `SWARM_OWNER_DISCORD_ID` to the operator's numeric Discord user ID before
provisioning. Phase 4d pins it as `loginControlOwnerId` and records it in both top-level
`allowFrom` (the only principal allowed to request Codex Git-broker actions)
and the swarm's channel group; it never infers an operator from a bot or watcher
membership. `access.json` is written as an owner-held `0600` file. Re-running
`swarm-add` safely narrows a historical owned `0644` file to `0600`.
An upgraded file without `loginControlOwnerId` remains compatible only when
top-level `allowFrom` contains exactly one numeric principal; ambiguity disables
secure re-auth until provisioning pins the owner.

A `type=cpo` swarm is dual-bound to its operator channel and
`SWARM_BUS_CHANNEL`. Provisioning ensures the bus group contains the explicit
operator plus `CTO_BUS_WATCHER_BOT_ID`, so watcher reposts are accepted without
granting the watcher operator/Git authority. `swarm-doctor` checks both groups.

Each Codex swarm has an isolated copy at
`~/.codex/channels/discord-<name>/access.json`. Launch reconciles its bound
group from the canonical Claude ACL on every start, including revocations, and
also reconciles the explicit top-level operator list. It refuses to start if a
bound guild allowlist or the top-level operator list is empty. Codex DM pairing
commands must set `DISCORD_STATE_DIR` to that exact per-swarm directory; the
daemon prints a copy-paste-safe command when pairing is requested.

### tmux + state paths

| Path | Holds |
| --- | --- |
| `$SWARM_HOME/swarm.conf` | One line per swarm: `name \| repo \| TOKEN_VAR \| CHANNEL_ID \| GUILD_ID \| ACCOUNT \| ENGINE`. Legacy shorter Claude rows remain valid. |
| `$SWARM_HOME/tokens.env` | `export BOT_<NAME>="..."` per swarm. Gitignored, chmod 600, fail-loud during `swarm-add` if not in `.gitignore`. |
| `$SWARM_HOME/.claude/settings.json` | This repo's own Claude Code settings (the source repo, not a stamped swarm). |
| `~/.claude/channels/discord/access.json` | Per-channel access policy (see above). |
| `~/.claude/channels/discord/login-control/` | Host-owned private readiness and one-shot Claude `/login` request/response records. The bridge and relay use it to keep OAuth URLs and paste-back values out of ordinary Discord/model ingress; repository agents are denied access. |
| `~/.claude/projects/<encoded-path>/...` | Lead + teammate transcript jsonls. The liveness signal scans these. |
| `~/.claude/qofi-review-result-sets/<repository-key>/` | Owner-private canonical-v2 sidecars for the installed Claude -> Codex Companion's raw v1 review jobs. Legacy sidecars explicitly carry a null reviewed-diff hash because that plugin does not attest exact reviewed bytes. |
| `~/.codex/channels/discord-<name>/` | Per-Codex-swarm ACL, profile-scoped resumed-thread map, sanitized `rotation-state.json`, metadata-only quota `parked-turns.json`, task/profile-scoped Fable review artifacts with reviewed-input hashes, attachments, atomic `runtime.json`, bounded/redacted `events.jsonl`, and owner-only native facade. |
| `~/.codex/app-server-manager/` | Owner-private control endpoint and harness-side per-swarm lease/cooldown/telemetry state for the one root-attested global Codex App Server manager. |
| `~/.config/swarm/` | launchd job logs, heartbeat state. |
| tmux session `swarm-<name>` | The engine lead's session. Use `swarm-attach` for Claude and `swarm-view.sh <name>` for the Codex live view. |
| tmux session `codex-view-<name>` | Replaceable, separate Codex viewer generation: navigation-enabled `codex-native` behind the read-only facade when all proofs pass, otherwise read-only `codex-events`. It never keeps the daemon's `swarm-<name>` session alive. |

### The Max-pool ceiling

Claude rows ride the configured Claude Max pool and remain subject to its
historical **1–2 concurrent-team** guidance ([ADR-0004](./docs/adr/ADR-0004-max-capacity-ceiling.md)).
Codex rows use their independent ChatGPT subscription login. The launcher keeps
those auth lanes separate and rejects API-key fallback; it does not treat a
second subscription as permission to exceed either provider's terms or limits.

## 8. Enforcement — mechanical vs probabilistic

The system has two layers of discipline. Be honest about the line — over-
claiming the mechanical layer is what turns gates into theater.

### Shared harness lifecycle controls (implemented/tested; not live)

ADR-0023 moves lifecycle compliance above both CLIs. Normalized Claude and Codex
events feed one policy layer: a terminal transition requires the final
review-artifact hash and a Discord stop outcome of `delivered` or durably
`queued`; idle pings require a correlated `qofi.cto-checkin/v1` object; roadmap
and digest state derive from event/result-set journals; and pre-edit read/search
counts produce bounded context-pack gap metrics. Agent prose cannot satisfy any
of those controls. The same conformance fixtures execute through both runtime
adapters, and known differences are recorded in
[`docs/RUNTIME-PARITY.md`](docs/RUNTIME-PARITY.md).

These controls remain behind explicit adoption switches. Ratification of
ADR-0023, a template sync/restart, provider delivery/dead-letter shakedowns, and
installed-version conformance are required before the repository calls them
live. The current adapters disable early review on both runtimes because neither
has a trusted symmetric in-session boundary for granting it.

### Claude mechanical controls

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

### Codex controls and their exact boundary

Codex event semantics are not renamed Claude semantics. The stamped integration
uses only the guarantees Codex actually exposes:

| Control | Strength and limit |
| --- | --- |
| Custom root-deny permission profile | Per-turn boundary: target workspace writes, host-root denial, no tool network, private bounded temp, exact read-only toolchain roots, active attachments only, secret-path read denials, and read-only managed doctrine/`.claude`/`.codex`/`.agents`. The child receives no Discord/provider credentials or ambient user config. |
| Hooks and exec-policy neutralization | The bridge always disables command hooks and passes `--ignore-rules`; editable repo hooks/rules cannot authorize host execution. `.codex/hooks.json` is intentionally empty. The stamped `qofi-hard-floor.rules` is only manual-interactive defense in depth. |
| Direct verification + harness completion boundary | Codex runs `.claude/test-cmd`, lint/type/canon checks, and DoD review directly. Mutable repo command hooks remain disabled. When ADR-0023 is adopted, active-worker reviewer calls remain refused. After a successful terminal App Server result, generation reap, ACL revocation, and an exact host snapshot, the manager invokes one fixed Fable review and the root lifecycle broker consumes its lease-bound receipt before stop delivery. CI, diff review, operator review, and truthful incomplete results remain mandatory. |
| Operator-authorized Git broker | Codex's own sandbox protects `.git`. The Discord bridge therefore accepts only its documented, allowlisted branch/commit/retire grammar while idle. Trusted host code reproduces the deterministic docs-touch and secret checks and uses Git plumbing. It advances only an independent side ref; canonical HEAD/index are unchanged, unintegrated history is never retired, and hooks/filters/signing/push/reset/merge/worktrees/arbitrary Git arguments remain unavailable. |
| Bridge gate and resource limits | Hard bound-channel/nonempty-owner ACL, FIFO serialization, queue/output/attachment limits, process-group cleanup, and mention-safe outbound delivery before/around model execution. |

Lifecycle and repository-lease transaction locks fail closed after an ungraceful process death.
They span config, repository, tmux, and runtime-authority changes, so PID death
is not enough evidence to delete them safely. Existing Claude attach and
emergency `down` remain available. Never delete retained locks by hand:
[`bin/swarm-recover.sh`](bin/swarm-recover.sh) emits a read-only evidence receipt
and removes only the same dead-owner inode after explicit reconciliation; see
[`docs/CODEX.md`](docs/CODEX.md#interrupted-lifecycle-transactions).

Codex 0.144.x launches trusted command hooks as ordinary host processes outside
the tool sandbox. For that reason swarm automation never enables hook-trust
bypass and never executes mutable repo-local hook helpers in unattended turns.

### Probabilistic (judgment doctrine; hooks CAN'T enforce these)

These live in `templates/_base/CLAUDE.md` (universal spine) +
`templates/engineering-cto/CLAUDE.md` (engineering overlay) +
`templates/engineering-cto/TEAM_LEAD.md` (single-file, engineering-only).
They're
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
- **tmux discipline.** Use `Ctrl-b d` to detach. In a Claude TUI, `Esc` is the
  normal turn interrupt. The Codex viewer is also read-only: it normally renders
  the native TUI through the filtering facade and may fall back to the persisted
  event/status window. Lifecycle/Discord controls own cancellation; the viewer
  cannot mutate or approve. Do not send `Ctrl-C` to either engine's daemon/lead
  pane — it terminates the process and closes the session.
- **Re-source aliases after `swarm-add`.** The per-swarm aliases
  (`swarm-<name>`, `swarm-restart-<name>`, `swarm-update-<name>`) are
  generated from `swarm.conf` at source time. A shell opened before you
  ran `swarm-add` won't have the new aliases until you `source ~/.zshrc`
  (or open a new terminal).
- **`SWARM_HOME` uses the anti-secret-only pre-commit variant.** The
  standard pre-commit's docs-touch leg would misfire on routine tooling
  commits (e.g. `bin/swarm-*.sh` edits with no doc change), so this repo
  installs `templates/engineering-cto/git-hooks/pre-commit-anti-secret-only` instead.
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
