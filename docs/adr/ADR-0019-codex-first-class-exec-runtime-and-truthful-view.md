# ADR-0019 — First-class Codex uses a hardened exec bridge and truthful live view

**Status:** accepted
**Date:** 2026-07-11

> **Current implementation note (2026-07-12):** ADR-0020's accepted topology is
> now implemented: production Codex turns use the global App Server manager and
> `swarm-view.sh` prefers a per-swarm filtered, read-only native TUI. The exec and
> non-native-view statements below record the baseline this ADR established;
> they are no longer the production attach path. The persisted redacted view
> remains the fail-safe fallback, and live external acceptance is still open.
>
> **Rotation addendum (2026-07-12):** ADR-0021 supersedes this record's
> Claude-only account-rotation exclusion for Codex. Claude remains unchanged;
> Codex now rotates complete isolated profile homes per swarm at manager task
> boundaries.

## Context

The original swarm treated Claude Code's long-lived TUI, hooks, transcripts,
plugin bridge, account rotation, and Agent Teams as universal. Adding a Codex
row only at launch time produced false safety proofs: Claude hooks did not govern
Codex, Claude transcript probes could kill active Codex work, host Codex config
leaked capabilities into Discord turns, and there was no honest tmux view.

Codex has two relevant integration surfaces:

- `codex exec --json`, a stable non-interactive turn with persisted thread ids;
- Codex App Server plus `codex --remote`, which can power a native remote TUI but
  requires the bridge itself to speak the App Server protocol.

A TUI opened with `codex resume` beside an exec-driven daemon is not attached to
the running process. It can show stale history and introduces a competing writer.

## Decision

1. `swarm.conf` field 7 selects `claude` (default) or `codex`. Every lifecycle
   consumer must branch on that parsed value; no Codex decision may be inferred
   from Claude transcript/account state.
2. The stable Codex backend remains a hardened `codex exec --json` bridge:
   explicit workspace sandbox and network policy, ignored operator config,
   scrubbed environment, bounded queue/output/attachments, one process group per
   turn, classified resume recovery, and one repository writer at a time.
3. The bridge publishes atomic health and a bounded/redacted event stream. This
   is the default live tmux operator view and is labeled non-native.
4. `runtime.json` reserves `app_server_endpoint`. A future viewer may launch
   `codex --remote <endpoint>` only when the active runtime owns and advertises
   that endpoint and the remote client runs through the dedicated boundary.
   That client path is not implemented today; the current viewer always uses
   the event stream and never implies a native TUI is live-attached.
5. App Server becomes eligible as a future backend only with protected local Unix
   transport, version-matched generated protocol types, fail-closed approvals,
   interrupt/process ownership, reconnect/resubscribe handling, and arbitration
   between Discord and interactive clients.
6. Codex receives native `.codex` policy and `.agents/skills`; Claude artifacts
   remain in place and its behavior remains the compatibility baseline.
7. Unattended Codex runs as a root-attested hidden macOS account through a fixed
   runner/toolchain. Registration prepares and verifies repo-scoped authority
   before its row commits; migration/removal revokes that authority only when
   the final Codex row for the canonical repo disappears.

## Consequences

- Operators can safely observe live Codex command/tool/turn events from tmux now.
- The view is not the native Codex screen under the exec backend; its label says
  so. This is less visually rich but does not lie or race repository writes.
- A future App Server migration is an implementation change behind the published
  runtime endpoint contract, not another orchestration redesign.
- First-class means a supported, independently gated control/runtime path with
  explicit boundaries—not identical team primitives. The exec backend hands a
  verified broker branch to operator/CI; autonomous teammate worktrees,
  merge/push/teardown, and the native remote TUI remain declared gaps.
- Claude launch, hooks, plugin, account rotation, and native TUI are unchanged.
- Failed adoption never leaves an unlaunchable Codex row, and decommissioning
  does not leave the hidden service account authorized to an orphaned repo.

ADR-0020 resolves the eligible topology: one global hidden-UID server behind a
global manager and per-swarm protocol-filtering gateways. Direct/per-swarm
socket exposure is rejected because it cannot preserve approval ownership,
review availability, or the existing single-writer runner boundary.
