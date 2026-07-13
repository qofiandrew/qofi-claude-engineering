# codex-bridge — Discord channel for Codex CLI

The Codex counterpart of `../bridge` (the Claude Code Discord plugin). Same
Discord semantics — pairing, allowlists, per-channel opt-in, hard channel
binding, bot-to-bot @mention rules, 2000-char chunking — but a different
integration shape, because Codex CLI has no equivalent of Claude Code's
channels capability (the MCP hook that pushes inbound messages into a live
session).

So instead of an MCP plugin, this is a **standalone daemon** backed by the
host-wide App Server manager:

```
Discord gateway ─▶ gate ─▶ FIFO ─▶ owner-only manager ─▶ hidden-UID App Server
       ▲                                                      │
       └──────── chunked final agent message ◀────────────────┘

native Codex TUI ─▶ per-swarm read-only facade (no upstream mutation path)
```

- One Codex **thread per Discord chat and leased auth profile** (`sessions.json`), started/resumed through
  the manager so conversation context survives both message boundaries and
  daemon/App Server generation restarts. The private schema-versioned LRU is
  capped at 256 entries/128 KiB; successful turns refresh recency and evict
  the oldest mapping deterministically.
- Codex's **final agent message** of each turn is posted back to the chat,
  chunked at ≤2000 chars. A first-turn preamble teaches Codex the contract.
  The sole no-post exception is an exact trusted CPO-bus silence directive
  described below.
- Turns and advisory reviews are **globally serialized** by the App Server
  manager; per-swarm FIFOs and inode-bound repository leases retain their
  narrower ordering and single-writer guarantees. A completed turn revokes
  hidden-UID ACLs, removes staging, snapshots changes, releases the repository
  lease, and acknowledges manager cleanup before any attention relay or
  Discord reply. Lost reservation/cleanup acknowledgements have bounded exact
  replay; unproven expiry blocks and reaps rather than reopening admission.
- Codex's internal `multi_agent` delegation remains intentionally enabled
  inside one supervised App Server turn. The preamble limits parallel
  delegates to read-only investigation or disjoint files and forbids
  overlapping edits; “globally serialized” refers to Discord turns, not to
  internal subagent scheduling.
- Attachments are downloaded to a per-message `<state>/inbox/` subtree only
  after the message owns its daemon FIFO and physical repository lease. The
  staged bytes remain operator-private. Immediately before granting the hidden
  UID any turn-scoped ACL, the daemon acquires the manager's host-global turn
  reservation; it retains that reservation until ACLs and staged paths are
  removed or the reservation is atomically consumed by the active turn lease.
  Attachments are bounded by both per-file and per-message limits and removed
  before the next turn starts (Codex has no lazy `download_attachment` tool).
  The host fetcher accepts only HTTPS Discord `cdn.discordapp.com` /
  `media.discordapp.net` attachment paths, disables automatic redirects, and
  revalidates every redirect target; localhost, private/non-CDN, `file:`, and
  plain-HTTP URLs never reach `fetch`.

## What's intentionally identical to the Claude plugin

- `access.json` format and location semantics, the pairing flow (6-char code,
  1h expiry, resend cap 2, pending cap 3), `approved/<senderId>` confirmation
  protocol, `DISCORD_ACCESS_MODE=static`, `DISCORD_BOUND_CHANNEL` binding,
  delivery config (`ackReaction`, `replyToMode`, `textChunkLimit`,
  `chunkMode`, `mentionPatterns`).
- Bot-to-bot rules: own messages ignored; bot messages ignored unless they
  @mention this bot — so a Codex agent slots into the existing swarm bus and
  cto-watcher routing unchanged.
- The `<channel source="discord" ...>` inbound envelope format.

One deliberate hardening difference: a Codex guild group with an empty
`allowFrom` is denied. The file shape remains shared, but this non-interactive
workspace-writing bridge requires explicit sender IDs.

Swarm launches also bind `CODEX_BRIDGE_CANONICAL_ACCESS_FILE` to the
owner-private Claude-side ACL. The daemon freshly parses it for every inbound
message **and again when an accepted queued job begins**, then intersects its
DM/group allowlists with the local state. Local
pairing can add a sender but can never override a canonical revocation;
missing, malformed, symlinked, or permission-loose canonical state fails
closed.

