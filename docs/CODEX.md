# Codex engine operations

Codex is a per-swarm engine, not a replacement for the Claude path. Existing
rows with an empty engine remain Claude and retain their plugin, TUI, hooks,
account rotation, and Agent Teams behavior. A row created with `--engine codex`
uses the standalone Codex Discord bridge and independent ChatGPT subscription
auth.

## Bring up a Codex swarm

```sh
codex --version                 # audited range: >=0.144.1,<0.145.0
if [ ! -e "$HOME/.codex" ]; then (umask 077; mkdir "$HOME/.codex"); fi
[ ! -L "$HOME/.codex" ] || { echo "refusing symlinked ~/.codex" >&2; exit 1; }
chmod -N "$HOME/.codex" 2>/dev/null || true
chmod 700 "$HOME/.codex"       # owner-private operator state root
stat -f '%Sp %N' "$HOME/.codex"
bun --version

# pnpm workspaces must declare packageManager "pnpm@9.12.3". Populate the
# already-verified operator cache without sudo; the root installer never runs
# Corepack or package scripts.
corepack pnpm@9.12.3 --version

# One-time host bootstrap. This copies a root-controlled
# Node/Codex/Bun/npm/npx and, when required, pinned pnpm runtime, creates a
# distinct hidden macOS account, and installs the attested global App Server
# manager launcher/bundle. It does not reuse the operator account's Codex auth
# or Keychain context.
bin/swarm-codex-runtime.sh install --repo /absolute/path/to/repo
bin/swarm-codex-runtime.sh login

# Log out and back in, then restart tmux so the operator process credentials
# include the new supplemental workspace group.
bin/swarm-codex-runtime.sh verify --repo /absolute/path/to/repo

bin/swarm-add.sh <name> <repo> --engine codex
bin/swarm-up.sh up <name>
bin/swarm-attach.sh <name>
```

### Add isolated quota profiles

The default pool above preserves the existing single login. To add rotation,
initialize every named home before referencing it from a pool:

```sh
bin/swarm-codex-runtime.sh login --profile max_b
bin/swarm-codex-runtime.sh verify --profile max_b --repo /absolute/path/to/repo

# Add max_b to `profiles`, then create an ordered pool in codex-profiles.json.
bin/swarm-add.sh <name> <repo> --engine codex --codex-auth-pool rotating
```

Profile handles are labels only. `default` uses the hidden user's `.codex`;
named profiles use `.codex-profiles/<handle>`. Each is a complete `CODEX_HOME`
with its own file-backed ChatGPT auth, sessions, and rollouts. Never paste auth
or callback values into `codex-profiles.json`, `swarm.conf`, or Discord.

A committed install with no hidden `auth.json` is an expected transitional
state, not a reason to copy the operator's Codex credentials. Complete `login`
before running `verify`. Run that command in the local terminal that invoked the
lifecycle helper. When the provider can return through a reachable localhost
callback, the browser completes the terminal automatically; a relayed or
otherwise unreachable callback uses paste-back instead. Any paste-back value
goes only into that waiting terminal—never Discord, a bot prompt, or a channel.
The lifecycle accepts success only after the hidden account reports exactly
`Logged in using ChatGPT`.

Security.framework may create a private platform-UUID subtree beneath the
hidden user's `Library/Keychains` even while its keychain search list is empty.
That opaque runtime-owned state is neither a login nor an imported operator
keychain. Qofi descriptor-validates only its non-writable boundary and never
enumerates, reads, deletes, or copies its contents. Before and after login—and
again before unattended execution—the hidden user's search list must be exactly
empty, while every login/status and unattended-turn Codex argv pins
`cli_auth_credentials_store="file"`; only the selected profile home's hardened
`auth.json` is accepted for that generation. Version-only probes carry no auth
or turn.

An older installed helper that still rejects this normal macOS subtree cannot
reach its own update path. Refresh that one fixed file explicitly, then rerun
the normal transactional installer:

```sh
bin/swarm-codex-runtime.sh refresh-lifecycle
bin/swarm-codex-runtime.sh install --repo /absolute/path/to/repo
```

A legacy 16-field v2 attestation also predates the fixed Fable reviewer files.
During that explicit privileged upgrade, `install` first binds only the exact
root-owned lifecycle entrypoint, then transactionally publishes and validates
the reviewer shim, doctrine, and schema before expanding the attestation or
sudoers authority. Existing expanded attestations and every ordinary lifecycle
command still require all reviewer files up front. A failed first publication
removes the new files, while a failed replacement restores the prior bytes.

