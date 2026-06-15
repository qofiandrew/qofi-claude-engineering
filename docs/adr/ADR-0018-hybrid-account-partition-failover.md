# ADR-0018 — Hybrid multi-account: partition by config + cap-triggered failover

**Status:** accepted
**Date:** 2026-06-15
**Reversibility:** two-way at rest (inert behind an empty default); one-way only at
the moment the operator provisions real accounts (a terms-cleared action).
**Escalated:** yes (batched) — the multi-account posture reverses ADR-0004's
rejection, so the operator confirmed the §6 model and the phased build.
**Supersedes:** ADR-0016
**Amends:** ADR-0004

---

## Context

ADR-0016 settled the fleet on **one active Max account plus rotation**: when the
active account caps, the whole fleet rotates to a fresh account and the prior one
cools down. That treats the usage limit as a **duration** problem and reclaims
headroom in time rather than withholding concurrency. It explicitly rejected
(option *c*) "multiple simultaneous active accounts" as concurrency-multiplication
that "re-raises the per-member-limits concern ADR-0004 flagged." ADR-0004 likewise
rejected "multiple Max accounts to multiply quota — against the spirit of
per-member limits; not a foundation to build on."

Two facts have shifted the calculus without invalidating that concern:

1. **The bottleneck ADR-0016 predicted arrived.** With concurrency uncapped inside
   one window, a *single* account's 5h/weekly limit is now the throughput ceiling —
   one account cannot feed the whole fleet through a full week.
2. **The two uses of multiple accounts are different decisions.** ADR-0016 conflated
   them. *Failover* rotation (one account active at a time, move when it caps) is
   resilience and was already accepted. *Partition* (different swarms pinned to
   different accounts, producing **concurrently**) is throughput — and that is the
   piece ADR-0004/0016 rejected on per-member-terms grounds.

The per-member-terms concern is **real and is not waved away here**. What changed is
that it is now treated as an **activation gate the build never crosses**, not as a
reason to leave the capability unbuilt. The mechanism can exist, fully tested and
inert, while the decision to run more than one real Max subscription in concurrent
automation remains a deliberate, operator-only, terms-cleared act.

## Decision

We will build a **hybrid multi-account model** with two orthogonal axes:

- **Partition by config (throughput).** Each swarm pins to an account via a 6th
  `swarm.conf` field, `ACCOUNT`. N labelled accounts run N partitions
  **concurrently**. An **empty** `ACCOUNT` is the default account — today's single
  keychain-auth pool — so an all-empty fleet is byte-for-byte unchanged.
- **Cap-triggered failover (resilience).** When an account caps, only the swarms on
  *that* account move to a non-capped account and restart; every other swarm stays
  put. This is **rotation retained as the failover layer**, not retired —
  superseding ADR-0016's single-active-account framing while keeping its
  clean-boundary / checkpoint / ring-exhaustion contracts intact and reused.

This **reverses ADR-0004's and ADR-0016's rejection of multiple concurrent
accounts**, with the per-member-terms concern addressed head-on rather than deleted:

- **Activation is terms-gated and operator-only.** The build ships **inert**: every
  new code path is gated on a non-empty `ACCOUNT` label, and the real `swarm.conf`
  rows ship empty. Going live requires the operator to (a) label accounts, (b)
  provision each account's isolated config dir, and (c) put each account's
  `OAUTH_TOKEN_<LABEL>` in the vault. **The build performs none of these.** Until
  they are done, the fleet runs exactly as ADR-0016 left it.
- The single-active-pool framing of ADR-0004/0016 is amended, not erased: with an
  empty partition the fleet *is* single-pool-plus-rotation, exactly as before.

### Scope built (v1 = Phases 1–3)

- **Substrate (net-new):** `ACCOUNT` field + `swarm_account_resolve` (the sole
  constructor of every `~/.claude` path) + `swarm_conf_set_account` (atomic field-6
  rewrite). All consumers thread the resolver per-swarm.
- **Per-swarm swap actuator:** `swarm-account.sh` — validate → provision-check →
  auth-probe target → checkpoint → atomic rewrite → restart, with revert on a
  clean-boundary refusal and a `--reset` escape hatch.
- **Per-account detection:** `swarm-limit-detect.sh --by-account` groups live swarms
  by account and reports each account's cap verdict.
- **Failover target selector (v1 = fallback behind a seam):**
  `swarm-failover-target.sh` picks a non-capped, least-recently-capped account;
  never targets a capped one; ring-exhaustion is terminal.
- **Router:** `swarm-rotate-tick.sh --failover` composes detect → select → swap,
  spreading a capped account's swarms across targets. The legacy global-clock
  whole-fleet path is unchanged (default mode).

### Seams left for Phase 4 (NOT built)

- **True lowest-use selection.** v1's selector is least-recently-capped round-robin.
  The Phase-4 per-account telemetry collector feeds a real headroom signal via
  `SWARM_ACCOUNT_HEADROOM_CMD`; swapping the selector in via
  `SWARM_FAILOVER_TARGET_CMD` is additive, zero rework.