`binding.ts` and `normalize.ts` are imported from `../bridge` directly (both
are pure modules); the gate/chunking logic is ported into `gate.ts`/`chunk.ts`
with tests, keeping the plugin itself untouched and self-contained.

## What's different

| | Claude plugin (`../bridge`) | codex-bridge |
| --- | --- | --- |
| Shape | MCP server inside a live session | standalone daemon driving a root-attested global App Server manager |
| Inbound delivery | `notifications/claude/channel` | prompt envelope per turn |
| Session | the one live Claude session | one Codex thread per chat, resumed |
| Outbound | `reply`/`react`/`edit_message` tools | final agent message auto-posted |
| Permission relay | Discord buttons / `yes <code>` | none — fixed workspace-only permission profile |
| Access admin | `/discord:access` skill | `bun cli.ts …` on the host |

There is no permission relay: managed App Server turns fix approval policy to
`never`. Every turn ignores the operator's normal user config/MCP/plugin
surface and ignores user/project execpolicy rules. The selected isolated
`CODEX_HOME` contains one deterministic, byte-verified MCP registration:
`fable_reviewer.adversarial_review`. No ambient or project MCP server is
admitted. The turn explicitly disables ambient
plugin/app/browser/computer/image/persistence surfaces and passes only a
minimal non-secret environment allowlist. A fixed inline
`qofi-workspace-only` permission profile denies the host filesystem root,
restores Codex's minimal runtime files, allows writes only in the active
workspace, denies network and temp roots, and exposes only the active turn's
attachment directory read-only. It does not use the classic `workspace-write`
sandbox, which is too broad for untrusted Discord input because it can read
host credentials. These controls are pinned to Codex CLI `>=0.144.1,<0.145.0`;
the daemon refuses other versions until their permission semantics are audited.
Manifest-owned doctrine/enforcement (`.claude/`, `.codex/`, `.agents/`, root
doctrine, `.gitleaks.toml`) is read-only, while authored artifacts such as
`PROJECT_SPEC.md`, `LEARNINGS.md`, ADRs, and `docs/` stay writable/committable.

The filesystem profile is not, by itself, a host-secret boundary on macOS:
Keychain/securityd and launchd IPC can remain reachable even when root reads
and network are denied. Therefore the daemon refuses current-user execution.
It accepts only a root-owned fixed `/private/etc/qofi-codex-runtime.json` v2
attestation for a distinct, non-root, credential-clean OS account, a shared
workspace group, and SHA-256-pinned root runner/Node/`codex.js`. The operator's
only manager sudo target is the fixed no-argument
`/usr/local/libexec/qofi-codex-manager-launcher`. That root launcher verifies the
installed manager authority, publishes a root-only admission record, drops the
manager to the operator, and remains its direct parent. Only that admitted
manager can ask `/usr/local/libexec/qofi-codex-runner` to launch the exact
hidden-UID App Server argv; direct operator/daemon invocation is rejected. The
runner cleans hidden-UID payloads before/after a generation, enters the target
bootstrap, drops groups/gid/uid, monitors the manager parent, and launches only
the attested Node/script with a clean env.
Startup uses that exact route and exact pinned permission profile to prove the
runtime uid, absence of the operator launchd canary,
an empty runtime user-Keychain search list, refusal of persistent launchd job
submission, detached-process cleanup, shared-group workspace
create/edit/delete access, and real builds through every detected stack.
There is no current-user fallback for the daemon or workspace execution path.
The Claude contrarian review command is a separate, advisory-only lane. It
prefers the global manager's review endpoint, which first reaps the shared App
Server and then invokes the exact hidden-UID, tool-less root-runner command;
cleanup acknowledgement restores the App Server generation. When no manager
endpoint exists it tries the same dedicated route directly, then may use the
operator's validated ChatGPT login with an empty private cwd, ephemeral storage,
and both shell execution features disabled. Review also pins
`gpt-5.6-sol`/`ultra`, but uses Codex's built-in review mode, whose internal
review session disables Sol's model-level multi-agent delegation. The lane can
review text already supplied on stdin; it cannot become a Codex swarm runtime.

