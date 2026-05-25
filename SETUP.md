# SETUP.md — fresh-machine standup

Sibling to `README.md`. The README is **how the system works**; this is
**how to get the system running on a new macOS machine from bare metal**.
Read this first, sequentially. Once you have a heartbeat in Discord and a
swarm responding to `@mention`, switch to the README.

Approximate time: **45–90 minutes** on a truly fresh Mac — most of the
new friction is the identity/toolchain layer (§0.5: `gh` auth, the SSH
alias, Xcode CLT download) plus the Claude Code login (§1) and the
Discord-portal clicking (§4/§8). §2 and §6–§7 are mechanical.

Marker conventions:
- `[VERIFY ON SETUP]` flags a step that can't be confirmed from the repo
  alone — an external service (Discord/GitHub portal) or an interactive
  UI action (Claude Code login, `gh auth`).
- `[S]` = scriptable (a `setup.sh` could do it unattended).
  `[M]` = inherently manual / human-in-the-loop (a GUI dialog, a browser
  login, a token paste). Every step below is marked.

---

## 0. Scope and how to use this doc

- Numbered, sequential, **strict dependency order**. Don't skip or
  reorder — later steps assume earlier ones landed. In particular, the
  §2 clone **cannot succeed** until §0.5 is complete (the system repo is
  private and reached through the `github-company` SSH alias).
- Every step has a concrete **Verify** line; if it doesn't pass, fix
  before proceeding rather than pressing on.
- After §9 passes, you have a live swarm. The README owns operating it.

---

## 0.5. GitHub identity & toolchain from zero  ← do this FIRST on bare metal

A fresh Mac mini has no Xcode tools, no Homebrew, no git identity, no
`gh`, and no SSH key on the company GitHub account. **Nothing else in
this doc works until this section does** — including the §2 clone, which
reaches a *private* repo (`qofi-claude-engineering`) through the
`github-company` SSH alias. The swarm scripts also assume `gh` is
authenticated as `qofiandrew` (`bin/swarm-new.sh:91-122` preflights all
of this and refuses to run otherwise).

Run these five sub-steps in order.

### 0.5.1 Xcode Command Line Tools  `[M]`

`/usr/bin/git` and `/usr/bin/python3` on a fresh Mac are **install-prompt
shims** — the first time you invoke them they pop a GUI dialog rather
than running. They do not work until CLT is installed, and Homebrew's
installer needs CLT too. This is the true first dependency.

```sh
xcode-select --install     # accept the GUI dialog; wait for it to finish
```

**Verify**: `git --version` prints a version with **no** install dialog.

### 0.5.2 Homebrew  `[M→S]`

Interactive once (it prompts for your password); the shellenv line is
scriptable.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Apple Silicon installs to /opt/homebrew. Put brew on PATH for every shell:
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**Verify**: `brew --version` prints a version; `which brew` is
`/opt/homebrew/bin/brew`.

### 0.5.3 Git identity  `[S]`

`swarm-new`, `swarm-onboard`, and `swarm-sync` all run `git commit`
(`bin/swarm-new.sh:160`, `bin/swarm-onboard.sh:296`,
`bin/swarm-sync.sh:211`). With no identity configured, the first commit
aborts with *"Please tell me who you are."*

```sh
git config --global user.name  "Andrew Schettino"
git config --global user.email "operations@qofi.ai"
```

**Verify**: `git config --global user.email` echoes the address.

### 0.5.4 `gh` CLI — install + auth as `qofiandrew`  `[M]`  `[VERIFY ON SETUP]`

**Two GitHub accounts exist on this operator's setup.** The
`github-company` alias and `gh repo create` both target `qofiandrew`, so
the *active* `gh` account must be `qofiandrew` — otherwise `swarm-new`
would create repos under the wrong owner (`bin/swarm-new.sh:102-114`
refuses if the active account is wrong).

```sh
brew install gh
gh auth login              # interactive: GitHub.com → log in as qofiandrew
```

**Verify** — this MUST print exactly `qofiandrew`:

```sh
gh api user --jq .login    # → qofiandrew
```

If it prints any other account, switch and re-verify:

