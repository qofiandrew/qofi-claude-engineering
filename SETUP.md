# SETUP.md — fresh-machine standup

Sibling to `README.md`. The README is **how the system works**; this is
**how to get the system running on a new macOS machine from bare metal**.
Read this first, sequentially. Once you have a heartbeat in Discord and a
swarm responding to `@mention`, switch to the README.

Approximate time: **45–90 minutes** on a truly fresh Mac — most of the
new friction is the identity/toolchain layer (§0.5: `gh` auth, the SSH
alias, Xcode CLT download) plus the selected Claude login (§1) or dedicated Codex runtime login (§5) and the
Discord-portal clicking (§4/§8). §2 and §6–§7 are mechanical.

Marker conventions:
- `[VERIFY ON SETUP]` flags a step that can't be confirmed from the repo
  alone — an external service (Discord/GitHub portal) or an interactive
  UI action (agent CLI login, `gh auth`).
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

## 0.1. STOP — two "think you're done when you're not" traps

These were the **#1 and #2 time-sinks on this mini's first standup**.
Both produce a swarm that looks healthy in Discord and does nothing. Read
them now; they reframe what "done" means in §8 and §9.

### Trap A — `swarm-up` ≠ `swarm-add`

They are NOT interchangeable. `swarm-up` **launches** the row's selected
engine in tmux: Claude's native TUI/plugin path or the hardened Codex Discord
daemon. `swarm-add` **configures** doctrine plus the selected engine's ACL,
runtime, and policy surfaces (including Claude's enabled plugin or Codex's
dedicated workspace verification). A swarm that's been `up`-ed but never `add`-ed
shows the bot **online** in Discord and **ignores every message** —
because the bridge MCP never spawns (Trap C / §3.4) and the ACL has no
group for the channel (§3.5). This was the single biggest time-sink
today: three silent half-launches before the gates in `swarm-up.sh`
existed. **Per swarm, run `swarm-add` once even if `swarm-up` already
brought it online.** (§8 enforces this; the new `swarm-up` preflight
gates §0.1.4 below now hard-refuse without it.)

### Trap B — `requireMention: false` (the bot listens to everything)

The default bridge ACL sets `requireMention: false` on every per-channel
group (`bin/swarm-add.sh` Phase 4d), so the bot processes **every** message
in the channel — no `@`-mention required. Reach is still gated by
`allowFrom` (only listed senders trigger it) and by Discord's shared-server
requirement, but within those bounds the agent acts on all ambient chatter.
If you want the lead to stay quiet until explicitly addressed, set
`requireMention: true` in `~/.claude/channels/discord/access.json` under
`groups.<channel-id>.requireMention` (re-read on every message, no restart),
or pass `--require-mention` to `/discord:access group add`.

### Trap C — preflight gates in `swarm-up`

`swarm-up.sh launch_one()` now hard-refuses (exit 1) before launching if
the swarm isn't fully configured: missing `enabledPlugins`, missing
`access.json` group for the channel, missing doctrine
(`CLAUDE.md`/`ESCALATION.md`/`TEAM_LEAD.md`), or missing
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the repo's
`.claude/settings.json` `env` block (without that flag Agent Teams
silently disables and the lead can never spawn teammates). The
remediation it prints is always the same: `bin/swarm-add.sh <name>
<repo> --skip-walkthrough`. The "I know what I'm doing" bypass is
`SWARM_UP_SKIP_SANITY=1`. These gates exist specifically to turn
today's silent half-launches into loud refusals.