- **Hysteresis** (a headroom-margin damper on *proactive* not-yet-capped moves)
  exists behind that seam and is inert without telemetry. Its load-bearing safety
  property is the **evacuation carve-out**: hysteresis gates only proactive moves and
  **never blocks evacuating a capped swarm** (a capped swarm has zero headroom and
  must move regardless of margin). The carve-out is structural — evacuation never
  consults headroom — and is pinned by test.

### Tightening decisions recorded here

- **State separation (tightening #3).** `swarm-account-state.sh` is **kept as-is**
  for the legacy global-clock path's whole-fleet *active account*. The per-account
  **last-recently-capped (LRC)** store the selector needs is a **separate, orthogonal**
  marker directory (`SWARM_ACCOUNT_CAPS_DIR`, default `~/.config/swarm/account-caps`,
  one mtime-marker per account, written by the router on cap-detect). Neither
  repurposing nor deprecating the existing store: "which account is active globally"
  and "when did account X last cap" are different facts and stay in different files.
- **Persistence = the conf rewrite.** A swap rewrites just that swarm's field-6; it
  sticks across restarts until the next cap. `swarm-account.sh --reset` restores the
  pre-failover split from a gitignored sidecar snapshot captured at the first swap
  (no snapshot → churn-free no-op).

## Reversibility & cost of change

**Two-way at rest.** With an empty partition the entire mechanism is inert and the
fleet is byte-identical to ADR-0016; backing the feature out is deleting branch code
nothing on the real config exercises. The byte-identity is enforced, not asserted:
the default account resolves through the same `swarm_account_resolve` as labelled
ones, and a repo-wide grep-assert pins it as the sole path constructor.

**One-way only at activation.** The moment the operator provisions a second real Max
subscription and points concurrent automation at it, that is the terms-relevant,
hard-to-walk-back step ADR-0004 flagged. The build deliberately stops at the seam
before it. Reversing *after* activation means collapsing back to one account
(`--reset` + de-provision) — operationally cheap, but the terms question will already
have been answered.

## Consequences

- **Co-location dissolves after the first cap.** Spread-greedy evacuation + stay-put
  persistence means a group of swarms intentionally co-located on one account is
  permanently *de*-co-located the first time that account caps: each swarm lands on
  whatever target was least-recently-capped at the moment it evacuated, and stays
  there (the rewrite is the persistence). There is no rebalance-home step in v1.
  `--reset` is the only way back to the configured split, and it is manual. If
  co-location matters (e.g. a shared-rate-window assumption), the operator must
  re-assert it deliberately.
- **Per-pane token isolation is a go-live gap (Phase-2 Finding F1).** The pane env
  sources the whole `tokens.env` vault, so every pane can see every
  `OAUTH_TOKEN_*`, not just its own account's. This is harmless while inert (no real
  tokens) but is a **go-live runbook item**: before real tokens land, scope each pane
  to only its own `OAUTH_TOKEN_<LABEL>` (e.g. export just the resolved token var,
  not `set -a; . tokens.env`). Recorded here so activation does not silently ship a
  shared-vault pane.
- **Account-label provisioning footgun.** The vault token var is derived
  `OAUTH_TOKEN_<LABEL_UPPER>` with `'-'→'_'`, so two labels differing only by `-`
  vs `_` (`max-a` / `max_a`) collapse to the *same* token var while keeping distinct
  config dirs — a wrong-credential risk. Go-live runbook item: account labels must
  be unique after the `-`/`_` fold (the provisioning step should reject a collision).
- **The WORKING rail is now account-aware everywhere.** Every per-swarm liveness probe
  resolves *that swarm's* account's projects dir; a malformed label fails safe
  (skip / treat-as-working / refuse), never reads a stale/foreign dir (Phase-2
  Finding 1). A miss here silently kills live swarms, so it is covered by the
  adversarial review gate and regression tests.
- **More moving parts in the rotation subsystem.** Three new scripts plus a new tick
  mode. Mitigated by keeping each behind an injectable seam (so each is unit-tested in
  isolation) and leaving the legacy global-clock path untouched.
- **Upside:** N accounts produce concurrently (throughput) *and* a capped account no
  longer stalls its swarms (resilience) — the two things one-account-plus-rotation
  could not give at once.

## Alternatives considered

- **(a) Keep ADR-0016 single-active-account + rotation** — rejected: one account's
  weekly window cannot feed the whole fleet; the predicted throughput ceiling arrived.
- **(b) Partition only, no failover** — rejected: a capped partition would simply
  stall its swarms with no recovery; resilience needs the failover layer.
- **(c) Failover only, no partition (literally ADR-0016)** — rejected: that is the
  status quo; it gives resilience but not concurrent throughput across accounts.
- **(d) Rewrite a runtime override file instead of `swarm.conf`** — rejected: a
  separate override consulted by every consumer is a larger change than the field-6
  rewrite and splits the source of truth; the conf rewrite (with a snapshot for
  `--reset`) keeps `swarm.conf` authoritative.
- **(e) Build the lowest-use telemetry selector now** — rejected as v1 scope: it needs
  the per-account `ccusage` collector (Phase 4). The fallback selector behind the seam
  ships resilience today; the telemetry selector drops in additively later.
- **(f) Ship the partition active (label the real rows now)** — rejected: that crosses
  the per-member-terms activation gate, which is the operator's call, not the build's.
  Inert-behind-empty-default is the whole point.