The mirror direction is the terminal Fable reviewer available inside managed
Codex turns. A root-attested one-tool stdio shim accepts only bounded review
text, named context excerpts, and a review mode. It calls headless Claude with
the exact `claude-fable-5` model and no tools, exec, nested MCP, plugins,
persistence, or repository access. Reviewed content is stdin data under a
separate immutable doctrine, so instructions embedded in a diff cannot alter
the reviewer session. The shim cannot invoke Codex; the internal Codex review
lane continues to ignore config and disable MCP, mechanically ending recursion.

The manager derives swarm, profile, task, and artifact location from the active
turn lease rather than accepting those claims from the shim. Per-swarm policy
in `fable-reviewer.json` defaults to device auth, one completion call per task, and twelve
serialized calls per hour. An explicit `anthropic-api-key` override decouples
reviewer quota from the device-global Claude login. Timeout, quota, auth, or
schema failure becomes `review-unavailable`/`review-pending`, never approval.
The durable budget ledger keeps task caps across parked interleavings, exact
scope is re-proved after queue waits, and a crash-surviving supervisor holds the
global review lock until Claude's complete process group is dead. Suspect
credential-bearing output is refused without reflecting it.
Verdicts and the exact reviewed-input SHA-256 land as private
`review-artifacts/<task>/<profile>/` artifacts; hard-limit replay and
same-profile retry consume only the current attempt's profile-scoped delta.
Only a `block` notice with swarm/profile labels reaches Discord. All verdicts
remain advisory and operator ratification remains authoritative.

The installed root toolchain baseline is Node, Bun, npm, and npx, plus the
fixed macOS system PATH. A project that exactly declares `pnpm@9.12.3` also
gets the singleton audited pnpm package copied from the operator's populated
Corepack cache into that root tree and invoked by fixed Node directly; Corepack
is never executed by root or by a turn. Before a workspace launch, the host preflight reads
bounded manifests, lockfiles, and package-script command tokens, then requires
every implied tool to resolve root-controlled from that exact runner PATH. The
runner repeats fixed version probes as the service UID. Missing baseline tools
are repaired by reinstalling the runtime; stacks without a supported root
provisioning route (for example Cargo, Go, uv, yarn, or Deno when absent)
fail explicitly before a turn. After initial group provisioning, the operator
must log out/in and restart tmux so the daemon's live supplementary groups
include the shared runtime group.

Before opening Discord, daemon startup runs `codex --version` and
`codex login status` with the same credential-stripped child environment. It
requires that pinned version window and a positive `Logged in using ChatGPT`
subscription-auth status; API-key auth is not accepted.

`CODEX_BIN` is not trusted merely because it prints those two answers. The
launcher supplies an audited exec plan: the official NVM installation is an
absolute native Node executable plus canonical `codex.js` argv prefix, never
the script's `/usr/bin/env node` shebang. The daemon validates both paths under
owner-controlled host install roots, rejects anything under the workspace,
swarm source, state, or temp directories, and pins the validated toolchain
PATH. The root attestation must name those exact independently resolved paths;
it also pins the dedicated account's private `HOME`, `CODEX_HOME`, `.tmp`, and
`auth.json`. The complete attestation/executable route is revalidated before
every turn. A repo-local fake binary, poisoned `HOME=$REPO`, changed
attestation, or direct-node route therefore fails before launch.

Project `.codex/config.toml` is parsed by the daemon itself with a strict
allowlist of restrictive/display-only keys, in addition to file identity,
ownership, size, and secret checks. Unknown capability-bearing keys fail both
direct daemon startup and the immediate pre-turn identity recheck. The target
workspace must not contain or sit inside the bridge runtime/SWARM_HOME source,
so a turn cannot rewrite code that a later host restart executes.

The state directory is likewise a capability boundary: it and known subdirs
must be canonical, owner-controlled, non-symlink directories (0700); token,
ACL, session, runtime, and event files must be regular non-symlinks (0600).
The daemon sets umask 077. Volatile cache/inbox contents remain opaque beneath
validated 0700 roots because npm/Bun/Python may choose their own internal
modes. The Discord credential comes only from the exact
`<state>/discord-token` owner-regular 0600 file; ambient
`DISCORD_BOT_TOKEN` and state `.env` are not credential fallbacks. Narrow
named-user ACLs give the dedicated runtime search-only access through private
state ancestors, read/execute access to immutable shims, write access to the
one active temp directory, and read access to only that turn's attachments;
sensitive state files receive no ACL. Graceful exit revokes base ACLs and
active directories are deleted. These checks repeat before inbound state
reads.