For `engine=codex`, the equivalent preflight is different and cannot be
silently bypassed: root attestation/source hashes, hidden-account ChatGPT auth,
workspace journal/inode, project config, managed Codex surfaces, canonical ACL,
toolchain, and daemon quiescence must all pass. Claude plugin/Agent Teams gates
are intentionally not imposed on the Codex daemon.

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
| **bun 1.3+** | both Discord adapters are Bun projects; committed lockfiles make first launch reproducible | `curl -fsSL https://bun.sh/install \| bash` `[S]` |
| **Claude Code v2.1.32+** | required for `engine=claude`; needs the dev-channels flag and marketplace plugin. Managed Codex's Fable reviewer was audited on 2.1.207 and requires an installed CLI accepting `claude-fable-5`. | https://claude.com/claude-code `[M]` |
| **Codex CLI `>=0.144.1,<0.145.0`** | required for `engine=codex`; this audited window pins the App Server/remote-TUI protocol, permission profiles, and ambient-feature disables; later minors fail closed pending review | https://developers.openai.com/codex/cli `[M]` |
| **python3** | manifest walker, settings merger, dod-affirm hook, permission-gate hook, watcher JSON, reset-time parser | provided by **CLT (§0.5.1)**; `/usr/bin/python3` is an install-prompt shim until then |
| **git** | clone + worktrees + the `git commit`s in swarm-new/onboard/sync | installed via **CLT (§0.5.1)**, configured in **§0.5.3** |
| **gh** | `swarm-new` preflight + GitHub repo creation | installed + authed in **§0.5.4** |
| **`github-company` SSH alias** | the remote form every swarm repo uses | created in **§0.5.5** |
| **curl** | watcher posts directly to Discord REST | ships with macOS |
| **A Discord account + a server you own** | one bot identity per swarm; the bot needs Manage-Messages-equivalent permissions in the channel | n/a |

Not required: `jq` (the system uses `python3` for JSON), GNU coreutils, or
brew bash. A Claude-only host does not need Node for the bridge. A Codex host
does: the supported npm/NVM CLI shape is an attested absolute Node plus
canonical `codex.js`, and the root runtime provisions Node/npm/npx itself.

> **Apple Silicon vs Intel.** The default Homebrew prefix is
> `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel. You don't hand-
> edit anything for this: the launchd installer (§6) fills the tmux path
> from `command -v tmux` at install time, so either architecture just
> works. Verify your tmux with `which tmux`.

### Install + preflight  `[S]`

```sh
brew install tmux
curl -fsSL https://bun.sh/install | bash    # then ensure bun is on PATH in ~/.zshrc
# install Claude Code per https://claude.com/claude-code (native installer)
# install Codex only if this host will run engine=codex rows
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
  echo "codex:     $(codex --version 2>/dev/null || echo MISSING)"
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

For a host that will run Codex rows, verify only the install/version here:

```sh
codex --version
# required audited line: codex-cli 0.144.x, with patch >= 0.144.1
```

Do not use the current user's `codex login status` as the unattended proof. The
production bridge runs under a distinct hidden account and provisions that
account's ChatGPT login after `$SWARM_HOME` is cloned (§5). Claude and Codex
subscription state are independent; a Claude account label in field 6 is ignored
for a Codex row before Claude-only account preflight runs.

---

## 1.5. PRODUCT-TIER dependencies (conditional — NOT swarm-system prereqs)

> These are product-tier additions, not extra Claude-only host prerequisites.
> Docker is never required by orchestration. Node is already mandatory and
> root-provisioned on Codex hosts; install a separate operator Node only when a
> **Claude-built product repo** needs it.
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
- **Operator Node** `[M]` — `brew install node` only if a Claude product repo's
  test-gate runs node (`templates/engineering-cto/hooks/permission-gate.sh` whitelists
  `node --test` / `npm test` for product gates). This is separate from the
  root-owned Node/npm/npx installed for the dedicated Codex runtime.

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
ls "$SWARM_HOME/templates/engineering-cto/manifest.tsv"  # exists (default archetype)
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

### 3.0 STOP — do §3.2 + §3.3 BEFORE §8

