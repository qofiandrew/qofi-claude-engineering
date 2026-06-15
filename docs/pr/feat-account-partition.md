# feat: hybrid multi-account — partition by config + cap-triggered failover (ADR-0018)

> **Merging this changes no fleet behavior.** Every new code path is gated on a non-empty `swarm.conf` `ACCOUNT` field, and all real rows ship empty. Going live is a separate, later, **operator-only, terms-gated** action the build never performs. See *What it does NOT do* and *Go-live prerequisites* below.

## What it does

Builds a **hybrid multi-account model** on the single-Max-account fleet:

- **Partition by config (throughput).** A 6th `swarm.conf` field, `ACCOUNT`, pins each swarm to an account. N labelled accounts run N partitions **concurrently** — the throughput axis one account + rotation could never give.
- **Cap-triggered per-account failover (resilience).** When an account caps, **only that account's swarms** move to the **least-recently-capped non-capped account** and restart; every other swarm stays put. A capped account no longer stalls its swarms.
- **Rotation is RETAINED as the failover layer, not retired.** The clean-boundary / checkpoint / auth-probe / ring-exhaustion contracts of the existing rotation subsystem are reused, not replaced.

**ADR-0018 supersedes ADR-0016** (single-active-account framing) and **amends ADR-0004** — reversing the multi-account rejection, with the per-member-terms concern **addressed head-on as a terms-gated activation, not resolved away**.

v1 = Phases 1–3. The per-account telemetry selector is Phase 4 (a documented seam, **not built** — see below).

## What it does NOT do — the safety story

**Provably inert behind the empty default.** With every `ACCOUNT` field empty (the shipped state), fleet behavior is **byte-identical to today**:

- The resolver's default branch preserves the `CLAUDE_PROJECTS_DIR` / `SWARM_ACCESS_FILE` overrides every consumer honors today.
- Pinned by tests, not asserted: the repo-wide **sole-constructor grep-assert** (`swarm_account_resolve` is the only builder of `~/.claude` paths) + the **empty-label byte-identity** tests, and the legacy global-clock router path proven byte-identical (POLL-to-EOF diff empty).
- The adversarial review confirmed this across all 5 dimensions.

**It does not activate anything.** It never labels a row, never provisions an account, never writes a real token. **Merging is safe and reversible**; activation is the operator's separate call.

## Go-live prerequisites (operator, terms-gated — the build never performs these)

1. **Anthropic TERMS clearance** for running more than one Max subscription in concurrent automation. This is **gate zero**. ADR-0004's per-member-limits concern is *reversed only as a terms-gated activation*, **not resolved** — the build deliberately stops before crossing it.
2. **Label accounts + provision** each account's isolated config dir (`~/.claude-accounts/<label>`) + its `OAUTH_TOKEN_<LABEL>` in the vault.
3. **F1 — scope each pane to its OWN `OAUTH_TOKEN_*` before real tokens land.** Today the pane env sources the *whole* `tokens.env`, so every pane can read every token var. Harmless while inert; **this is the one hard go-live prerequisite.** Recorded in **ADR-0018 §Consequences** and the PROJECT_SPEC §10 build log.

## Provisioning caveat

`OAUTH_TOKEN_<LABEL>` is derived with `'-'→'_'`, so two labels differing **only** by `-` vs `_` (`max-a` vs `max_a`) collide to the **same vault var** while keeping distinct config dirs — a wrong-credential risk. **Pick labels that are distinct after the `-`/`_` fold.** (Documented in the resolver comment + ADR-0018.)

## What's in the diff

New scripts (each behind an injectable seam, each unit-tested in isolation):

- **`bin/swarm-account.sh`** — per-swarm swap actuator: validate → provision-check → **auth-probe the target** (reuses `swarm-auth-probe` 0/1/75; never moves onto a dead or capped token) → checkpoint → atomic field-6 rewrite → restart, with **revert on a clean-boundary refusal** and a `--reset` escape hatch.
- **`bin/swarm-failover-target.sh`** — v1 fallback selector: least-recently-capped round-robin among non-capped accounts; never targets a capped/excluded/source account; ring-exhaustion terminal. Hysteresis lives behind the unwired `SWARM_ACCOUNT_HEADROOM_CMD` seam and **never blocks an evacuation** (the carve-out).
- **`swarm_conf_set_account`** (`swarm-lib.sh`) — atomic, arity-safe field-6 rewrite (the failover persistence).

Retargeted additively (legacy paths byte-unchanged):

- **`swarm-limit-detect.sh --by-account`** — per-account cap grouping (no early break).
- **`swarm-rotate-tick.sh --failover`** — detect → select → swap router; spreads a capped account's swarms across targets, writes per-account LRC markers, handles the exit-7 capped-target race (bounded), escalates ring-exhaustion (exit 6). Default global-clock mode is gated out and byte-identical.

Also: pre-emptive resolver rc-check in `swarm-add.sh` / `swarm-bus-wire.sh` (no-op today, fail-safe for a future `--account` flag); ADR-0018 + reciprocal pointers on 0016/0004; PROJECT_SPEC §10 build log + operator runbook delta.

## Phase 4 — not built; documented seam

Per-account `ccusage` telemetry → a headroom signal via `SWARM_ACCOUNT_HEADROOM_CMD`, swapping v1's least-recently-capped fallback for **true lowest-use** via `SWARM_FAILOVER_TARGET_CMD`. **Additive, zero rework** — the hysteresis path and its evacuation carve-out already exist and are tested behind the seam.

## Verification

Adversarial review (5 dimensions, every High/Medium finding independently refute-verified): **4/5 SOLID, zero findings** — swap never moves onto a bad account (swept 10 exit codes); a WORKING swarm is un-killable without operator `--force`; default path byte-identical; **gitleaks + semgrep clean**; no secret leak or `sh -c` injection. One Medium (R1-1, leading-zero headroom → bash-3.2 octal fall-through bypassing the hysteresis gate) **found, fixed (base-10 coercion + fail-safe guard + regression test), re-verified under `/bin/bash` 3.2.57**.

**Gate state: bun 142/0, shell 38/38 under bash 3.2. 4 commits. Real `swarm.conf` rows untouched. Branch-only.**

- `81cc02c` P1 — `ACCOUNT` field + resolver (sole constructor; empty = default, byte-identical)
- `1375ba6` P2 — thread all consumers through the resolver (per-swarm WORKING-rail projects)
- `c965854` — fail-safe every WORKING-rail resolve on a rejected account (Phase-2 Finding 1)
- `2cbb275` P3 — cap-triggered per-account failover + swap actuator (ADR-0018)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