```sh
gh auth switch -u qofiandrew
```

### 0.5.5 The `github-company` SSH alias — from scratch  `[M]`  `[VERIFY ON SETUP]`

The system depends on the remote form `git@github-company:qofiandrew/…`
(`bin/swarm-new.sh:79,82`). `github-company` is **not** a real host — it's
a `~/.ssh/config` alias you create that points at github.com with the
company key. **This gates the §2 clone**, so it must exist first. A fresh
Mac has none of it; build it now.

```sh
# 1. Generate a dedicated company keypair (separate from any personal key).
ssh-keygen -t ed25519 -C "qofiandrew company key" -f ~/.ssh/qofi_company

# 2. Upload the PUBLIC key to the qofiandrew account (gh is authed as them
#    from §0.5.4, so this lands on the right account).
gh ssh-key add ~/.ssh/qofi_company.pub --title "mac-mini"

# 3. Define the alias. IdentitiesOnly stops SSH from offering a personal
#    key first — important with two accounts in play.
cat >> ~/.ssh/config <<'EOF'

Host github-company
  HostName github.com
  User git
  IdentityFile ~/.ssh/qofi_company
  IdentitiesOnly yes
EOF
```

**Verify** — this MUST greet you as `qofiandrew`:

```sh
ssh -T git@github-company
# → "Hi qofiandrew! You've successfully authenticated, but GitHub does
#    not provide shell access."  (the non-zero exit is normal)
```

If this fails, **do not proceed to §2** — the clone will fail or silently
route through plain github.com and break the remote convention every
swarm repo uses.

---

## 1. Prerequisites — the swarm runtime

§0.5 gave you the toolchain and GitHub identity. §1 installs the always-on
**swarm runtime** and verifies the whole chain. Derived from the script
shebangs, the launchd plists, and the bridge's `package.json` — not from
memory. **Bash 3.2 is the macOS default** (`/bin/bash`) and the scripts
are written to that floor; you do **not** need a newer bash.

| Dep | Why | How |
| --- | --- | --- |
| macOS 13+ | tmux, launchd, `/opt/homebrew` paths | n/a |
| **tmux** | every swarm runs as a persistent `tmux` session; watcher reads pane content via `capture-pane` | `brew install tmux` `[S]` |
| **bun** | the discord-b2b bridge is a Bun project (`bridge/server.ts` → `#!/usr/bin/env bun`); first launch runs `bun install` automatically | `curl -fsSL https://bun.sh/install \| bash` `[S]` |
| **Claude Code v2.1.32+** | the lead process; needs the dev-channels flag and the marketplace plugin install | https://claude.com/claude-code `[M]` |
| **python3** | manifest walker, settings merger, dod-affirm hook, permission-gate hook, watcher JSON, reset-time parser | provided by **CLT (§0.5.1)**; `/usr/bin/python3` is an install-prompt shim until then |
| **git** | clone + worktrees + the `git commit`s in swarm-new/onboard/sync | installed via **CLT (§0.5.1)**, configured in **§0.5.3** |
| **gh** | `swarm-new` preflight + GitHub repo creation | installed + authed in **§0.5.4** |
| **`github-company` SSH alias** | the remote form every swarm repo uses | created in **§0.5.5** |
| **curl** | watcher posts directly to Discord REST | ships with macOS |
| **A Discord account + a server you own** | one bot identity per swarm; the bot needs Manage-Messages-equivalent permissions in the channel | n/a |

Not required (verified against repo): `jq` (the system uses `python3 -c`
for JSON), GNU coreutils, brew bash. **`node`/`npm` are NOT swarm-system
dependencies** — bun is the bridge runtime. (Node is only relevant
per-product; see §1.5.)

> **Apple Silicon vs Intel.** All paths in `launchd/*.plist` and the
> existing repo assume Apple Silicon (`/opt/homebrew/bin/tmux`). On
> Intel that's `/usr/local/bin/tmux` — you'll edit the two plists in §6
> before loading them. Verify with `which tmux`.

### Install + preflight  `[S]`

```sh
brew install tmux
curl -fsSL https://bun.sh/install | bash    # then ensure bun is on PATH in ~/.zshrc
# install Claude Code per https://claude.com/claude-code (native installer)
```