`/plugin marketplace add` (§3.2) and `/plugin install discord-b2b@qofi-swarm`
(§3.3) are run **inside a `claude` session** — not in the terminal. In
a fast standup it's easy to scroll past, run the §8 swarm-add, and
launch a swarm whose lead never has the bridge plugin available. The
bot will show **online** in Discord and every Discord tool call from
the lead will fail silently — exactly the failure mode of §3.4. There
is no second chance: once a swarm is `swarm-up`-ed without the plugin
installed for the user, the only fix is to install the plugin from
inside any claude session and then `swarm-restart` the swarm.

**Confirm the plugin is installed before reaching §8.** One-liner:

```sh
python3 -c 'import json,os;p=os.path.expanduser("~/.claude/plugins/installed_plugins.json");print("OK" if "discord-b2b@qofi-swarm" in json.load(open(p)).get("plugins",{}) else "MISSING — do §3.3 first")' 2>/dev/null || echo "MISSING — do §3.2 + §3.3 first"
```

If that prints anything other than `OK`, **stop and complete §3.2 +
§3.3 before going further**.

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
--frozen-lockfile --no-summary && bun server.ts"`), so the first cold start is a few
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
  "loginControlOwnerId": "<your-discord-user-id>",
  "allowFrom": ["<your-discord-user-id>"],
  "groups": {
    "<channel-id>": { "requireMention": false, "allowFrom": ["<your-id>"] }
  },
  "pending": {}
}
```

**You do not pre-create this file.** `swarm-add.sh` Phase 4d
(`bin/swarm-add.sh:436-461`) creates it on first standup with sensible
defaults (`dmPolicy: "pairing"`, your owner ID in `allowFrom`), and
appends a per-channel group entry on every subsequent `swarm-add`.

Before the first standup, export the operator identity explicitly (numeric
Discord user ID, not a bot/application ID):

```sh
export SWARM_OWNER_DISCORD_ID='<your-discord-user-id>'
```

Phase 4d pins this ID as `loginControlOwnerId`, puts it in top-level
`allowFrom` and the channel group, then
writes the file mode `0600`. Top-level membership is deliberately narrower
than ordinary group membership: it authorizes Codex's constrained `!qofi-git`
broker. Never substitute the CTO watcher bot ID or infer an operator from a
channel group. A safe re-run migrates an owned historical `0644` file to
`0600`; `swarm-doctor` fails if the mode or explicit principal is wrong.

For `--type cpo`, Phase 4d also creates the `SWARM_BUS_CHANNEL` group with the
operator and `CTO_BUS_WATCHER_BOT_ID`. The watcher remains a bus sender only;
it is not added to top-level `allowFrom` and cannot authorize Git actions.

> **`requireMention: false` — listens to the whole channel.** Each
> per-channel group is created with `requireMention: false`, so the bot
> processes **every** message in the channel without an `@`-mention.
> Reach is still bounded by `allowFrom` (only listed senders trigger it)
> and Discord's shared-server requirement. If you want the lead to stay
> quiet until explicitly addressed, edit the group entry in
> `~/.claude/channels/discord/access.json` and set
> `requireMention: true`; the bridge re-reads the file at message
> dispatch time, no restart needed.

You will need **your Discord user ID** for `SWARM_OWNER_DISCORD_ID`: in Discord,
User Settings → Advanced → enable Developer Mode, then right-click your own name
and "Copy User ID". `[VERIFY ON SETUP]`

---

## 4. Secrets — `tokens.env` from a vault

**The model.** Bot tokens live in a **secrets vault** — the durable source
of truth, provisionable to any number of machines. `tokens.env` is a
**per-machine, least-privilege derivative**: it holds exactly the tokens
for the swarms *this* machine runs, and nothing else. You don't hand-author
it and you don't transfer it between Macs — you **regenerate it from the
vault** on each machine. That makes `tokens.env` disposable; anything that
must survive a machine belongs in the vault, not here.

**Location**: `$SWARM_HOME/tokens.env`. **Format**: one `export
BOT_<NAME>="..."` line per swarm. **Permissions**: `chmod 600` (the
provisioner enforces this). **Gitignored**: yes (`.gitignore:2`);
`swarm-add` *and* the provisioner exit fatal if it's ever git-tracked
(`bin/swarm-add.sh:386-394`).

**1Password is the durable store; you are the manual conduit.** The default
provisioning flow needs **no `op` CLI**: the script walks this machine's
`swarm.conf` and shows a **silent prompt** for each token — you copy it from
1Password and paste it (hidden, never echoed, never in scrollback, never on a
command line). 1Password stays the source of truth across every machine; you
just relay each machine's subset by hand. (An optional unattended path for
power users is noted in §4.2.)

**ANTHROPIC_API_KEY** must never be in `tokens.env` or anywhere the lead's
shell sources — `swarm-up.sh` explicitly `unset`s it (line 74) so leads run
on your **Max** pool, not metered API.

### 4.1 Store each bot token in the vault (once per bot)  `[M]`

A token first **enters** the system through `swarm-add.sh` Phase 3's
**silent prompt** (no echo, no scrollback, no command-line arg) when you
mint a brand-new bot. Immediately also **save that token to the vault**
under the name `BOT_<NAME>` (matching the `TOKEN_VAR_NAME` column in
`swarm.conf`). The vault is the durable backing store; `swarm-add` is just
the first entry point. Never paste a token into chat or a command line —
once it's in scrollback or history, treat it as leaked and rotate.

For this fleet that means vault items: `BOT_RESERVE_BACKEND_2`,
`BOT_QOFI_IOS_APP`, plus the shared `SWARM_STATUS_SECRET` /
`SWARM_STATUS_ENDPOINT` (§4.3).

### 4.2 Provision THIS machine's tokens  `[M]`

`bin/swarm-provision-tokens.sh` walks **this machine's** `swarm.conf` and, for
each swarm's `TOKEN_VAR_NAME`, shows a **silent prompt**. Copy that secret
from 1Password, paste, press Enter — nothing is echoed. It writes a
`chmod 600` `tokens.env` containing exactly that subset, **atomically** (an
empty or aborted paste leaves any existing `tokens.env` untouched) and never
echoes a value.

```sh
"$SWARM_HOME/bin/swarm-provision-tokens.sh" --status   # prompts for each bot
                                                       # token + the shared §4.3 secret
