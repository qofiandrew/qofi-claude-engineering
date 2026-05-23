# SETUP.md — fresh-machine standup

Sibling to `README.md`. The README is **how the system works**; this is
**how to get the system running on a new macOS machine from zero**. Read
this first, sequentially. Once you have a heartbeat in Discord and a
swarm responding to `@mention`, switch to the README.

Approximate time: **30–60 minutes**, mostly Discord-portal clicking and
one Claude Code login. Most of the friction is in §3 and §4 (Claude /
agent config and tokens); §1–§2 and §6–§7 are mechanical.

Marker convention: `[VERIFY ON SETUP]` flags any step that can't be
confirmed from the repo alone — typically an external service (Discord
portal) or an interactive UI action (Claude Code login).

---

## 0. Scope and how to use this doc

- Numbered, sequential. Don't skip — later steps assume earlier ones land.
- Every step has a concrete **Verify** line; if it doesn't pass, fix
  before proceeding rather than pressing on.
- After §9 passes, you have a live swarm. The README owns operating it.

---

## 1. Prerequisites

Derived from the script shebangs, the launchd plists, and the bridge's
`package.json` — not from memory. **Bash 3.2 is the macOS default**
(`/bin/bash`) and the scripts are written to that floor; you do **not**
need a newer bash.

| Dep | Why | How |
| --- | --- | --- |
| macOS 13+ | tmux, launchd, `/opt/homebrew` paths | n/a |
| Homebrew | installs tmux, bun if you want via brew | https://brew.sh |
| **tmux** | every swarm runs as a persistent `tmux` session; watcher reads pane content via `capture-pane` | `brew install tmux` |
| **bun** | the discord-b2b bridge is a Bun project; first launch runs `bun install` automatically | `curl -fsSL https://bun.sh/install \| bash` |
| **Claude Code v2.1.32+** | the lead process; needs the dev-channels flag and the marketplace plugin install | https://claude.com/claude-code |
| **python3** | manifest walker, settings merger, dod-affirm hook, permission-gate hook, watcher JSON, reset-time parser | ships with macOS (`/usr/bin/python3`) |
| **git** | clone + worktrees | ships with macOS (`/usr/bin/git`) |
| **curl** | watcher posts directly to Discord REST | ships with macOS |
| **A Discord account + a server you own** | one bot identity per swarm; the bot needs Manage-Messages-equivalent permissions in the channel | n/a |

Not required (verified against repo): `jq` (the system uses `python3 -c`
for JSON), `node`/`npm` (bun is the runtime), GNU coreutils, brew bash.

> **Apple Silicon vs Intel.** All paths in `launchd/*.plist` and the
> existing repo assume Apple Silicon (`/opt/homebrew/bin/tmux`). On
> Intel that's `/usr/local/bin/tmux` — you'll edit the two plists in §6
> before loading them. Verify with `which tmux`.

### Preflight sanity check

Paste this whole block into a terminal. Every line should print a
version (or "OK") with no `command not found`. If anything fails, stop
and install it before proceeding.

```sh
{
  echo "--- preflight ---"
  echo "macOS:    $(sw_vers -productVersion)"
  echo "shell:    $SHELL ($(bash --version | head -1))"
  echo "tmux:     $(tmux -V 2>/dev/null || echo MISSING)"
  echo "bun:      $(bun --version 2>/dev/null || echo MISSING)"
  echo "claude:   $(claude --version 2>/dev/null || echo MISSING)"
  echo "python3:  $(python3 --version 2>/dev/null || echo MISSING)"
  echo "git:      $(git --version 2>/dev/null || echo MISSING)"
  echo "curl:     $(curl --version 2>/dev/null | head -1 || echo MISSING)"
  echo "which tmux: $(which tmux 2>/dev/null || echo MISSING)"
}
```

