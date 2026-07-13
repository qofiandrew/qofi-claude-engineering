# Architecture

The swarm runs either Claude Code or OpenAI Codex behind the same operator
contract. The engine is selected per `swarm.conf` row; an empty engine remains
`claude`, preserving the historical path. The load-bearing boundary is unchanged:
directives enter through one bound Discord channel, while escalations and results
leave through that same channel. Repository work stays on the host.

## The six layers

1. **Control plane — Discord.** One channel and bot identity per product. The
   operator sends vision/directives and receives results or escalations.
2. **Engine adapter.** Claude loads the `discord-b2b` MCP plugin from `bridge/`.
   Codex uses `codex-bridge/`, a direct Discord gateway that applies the same
   channel/owner ACL before any model invocation.
3. **Host — macOS + tmux.** `swarm-up.sh` owns one `swarm-<name>` session per
   configured repo. Launch, restart, rotation, watcher, and typing paths branch on
   the parsed engine rather than assuming Claude artifacts.
4. **Execution.** Claude is a long-lived interactive Agent Teams lead. Codex is a
   persistent gateway with a bounded FIFO; each accepted Discord chat maps to one
   resumable Codex thread. Production turns run through one root-attested global
   App Server manager and its hidden-runtime-UID App Server generation. The
   manager admits one turn or advisory review at a time, validates the effective
   repo/profile/sandbox authority, and fully reaps the App Server after a terminal
   result. It starts a fresh generation only after the owning daemon proves its
   repository lease, ACL, attachment, temporary-state, and session cleanup.
   Per-swarm FIFOs plus a shared physical-repo lease still cover startup, turns,
   and Git control. Managed launches refuse any active same-inode pairing that
   includes Codex; existing Claude/Claude behavior stays unchanged.
5. **Guardrails + memory.** Shared doctrine/spec/ADRs live in the repo. A
   runtime-blind harness normalizes Claude transcript and Codex rollout events,
   then owns completion review evidence, delivered-or-queued stop outcomes,
   check-in shape, roadmap derivation, and grounding metrics. Runtime adapters
   translate only. Claude consumes its existing `.claude` hooks and skills.
   Unattended Codex consumes `AGENTS.md`/`.agents/skills` under a bridge-owned
   permission profile; command hooks are empty/disabled and project rules are
   ignored. Its narrow Git broker reproduces deterministic checks in trusted
   host code and uses plumbing only after an allowlisted operator command;
   repository hooks never gain host trust. The shared lifecycle layer is
   implemented/tested behind adoption controls pending ADR-0023 ratification.
6. **Observability.** Claude exposes its native TUI/transcripts. Each registered
   Codex swarm receives an owner-private, protocol-filtering App Server facade.
   `swarm-view.sh` opens the configured Discord channel's persisted thread in the
   pinned native Codex TUI through that facade. The tmux client is navigation-
   enabled for scrolling and copy mode; the facade is the read-only boundary and
   rejects mutations, approvals, and unbound-thread access locally. Viewer
   traffic never reaches the hidden App Server. Atomic `runtime.json`
   health and the bounded, redacted event log remain the persisted fallback when
   the manager, facade, runtime, toolchain, or channel-thread mapping cannot be
   attested.

## Directive flow

1. Discord receives a message and the selected adapter applies hard channel and
   sender binding.
2. The lead holds the design conversation. On **go build**, it authors and asks
   the operator to confirm `PROJECT_SPEC.md` and one-way-door ADRs.
3. The lead decomposes work under the repository's ownership doctrine. Claude
   uses native Agent Teams and per-teammate worktrees. Codex's explicit
   substrate override permits only disjoint-path delegates in the serialized
   shared checkout; it must not claim autonomous worktree/merge/push/teardown.
4. Claude hooks and the shared Git hook retain their existing safe in-session
   path. Codex uses the explicit sandbox/network/secret boundary, direct
   verification, and the operator-authorized Git broker; it does not relabel
   Claude hook semantics. Both adapters feed normalized lifecycle events to the
   same harness policy.
5. The lead reconciles docs and runs the canonical suite. At the completion
   boundary, one foreign-model review artifact must bind to the exact final
   reviewed input. The harness then performs Discord stop delivery and records
   `delivered` or a durable dead-letter `queued` outcome before adopting the
   terminal state. Claude performs its normal integration flow; Codex hands a
   broker-owned side ref to operator/CI for integration. The canonical checkout
   is never switched by the broker. Codex does not pretend to call the Claude
   Discord reply MCP.

## Runtime ownership and safety