Paste this whole block into a terminal. Every line should print a version
(or "OK") with no `command not found`. If anything fails, stop and install
it before proceeding.

```sh
{
  echo "--- preflight ---"
  echo "macOS:     $(sw_vers -productVersion)"
  echo "shell:     $SHELL ($(bash --version | head -1))"
  echo "tmux:      $(tmux -V 2>/dev/null || echo MISSING)"
  echo "bun:       $(bun --version 2>/dev/null || echo MISSING)"
  echo "claude:    $(claude --version 2>/dev/null || echo MISSING)"
  echo "python3:   $(python3 --version 2>/dev/null || echo MISSING)"
  echo "git:       $(git --version 2>/dev/null || echo MISSING)"
  echo "gh:        $(gh --version 2>/dev/null | head -1 || echo MISSING)"
  echo "gh user:   $(gh api user --jq .login 2>/dev/null || echo 'NOT AUTHED')"   # MUST be qofiandrew
  echo "ssh alias: $(ssh -T git@github-company 2>&1 | grep -o 'Hi [A-Za-z-]*' || echo 'NO ALIAS')"  # MUST be 'Hi qofiandrew'
  echo "curl:      $(curl --version 2>/dev/null | head -1 || echo MISSING)"
  echo "which tmux: $(which tmux 2>/dev/null || echo MISSING)"
}
```

**Verify**: Claude Code is logged in on a **Max** plan, **not** an
ANTHROPIC_API_KEY. Open Claude Code and run `/status` — the panel
should show a Max subscription. The lead processes will run unattended,
charging your Max pool; an exported `ANTHROPIC_API_KEY` in the launching
shell would silently divert to metered API billing. `swarm-up.sh`
explicitly `unset`s it before launching the lead (see
`bin/swarm-up.sh:74`), but it's still cleaner not to have it in your
shell at all. `[VERIFY ON SETUP]`

---

## 1.5. PRODUCT-TIER dependencies (conditional — NOT swarm-system prereqs)

> **These are NOT required by the swarm system.** There are zero Docker
> or Node references in `bin/`, `launchd/`, or the swarm config. Install
> them only because the **product repos your swarms build** need them.
> Skip this section entirely if you're only standing up the swarm
> orchestration; come back when a product requires it.

- **Docker Desktop** `[M]` — install if a product runs containers in its
  dev/test loop (e.g. a backend swarm). **RAM cap matters here:** this
  host runs Claude leads + bun bridges *and* containers, and you've hit
  memory pressure before. Check total RAM first (`sysctl hw.memsize`),
  then **Docker Desktop → Settings → Resources → Memory ≈ 25–33% of
  total** (≈4 GB on a 16 GB mini, ≈6–8 GB on 24 GB), leaving ≥2 GB
  headroom per concurrent lead. `swarm.conf.example` already caps you at
  ~1–2 concurrent teams on one Max pool, which bounds lead memory — start
  conservative, raise only if a container demands it.
- **Node** `[M]` — `brew install node` **only** if a product repo's
  test-gate runs node (`templates/hooks/permission-gate.sh` whitelists
  `node --test` / `npm test` for product gates). The swarm system itself
  never needs it; bun is the bridge runtime.

---

## 2. Clone + `SWARM_HOME`  ← the recurring footgun  `[S]`

`SWARM_HOME` is the single most important environment variable in the
system. **Every script in `bin/` fails loud if it's unset or wrong** —
that's by design (see, e.g., `bin/swarm-watch.sh:46-49`).

The system repo is **private** and is cloned through the `github-company`
alias you created in §0.5.5 — plain `git clone https://github.com/…`
would prompt for credentials a fresh machine doesn't have.