Direct operator `verify` deliberately receives only search/read-attribute ACLs
on the hidden home. It checks stable owner/group/mode/link metadata plus the
deterministic rendered-config hash without opening the private directory or its
mode-0600 config. The mandatory fixed root runner `--verify` then proves the
actual config bytes, hash, mode, link count, and ACL absence and must return one
exact success line. Do not broaden the operator ACL to make verification pass.

The first install also creates the hidden user's background launchd domain.
On current macOS, `launchctl bootstrap user/<uid>` can return before that domain
finishes importing its agents. The installer therefore retries only the fixed,
read-only hidden-credential `/usr/bin/id -u` proof for up to five seconds and
still requires the exact hidden UID. If this proof is exhausted, the error
includes a bounded diagnostic and the install transaction rolls back only state
it proved was created by that attempt. Exact Qofi-marked user/group records that
predated the attempt are intentionally retained, revalidated, and reconciled by
the same install command on rerun; they confer no execution authority by
themselves.

Once that domain is initialized, macOS may retain one PID-1 child
`/usr/sbin/distnoted agent` for the hidden user. Quiescence means zero Codex or
other payload processes, not disabling the operating system's user domain. The
lifecycle and runner exempt only one stable session-0/process-group-leader
instance with exact real/effective/saved runtime credentials, libproc path,
argv, and SIP-restricted root:wheel image metadata. Any duplicate, drift, or
other hidden-UID process remains killable payload and blocks if it respawns.

`asuser` changes the bootstrap/audit context but not POSIX credentials. The root
lifecycle and runner therefore enter the hidden user's context first, then use
an identical fixed isolated-system-Python trampoline to prove the Directory
Services name/UID/GID mapping, drop groups/GID/UID, prove exact real/effective
UID/GID with no group 0, and `execve` only the exact absolute argv. No shell or
general sudo-as-user grant is involved. Lifecycle login keeps its terminal;
unattended runner children use a separate process session for bounded
process-group cleanup.

After the one-time host bootstrap, `swarm-add --engine codex` runs
`prepare-workspace` and `verify` itself before registering each additional
target, and refuses to commit an unlaunchable row. The direct commands remain
available for diagnostics or advance preparation. To retire a target, use the
engine-aware `swarm-remove`/migration path, which releases that workspace before
changing the registry. Global teardown is explicit:

```sh
# First remove/migrate every engine=codex row. This removes the installed
# runner/toolchain and every registered workspace authority journal.
bin/swarm-codex-runtime.sh uninstall
# --remove-account additionally deletes the hidden OS account.
```

Do not run global `uninstall` while any Codex row is active: it disables all
Codex launches even without `--remove-account`. A missing/replaced registered
workspace fails teardown closed so its inode-bound restoration journal is not
discarded. Workspace journals bind the inode to the filesystem's stable volume
UUID; the session-local `st_dev` value is refreshed after an APFS remount or
reboot. Legacy v2 journals receive a one-time refresh only when the complete
root metadata and inode still match, so a genuinely replaced root remains
closed.

The hidden runtime user's exact search-only ACEs on the operator home,
`~/.codex`, and `~/.codex/channels` are shared by every Codex daemon. They
therefore persist across individual daemon exits and are removed only by global
`uninstall`, after the root lifecycle lock has quiesced the shared runtime UID;
foreign, broader, inherited, or duplicate ACL entries make cleanup fail closed.

Launch fails before creating a usable lead when Codex/Bun or the required local
toolchain is missing, the CLI is outside the audited version window, ChatGPT
subscription auth is absent, a metered API-key variable is present, the bound
channel has no owner allowlist, the target contains a swarm vault, project
configuration is unreviewed, locked dependencies cannot install, the global
manager cannot be root-attested and brought ready, or a prior runtime is not
quiescent. Workspace preparation also rejects cross-device
mounts, unrecognized owner UIDs, setuid/setgid/sticky regular files, and
hard-linked or duplicate regular-file inodes before privileged mode changes.
The one package-manager exception is a fully closed `node_modules` alias set:
every hard-link name must be observed inside the ordinary dependency tier,
the observed count must exactly equal `st_nlink`, and the operator-owned inode
must be ACL-free, runtime-readable/executable, and neither group- nor
world-writable. Those proven pnpm/esbuild inodes are scanned but never
chmodded, chgrped, or included in the restoration journal; their managed parent
directories remain replaceable so package tools can atomically update them.
An outside, hidden, sensitive-tier, mutable, or partial alias set still fails
closed because it could bypass the path sandbox or extend write authority past
the repository boundary.
A failed post-tmux check removes the stale session and returns nonzero so a
later `up` can recover normally.