The production turn PATH is rebuilt from the installed root-owned baseline:
Node, Bun, npm, npx, optional exact pnpm 9.12.3, and fixed macOS system tools. Every executable and parent
chain is non-writable by group/other. A repo `.venv/bin`, operator Homebrew/NVM
directory, or other user-owned tool root is never added. Projects requiring Go,
Cargo/Rust, uv, yarn, Deno, or another stack fail before a turn unless
that stack first gains an explicit audited root-provisioning route. This is an
intentional supported-toolchain boundary, not parity with Claude's ambient
developer PATH. Build/cache outputs stay in the private turn temp.
pnpm's home, content-addressable store, XDG data/state, and cache are likewise
pinned under that temp; project-selected package-manager download/dispatch is
disabled, the exact version is reproved as the service UID, and `pnpx` remains
outside the supported executable surface.

Outbound delivery is capped at 20 Discord messages per turn; larger responses
are visibly truncated, preventing a large model event or tiny configured chunk
size from turning one job into thousands of API calls.

The workspace-only profile intentionally blocks the doctrine's host-side
`swarm-attention.sh` path. For launchers that configure the three attention
binding variables below, a final exact `[[SWARM_ATTENTION_RAISE: reason]]` or
`[[SWARM_ATTENTION_CLEAR]]` line activates a narrow daemon capability. The
line is removed before Discord delivery; the daemon validates the fixed swarm
and numeric channel and atomically creates/removes only that channel's private
flag. It runs no shell, PATH tool, TMUX lookup, or mutable workspace helper.

For CPO launches, the launcher binds an archetype plus distinct operator and
bus channel IDs. The daemon stamps the derived `archetype` and `channel_role`
into each trusted envelope; sender text cannot switch registers. Only on a
trusted CPO bus turn, an exact entire final `[[QOFI_SILENT]]` suppresses the
Discord post with no substitute placeholder, preserving doctrine's silent-on-
STATUS/ACK rule. The same token on the operator channel, an engineering bot,
or alongside visible text is not suppressible.

Command hooks are explicitly disabled for unattended Discord turns. In Codex
CLI 0.144.1 hook commands launch outside the tool filesystem/network sandbox,
so any repo command hook could pierce this bridge's host isolation.
`.codex/hooks.json` is stamped with an empty hook set; separately trusted manual
interactive sessions may use the conservative exec-policy rules, but the bridge
also ignores those. It relies on project instructions, its immutable preamble,
direct test execution, and the OS-enforced permission profile instead.

### Constrained Git broker

The sandbox deliberately makes `.git` read-only: status, diff, and history
work, while `git add`, branch/commit, config writes, and hook writes cannot
mutate repository metadata. Git writes are a separate host capability accepted
only from a sender present in the top-level local and live canonical operator
allowlists, after the normal channel gate, with no attachments and while the
serialized turn queue is completely idle. Control text is never sent to Codex.

The operator first creates one non-protected broker side ref. The canonical
checkout's symbolic HEAD, checked-out branch tip, and real index are not changed:

```text
!qofi-git branch feature/name
```

After one successful Codex turn, the operator may commit a subset of the exact
files whose content/mode/existence changed during that turn to that side ref:

```text
!qofi-git commit {"message":"one line","paths":["src/exact.ts","README.md"]}
```

After the exact side-ref tip is reachable from canonical HEAD, the operator may
clear the broker capability without deleting the historical ref:

```text
!qofi-git retire feature/name
```

Commit paths are normalized, bounded, regular-file-or-explicit-deletion only,
reopened immediately before the transaction, and matched against the latest
turn's before/after hashes. Pre-existing dirt, later edits, symlinks, special
files, secrets, operator-owned paths, protected branches, staged state, and
merge/rebase/cherry-pick/revert/bisect state all refuse. Source changes require
a non-deleted docs change in the same commit. Exactly one broker-owned branch
capability exists at a time. A second branch is refused; retirement succeeds
only after Git proves the exact registered tip is already an ancestor of
canonical HEAD. Unintegrated history is never implicitly retired or deleted.