**Verify**: Claude Code is logged in on a **Max** plan, **not** an
ANTHROPIC_API_KEY. Open Claude Code and run `/status` — the panel
should show a Max subscription. The lead processes will run unattended,
charging your Max pool; an exported `ANTHROPIC_API_KEY` in the launching
shell would silently divert to metered API billing. `swarm-up.sh` 
explicitly `unset`s it before launching the lead (see
`bin/swarm-up.sh:64`), but it's still cleaner not to have it in your
shell at all. `[VERIFY ON SETUP]`

---

## 2. Clone + `SWARM_HOME`  ← the recurring footgun

`SWARM_HOME` is the single most important environment variable in the
system. **Every script in `bin/` fails loud if it's unset or wrong** —
that's by design (see, e.g., `bin/swarm-watch.sh:46-49`).

```sh
# Clone anywhere; the path becomes SWARM_HOME.
mkdir -p ~/qofirepos
cd ~/qofirepos
git clone <your-fork-or-this-repo-url> qofi-claude-engineering
```

Add to `~/.zshrc` (above the aliases line you'll add in §7):

```sh
export SWARM_HOME="$HOME/qofirepos/qofi-claude-engineering"
```

Then open a new terminal (or `source ~/.zshrc`).

> Sourcing `bin/swarm-aliases.sh` (§7) ALSO self-locates `SWARM_HOME`
> from the file's own path — so once §7 lands, even a fresh shell that
> never read `~/.zshenv` will see `$SWARM_HOME`. But `launchd` plists
> hard-code it (no shell involved) and one-off scripts you invoke from
> a not-yet-aliased shell need it too. Setting it explicitly in
> `~/.zshrc` is the safe belt-and-suspenders.

**Verify**:

```sh
echo "$SWARM_HOME"                              # the path above
ls "$SWARM_HOME/templates/manifest.tsv"          # exists
"$SWARM_HOME/bin/swarm-up.sh" status             # prints "(no swarm sessions running)"
```

If `swarm-up.sh status` complains about `SWARM_HOME unset or wrong`,
fix it before going further.

---

## 3. Claude Code / agent-managed config  ← the hot zone

This is the part that lives **outside the repo**, under `~/.claude/`,
and is the single most likely source of "I followed the README but
nothing works" on a fresh machine. The `swarm-add.sh` Phase 5 check
exists specifically because of one botched standup (`reserve-backend-2`)
where this was wrong. Walk it carefully.

### 3.1 `~/.claude` layout (created by Claude Code on first login)

After your first `claude` login, Claude Code creates this structure:

```
~/.claude/
├── settings.json                 # user-global Claude Code settings
├── plugins/
│   ├── installed_plugins.json    # which plugins are installed (and where)
│   └── known_marketplaces.json   # which marketplaces are registered
└── projects/                     # per-repo transcript jsonls
```

After you finish §3.2–3.3 + your first `swarm-add` you'll also see:

```
~/.claude/
├── channels/discord/
│   ├── access.json               # bridge ACL — who can talk to which bot
│   └── (other bridge state)
└── plugins/cache/qofi-swarm/discord-b2b/<version>/   # cached plugin
```

None of this is in the repo. It's all re-created on a fresh machine by
running the steps below.

### 3.2 Register `qofi-swarm` as a Claude Code marketplace (directory source)

This is what makes the discord-b2b plugin discoverable from inside a
Claude Code session. The marketplace's source is **this repo as a
directory** (see `.claude-plugin/marketplace.json`), not a remote git
URL.

From any Claude Code session:

```
/plugin marketplace add /Users/<you>/qofirepos/qofi-claude-engineering
```

(Use your actual `$SWARM_HOME` path.)

**Verify**:

```sh
cat ~/.claude/plugins/known_marketplaces.json | python3 -m json.tool
```

There should be a `"qofi-swarm"` entry with `"source": {"source":
"directory", "path": "<your-SWARM_HOME>"}`.

### 3.3 Install the `discord-b2b` plugin

From any Claude Code session:

```
/plugin install discord-b2b@qofi-swarm
```

**Verify**:

```sh
cat ~/.claude/plugins/installed_plugins.json | python3 -m json.tool
```

Should show `"discord-b2b@qofi-swarm"` with an `installPath` under
`~/.claude/plugins/cache/qofi-swarm/discord-b2b/<version>/`. The first
time a swarm launches the bridge, `bun install` runs automatically in
that cache dir (see `bridge/package.json` — `"start": "bun install
--no-summary && bun server.ts"`), so the first cold start is a few
seconds slower than later launches.

### 3.4 `enabledPlugins[...] = true` per swarm — the silent-failure trap

Installing the plugin is **not enough**. Each stamped swarm's
**repo-local** `.claude/settings.json` must also have:

```json
{
  "enabledPlugins": {
    "discord-b2b@qofi-swarm": true
  }
}
```

When this is missing or `false`, the lead launches and connects to
Discord, but the bridge MCP **never spawns** — every Discord tool call
fails silently and the bot looks online while doing nothing. This is
the failure mode that broke `reserve-backend-2`'s first bringup.

`swarm-add.sh` Phase 5 verifies this **after every standup** and offers
to repair it in place (see `bin/swarm-add.sh:463-548`). You don't need
to set it by hand for new swarms — `swarm-add` handles it. But on a
fresh machine, when you onboard an **existing** repo via `swarm-onboard`,
re-run `swarm-add <name> <repo> --skip-walkthrough` afterwards to let
Phase 5 cover this check.

### 3.5 `~/.claude/channels/discord/access.json` — bridge ACL

The bridge enforces who can talk to each bot. Lives at
`~/.claude/channels/discord/access.json` (NOT in this repo — it's per-
machine, holds Discord IDs).

```json
{
  "dmPolicy": "pairing" | "allowlist" | "disabled",
  "allowFrom": ["<your-discord-user-id>"],
  "groups": {
    "<channel-id>": { "requireMention": true, "allowFrom": ["<your-id>"] }
  },
  "pending": {}
}
```

**You do not pre-create this file.** `swarm-add.sh` Phase 4d
(`bin/swarm-add.sh:436-461`) creates it on first standup with sensible
defaults (`dmPolicy: "pairing"`, your owner ID in `allowFrom`), and
appends a per-channel group entry on every subsequent `swarm-add`.

You will need **your Discord user ID** when `swarm-add` prompts for
`OWNER_ID`: in Discord, User Settings → Advanced → enable Developer
Mode, then right-click your own name and "Copy User ID". `[VERIFY ON
SETUP]`

---

## 4. Secrets — `tokens.env`

**Location**: `$SWARM_HOME/tokens.env`. **Format**: one `export
BOT_<NAME>="..."` line per swarm. **Permissions**: `chmod 600`.
**Gitignored**: yes, verified in `.gitignore:2`. `swarm-add` exits
fatal if you ever managed to add this file to git tracking (see
`bin/swarm-add.sh:386-394`).

You do **not** create this file by hand. `swarm-add.sh` Phase 3 captures
each bot token via a **silent prompt** (no terminal echo, no scrollback,
no command-line argument). Never paste a bot token onto a command line
or into chat — once it shows in scrollback or history, treat it as
leaked and rotate.

**ANTHROPIC_API_KEY** must not live in `tokens.env` or anywhere the
lead's shell sources — `swarm-up.sh` explicitly `unset`s it (line 64)
so leads run on your **Max** pool, not metered API. The example file
`tokens.env.example` includes this warning.

### How to get a Discord bot token  `[VERIFY ON SETUP]`

`swarm-add.sh` Phase 1 walks you through this interactively the first
time you stand up a swarm. The abbreviated version, for reference:

1. **Create the application** at https://discord.com/developers/applications
   → "New Application" → name it `swarm-<name>` (convention).
2. **Enable the privileged intent.** Bot sidebar → "Privileged Gateway
   Intents" → toggle on **MESSAGE CONTENT INTENT** → Save Changes.
   *(Of the four intents the bridge requests in
   `bridge/server.ts:81-89` — `Guilds`, `GuildMessages`,
   `DirectMessages`, `MessageContent` — only `MessageContent` is
   privileged. The other three are non-privileged and require no portal
   toggle; they just need to be in the code, which they are.)*
3. **Generate the invite URL.** OAuth2 → URL Generator. Scope: `bot`.
   Bot Permissions: **View Channels, Send Messages, Send Messages in
   Threads, Read Message History, Attach Files, Add Reactions**.
   Integration Type: **Guild Install**. Copy the generated URL, open it,
   pick your server, Authorize.
4. **Reset the token.** Bot sidebar → "Reset Token" → confirm → **copy
   immediately**. Discord shows it once. You'll paste it into
   `swarm-add`'s silent prompt in §8.

The script prints the same walkthrough live, with pauses between
groups, so on your first standup you can follow `swarm-add`'s prompts
rather than this section.

---

## 5. The bridge

Most of the bridge work is already done by §3.2–3.3. Confirm the wiring:

- `bridge/` is the Bun-based discord-b2b MCP plugin (`bridge/server.ts`,
  `bridge/package.json`).
- It loads into each swarm's lead session via the launch command
  `claude --dangerously-load-development-channels
  plugin:discord-b2b@qofi-swarm` (see `bin/swarm-up.sh:35` and
  `bin/swarm-up.sh:70`). The `--dangerously-load-development-channels`
  flag is required because `qofi-swarm` is a **self-published**
  marketplace (a local directory), not on Anthropic's approved
  channels allowlist — plain `--channels` would refuse to load it.
- First spawn auto-runs `bun install` in the plugin cache dir. No
  manual install step.

**Verify**: `bun --version` returns a version (§1 preflight covered
this). No other action required at setup time.

---

## 6. launchd agents — heartbeat watcher + typing pinger

Two `launchd` agents under `launchd/` supervise the always-on stack.
They share `$SWARM_HOME/swarm.conf` and post per-channel heartbeats
using each swarm's own bot token from `tokens.env`. They do **not**
depend on a logged-in shell — they run from system boot.

### 6.1 Edit the plists if your paths differ

The plists hard-code paths because launchd doesn't read your shell
profile. Open both files and confirm:

```sh
"$SWARM_HOME"           # ProgramArguments[1]
CLAUDE_PROJECTS_DIR     # ~/.claude/projects
SWARM_TMUX_BIN          # /opt/homebrew/bin/tmux on Apple Silicon
                        # /usr/local/bin/tmux on Intel
StandardOutPath         # ~/.config/swarm/{watch,typing}.log
StandardErrorPath       # ~/.config/swarm/{watch,typing}.err
```

If your `which tmux` does NOT match `SWARM_TMUX_BIN` in the plists,
edit the plists before symlinking. The shipped values assume an Apple
Silicon Homebrew install at the default user `aschettino`.

### 6.2 Make the log/state dir

```sh
mkdir -p ~/.config/swarm ~/Library/LaunchAgents
```

### 6.3 Symlink the plists into `~/Library/LaunchAgents/`

```sh
ln -sf "$SWARM_HOME/launchd/com.qofi.swarm-watch.plist"  ~/Library/LaunchAgents/
ln -sf "$SWARM_HOME/launchd/com.qofi.swarm-typing.plist" ~/Library/LaunchAgents/
```

### 6.4 Load

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.qofi.swarm-watch.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.qofi.swarm-typing.plist
```

(On older macOS that errors on `bootstrap`, fall back to
`launchctl load -w <plist>`.)

**Verify**:

```sh
launchctl list | grep com.qofi
# should show:
#   <pid-or-->  0  com.qofi.swarm-watch
#   <pid>       0  com.qofi.swarm-typing
tail -n 20 ~/.config/swarm/watch.err ~/.config/swarm/typing.err
# typing.err should show "swarm-typing: starting" once per relaunch.
# watch.err is silent unless something is wrong.
```

Until `swarm.conf` has at least one row (§8), the watcher's tick is a
no-op and the typing pinger sweeps an empty list. That's expected.

---

## 7. Aliases — source `bin/swarm-aliases.sh`

Add one line to `~/.zshrc`, **after** the `SWARM_HOME` export from §2:

```sh
source "$HOME/qofirepos/qofi-claude-engineering/bin/swarm-aliases.sh"
```

Open a new terminal (or `source ~/.zshrc`).

**Verify**:

```sh
type swarm-status         # should resolve to the swarm-up.sh status alias
swarm-status              # "(no swarm sessions running)" — no swarms yet
swarm-watch-log           # tails the launchd logs; Ctrl-C to exit
```

### Stale-shell gotcha

The per-swarm aliases (`swarm-<name>`, `swarm-restart-<name>`,
`swarm-update-<name>`) are generated by walking `swarm.conf` at
**source time**. After every `swarm-add`, open a new terminal or
`source ~/.zshrc` — a shell opened before the new swarm landed won't
have its alias.

---

## 8. Your first swarm

Two entry points. Pick by what the target repo already has — the
README §4 covers the choice in depth; this is the minimum to land your
first swarm.

| Use this | When |
| --- | --- |
| `bin/swarm-add.sh <name> <repo>` | **new** swarm, fresh codebase or one you just created. Walks the Discord portal interactively (§4 in this doc, abbreviated) and runs `swarm-init` against the repo for you. |
| `bin/swarm-onboard.sh <repo>` then `bin/swarm-add.sh <name> <repo> --skip-walkthrough` | **existing** real codebase you want to onboard. Onboard stamps the doctrine + hooks with collision-refuse-and-report semantics; then swarm-add wires up the Discord side. |

For your **very first** standup, use `swarm-add` — the interactive
Phase 1 walkthrough covers §4 of this doc end-to-end and pauses
between steps.

```sh
bin/swarm-add.sh mythirdswarm ~/code/mythirdswarm
```

You'll be prompted for:

- The **channel ID** (Discord Developer Mode → right-click channel →
  Copy Channel ID).
- Your **owner ID** (same Developer Mode → right-click yourself → Copy
  User ID). Goes into `access.json` as `allowFrom`.
- The **bot token** (silent prompt; never echoed).

The script is idempotent: re-running with the same args picks up where
it left off (Phase 0 reports detected pre-existing state). If anything
goes wrong, see `TROUBLESHOOTING` printed at the end of Phase 6.

---

## 9. Verify / smoke test

This is the concrete sequence that proves the whole chain works
end-to-end. Don't skip steps — silent partial failures are the most
common bringup mode.

| # | Check | Pass criterion |
| --- | --- | --- |
| 1 | `launchctl list \| grep com.qofi` | both agents listed |
| 2 | `swarm-status` | shows `(no swarm sessions running)` until next step |
| 3 | `bin/swarm-up.sh up <name>` | prints `launching: swarm-<name> (<repo>)`, no `ERROR:` lines |
| 4 | `bin/swarm-attach.sh <name>` (or `swarm-<name>` alias) | attaches to the tmux session; the Claude TUI renders within ~20s |
| 5 | watch the pane | sees: `unset ANTHROPIC_API_KEY` → `claude --dangerously-load-development-channels …` → dev-channels prompt (auto-cleared) → main UI with footer `auto mode` → the initial brief lands |
| 6 | Discord member sidebar in your server | the bot status flips **online** |
| 7 | `@mention` the bot in #<channel> | the lead replies or reacts within seconds |
| 8 | wait up to 10s, look in #<channel> | a heartbeat message lands (and is **pinned**) showing `🟢 swarm ready · waiting for input · <name>` or similar |
| 9 | `tail -F ~/.config/swarm/watch.log` (or `swarm-watch-log`) | no `ERROR:` / no `FATAL:` lines; tick output runs every 10s |

If step 7 fails (bot online but silent), §3.4 is wrong for this repo —
re-run `bin/swarm-add.sh <name> <repo> --skip-walkthrough` and Phase 5
will detect and repair `enabledPlugins`.

If step 8 fails (no heartbeat), the watcher isn't reaching Discord —
check `~/.config/swarm/watch.err` for token / channel ID / HTTP
errors. Common cause: the channel ID in `swarm.conf` doesn't match
what the bot was actually invited to.

---

## 10. Gotchas

Consolidated from `README.md §9` and from this setup's specific
failure modes. Skim these once before your first standup; come back
when something is wrong.

- **`SWARM_HOME` unset or wrong.** Every `bin/swarm-*.sh` fails loud
  with a remediation line if the env var doesn't point at this repo
  (the templates dir is the canary). Set it in `~/.zshrc`; sourcing
  `swarm-aliases.sh` self-locates it as belt-and-suspenders.
- **`enabledPlugins` set to `false` (or missing).** The bot connects to
  Discord but the bridge MCP never spawns; every Discord tool call
  fails silently. `swarm-add` Phase 5 is the canonical detect-and-fix.
  See `bin/swarm-add.sh:463-548`.
- **Stale-shell aliases.** Per-swarm aliases are generated at
  source-time from `swarm.conf`. After `swarm-add`, open a new terminal
  or `source ~/.zshrc` to pick up the new alias.
- **The racy dev-channels prompt.** `swarm-up.sh` polls for the
  `--dangerously-load-development-channels` warning prompt and sends
  `Enter` automatically. The poll can race a slow CLI start. If you
  attach and the prompt is still waiting:

  ```sh
  tmux send-keys -t swarm-<name> Enter
  ```

  Both `swarm-attach.sh` and `swarm-restart.sh` print this reminder on
  exit.
- **NEVER run `swarm-sync` against `$SWARM_HOME`.** `$SWARM_HOME` is
  the source repo, not a stamped swarm — its `CLAUDE.md` /
  `TEAM_LEAD.md` / `ESCALATION.md` are intentionally divergent from
  the templates. Syncing the templates over them would overwrite the
  brief doctrine. The pre-commit hook in this repo is the
  `anti-secret-only` variant for the same reason (see `README.md §9`).
- **`tmux Ctrl-C` kills `claude`.** Inside a swarm session: `Ctrl-b d`
  to detach (lead keeps running); `Esc` to interrupt a turn in flight.
  **Never `Ctrl-C`** — that kills the `claude` process, which closes
  the pane, which kills the tmux session, which (because §6's watcher
  predicates need the session) flips the heartbeat to `⚪ down`.
- **Apple Silicon vs Intel tmux path.** The shipped plists hard-code
  `/opt/homebrew/bin/tmux`. On Intel, change to `/usr/local/bin/tmux`
  before §6.3.
- **`ANTHROPIC_API_KEY` in your shell.** Even though `swarm-up.sh`
  `unset`s it before launching `claude`, leaving it in your interactive
  shell is a footgun for other workflows. Don't export it in
  `~/.zshrc` if you intend to bill against Max.
- **`bun install` on first bridge spawn.** The first time a swarm
  launches, the bridge runs `bun install` in
  `~/.claude/plugins/cache/qofi-swarm/discord-b2b/<version>/`. Adds
  ~5–10s to that one cold start. Later launches are instant.
- **Watcher needs a token in `tokens.env` per swarm.** A swarm.conf
  row whose `TOKEN_VAR_NAME` doesn't resolve to anything in
  `tokens.env` is skipped with a warning to `~/.config/swarm/watch.err`.
  Check there if a swarm's heartbeat never appears.
- **In-process teammates die on restart.** When you `swarm-restart`
  (cycles the tmux session), the CTO rebuilds from disk but any
  teammates that hadn't committed yet are gone. The WORKING safety
  rail in `swarm-restart` refuses without `--force` if a teammate is
  actively producing within `$SWARM_STALE_SECONDS` — see README §5.

---

## What's next

Once §9 passes end-to-end, switch to the README:

- `README.md §3` — the full command reference.
- `README.md §5` — the SYNC ≠ LIVE propagation model (what reloads
  when, the WORKING safety rail).
- `README.md §7` — the architecture map (always-on stack, liveness
  signal, bridge, access control, Max-pool ceiling).
- `TEAM_LEAD.md` and `CLAUDE.md` — the doctrine your CTO will operate
  by inside each swarm.

For a second swarm, repeat §8 — the rest of this doc only runs once
per machine.