`SWARM_OWNER_DISCORD_ID` is the explicit human operator principal. `swarm-add`
records it in canonical top-level `allowFrom` and the primary channel group,
writes `access.json` mode `0600`, and safely migrates historical owned `0644`
files. Top-level authorization is required on both the canonical and per-swarm
copies before `!qofi-git` is accepted; a watcher or ordinary channel member is
never inferred to be an operator. CPO rows additionally require the operator
and `CTO_BUS_WATCHER_BOT_ID` in the canonical `SWARM_BUS_CHANNEL` group.

The launcher ignores `CODEX_BIN` and ambient PATH for authority. Its fixed
resolver accepts audited install roots such as NVM, validates ownership/modes,
and turns the official npm wrapper into an explicit
`[absolute-node, canonical-codex.js]` execution plan. The operator's `~/.codex`
must be a real current-user-owned `0700` state directory. Subscription auth is
instead stored as mode `0600` beneath the hidden runtime account's separate
`CODEX_HOME`; doctor/preflight report exact remediation rather than falling back
to current-user or API-key auth.

Root-installed runner, lifecycle, attestation, sudoers, and toolchain authority
must also remain beneath descriptor-traversed, root-owned, non-writable,
extended-ACL-free parent chains. Installation strips inherited ACLs from staged
artifacts before publication, and both verification and the privileged runner
reject later parent or leaf ACL drift.

pnpm support is deliberately a singleton host contract: the audited version is
exactly `9.12.3`. The project must pin that version in `packageManager` (the
exact audited Corepack sha512 suffix is also accepted). Installation copies the
already-cached, operator-controlled package into the root toolchain and creates
a fixed-Node/direct-`pnpm.cjs` wrapper; neither ambient Homebrew pnpm nor
Corepack dispatch is used by the runtime. A later install for an npm-only repo
preserves a valid installed pnpm package, while another pnpm version, a partial
cache, or an integrity mismatch fails before Directory Services changes. pnpx
is not part of the current executable contract. Per-turn pnpm home, store,
XDG data/state, and cache paths live under the private turn temp, manager
auto-download is disabled, and the OS profile still disables network access.

`swarm-add` writes the seventh `swarm.conf` field and stamps both engine policy
surfaces. The repository includes:

- `AGENTS.md`, which directly routes Codex to the archetype-correct doctrine;
- `.codex/hooks.json`, deliberately stamped as an empty neutralizer;
- `.codex/rules/qofi-hard-floor.rules`, a conservative floor for separately
  trusted manual interactive sessions (the unattended bridge ignores it);
- `.agents/skills/*`, Codex-native discovery shims to the canonical skill bodies;
- the existing `.claude` files, unchanged for Claude compatibility;
- a constrained operator-authorized Git broker because Codex protects `.git`
  from tool writes. The broker reimplements the deterministic docs-touch and
  secret checks in trusted host code and uses Git plumbing. It creates and
  advances an independent side ref without switching canonical HEAD or
  installing the real index; it never executes mutable repository hooks or
  filters. A proof-based `retire` clears only an integrated capability and
  retains the historical ref.

The unattended launcher never uses Codex's hook-trust bypass. Codex 0.144.x
executes trusted command hooks outside the tool sandbox, so an editable
repository cannot safely supply host commands. The bridge disables hooks and
passes `--ignore-rules` on every turn; doctrine comes from `AGENTS.md` plus the
bridge-owned preamble, and completion evidence is run directly.

## Runtime shape

```text
Discord -> channel/owner gate -> bounded FIFO -> owner-only manager control
   ^                                               |
   |                                    root-attested global App Server
   +---------- mention-safe final response <-------+

native Codex TUI -> per-swarm read-only facade -> cached thread/live events
                  (no upstream mutation path)
```

One Discord chat maps to one persisted Codex thread. Turns across all chats for
the swarm are serialized because they share a working tree; the global manager
also admits only one Codex turn or advisory review at a time across the host.
Attachments are downloaded with a verified byte ceiling into operator-private
per-turn staging while the repository lease is held. The daemon then obtains a
host-global manager reservation before installing any hidden-UID turn ACL, and
releases that reservation only after cleanup or atomically converts it into the
active turn lease. Queue depth, buffered output, attachment count/bytes, and event-log size
are bounded; overload is rejected visibly instead of consuming memory/disk
without limit.