The broker never runs `add`, `commit`, `checkout`, `switch`, repo hooks,
filters, signing, tests, or a shell. It builds a private index with plumbing,
hashes bytes with `hash-object --no-filters`, creates with `commit-tree`, and
CAS-advances only the registered side ref. It never creates or installs the
canonical checkout's `index.lock`. A v2 private transaction journal detects a
crash around side-ref CAS, validates the exact old/new ref and registry tips,
and removes only its journal-bound private index directory on restart. Side-ref
creation has a separate journal; a crash or registry-write failure is validated
and deterministically completed
before another broker action. The latest-turn commit capability is in-memory
and single-use.
Linked Git worktrees (`.git` pointer files) are deliberately unsupported in
this first version and fail startup; the real sandbox contract separately
proves that even their pointer file cannot be rewritten.

## Setup

1. Create a Discord bot (same steps as `../bridge/README.md` §1 — enable the
   Message Content intent, invite it to the server).
2. Use the root installer/doctor to provision the dedicated service account,
   shared workspace group, root-owned runner, exact v2 attestation and hashes,
   narrow sudoers rule, root-owned child toolchain, and workspace setgid/group
   modes. Hand-written/current-user attestations are not supported.

   ```sh
   if [ ! -e "$HOME/.codex" ]; then (umask 077; mkdir "$HOME/.codex"); fi
   [ ! -L "$HOME/.codex" ] || { echo "refusing symlinked ~/.codex" >&2; exit 1; }
   chmod -N "$HOME/.codex" 2>/dev/null || true
   chmod 700 "$HOME/.codex"  # operator bridge state only
   "$SWARM_HOME/bin/swarm-codex-runtime.sh" install --repo /absolute/target
   "$SWARM_HOME/bin/swarm-codex-runtime.sh" login
   # Log out/in and restart tmux so it receives the supplemental group.
   "$SWARM_HOME/bin/swarm-codex-runtime.sh" verify --repo /absolute/target
   ```

   Missing hidden-account auth after `install` is the expected pre-login state;
   operator auth is never copied or used as a fallback. Keep `login` attached to
   its terminal. Automatic localhost callback completion needs no pasted value;
   when the provider selects paste-back, enter it only in that terminal and
   never in Discord.

   A nonempty hidden `Library/Keychains` directory is normal Security.framework
   backing state, not accepted provider auth. The runner treats it as opaque,
   requires an exactly empty keychain search list, and pins every login/status
   and unattended-turn Codex command to `cli_auth_credentials_store="file"`;
   only the hardened `auth.json` is authoritative. Version-only probes do not
   carry auth or a turn.

   After this one-time bootstrap, `swarm-add --engine codex` automatically runs
   `prepare-workspace` and `verify` before committing each target row. Final
   Codex-to-Claude migration/removal calls `release-workspace`; it revokes only
   service-account permission metadata and does not delete repository content.

3. Register the bot/channel through engine-aware onboarding. It stores the bot
   token in `tokens.env`, writes the canonical ACL, prepares/verifies the hidden
   runtime workspace, and commits the row only after those checks pass. The
   launcher materializes the token into
   `~/.codex/channels/discord-<name>/`; do not hand-write the unused default
   `~/.codex/channels/discord/discord-token`.

   ```sh
   "$SWARM_HOME/bin/swarm-add.sh" <name> /absolute/target <channel-id> --engine codex
   ```

4. Start through the generated hardened swarm launcher. It changes to trusted
   runtime source, starts Bun with repo env/config/preload discovery disabled,
   supplies a clean explicit environment, and points
   `CODEX_BRIDGE_DISCORD_TOKEN_FILE` at the exact state file. Do **not** run
   `bun daemon.ts` from a writable target repo: Bun can process repo
   `bunfig.toml` preloads and `.env` before daemon code executes.

   ```sh
   "$SWARM_HOME/bin/swarm-up.sh" up <swarm-name>
   ```

5. `swarm-add` owns guild-channel authorization; local `group add` is not a
   canonical onboarding path and launch reconciliation may replace it. For
   status or DM pairing diagnostics, target the exact per-swarm state:

   ```sh
   DISCORD_STATE_DIR="$HOME/.codex/channels/discord-<name>" \
     bun "$SWARM_HOME/codex-bridge/cli.ts" status
   DISCORD_STATE_DIR="$HOME/.codex/channels/discord-<name>" \
     bun "$SWARM_HOME/codex-bridge/cli.ts" pair <code>
   ```

