# ADR-0020 — Broker one global Codex App Server before exposing a native TUI

**Status:** accepted
**Date:** 2026-07-11

> **Implementation status (2026-07-12):** the root-attested global manager,
> lifecycle draining, manager-backed review, per-swarm read-only protocol
> facades, runtime endpoint publication, and native `codex --remote` viewer are
> implemented. The viewer rejects mutations rather than sharing turn/approval
> authority and retains the persisted event/status fallback. The real
> Discord/provider/native-TUI shakedown and full regression pass in the
> acceptance gate remain open; implementation is not a claim that those external
> checks passed.
>
> **Rotation addendum (2026-07-12):** ADR-0021 retains this global manager and
> one-runner topology while binding each reservation/generation to a per-swarm
> leased Codex profile home. No live App Server changes homes.

## Context

Codex CLI 0.144.1 supports a Unix-socket App Server and a native remote client:

```sh
codex app-server --listen unix:///path/app-server.sock
codex --remote unix:///path/app-server.sock
```

The protocol can start/resume threads, stream turn/item events, interrupt a
turn, and serve multiple subscribers. A local no-provider probe also proved
that `thread/start.config` can select a custom per-thread permission profile,
so one server can host repository-scoped threads.

That capability is not sufficient to publish the upstream socket directly.
All managed Codex swarms share one hidden UID, one `CODEX_HOME`, and the root
runner's global process lock. The current runner kills all processes of that
UID before and after each bounded child. A persistent per-swarm server would
therefore race shared state and kill or block sibling swarms, host checks, and
the Codex review lane.

App Server also broadcasts approval/user-input requests to subscribed clients;
the first result or error response consumes the pending callback. A non-owner
must therefore defer without responding. App Server also permits concurrent
turns and protocol methods broader than the exec bridge's single-writer
capability. A direct TUI could therefore race a Discord-owned approval, start a
second writer, or request configuration/filesystem operations outside the
swarm's bound repository.

## Decision

1. The only eligible persistent topology is **one global App Server** under the
   attested hidden UID.
2. Neither `runtime.json` nor `swarm-view.sh` may expose that upstream socket.
   Each swarm needs an operator-owned, mode-0600, protocol-filtering gateway.
3. A global manager must own server lifecycle, a pre-turn reservation, and a
   connection-bound turn lease. A daemon may stage operator-private inputs
   first, but must reserve the host-global slot before granting the hidden UID
   any turn ACL. Only exact post-revocation cancellation may reopen admission;
   expiry or uncertain cleanup blocks and reaps instead. The manager drains
   before login/install/verify/release/uninstall work and before the fallback
   exec review lane uses the runner.
4. Discord and native clients use the same App Server threads only through the
   manager/gateway. The gateway forces canonical cwd and the fixed permission
   profile, filters thread/path/config methods, and routes approvals solely to
   the client that owns the active turn.
5. Disconnect or ambiguous interruption never causes automatic turn replay.
   The lease remains fail-closed until a terminal event, server death, or
   explicit reconciliation proves the outcome.
6. `codex --remote` becomes the default Codex attach path only after manager,
   gateway, review migration, lifecycle draining, and a two-client approval/
   concurrency shakedown pass. Until then the redacted event view remains the
   truthful supported view.
7. Native-client admission projects only its execution authority from the root
   runtime record: schema/operator identity and the exact Node/Codex paths and
   hashes. Unrelated reviewer or lifecycle authority cannot remove a still-valid
   viewer. Any viewer-relevant identity, ownership, ACL, hash, or version drift
   still falls back closed.

## Consequences

- There is no Codex-version blocker to a native interface; the remaining work
  is host lifecycle and cross-client authority mediation.
- A direct or per-swarm App Server shortcut is rejected even if it appears to
  work locally, because it regresses the existing hidden-UID, review, and
  single-writer guarantees.
- The version-pinned JSON-RPC client may be built and tested independently, but
  its presence alone does not make an endpoint safe to advertise.
- Claude's TUI, hooks, plugin, account rotation, and Agent Teams lifecycle stay
  untouched throughout the migration.

## Acceptance gate

- exact root-runner App Server argv and parent/socket cleanup;
- global manager singleton, drain, restart generation, and connection-bound lease;
- initialized, exactly pinned 0.144.1 protocol over an inode/owner/mode-attested
  Unix socket, with bounded frames and requests;
- effective per-thread permission-profile verification;
- Discord plus two TUI subscribers with owner-only approval responses;
- cross-repo thread/path/config rejection and serialized turns;
- reconnect/interrupt ambiguity retained fail-closed;
- Codex review remains available while the server is active;
- native `codex --remote` tmux smoke test plus live Discord/TUI shakedown;
- the full existing Claude and Codex suite remains green.

Official protocol reference: [Codex App Server](https://developers.openai.com/codex/app-server).
The pinned implementation details are also auditable in the
[0.144.1 Unix transport](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/app-server-transport/src/transport/unix_socket.rs),
[outgoing request routing](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/app-server/src/outgoing_message.rs),
and [thread subscription state](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/app-server/src/thread_state.rs).