After the App Server reaches a terminal result, local authority cleanup comes
before external delivery: turn ACLs and staging are removed, the workspace
snapshot and repository lease are settled, sessions are synchronized, and the
manager cleanup capability is acknowledged before Discord sends or attention
relays. Missing cleanup proof has a bounded fail-closed deadline and never
silently admits another hidden-UID turn.

### Engineering lifecycle boundary

The App Server backend is first-class for onboarding, Discord control, resumed
conversation, repository editing, bounded verification, lifecycle safety, and
operator-authorized side-ref branch/commit/retire handoff. It does **not** implement Claude
Agent Teams' autonomous per-teammate worktree, merge-to-dev, push, and teardown
lifecycle. `AGENTS.md` explicitly overrides only those impossible
Claude-substrate clauses: Codex delegates use disjoint path ownership in the
serialized shared checkout, and the broker produces a verified non-protected
side ref for operator/CI integration without switching the checkout. A Codex lead must not report that merge or
push completed. Host-owned pooled worktrees remain a separate future feature.

Claude's `.claude/worktrees/` subtree is opaque to the privileged provisioner
and explicitly denied by the Codex permission profile. Its nested `.git`
pointers and checkout contents are neither scanned nor exposed to Codex. A
managed Claude and Codex swarm may not run simultaneously against the same
repository device/inode. Multiple rows may reference one repo, but at most one
managed Codex daemon for that physical checkout is live at a time because its
startup also reconciles and tests the boundary. Startup, turns, and Git controls
all take the inode-bound repo lease documented below.

Every managed turn:

- starts or resumes only through the owner-private manager control endpoint;
  named profile layering is rejected because the manager cannot safely apply it
  per thread;
- runs in the hidden runtime account with a clean fixed environment, pins
  `forced_login_method="chatgpt"` and `cli_auth_credentials_store="file"`, and
  retains only subscription auth;
- has its effective repo, model/provider, permission profile, sandbox, writable
  roots, and runtime workspace roots checked before input is submitted;
- applies the bridge's custom root-deny permission profile: workspace writes
  except protected doctrine/policy, exact read-only toolchain roots, discovered
  secret-path denials, active attachments, and one private per-turn temp root;
- disables tool network access, hooks, project exec-policy, ambient/project MCP,
  plugins, apps, browser/computer/image tools, persistence, and shell snapshots;
  the only MCP registration is the byte-verified, root-attested one-tool Fable
  reviewer rendered into the selected isolated home;
- removes Discord and provider API credentials from the child environment;
- runs inside a root-admitted App Server generation; timeout/shutdown interrupts
  the owned turn and fully reaps that hidden-UID payload;
- ignores malformed/non-object JSONL noise without wedging the queue;
- classifies a missing-thread error before deleting context and retrying fresh;
  arbitrary errors are never replayed as a new mutating turn.

After every terminal turn, the manager stops and reaps the App Server before it
returns a cleanup capability. The daemon must then finish its workspace
runtime ACL revocation, attachment/temp removal, workspace snapshot,
repository-lease release, and persisted-session sync. Only a positive cleanup acknowledgement
permits the manager to start a new generation and resume registered threads. An
ambiguous result or incomplete cleanup leaves the manager stopped and the daemon
fail-closed. Discord delivery starts only after that local cleanup boundary.

Final model text is delivered automatically once. It is sent with Discord role,
everyone, and replied-user mention parsing disabled. Codex is told not to call
the Claude-only Discord reply MCP.

## Runtime state and lifecycle

Each swarm owns `~/.codex/channels/discord-<name>/`:

| Path | Purpose |
| --- | --- |
| `access.json` | isolated `0600` ACL; bound guild groups and the explicit top-level operator list are reconciled from the canonical owner ACL on every launch |
| `sessions.json` | atomic `(Discord chat, auth profile)` to Codex-thread mapping |
| `runtime.json` | atomic `codex-bridge-runtime/v1` heartbeat, daemon PID, `backend`, native-facade `app_server_endpoint`, active/queue state, and completion/error metadata; App Server mode never publishes a hidden child PID |
| `events.jsonl` | bounded and redacted operator feed; no prompt/message body or credential content |
| `rotation-state.json` | sanitized active profile, pool headroom, leases, cooldowns, and parked reset; profile labels only |
| `parked-turns.json` | owner-private metadata-only replay ledger for quota-parked tasks: Discord message/channel IDs, authorization binding, retry time, and bounded attempt; no prompt, attachment URL, credential, or token content |
| `review-artifacts/<task>/<profile>/` | owner-private, profile-scoped Fable verdicts plus the reviewed-input SHA-256 and non-secret swarm/profile/task provenance; hard-limit retries never consume another profile's artifacts |
| `native-view/app-server.sock` | owner-only, ACL-free per-swarm App Server facade used by the pinned native TUI; it is not the hidden upstream socket |
| `inbox/` | bounded per-turn attachment staging; cleaned after completion/shutdown |
| `tool-tmp/` | private per-turn tool temp/cache roots; cleaned between turns/startup |

Restart/update, watcher, typing, and the view command use the same validated
runtime snapshot. Missing, malformed, stale, or dead state does not mean “idle”:
destructive lifecycle operations fail safe. Claude account rotation still
excludes Codex rows entirely; Codex uses the independent per-swarm rotation
contract below.

### Quota-aware per-swarm rotation

`codex-profiles.json` declares non-secret profiles and ordered named pools.
Profiles are exclusive across swarms unless their registry entry explicitly
sets `shared: true`; the committed `default` profile is shared to preserve the
historical single-login behavior. A pool's `thresholdPercent` defaults to 95.

After each terminal run, and only after the App Server has been reaped, the
fixed runner reads the selected home's newest rollout. It emits only the latest
physical `token_count.rate_limits` timestamp and windows. Window identity comes
from `window_minutes` (`300` for 5-hour, `10080` for weekly), not from
`primary`/`secondary`. Null, malformed, future, or older-than-30-minute evidence
is unknown and never triggers proactive rotation. A known fresh window at or
above the inclusive threshold cools through its reset and moves that swarm to
the eligible profile with most headroom.

A structured usage-limit or HTTP-429 terminal result rotates immediately after
cleanup and requeues the same task. If all profiles are cooling or leased, the
swarm announces a park on Discord and releases the turn/repository boundary. A
private metadata-only ledger refetches the immutable original Discord message
at the earliest reset/backoff, including after daemon restart; prompt and
attachment content are never copied into the ledger. Rotation never changes a
live pane's home, another swarm's lease, or another swarm's sessions. Inspect
the local sanitized state with:

```sh
DISCORD_STATE_DIR="$HOME/.codex/channels/discord-<name>" \
  bun "$SWARM_HOME/codex-bridge/cli.ts" status
```

The one host-wide manager owns `~/.codex/app-server-manager/control.sock` and
runs in the dedicated `qofi-codex-app-server-manager` tmux session. The fixed
root launcher—not repository TypeScript or a caller-supplied argv—admits that
manager against the installed hashes and root-only admission record. Normal
`swarm-up` ensures it automatically. Operator diagnostics are available through
`bin/swarm-codex-manager.sh {status|health|ready}`; `drain`, `resume`, and
`shutdown` are lifecycle controls, not per-turn UI commands. Root runtime
install/verify/login operations drain or replace the manager as required.
Codex 0.144.1 gates `runtimeWorkspaceRoots`, named permissions, and their
effective response fields behind the initialize `experimentalApi` capability.
Only the manager connection opts in because it sends and verifies those exact
fields; generic protocol clients remain default-off, attestation stays disabled,
and the fixed server-request deny/allowlist is unchanged.
If an older manager becomes stopped and ambiguous before any swarm is
registered (for example, a rejected advisory review), replacement shutdown may
retire only that exact zero-registration state through the fixed root helper.
Recovery rebinds the root admission, exact launcher/manager identities and
argv, the launcher's singleton lock, and the control socket's inode and kernel
peer PID. It takes the hidden-runner singleton before the final exact health
proof, preventing a concurrent resume from creating a generation, and retains
that lock through signaling, supervised launcher reap, and UID quiescence. Tmux
names and panes are never termination authority. Any registered ambiguity
remains blocked for explicit workspace/ACL reconciliation.

Install and uninstall take that same root launcher singleton before the global
runner lock and retain both across every manager launcher, bundle, or authority
mutation. A concurrent manager start therefore either owns the singleton and
blocks the lifecycle transaction before mutation, or loses before it can
publish admission; the admission check is repeated only after both locks.