```sh
# Clone via the company SSH alias. The path becomes SWARM_HOME.
mkdir -p ~/qofirepos
cd ~/qofirepos
git clone git@github-company:qofiandrew/qofi-claude-engineering.git
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

### 3.2 Register `qofi-swarm` as a Claude Code marketplace (directory source)  `[M]`

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

### 3.3 Install the `discord-b2b` plugin  `[M]`

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

For a **brand-new** swarm you do not create this file by hand —
`swarm-add.sh` Phase 3 captures each bot token via a **silent prompt**
(no terminal echo, no scrollback, no command-line argument). Never paste
a bot token onto a command line or into chat — once it shows in
scrollback or history, treat it as leaked and rotate.

**ANTHROPIC_API_KEY** must not live in `tokens.env` or anywhere the
lead's shell sources — `swarm-up.sh` explicitly `unset`s it (line 74)
so leads run on your **Max** pool, not metered API. The example file
`tokens.env.example` includes this warning.

### 4.1 Migrating existing secrets to the new Mac  `[M]`  `[VERIFY ON SETUP]`

On a fresh machine you're re-standing-up **existing** swarms
(`BOT_RESERVE_BACKEND_2`, `BOT_QOFI_IOS_APP`). Get their tokens onto the
new Mac by **one** of these — never via the repo, chat, email, or
terminal scrollback:

- **Option A — re-mint (rotates; cleanest if decommissioning the old Mac).**
  On the new Mac run `swarm-add <name> <repo> --skip-walkthrough` per
  swarm; in the Discord Developer Portal hit **Reset Token** for each
  bot and paste the new value into `swarm-add`'s silent prompt.
  *Pro:* no secret ever leaves a device; old tokens are invalidated.
  *Con:* resetting a token **immediately kills that bot on the old Mac** —
  only do this when you're cutting over for good.

- **Option B — secure direct transfer (keeps both Macs working).**
  **AirDrop** `tokens.env` Mac→Mac (peer-to-peer, no cloud), or move it
  via a password manager / `scp` over SSH. Then on the new Mac:
  ```sh
  chmod 600 "$SWARM_HOME/tokens.env"
  git -C "$SWARM_HOME" status --short tokens.env   # MUST print nothing (gitignored)
  ```

While migrating, **prune the stale `BOT_TEST_ERPO`** line — it's a
leftover test bot, not a live swarm.

### 4.2 iOS-widget status feed — `SWARM_STATUS_SECRET` / `SWARM_STATUS_ENDPOINT`  `[M]`

`qofi-ios-app`'s status widget is fed by `swarm-watch.sh`, which POSTs
`$STATE_DIR/status.json` to an ingest endpoint when **both** of these are
set in `tokens.env` (documented in `tokens.env.example:13-28`):

```sh
export SWARM_STATUS_ENDPOINT="https://swarm-status.up.railway.app/ingest"
export SWARM_STATUS_SECRET="..."
```

Both required: endpoint-without-secret allows spoofed POSTs;
secret-without-endpoint has nowhere to send. If either is unset, the local
`status.json` is still written but no network call is made.

**`SWARM_STATUS_SECRET` cannot be re-minted unilaterally** — it must match
what the ingest endpoint expects. **Transfer it** (Option B above), or
rotate it on **both** the Mac and the server together. Treat it as
bot-token-tier: `chmod 600`, never on a command line, never in chat.

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
  plugin:discord-b2b@qofi-swarm` (see `bin/swarm-up.sh:37` and
  `bin/swarm-up.sh:77`). The `--dangerously-load-development-channels`
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

### 6.1 Edit the plists — they hard-code paths  `[M→S]`

launchd doesn't read your shell profile, so the plists use **absolute
paths**. Critically, **both plists hard-code `/Users/aschettino` in 6+
places each** — the script path, `SWARM_HOME`, `CLAUDE_PROJECTS_DIR`,
`SWARM_STATE_DIR`, and both log paths — plus `SWARM_TMUX_BIN`.

> **Simplest option: name the mini's macOS account `aschettino`.** If the
> new Mac's username is `aschettino`, every hard-coded path resolves
> as-shipped and you edit **nothing** here except (on Intel) the tmux
> path. Worth deciding deliberately at OS-install time — it makes this
> whole step a no-op.

If the username **differs**, substitute it in both plists before
symlinking:

```sh
sed -i '' "s#/Users/aschettino#$HOME#g" "$SWARM_HOME"/launchd/*.plist
```

Then confirm the remaining values:

```sh
grep -nE 'SWARM_HOME|CLAUDE_PROJECTS_DIR|SWARM_TMUX_BIN|StandardOut|StandardError|swarm-(watch|typing).sh' \
  "$SWARM_HOME"/launchd/*.plist
```

- `SWARM_TMUX_BIN` must match `which tmux` — `/opt/homebrew/bin/tmux` on
  Apple Silicon, `/usr/local/bin/tmux` on Intel. (The `sed` above only
  fixes the username, not the Homebrew prefix; on Intel, change the tmux
  path by hand.)

### 6.2 Make the log/state dir  `[S]`

```sh
mkdir -p ~/.config/swarm ~/Library/LaunchAgents
```

### 6.3 Symlink the plists into `~/Library/LaunchAgents/`  `[S]`

```sh
ln -sf "$SWARM_HOME/launchd/com.qofi.swarm-watch.plist"  ~/Library/LaunchAgents/
ln -sf "$SWARM_HOME/launchd/com.qofi.swarm-typing.plist" ~/Library/LaunchAgents/
```

### 6.4 Load  `[S]`

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

## 7. Aliases — source `bin/swarm-aliases.sh`  `[S]`

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

## 8. Your first swarm  `[M]`

Two entry points. Pick by what the target repo already has — the
README §4 covers the choice in depth; this is the minimum to land your
first swarm.

| Use this | When |
| --- | --- |
| `bin/swarm-new.sh <name>` | **brand-new** swarm with no repo yet. Creates the local repo at `~/qofirepos/<name>`, the GitHub repo under `qofiandrew` (via the `github-company` alias), pushes the initial commit, then execs `swarm-add` for the Discord half. |
| `bin/swarm-add.sh <name> <repo>` | **existing local** repo. Walks the Discord portal interactively (§4 in this doc, abbreviated) and runs `swarm-init` against the repo for you. |
| `bin/swarm-onboard.sh <repo>` then `bin/swarm-add.sh <name> <repo> --skip-walkthrough` | **existing real codebase** you want to onboard. Onboard stamps the doctrine + hooks with collision-refuse-and-report semantics; then swarm-add wires up the Discord side. |

For your **very first** standup, use `swarm-add` (or `swarm-new` if the
repo doesn't exist yet) — the interactive Phase 1 walkthrough covers §4
of this doc end-to-end and pauses between steps. Re-cloning an existing
product repo first? `git clone git@github-company:qofiandrew/<name>.git`
into `~/qofirepos/`, then `swarm-add <name> ~/qofirepos/<name>`.

```sh
bin/swarm-add.sh mythirdswarm ~/qofirepos/mythirdswarm
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

- **Wrong `gh` account (two accounts exist).** `swarm-new` refuses if
  `gh api user --jq .login` isn't `qofiandrew`. Fix with
  `gh auth switch -u qofiandrew`. See §0.5.4.
- **`github-company` alias missing.** Without the `~/.ssh/config` block
  from §0.5.5, the §2 clone and `swarm-new`'s push fail (or silently
  route through plain github.com). `ssh -T git@github-company` must
  greet you as `qofiandrew`.
- **CLT shims.** On a fresh Mac `git`/`python3` pop an install dialog
  until `xcode-select --install` completes (§0.5.1). "Command not found"
  or a GUI prompt here means CLT isn't done.
- **`SWARM_HOME` unset or wrong.** Every `bin/swarm-*.sh` fails loud
  with a remediation line if the env var doesn't point at this repo
  (the templates dir is the canary). Set it in `~/.zshrc`; sourcing
  `swarm-aliases.sh` self-locates it as belt-and-suspenders.
- **`enabledPlugins` set to `false` (or missing).** The bot connects to
  Discord but the bridge MCP never spawns; every Discord tool call
  fails silently. `swarm-add` Phase 5 is the canonical detect-and-fix.
  See `bin/swarm-add.sh:463-548`.
- **Plist username/path drift.** The plists hard-code `/Users/aschettino`
  and `/opt/homebrew/bin/tmux`. Different username → `sed` substitution
  in §6.1 (or name the account `aschettino`). Intel → fix the tmux path.
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