# preview which vars it will ask for, without prompting or writing:
"$SWARM_HOME/bin/swarm-provision-tokens.sh" --dry-run
```

The subset is driven by `swarm.conf`, so a token is only requested if a swarm
row references it — the stale `BOT_TEST_ERPO` from the old machine simply
**isn't prompted for** (no row, no token). Verify:

```sh
ls -l "$SWARM_HOME/tokens.env"                          # -rw------- (600)
git -C "$SWARM_HOME" status --short tokens.env          # MUST print nothing (gitignored)
```

> **Optional — unattended automation (power user).** Set `SWARM_VAULT_FETCH`
> to a `{}`-templated fetch command and the script fetches non-interactively
> instead of prompting — e.g. with the 1Password CLI:
> `export SWARM_VAULT_FETCH='op read op://Swarm/{}/credential'`. Unset (the
> default), you get the manual paste flow above. Either way the same
> safeguards apply: `chmod 600`, atomic, git-tracked refusal, no value echoed.

### 4.3 iOS-widget status feed — `SWARM_STATUS_SECRET` / `SWARM_STATUS_ENDPOINT`  `[M]`

`qofi-ios-app`'s status widget is fed by `swarm-watch.sh`, which POSTs
`$STATE_DIR/status.json` to an ingest endpoint when **both** of these are
set in `tokens.env` (documented in `tokens.env.example:13-28`):

```sh
export SWARM_STATUS_ENDPOINT="https://swarm-status.up.railway.app/ingest"
export SWARM_STATUS_SECRET="..."
```

These are **shared, not per-swarm**: the *same* secret goes on every machine
that posts the feed, and it must **match what the ingest endpoint expects**.
So it's not re-mintable per machine — keep it in 1Password and provision it
with `--status` (above), which prompts you to paste it, and when you rotate
it, rotate it on **both** the machines and the server together. Both required: endpoint without
secret allows spoofed POSTs; secret without endpoint has nowhere to send. If
either is unset, the local `status.json` is still written but no POST is made.

### 4.4 Sharding across multiple minis  `[design — read before n=2]`

> **Today (n=1): one mini runs ALL swarms.** It holds every token, every
> `swarm.conf` row matches a local token, and there are **zero
> skip-warnings**. The shared committed `swarm.conf` + "tokens are the
> boundary" model is **trivially correct at n=1** — nothing to build this
> afternoon.
>
> **At n≥2 this needs revisiting — a known PRE-`n=2` DESIGN TASK, not built
> now.** When swarms are split across minis, the current setup leans on an
> *implicit* boundary: a machine acts on a `swarm.conf` row only if it
> happens to hold that row's token (`swarm-watch.sh:325` skips un-tokened
> rows). That has two problems at scale: (a) every mini's `watch.err` fills
> with skip-warnings for the swarms it *doesn't* run, and (b) there's no
> **explicit, reviewable record of the shard layout** — which mini owns
> which swarms. Before the second mini lands, design an **explicit
> per-machine swarm-assignment mechanism** (e.g. a per-host `swarm.conf`, or
> a host→swarms map the watcher/provisioner both read) so assignment is
> declared, not inferred from "whichever tokens happen to be here." The
> vault + per-machine `tokens.env` subset (§4.2) is already the right
> secrets primitive for that future — it's only the *assignment record*
> that's missing.

### How to get a Discord bot token  `[VERIFY ON SETUP]`

`swarm-add.sh` Phase 1 walks you through this interactively the first
time you stand up a swarm. The abbreviated version, for reference:

1. **Create the application** at https://discord.com/developers/applications
   → "New Application" → name it `<repo>-bot` (convention).
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

## 5. Engine bridges

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

For `engine=codex`, no Claude marketplace/plugin setup is used. The host launches
`codex-bridge/daemon.ts`, reconciles the channel owner ACL into the swarm's
isolated `~/.codex/channels/discord-<name>/`, and installs dependencies with
`bun install --frozen-lockfile`. See [`docs/CODEX.md`](docs/CODEX.md) for the
runtime state, access CLI, root-attested global App Server manager, native tmux
view, and persisted fallback boundary.

### 5.2 Dedicated Codex runtime (Codex hosts only) `[S]`

The unattended bridge must not run Codex as the logged-in operator: macOS
Keychain/securityd and launchd IPC are broader than a filesystem sandbox. Create
the root-attested hidden runtime once, including its fixed global App Server
manager launcher/bundle, store its own ChatGPT subscription login, then refresh
the operator's group credentials:

```sh
if [ ! -e "$HOME/.codex" ]; then (umask 077; mkdir "$HOME/.codex"); fi
[ ! -L "$HOME/.codex" ] || { echo "refusing symlinked ~/.codex" >&2; exit 1; }
chmod -N "$HOME/.codex" 2>/dev/null || true
chmod 700 "$HOME/.codex"   # operator event/ACL/session state, not provider auth