### Interrupted lifecycle transactions

The cooperative lifecycle locks at `swarm.conf.mutation.lock` and
`swarm.conf.launch.locks/<name>` deliberately survive an ungraceful process
death. They cover config, repository surfaces, tmux generation, and runtime
authority as one transaction, so a dead PID alone cannot prove which boundary
was crossed. `swarm-add`, `swarm-remove`, `swarm-sync`, and new launches fail
closed while that signal exists; emergency `down` and attaching to an existing
Claude session remain available.

Do **not** remove either lock by hand. `bin/swarm-recover.sh` is the explicit,
fail-closed recovery path. Its read-only `audit` binds the exact lock and owner
inodes, config digest, repository identities, tmux inventory, and bounded Codex
runtime evidence into a SHA-256 receipt. `recover` recomputes that evidence and
removes only the same inode; a live owner, malformed evidence, new session,
config edit, runtime heartbeat, or lock ABA retains the signal and requires a
new audit. It never kills a session and never infers a workspace mutation.

Recover a per-name launch first. Quiesce that exact session, audit, then pass
the receipt back with the explicit acknowledgement:

```sh
bin/swarm-up.sh down <name>
bin/swarm-recover.sh audit launch <name>

bin/swarm-recover.sh recover launch <name> \
  --receipt <sha256-from-audit> \
  --ack-reconciled
```

Shared repositories also have a cross-swarm startup/turn/Git lease at
`~/.codex/channels/repo-locks/<repo-dev>-<repo-ino>.lock`. After stopping the
fleet, recover each retained lease before the global mutation lock:

```sh
bin/swarm-recover.sh audit repo-lease /absolute/canonical/repo

bin/swarm-recover.sh recover repo-lease /absolute/canonical/repo \
  --receipt <sha256-from-audit> \
  --ack-reconciled
```

This scope requires a matching live repository device/inode, no fleet session
or runtime PID, and an exact
`qofi-codex-repo-lease/v1` owner. The audit binds the random UUID token but
prints only its SHA-256 digest. Recovery rereads the same token after atomically
binding the exact audited lock inode; an owner/config/repo/token ABA keeps the
lease. The owner evidence remains recoverable after its config row is removed,
so removal cannot create an irrecoverable lease. An in-progress exact-release
tombstone remains blocking and recoverable in both exchange phases; finalized
`.released.*` cleanup evidence is inert. Missing or replaced repos are never
pathname-deleted.

Mutation recovery is deliberately fleet-quiescent because the old PID-only
owner file cannot prove which name an interrupted transaction affected. Stop
the fleet, recover all retained launch and repo locks as above, and then audit
the global transaction:

```sh
bin/swarm-up.sh down
bin/swarm-recover.sh audit mutation \
  --operation account --name <name>
```

Audit and replay must carry the same exact operation/name/engine/repo/workspace
tuple; that tuple is part of the receipt. After reconciling the named
interrupted operation, replay the receipt. For an
account rewrite, sync, or launch transaction no workspace action is accepted:

```sh
bin/swarm-recover.sh recover mutation \
  --receipt <sha256-from-audit> \
  --ack-reconciled \
  --operation account --name <name>
```

An interrupted `add` or `remove` must name its target repo and engine. A Codex
workspace action is a separate, explicit choice. Pass the same tuple to the
read-only audit first and then replay its action-bound receipt:

```sh
bin/swarm-recover.sh audit mutation \
  --operation add --name <name> --engine codex \
  --repo /absolute/canonical/repo \
  --workspace-action <prepare|verify|release>

bin/swarm-recover.sh recover mutation \
  --receipt <sha256-from-audit> \
  --ack-reconciled \
  --operation add --name <name> --engine codex \
  --repo /absolute/canonical/repo \
  --workspace-action <prepare|verify|release>
```

`prepare` and `verify` are accepted only when the current config has a Codex
reference to that exact repo. `release` is accepted only when it has none; this
is the conservative cleanup for an authority journal left by an uncommitted
Codex adoption. Release audit binds a root-attested digest of that exact
workspace journal, and the privileged release performs a digest CAS before any
authority change. Claude recovery rejects every workspace action. The command
never chooses among them. Immediately before any recovery deletion, the fixed
root lifecycle takes the global runner lock, terminates orphaned hidden-UID
processes, and emits an exact quiescence proof. It also runs the
root-attested read-only verifier for every currently configured Codex workspace
before removing the global signal. Missing/replaced roots, ambiguous journals,
or any failed prepare/release/verify keep the lock for a new audit. Once
recovered, rerun the interrupted lifecycle command from the beginning.

