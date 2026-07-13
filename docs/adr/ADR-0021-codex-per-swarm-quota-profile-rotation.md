# ADR-0021 — Rotate isolated Codex profiles per swarm from local quota evidence

**Status:** accepted
**Date:** 2026-07-12
**Supersedes:** ADR-0019/ADR-0020 statements that Claude account rotation is the
only rotation path and that Codex has one immutable credential home. It does not
supersede their global manager, hidden-UID, cleanup, or read-only-view decisions.

## Context

Claude Code's OAuth session is device-global. Re-authentication changes account
state for every Claude process which adopts that credential, so its rotation
actuator is necessarily fleet/account oriented. Codex subscription auth and
sessions can instead live in separate `CODEX_HOME` directories. Treating Codex
like Claude would discard that isolation and would let one swarm's quota event
restart or move unrelated swarms.

The existing Codex topology has one root-attested hidden UID, one runner lock,
one operator manager, and at most one App Server generation. It already stops
and reaps a terminal generation before accepting the daemon's cleanup proof.
That proven boundary is where a different complete `CODEX_HOME` can be selected;
mutating `CODEX_HOME` or `auth.json` in a live process is not allowed.

Pinned Codex 0.144.1 persists subscription windows in the latest physical
`event_msg/token_count` rollout record. A snapshot may be null, and
`primary`/`secondary` do not identify a fixed duration. The 5-hour and weekly
windows are identified by `window_minutes == 300` and `10080` respectively.

## Decision

1. `swarm.conf` field 8 is `CODEX_AUTH_POOL`. It names a pool in the non-secret
   exact-schema `codex-profiles.json`. Field 6 `ACCOUNT` remains Claude-only;
   `CODEX_PROFILE` remains the unrelated Codex config-profile feature and is
   still refused by the managed App Server path.
2. A registry profile is a non-secret handle matching
   `[a-z][a-z0-9_-]{0,31}`. `default` maps to the existing hidden user's
   `.codex`; named handles map to `.codex-profiles/<handle>`. Auth, sessions,
   and rollout history switch together. Rotation state is never written into a
   profile home.
3. Each swarm leases one ordered-pool profile. Profiles are exclusive unless
   the registry explicitly sets `shared: true`. The manager persists a global
   lease/state snapshot and a sanitized per-swarm `rotation-state.json` mirror.
   A rotation updates only the triggering swarm object, registration, facade,
   and subsequent generation. It never rewrites another swarm's lease, thread
   map, pane, or retry ledger.
4. The manager binds the selected profile into the reservation and terminal
   lease. Before a turn, an idle profile change stops/reaps the old generation
   and starts the fixed root runner with only the selected handle. After a
   terminal turn, the manager first reaps the generation, samples telemetry,
   waits for the daemon's ACL/session/repository cleanup acknowledgement, then
   commits the lease change and respawns. This is drain-then-respawn at task
   boundaries; there is no mid-task rotation.
5. After every run, the fixed runner reads only the selected home's newest
   `sessions/**/rollout-*.jsonl`, selected by file mtime and then physical line
   order. It uses no-follow/inode/size/change checks and emits only timestamp and
   sanitized rate-limit windows. Prompts, token counts, auth, account identity,
   paths, and response content cannot cross the runner output. No OpenAI usage
   endpoint is called.
6. Telemetry is fresh for at most 30 minutes. The physically latest token-count
   wins: `rate_limits: null`, stale, future, malformed, or zero recognized
   windows is unknown. A snapshot with one recognized window is partially fresh;
   that known window may trigger while the missing window remains unknown.
   Unknown telemetry alone never rotates and remains an eligible fallback.
7. A pool threshold defaults to 95 percent and is inclusive. A fresh known
   5-hour or weekly window at or above threshold cools that profile through the
   latest breached reset and selects the eligible profile with most known
   headroom. Known headroom outranks unknown; pool order breaks ties.
8. A structured App Server `usageLimitExceeded` or HTTP-429-class terminal
   failure is a hard trigger. It cools through the known reset, or one 5-hour
   fallback window when no reset is known. After cleanup it requeues the same
   Discord task inside the active serial job, so another queued task cannot
   overtake an immediately available retry. Retries are bounded to 16 profile
   attempts. Arbitrary error prose is not promoted to structured hard evidence.
9. If every profile is cooling or exclusively leased, the swarm parks until the
   earliest known reset (or bounded backoff when no reset is knowable) and
   releases the turn/repository boundary. An owner-private `parked-turns.json`
   stores only the original Discord message/channel identifiers, authorization
   binding, retry time, and bounded attempt. After reset—or daemon restart—the
   daemon revalidates authorization, refetches that original message, and
   requeues it; prompts, attachment URLs, credentials, and tokens are never
   persisted in the ledger. Discord announces rotation or parking only after
   local cleanup, using profile labels and reset time only.
10. Session persistence is keyed by `(chat_id, profile_id)`. Switching profiles
    changes the facade's active thread set and never attempts to resume a thread
    from another home. The native viewer reads the active profile from the
    sanitized rotation mirror.
11. `codex status` renders the active profile, per-profile headroom, lease map,
    cooldowns, and parked reset from the per-swarm mirror. It never renders
    credential bytes or account identity.

## Consequences

- Rotation extends quota duration and failover but not parallel App Server
  capacity: the existing global manager and root-runner lock still serialize
  hidden-UID Codex work.
- Complete profile homes are operationally isolated, but they share one hidden
  UID. This decision does not claim OS-credential isolation between profiles;
  separate UIDs/managers would be required for that stronger boundary.
- Every profile referenced by an active pool must be initialized first with
  `swarm-codex-runtime.sh login --profile <handle>` and verified with the matching
  `verify --profile` command. A missing/unsafe auth home fails closed.
- Claude launch, device-global account rotation, hooks, panes, and credentials
  are unchanged. Codex field 8 and registry parsing are independent of Claude
  field 6 and all Claude rotation scripts continue to exclude Codex rows.

## Verification contract

Tests cover exact registry validation; fresh, weekly-only, null, stale,
malformed, and physical-order rollout fixtures; inclusive threshold decisions;
structured hard-trigger cooldown/requeue; exclusive and explicitly shared
leases; pool exhaustion; profile-scoped sessions; manager cleanup-before-switch;
and a two-swarm state simulation proving that rotating one swarm leaves the
other lease and state byte-equivalent.