# Only for a repo declaring packageManager "pnpm@9.12.3": populate the
# operator-trusted cache without sudo. The installer copies it and never runs
# Corepack or package scripts as root.
corepack pnpm@9.12.3 --version

"$SWARM_HOME/bin/swarm-codex-runtime.sh" install \
  --repo /absolute/path/to/first-codex-repo
"$SWARM_HOME/bin/swarm-codex-runtime.sh" login
```

The install intentionally does not copy `$HOME/.codex/auth.json`; until the
second command completes, the host is installed but not login-ready and
`verify` exits with the exact login remediation. Keep the `login` terminal open
while using the browser. A localhost callback may finish automatically; if the
provider presents a paste-back flow, paste the value into that same terminal
only, never into Discord or a swarm message.

macOS may initialize an opaque runtime-owned `Library/Keychains/<platform-id>`
subtree even with an empty search list. Qofi never enumerates or deletes it; it
validates the directory boundary, proves the hidden search list empty before
and after login, and pins Codex to the hardened file credential store. If an
older fixed helper reports that this directory must be empty, refresh only the
fixed lifecycle and resume the ordinary install:

```sh
"$SWARM_HOME/bin/swarm-codex-runtime.sh" refresh-lifecycle
"$SWARM_HOME/bin/swarm-codex-runtime.sh" install \
  --repo /absolute/path/to/first-codex-repo