## Environment

This table documents direct/raw daemon controls. The supported `swarm-up`
launcher pins `CODEX_BIN`, state, argv prefix, and permission profile, and
removes ambient `CODEX_MODEL`/`CODEX_PROFILE`; those are not production
operator overrides.

| Var | Default | Meaning |
| --- | --- | --- |
| `CODEX_BRIDGE_DISCORD_TOKEN_FILE` | — (required) | must equal exact `<state>/discord-token`; owner-regular mode 0600 |
| `DISCORD_BOUND_CHANNEL` | unset | comma-separated channel ids the bot answers in |
| `DISCORD_STATE_DIR` | `~/.codex/channels/discord` | access.json, profile-scoped sessions.json, rotation-state.json, inbox/ |
| `DISCORD_ACCESS_MODE` | dynamic | `static` pins access.json to its boot snapshot |
| `CODEX_BRIDGE_CANONICAL_ACCESS_FILE` | unset | canonical owner-private ACL re-read as a live authorization ceiling for every message |
| `CODEX_BRIDGE_ARCHETYPE` | unset | trusted `cpo` or `engineering-cto` role; invalid values refuse startup |
| `CODEX_BRIDGE_OPERATOR_CHANNEL` | unset | trusted numeric operator-register channel ID |
| `CODEX_BRIDGE_BUS_CHANNEL` | unset | trusted numeric CPO bus ID; required and distinct for `cpo`, forbidden for engineering |
| `CODEX_BRIDGE_CWD` | `$PWD` | working dir Codex runs in (the agent's repo) |
| `CODEX_MODEL` | codex default | model override |
| `CODEX_PROFILE` | unset | `-p` config profile |
| `CODEX_TURN_TIMEOUT_MS` | `4500000` | hard kill for a stuck turn (75 min, including one full Fable budget-window wait plus review/cleanup margin) |
| `CODEX_BIN` | `codex` | canonical trusted native executable; interpreter-indirect scripts and repo/state/temp binaries are refused |
| `CODEX_BRIDGE_CODEX_ARGV_PREFIX` | unset | canonical Codex script passed before CLI flags (official NVM plan: `codex.js` after absolute Node) |
| `CODEX_BRIDGE_PREAMBLE_EXTRA` | unset | extra brief appended to the first-turn preamble (swarm-up.sh injects the doctrine directive here) |
| `CODEX_BRIDGE_INGRESS_LIMIT` | `100` | max accepted messages awaiting ordered preprocessing |
| `CODEX_BRIDGE_QUEUE_LIMIT` | `25` | max serialized Codex turn jobs (active + waiting) |
| `CODEX_BRIDGE_ENV_ALLOWLIST` | unset | comma-separated non-secret env names additionally passed to Codex; credential/provider names remain hard-denied |
| `CODEX_BRIDGE_ATTENTION_CHANNEL` | unset | trusted numeric channel bound to the narrow attention-flag relay |
| `CODEX_BRIDGE_ATTENTION_SWARM` | unset | trusted swarm name bound to the relay |
| `CODEX_BRIDGE_ATTENTION_STATE_DIR` | unset | normalized absolute private directory containing `attention-<channel>.flag` |
| `CODEX_BRIDGE_GIT_AUTHOR_NAME` | `Codex Bridge` | bounded author/committer identity for broker commits |
| `CODEX_BRIDGE_GIT_AUTHOR_EMAIL` | `codex-bridge@localhost` | validated author/committer email for broker commits |

Multiple agents on one machine: give each its own `DISCORD_STATE_DIR` (own
token, own sessions) — exactly like running multiple Claude bridge identities
with per-session env.

Do not place credentials in any per-user launchd bootstrap environment. The
dedicated runtime startup canaries deliberately query that namespace and fail
if the operator canary crosses the boundary. Bot/provider secrets belong only
in private credential files managed by the launcher; each bot token is the
per-swarm `discord-token` materialized from `tokens.env` at launch.

## Runtime state and operator view

The daemon atomically writes `<state>/runtime.json` using schema
`codex-bridge-runtime/v1`. It heartbeats every five seconds and reports gateway
readiness, active/queued work, the direct Codex child PID, turn timestamps, and
bounded error status. Consumers should treat a heartbeat older than 20 seconds
as stale and verify the daemon PID before acting.

Quota rotation is manager-owned and per swarm. Field 8 `CODEX_AUTH_POOL` names
an ordered pool from `codex-profiles.json`; blank means `default`. After every
terminal generation is reaped, the fixed runner emits only the selected home's
latest sanitized rollout rate-limit timestamp/windows. Fresh 300-minute or
10080-minute windows at the inclusive pool threshold (95% by default) cool the
profile through reset; structured usage-limit/429 failures rotate and requeue.
Null/stale/unknown telemetry never proactively rotates. The manager commits a
new lease only after daemon cleanup, writes sanitized `rotation-state.json`,
and never mutates another swarm's lease or sessions.

An atomic `<state>/daemon.lock/owner.json` singleton lock prevents overlapping
daemons from consuming or replying twice and from racing on runtime/session
state. The lock records PID plus an ownership token, rejects live owners,
and is released only after shutdown drains. The raw daemon fails closed on any
pre-existing lock. The supported serialized launcher may quarantine/remove one
exact well-formed dead-owner lock only after a final daemon/child quiescence
recheck. Malformed or ownerless-initializing locks remain fail-closed and need
operator investigation; there is no unconditional stale-path deletion.

Accepted Discord message IDs and their sender/gate metadata are durably staged
in bounded private `retry-notices.json` before queue admission. Graceful
shutdown sends awaited retry notices for waiting and active jobs. If Discord
rate limits outlast the forced-exit bound, remaining notices survive and are
replayed FIFO on startup/reconnect only after fresh local+canonical ACL/channel
reauthorization. The ledger is capped at 256 entries and 256 KiB.

`<state>/events.jsonl` is a redacted, content-free live feed, rotated at 1 MiB
to `events.jsonl.1`. It contains lifecycle, queue, Codex event/item type, and
final/error status only—never prompts, response text, commands, stderr, or
credentials. Follow it with:

```sh
bun codex-bridge/view.ts "$DISCORD_STATE_DIR"
```

The App Server bridge auto-delivers one final text response except the exact
trusted CPO-bus silence case above. It has no Discord reply MCP/tool and does not
upload outbound files; agents should name a repo-relative output path in final
text when relevant.

## Native App Server/TUI view

Production `swarm-up` requires the version-pinned 0.144.1 protocol client and
one root-attested global manager. A successful daemon registration publishes
`backend: "app-server"` plus only its per-swarm
`native-view/app-server.sock` facade in `runtime.json`; the hidden upstream
socket is inherited/internal and is never advertised.

`swarm-view.sh <name>` verifies that runtime, socket path, pinned Node/Codex pair,
isolated viewer `CODEX_HOME`, repo, and the exact thread mapped to the configured
Discord channel. It launches the native TUI as `codex resume --remote ...` in a
separate navigation-enabled tmux client with `--no-alt-screen`, a 100,000-line
history limit, mouse/copy-mode scrolling, and latest-client responsive sizing.
The facade remains read-only: it serves bounded cached history and filtered live
notifications for registered threads, implements only the reads required by the
pinned TUI, and rejects mutations, approvals, authority requests, and unbound
threads without forwarding anything upstream. Managed execution and the native
view both pin `gpt-5.6-sol`; CPO workers use `medium` effort and
engineering/default workers use `ultra`. The contrarian review route remains
independently pinned to Sol Ultra.

When any proof is missing—or before the configured channel has its first
persisted thread—the same command opens the explicitly labeled bounded/redacted
event/status fallback. The fallback is retained as durable observability, not as
the primary interface.

## Tests

```sh
bun test codex-bridge
```

Covers the gate decision table and live canonical revocation, daemon
outbound/admission/config policies,
pairing lifecycle, attachment limits, FIFO isolation, singleton locking,
chunking, the JSONL event parser (fixtures captured from codex-cli 0.142.3),
permission-profile arg construction and a real `codex sandbox` host-denial /
repo-read-write contract check, global manager generation/reaping, per-swarm
read-only facade filtering, session persistence,
runtime/event state, trusted binary/auth/state boundaries, latest-turn change
hashing, plumbing-only Git branch/commit transactions (including TOCTOU and
crash recovery), and the access CLI including the `approved/` protocol.