This differs from a daemon singleton lock, for which the launcher implements a
narrowly checked dead-owner/quiescence recovery path.

Pairing/access administration must target the swarm's state directory:

```sh
DISCORD_STATE_DIR="$HOME/.codex/channels/discord-<name>" \
  bun "$SWARM_HOME/codex-bridge/cli.ts" status

DISCORD_STATE_DIR="$HOME/.codex/channels/discord-<name>" \
  bun "$SWARM_HOME/codex-bridge/cli.ts" pair <code>
```

The daemon includes this exact state-aware form in pairing replies.

## Native read-only operator view

Use:

```sh
bin/swarm-attach.sh <name>   # primary engine-aware command
# or explicitly:
bin/swarm-view.sh <name>
```

Codex documents a local App Server and remote TUI:

```sh
codex app-server --listen unix:///protected/path/app-server.sock
codex --remote unix:///protected/path/app-server.sock
```

The installed 0.144.1 topology uses one global hidden-UID App Server, a
connection-bound global turn/review lease, and one filtering facade per swarm.
The Discord daemon executes the same persisted threads through that manager. It
never exposes the upstream authority socket: doing so would let an operator TUI
race Discord approval ownership or start another turn/mutation.

`swarm-view.sh` accepts only a healthy App Server runtime and an endpoint
lexically bound beneath the selected swarm's state directory. It also attests
the pinned Node/Codex pair, isolated viewer `CODEX_HOME`, exact repo, and the
single persisted thread mapped to the row's configured Discord channel. It then
opens a separate `codex-view-<name>:codex-native` tmux session with:

```sh
codex resume --remote unix://... --no-alt-screen -C /exact/repo <configured-channel-thread>
```

The viewer consumes a least-authority projection of the root runtime record:
the attestation schema and operator identity plus the exact Node/Codex paths and
SHA-256 values. Reviewer, lifecycle, and configuration attestations are not
viewer execution authority. Adding or refreshing one of those unrelated
capabilities therefore cannot hide an otherwise valid native client; Node or
Codex path/hash/ownership/ACL/version drift still removes native eligibility and
falls back truthfully.

The native tmux client permits navigation so mouse scrolling and copy mode work;
the session retains 100,000 inline-history lines, hides its status row, and
tracks the latest active client size with aggressive resize. The facade—not the
tmux key filter—is the read-only authority boundary: it implements only bounded
reads required by the pinned native UI, filters history and notifications to
that swarm's registered threads, and rejects every mutation, approval response,
authority request, and unbound thread locally. Viewer requests have no
forwarding path to the hidden App Server. Managed turns pin model
`gpt-5.6-sol`; CPO workers use Codex reasoning effort `medium`, while
engineering and unknown/future archetypes use the fail-safe `ultra` default.
The manager fails closed if App Server reports a different effective model or
per-swarm effort.

The separate contrarian review lane also pins `gpt-5.6-sol` with `ultra`
reasoning. Because Sol advertises model-level multi-agent v2, the fixed command
uses Codex's built-in review mode, whose internal review session disables that
delegation; shell execution is independently disabled. A manager-backed review
reaps the shared Sol Ultra App Server, runs that fixed hidden-runtime review
command, and restores the shared generation only after the caller acknowledges
cleanup.

Managed Codex homes retain the symmetric
`fable_reviewer.adversarial_review` registration, but it is not a worker
invocation surface. Active-turn scope requests are refused and produce no
artifact. The trusted manager invokes the same root-installed shim in fixed
one-shot mode only after a successful terminal App Server result, generation
reap, hidden-runtime ACL revocation, and capture of the exact final changed-file
payload (or the exact no-change sentinel). The invocation accepts bounded
text/JSON on stdin and has no worker-selected swarm, profile, task, repository,
or path argument.

The shim is not `claude mcp serve`. It invokes the exact `claude-fable-5`
print-mode model with an immutable adversarial doctrine, no tools, no exec, no
nested MCP, no plugins, no persistence, and no repository access. Named files
and context excerpts are untrusted stdin data, never part of the system prompt.
The internal Codex review command still ignores user config and supplies an
empty MCP map, preventing reviewer recursion. A manager-liveness pipe makes
manager loss close the review supervisor and TERM/KILL-reap Claude's complete
process group.