```

The hidden launchd domain may also retain one Apple
`/usr/sbin/distnoted agent`. This is not a Codex child. Qofi exempts only the
exact stable PID-1/session-0 SIP process; every other hidden-UID process must be
quiesced. If the installed runner predates that rule, use the same
`refresh-lifecycle` then `install` sequence above before launching a swarm.

Log out of macOS and back in, then restart every tmux server/session that will
launch swarms. This is required because already-running processes do not acquire
a newly assigned supplemental group. Verify from the refreshed shell:

```sh
"$SWARM_HOME/bin/swarm-codex-runtime.sh" verify \
  --repo /absolute/path/to/first-codex-repo
```

For quota-aware per-swarm rotation, initialize every named profile before adding
it to `codex-profiles.json`, then select its ordered pool in field 8:

```sh
"$SWARM_HOME/bin/swarm-codex-runtime.sh" login --profile max_b
"$SWARM_HOME/bin/swarm-codex-runtime.sh" verify --profile max_b \
  --repo /absolute/path/to/first-codex-repo

"$SWARM_HOME/bin/swarm-add.sh" <name> <repo> --engine codex \
  --codex-auth-pool rotating
```

`default` uses the hidden account's `.codex`; named handles use complete,
separate `.codex-profiles/<handle>` homes. Registry and Discord state contain
profile labels and sanitized quota/reset metadata only—never auth or callback
values. Claude's field-6 account and device-global rotation are unaffected.

**PASS:** verification reports the exact v2 account/group/runner/toolchain/auth
contract and `Logged in using ChatGPT`; it must not accept an API-key session or
the operator's own `~/.codex/auth.json`. For another Codex target, registration
prepares and verifies the workspace before committing its row; the direct form is:

```sh
"$SWARM_HOME/bin/swarm-codex-runtime.sh" prepare-workspace \
  --repo /absolute/path/to/other-repo
"$SWARM_HOME/bin/swarm-codex-runtime.sh" verify \
  --repo /absolute/path/to/other-repo