| Concern | Claude | Codex |
| --- | --- | --- |
| Conversation | long-lived TUI session | resumed thread id per Discord chat |
| Discord transport | MCP plugin | direct gateway daemon |
| Work serialization | lead/team substrate | one global App Server turn/review lease + one live managed Codex daemon per repo inode + bounded FIFO + startup/turn/Git lease |
| Git/delegation lifecycle | teammate worktrees, merge/push/teardown | opaque Claude worktrees + disjoint shared-checkout delegates + operator side-ref branch/commit/retire broker; merge/push deferred |
| Active-work signal | Claude transcript freshness | fresh `runtime.json`, live daemon PID, `active`/`queue_depth` |
| Operator view | native Claude TUI | native Codex TUI through a per-swarm read-only facade; persisted redacted event/status fallback |
| Subscription floor | Max login; scrub `ANTHROPIC_API_KEY` | ChatGPT login; scrub `OPENAI_API_KEY`/`CODEX_API_KEY` |
| Rotation | Claude account machinery | excluded from Claude account rotation |

The hidden App Server runs in its own process session. Timeout/shutdown interrupts
the owned turn, then the root runner reaps the complete hidden-UID payload before
the manager can accept cleanup. A failed resume is not blindly replayed: only a
positively classified missing-thread failure may clear the mapping and start
fresh. Missing/stale runtime state makes destructive lifecycle commands fail
safe.

## On-disk layout

```text
<swarm-home>/
  bin/                       engine-aware lifecycle/operator scripts
  templates/                 stamped doctrine and both engine policy surfaces
  bridge/                    private Claude Discord plugin (locked Bun graph)
  codex-bridge/              private Codex Discord gateway (locked Bun graph)
  docs/CODEX.md              Codex setup, operation, visibility, limitations
  swarm.conf                 repo/token/channel/account/engine registry

<stamped-repo>/
  CLAUDE.md                  canonical shared doctrine (name retained for compatibility)
  AGENTS.md                  direct Codex doctrine router
  TEAM_LEAD.md               engineering lead contract, when archetype supplies it
  .claude/                   Claude hooks, settings, skills
  .codex/                    empty hook neutralizer + manual-interactive rules
  .agents/skills/            Codex-native repository skills
  .git/hooks/pre-commit      shared final commit boundary

~/.codex/channels/discord-<name>/
  access.json                isolated, reconciled ACL
  sessions.json              chat -> resumed Codex thread mapping
  runtime.json               atomic codex-bridge-runtime/v1 heartbeat
  events.jsonl               bounded/redacted live operator feed
  native-view/
    app-server.sock          owner-only read-only native-TUI facade
  inbox/                     bounded per-turn attachment staging, removed after completion
  tool-tmp/                  private per-turn tool caches/temp, cleaned between turns
  tool-shims/                immutable bridge-created tool shims

~/.codex/app-server-manager/
  control.sock               owner-only global manager control endpoint

~/.codex/channels/repo-locks/
  <dev>-<ino>.lock/          startup/turn/Git lease; explicit audited recovery
```

`bridge/bun.lock` and `codex-bridge/bun.lock` are committed. Production launch
uses frozen installs, so first boot cannot resolve an unreviewed graph.

## Native Codex interface

Codex officially supports `codex app-server --listen unix://PATH` and a TUI
client via `codex --remote unix://PATH`. The production implementation satisfies
the topology selected in ADR-0020: one root-attested hidden-UID App Server behind
a global lifecycle manager, with one owner-private protocol-filtering facade per
registered swarm. Discord turns and the displayed history therefore come from
the same managed thread substrate without exposing the authority-bearing
upstream socket or admitting a second writer.

Turn admission is two-stage: operator-private attachment staging may occur
under the repository lease, but hidden-UID ACLs require an exact host-global
manager reservation that is atomically consumed by `turn/start`. Terminal
local cleanup and manager acknowledgement complete before any Discord output;
reservation or cleanup expiry is ambiguous/fail-closed, never an idle retry.

`runtime.json` advertises `backend: "app-server"` and the facade's nullable
`app_server_endpoint` only after registration succeeds. `swarm-view.sh` further
attests the runtime, endpoint path, pinned CLI, isolated viewer `CODEX_HOME`, and
the exact configured-channel thread before launching `codex resume --remote`.
The tmux client is navigation-enabled for scrolling and copy mode, while the
facade implements only the bounded read methods the pinned TUI needs. It serves
cached/persisted thread history and filtered live notifications; every mutation,
approval response, authority request, and unbound thread is rejected without
forwarding upstream. If any precondition is absent or ambiguous, the command
labels and opens the persisted redacted event/status fallback instead.

The advisory `codex-review.sh` lane prefers the same global manager and its
tool-less read-only review profile. When no manager endpoint exists, it can use
the dedicated route, then retains a narrow current-user compatibility route only
if that dedicated route is unavailable: exact ChatGPT auth, an empty private
cwd, ephemeral state, and no shell or unified-exec tools.

## Capacity model

Claude and Codex use independent subscription-auth lanes, but each remains bound
by its provider's limits and terms. Claude's existing one-to-two-team Max guidance
still applies to Claude rows. The system refuses API-key fallback for persistent
leads and review lanes; more configured swarms are not permission for metered or
unbounded concurrency.