The terminal capability is bound to the manager registration and exact lease;
the shim cannot choose a swarm, profile, task, or state directory. Policy lives
in root-install-pinned `fable-reviewer.json`. Defaults are device auth, one call
per task, twelve serialized calls per hour, a 180-second call timeout, and
`review-pending` on provider failure. A per-swarm `anthropic-api-key` lane is
available for explicitly governed review spend. The default device credential
is global to the machine and therefore shares Claude quota across Claude
swarms; the queue and budgets bound pressure but do not claim credential
isolation. Budget state preserves per-task caps across profile rotation and
parked-task interleaving. Scope is fixed in memory by the manager and re-proved
before persistence, so a stale task or lease writes nothing. The root lifecycle
broker independently rebinds the opaque completion capability to the root
registry's repository, consumes the exact manager receipt, and records
delivered-or-queued completion before the manager permits cleanup. A
crash-surviving supervisor retains the one-at-a-time invocation lock while it
reaps Claude and all descendants after timeout, EOF, manager loss, or shim
termination.

To opt one swarm into the API lane, place only the non-secret lane selection in
`fable-reviewer.json`, then rerun the privileged runtime installer so the
manager's source hash and fixed bundle adopt it:

```json
"swarms": {
  "press-backend": { "authLane": "anthropic-api-key" }
}
```

Store the key under the fixed operator-Keychain service without putting it on
argv or in shell history:

```sh
IFS= read -r -s FABLE_KEY
printf '%s' "$FABLE_KEY" | /usr/bin/python3 -I -B \
  bin/security-add-generic-password.py \
  --service QOFI_FABLE_REVIEWER_API_KEY --account "$(/usr/bin/id -un)"
unset FABLE_KEY
```

The shim binds both service and operator account and injects the value only into
the bare headless Claude child. Never place it in `fable-reviewer.json`,
`swarm.conf`, Discord, or a Codex home.

The result contract is `qofi-adversarial-review-output/v2`. Findings contain
severity, locus, a falsifiable claim, evidence, and a suggested test. Approval
must state both what was and was not checked. Provider timeout, rate-limit,
auth, and malformed-output failures return a persisted `review-unavailable`;
the pipeline records `review-pending` and must never infer approval. A missing,
changed, or unlaunchable fixed reviewer creates no receipt and blocks the
manager in an ambiguous fail-closed state. Credential-like provider output
is rejected without reflecting suspect bytes. Private task/profile artifacts
pair the verdict with the reviewed-input SHA-256. `block` announces on Discord
with only swarm/profile labels and never gains merge, push, or ratification
authority.

This integration is implemented and covered by local tests but remains
adoption-off. It cannot be live until the operator runs the privileged installer
and a real managed Codex-to-Fable shakedown, and until the supervised
`claude -p` half has equivalent exact-final provenance; native Claude hooks do
not supply that authority. See ADR-0022 and ADR-0023.

If the runtime/facade/toolchain/thread proof is incomplete, or no configured
channel thread exists yet, the command opens
`codex-view-<name>:codex-events` instead. That explicitly labeled
**FALLBACK EVENT/STATUS VIEW** follows the bounded redacted persisted stream and
shows queue/turn lifecycle, tool/command activity, completion, and errors. A new
swarm therefore uses the fallback until its first accepted message creates the
configured channel's persisted thread; rerunning `swarm-view.sh` then opens the
native Codex TUI. Neither viewer is the writable daemon pane. Text entered into
the native viewer cannot start a turn because its facade rejects mutation; use
Discord and the supported lifecycle paths for work, and use the viewer for
scrolling, copying, status inspection, and resize-aware observation.

Official references: [App Server and remote TUI](https://developers.openai.com/codex/app-server),
[project hooks](https://developers.openai.com/codex/hooks),
[skills](https://developers.openai.com/codex/skills),
[exec-policy rules](https://developers.openai.com/codex/rules), and
[advanced configuration](https://developers.openai.com/codex/config-advanced).

## Verification

Local, no-provider-spend checks:

```sh
(cd bridge && bun install --frozen-lockfile && bun audit --production)
(cd codex-bridge && bun install --frozen-lockfile && bun audit --production)
npm test
```

Then run [`SHAKEDOWN.md`](SHAKEDOWN.md) against a throwaway `engine=codex` repo.
The live Discord → Codex → Discord round trip is an operator shakedown because it
uses an external bot/channel and subscription; unit tests must not fabricate that
acceptance result.