```

The current root toolchain baseline is Node, Bun, npm, and npx plus audited
root-controlled system tools. An exactly pinned `pnpm@9.12.3` project gains the
audited global pnpm package/direct-Node wrapper; that singleton is preserved by
later npm-only installs, while other pnpm versions fail closed. A product
requiring any other user-owned Homebrew/NVM tool outside the boundary is refused
until it is explicitly provisioned; Claude's toolchain remains unchanged.

A successful runtime install starts and attests the one global manager in the
persistent `qofi-codex-app-server-manager` tmux session through the fixed root
launcher; `swarm-up` also ensures it is ready before launching any Codex row.
Later rows share that manager and receive separate owner-only,
protocol-filtering facade sockets; they do not start per-repo App Servers.
`bin/swarm-codex-manager.sh status` reports its health. Root runtime lifecycle
commands drain, resume, or replace it automatically.

---

## 6. launchd agents — heartbeat watcher + typing pinger

Two `launchd` agents under `launchd/` supervise the always-on stack.
They share `$SWARM_HOME/swarm.conf` and post per-channel heartbeats
using each swarm's own bot token from `tokens.env`. They do **not**
depend on a logged-in shell — they run from system boot.

### 6.1 Generate + install the agents  `[S]`

launchd does **not** expand `$VARS` or `~` in plist path strings — every
path must be an absolute literal. So the repo commits the agents as
**templates** (`launchd/*.plist.template`) with `@@SWARM_HOME@@` /
`@@HOME@@` / `@@TMUX_BIN@@` placeholders, and `bin/swarm-launchd-install.sh`
renders them **per machine** at install time. The repo carries **zero**
hardcoded `/Users/<name>` paths — username- and host-agnostic by
construction, so every mini in the fleet just renders its own.

```sh
"$SWARM_HOME/bin/swarm-launchd-install.sh"
```

That one command:
- substitutes `$SWARM_HOME`, `$HOME`, and `$(command -v tmux)` into both
  templates (so **Apple Silicon vs Intel tmux is automatic** — no manual
  path edit),
- writes real plists to `~/Library/LaunchAgents/com.qofi.*.plist`,
- creates `~/.config/swarm` for the logs,
- validates each rendered plist (`plutil -lint`) and refuses to load a
  malformed one,
- `bootout`s any previous copy and `bootstrap`s the fresh one (falling back
  to `launchctl load -w` on older macOS).

It's idempotent — **re-run it** after editing a template or moving
`$SWARM_HOME`, and it re-renders + reloads. No symlinks, no hand-editing,
no username decision.

### 6.2 Verify  `[S]`

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

> **`swarm-add` is NON-OPTIONAL per swarm — even if `swarm-up` already
> launched a session for it.** `swarm-up.sh launch_one()` only starts the
> configured Claude TUI or Codex daemon; **only `swarm-add`** does Phase 4d
> (`access.json` group), Phase 4c (doctrine stamp), and Phase 5
> (`enabledPlugins["discord-b2b@qofi-swarm"]=true` in the repo's
> `.claude/settings.json`). A swarm that's been `up`-ed but never
> `add`-ed shows the bot online and ignores every message. The
> preflight gates in `swarm-up.sh` (§0.1.4) now hard-refuse this case
> with the exact remediation: `bin/swarm-add.sh <name> <repo>
> --skip-walkthrough`. Run it once per swarm, the first time, no matter
> which entry point initially created the session.

Two entry points. Pick by what the target repo already has — the
README §4 covers the choice in depth; this is the minimum to land your
first swarm.

| Use this | When |
| --- | --- |
| `bin/swarm-new.sh <name>` | **brand-new** swarm with no repo yet. Creates the local repo at `~/qofirepos/<name>`, the GitHub repo under `qofiandrew` (via the `github-company` alias), pushes the initial commit, then execs `swarm-add` for the Discord half. |
| `bin/swarm-add.sh <name> <repo> [--engine claude\|codex]` | **existing local** repo. Walks the Discord portal, writes the engine-aware row, and runs `swarm-init`. Codex additionally prepares/verifies its dedicated workspace before commit; Claude keeps the historical default row/path. |
| `bin/swarm-onboard.sh <repo> --engine <engine>` then `bin/swarm-add.sh <name> <repo> --engine <engine> --skip-walkthrough` | **existing real codebase** you want to onboard. Use the same explicit engine in both commands: onboard stamps doctrine plus that engine's repository surfaces, then swarm-add wires and verifies the selected runtime. `claude` remains the default when the flag is omitted. |

For your **very first** standup, use `swarm-add` (or `swarm-new` if the
repo doesn't exist yet) — the interactive Phase 1 walkthrough covers §4
of this doc end-to-end and pauses between steps. Re-cloning an existing
product repo first? `git clone git@github-company:qofiandrew/<name>.git`
into `~/qofirepos/`, then `swarm-add <name> ~/qofirepos/<name>`.

```sh
bin/swarm-add.sh mythirdswarm ~/qofirepos/mythirdswarm
# or: bin/swarm-add.sh mythirdswarm ~/qofirepos/mythirdswarm --engine codex
```

You'll be prompted for:

- The **channel ID** (Discord Developer Mode → right-click channel →
  Copy Channel ID).
- The **bot token** (silent prompt; never echoed).

The owner ID is not an interactive prompt: export and verify
`SWARM_OWNER_DISCORD_ID` as shown in §3.5 before running this command.

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
| 4 | `bin/swarm-attach.sh <name>` for either engine (`bin/swarm-view.sh <name>` is the explicit Codex-only form) | Claude renders its native TUI. After the configured Discord channel has a persisted thread, Codex prints `NATIVE CODEX TUI` and opens that thread through the read-only facade. Before the first accepted channel turn—or if a proof is unavailable—it explicitly opens `FALLBACK EVENT/STATUS VIEW`. |
| 5 | watch the engine view | Claude shows its normal launch/brief. Codex's native UI shows the persisted configured-channel conversation and filtered live updates without granting input; its fallback reports fresh runtime/gateway/queue/turn state without exposing prompts or tokens. |
| 6 | Discord member sidebar in your server | the bot status flips **online** |
| 7 | `@mention` the bot in #<channel> | the lead replies or reacts within seconds |
| 8 | wait up to 10s, look in #<channel> | a heartbeat message lands (and is **pinned**) showing `🟢 swarm ready · waiting for input · <name>` or similar |
| 9 | `tail -F ~/.config/swarm/watch.log` (or `swarm-watch-log`) | no `ERROR:` / no `FATAL:` lines; tick output runs every 10s |

If step 7 fails for Claude (bot online but silent), §3.4 is wrong for this repo;
re-run `swarm-add --skip-walkthrough`. For Codex, run `swarm-view.sh <name>` and
inspect `last_error`, then verify the bound group's nonempty `allowFrom` and run
`bin/swarm-codex-runtime.sh verify --repo <absolute-repo>`; Codex launch fails closed instead of silently opening an
unconfigured channel.

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
- **launchd plists are generated, not committed.** The repo ships
  `launchd/*.plist.template`; `bin/swarm-launchd-install.sh` renders the
  real plists per machine (§6.1). If you edit a template or move
  `$SWARM_HOME`, **re-run the installer** to re-render + reload. Never
  hand-edit or commit a rendered `~/Library/LaunchAgents/com.qofi.*.plist`.
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
- **Claude TUI: `tmux Ctrl-C` kills `claude`.** Inside a Claude swarm session: `Ctrl-b d`
  to detach (lead keeps running); `Esc` to interrupt a turn in flight.
  **Never `Ctrl-C`** — that kills the `claude` process, which closes
  the pane, which kills the tmux session, which (because §6's watcher
  predicates need the session) flips the heartbeat to `⚪ down`.
- **Codex view is read-only.** `swarm-attach.sh <name>` engine-dispatches to
  `swarm-view.sh <name>`, which normally opens the native
  Codex TUI for the configured channel thread, but its tmux client and per-swarm
  protocol facade reject all input/mutations. If runtime, endpoint, toolchain, or
  thread attestation is incomplete, it opens the explicitly labeled persisted
  event/status fallback. Stop or restart Codex through `swarm-up.sh down` /
  `swarm-restart.sh`, never by typing into the daemon or viewer session.
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
- **Branch reality on a fresh-machine clone (multi-branch swarms).**
  A product repo's live work may not be on `main` — `qofi-ios-app` runs
  on `dev`, and on a fresh clone `origin/main` may not exist at all.
  If you `swarm-onboard` (or `swarm-add`) on the freshly-cloned default
  branch without checking, you can stamp doctrine onto a phantom empty
  `main` that nobody else uses. After cloning a product repo, **always
  `git -C <repo> fetch && git -C <repo> branch -a`** to see what's
  actually there; if the swarm runs on `dev` (or a release branch),
  `git -C <repo> checkout dev && git -C <repo> pull` BEFORE stamping.
  This cost time today on `qofi-ios-app` — the doctrine commit landed
  on an unused branch and the swarm read no doctrine on startup.
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
