#!/usr/bin/env bash
# swarm-rotate-tick.sh — the ROTATION ORCHESTRATOR: on each tick, poll the
# active account's usage and ROUTE to a rotation if (and only if) the verdict
# says so. This is the cadence layer that ties the TRIGGER (swarm-usage-poll.sh)
# to the ACTUATOR (swarm-rotate.sh).
#
# THE MODEL. This deployment runs ONE Max account at a time (see
# swarm-usage-poll.sh / swarm-rotate.sh). Rotation extends wall-clock by swapping
# to the next account before the active one caps. Three scripts, one job each:
#
#   swarm-usage-poll.sh   the DETECTOR — reads usage, exits a verdict code.
#   swarm-rotate.sh       the ACTUATOR — checkpoint + clean-boundary guard +
#                         credential swap + fleet relaunch. Owns ALL mechanism.
#   swarm-rotate-tick.sh  THIS — the ROUTER. It contains NO rotation mechanism.
#                         It runs the poll, branches on the exit code, and on a
#                         rotate-worthy verdict invokes swarm-rotate.sh. That's
#                         it: poll -> decide -> delegate. No keychain, no tmux,
#                         no git here.
#
# ── ROUTING TABLE (poll exit code -> action) ─────────────────────────────────
#   0  OK            do nothing. Plenty of headroom.
#   10 NEAR-LIMIT    ROTATE at the next clean boundary. We invoke swarm-rotate.sh
#                    WITHOUT --force; its own clean-boundary guard refuses (exit 3)
#                    if a swarm is mid-turn — exactly the "rotate at next clean
#                    boundary" semantics. We do not retry; the next tick re-polls.
#   20 AT-LIMIT      ROTATE urgently. The account is already capped/stalling, so
#                    we still go through swarm-rotate.sh (it keeps the checkpoint
#                    discipline). Whether AT forces past a working swarm is the
#                    SWARM_TICK_AT_FORCE knob (default 0 — even "urgent" respects
#                    the clean boundary unless the operator opts in).
#   3  UNKNOWN       do nothing. A probe failure must NEVER trip a rotation
#                    (fail-safe is silence — same rule the poller encodes).
#   2  config-error  do nothing but LOG it. A bad threshold/probe spec is an
#                    operator problem, not a reason to swap credentials.
#   *  other         do nothing; log the unexpected code. Never rotate on a code
#                    we don't understand.
#
# Only 10 and 20 EVER route to a rotation. Everything else is a no-op (0/3) or a
# logged no-op (2/other). This asymmetry is deliberate: the cost of a missed
# rotation is "we hit a cap a little sooner"; the cost of a spurious rotation is
# a whole-fleet restart on a fresh account for no reason. We bias hard toward
# NOT rotating.
#
# ── ACTIVE-ACCOUNT STATE (sourced before, updated after) ─────────────────────
# The "which account is active" fact lives in Phase-3's account-state store
# (bin/swarm-account-state.sh get|set over ~/.config/swarm/active-account).
# This orchestrator:
#   1. Reads it (`... get`) BEFORE rotating and exports SWARM_ACTIVE_ACCOUNT so
#      swarm-rotate.sh computes the correct "next" from a known current.
#   2. After a SUCCESSFUL rotate, asks swarm-rotate.sh which account it landed on
#      (`swarm-rotate.sh --next` computes the same target deterministically) and
#      WRITES it back (`... set <new-active>`) so the next tick starts from the
#      new current. A failed/refused rotate leaves the stored active untouched.
# If the state script is absent/empty we still route correctly — we just can't
# persist the new active (we log that and continue). The state store is advisory
# input + bookkeeping output, never a gate on routing.
#
# ── EVERYTHING EXTERNAL IS AN INJECTABLE COMMAND (so tests stub it) ──────────
# This script performs NO live rotation itself; it only shells out to the three
# scripts below, each overridable so the tests substitute a stub and assert the
# ROUTING without ever polling a real endpoint, swapping a real credential, or
# restarting a real fleet:
#
#   SWARM_POLL_CMD          default "$SCRIPT_DIR/swarm-usage-poll.sh". Run; its
#                           EXIT CODE is the verdict we route on.
#   SWARM_ROTATE_CMD        default "$SCRIPT_DIR/swarm-rotate.sh". The actuator.
#                           Invoked with the routing flags below.
#   SWARM_ACCOUNT_STATE_CMD default "$SCRIPT_DIR/swarm-account-state.sh". Called
#                           as `<cmd> get` and `<cmd> set <account>`.
#   SWARM_LIMIT_DETECT_CMD  default "$SCRIPT_DIR/swarm-limit-detect.sh". The REAL
#                           rate-limit detector. In --observe mode we run it (read-
#                           only) to log the real on-limit signal alongside the
#                           burn estimate. Optional: if absent/unset we just log
#                           the proxy.
#   SWARM_ATTENTION_CMD     Optional. Run via `sh -c` with a one-line reason in $1
#                           to raise the operator attention flag on RING EXHAUSTION
#                           (actuator exit 6). Default: a loud warning + exit 6
#                           only (the canonical attention flag is raised from
#                           inside a swarm session via bin/swarm-attention.sh, or
#                           wired here by the operator).
#
# ── --dry-run ────────────────────────────────────────────────────────────────
# THE ORCHESTRATOR DOES NOT PERFORM A LIVE ROTATION IN THIS BUILD. Even a live
# tick delegates the actual swap to swarm-rotate.sh (which itself refuses without
# SWARM_CREDSWAP_CMD). --dry-run goes further: it LOGS the verdict and the action
# it WOULD take and invokes NOTHING that mutates state — it does not call the
# rotate actuator and does not write the account-state store. It still runs the
# poll (read-only) so the operator sees the real verdict the cadence would act on.
#
# ── --observe (CALIBRATION mode) ─────────────────────────────────────────────
# Before enabling live rotation, the operator needs to know whether the token
# BUDGETS (SWARM_5H_TOKEN_BUDGET / SWARM_WEEKLY_TOKEN_BUDGET) match reality. In
# --observe mode each tick:
#   * runs the poll with --json and logs the estimated burn-vs-budget,
#   * runs the REAL limit detector (read-only) and logs whether a real cap was
#     observed (so you can compare "my budget says NEAR" against "the pane
#     actually showed a limit"),
#   * ROTATES NOTHING and writes NO state.
# Run it on the same cadence the live tick would use (e.g. a launchd interval,
# logging to a file) for a few days, then tune the budgets so NEAR fires shortly
# BEFORE the real limit, and only then drop --observe to go live. This is the
# observe -> calibrate -> enable sequence. --observe implies no mutation, like
# --dry-run, but it ALSO logs the real signal and never even computes a rotation
# target (it is purely a measurement tick).
#
# Sample --observe log line (one per tick; fields are stable for easy grep/awk):
#   swarm-rotate-tick: OBSERVE ts=2026-06-14T19:40:02Z proxy_verdict=NEAR proxy_exit=10 \
#     five_hour_pct=88 weekly_pct=41 worst_pct=88 worst_window=5h threshold_pct=85 \
#     account=max-a real_signal=OK real_exit=0 would_rotate=yes (NOT rotating: observe-mode)
#
# Usage:
#   swarm-rotate-tick.sh                # one tick: poll, route, maybe rotate
#   swarm-rotate-tick.sh --observe      # CALIBRATION tick: log burn-vs-budget +
#                                       # real signal; rotate NOTHING, write NO state
#   swarm-rotate-tick.sh --dry-run      # one tick: poll + log the plan; mutate NOTHING
#   swarm-rotate-tick.sh --quiet        # exit code only, minimal logging
#   swarm-rotate-tick.sh -h | --help
#
# Exit codes (the tick's own outcome — distinct from the poll's verdict code):
#   0 — tick handled cleanly: no rotation was needed (OK/UNKNOWN), OR a rotation
#       was needed and the actuator returned 0 (rotated), OR --dry-run.
#   3 — a rotation was warranted but the actuator REFUSED at the clean-boundary
#       guard (poll said NEAR/AT, swarm-rotate.sh exited 3). Not an error — the
#       fleet was working; the next tick retries. Surfaced distinctly so a
#       launchd log / operator can see "wanted to rotate, waited for boundary".
#   4 — a rotation was warranted and the actuator FAILED for some other reason
#       (checkpoint/credswap/relaunch non-zero). The active-account store is left
#       unchanged. Operator should check swarm-rotate.sh's output.
#   2 — the poll reported a config error (exit 2): we logged it and did nothing.
#   6 — RING EXHAUSTED: the actuator reported the rotate target authenticates but
#       is itself rate-limited (swarm-rotate exit 6) — EVERY reachable account is
#       capped, so rotation has nowhere fresh to go. This is a TERMINAL state, NOT
#       a retry: we ESCALATE (raise the attention flag via SWARM_ATTENTION_CMD if
#       wired) and STOP. We do NOT re-rotate next tick (that would thrash). The
#       operator must add capacity or wait for a reset, then clear the flag.
#
# bash 3.2-safe (macOS default). CWD-independent. This script NEVER reads or
# writes a real credential, never restarts anything itself, and does no git.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Injectable seams — every external dependency is an overridable command so the
# tests stub them. Defaults point at the sibling scripts in this same bin/.
POLL_CMD="${SWARM_POLL_CMD:-$SCRIPT_DIR/swarm-usage-poll.sh}"
ROTATE_CMD="${SWARM_ROTATE_CMD:-$SCRIPT_DIR/swarm-rotate.sh}"
STATE_CMD="${SWARM_ACCOUNT_STATE_CMD:-$SCRIPT_DIR/swarm-account-state.sh}"
LIMIT_DETECT_CMD="${SWARM_LIMIT_DETECT_CMD:-$SCRIPT_DIR/swarm-limit-detect.sh}"

# Whether an AT-LIMIT (already-capped) verdict forces a rotation past a working
# swarm. Default 0: even "urgent" respects the clean boundary unless the operator
# explicitly opts in. NEAR never forces.
AT_FORCE="${SWARM_TICK_AT_FORCE:-0}"

usage() { sed -n '1,90p' "$0"; exit "${1:-0}"; }

DRY_RUN=0
QUIET=0
OBSERVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --observe) OBSERVE=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "swarm-rotate-tick: unknown flag: $1" >&2; usage 2 ;;
    *)         echo "swarm-rotate-tick: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

# log — one place owns this script's chatter. --quiet silences the informational
# lines; warnings/errors still go to stderr regardless (an operator scanning the
# launchd log needs to see a config error even under --quiet).
log()  { [ "$QUIET" -eq 1 ] || printf 'swarm-rotate-tick: %s\n' "$*"; }
warn() { printf 'swarm-rotate-tick: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1) POLL — run the trigger; its exit code is the verdict we route on.
# ---------------------------------------------------------------------------
# We capture the poll's own stdout for the log but route ONLY on its exit code
# (the contract: 0/10/20/3/2). The poll is read-only — it never mutates anything.
POLL_OUT="$(sh -c "$POLL_CMD" 2>&1)"; poll_rc=$?
[ -n "$POLL_OUT" ] && log "poll: $POLL_OUT"

# Map the poll exit code to a stable verdict WORD (used by the log line + observe).
verdict_word() {
  case "$1" in
    0)  echo OK ;;  10) echo NEAR ;;  20) echo AT ;;
    3)  echo UNKNOWN ;;  2) echo CONFIG-ERROR ;;  *) echo "exit-$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1b) OBSERVE / CALIBRATE — measure, do not rotate.
# ---------------------------------------------------------------------------
# Emit ONE stable, greppable line of estimated-burn-vs-budget (from the poll's
# --json) plus the REAL limit signal (from the limit detector), then exit. We
# ROTATE NOTHING and write NO state. This lets the operator tune the token budgets
# against observed reality before enabling live rotation (observe -> calibrate ->
# enable). It does not even compute a rotation target — it is purely a measurement.
if [ "$OBSERVE" -eq 1 ]; then
  pv="$(verdict_word "$poll_rc")"
  # Structured burn-vs-budget fields from the poll's JSON (best-effort; an
  # UNKNOWN/error poll yields blanks, which is itself a useful observation).
  POLL_JSON="$(sh -c "$POLL_CMD --json" 2>/dev/null || true)"
  metrics="$(printf '%s' "$POLL_JSON" | python3 -c '
import json,sys
try:
    d=json.loads(sys.stdin.read() or "{}")
except Exception:
    d={}
def g(k):
    v=d.get(k)
    return "" if v is None else v
print("five_hour_pct=%s weekly_pct=%s worst_pct=%s worst_window=%s threshold_pct=%s account=%s" % (
    g("five_hour_pct"), g("weekly_pct"), g("worst_pct"), g("worst_window"),
    g("threshold_pct"), g("account")))
' 2>/dev/null)"
  [ -z "$metrics" ] && metrics="five_hour_pct= weekly_pct= worst_pct= worst_window= threshold_pct= account="

  # Real limit signal (read-only). If the detector is missing/unrunnable we log
  # real_signal=n/a rather than fail the observe tick.
  if [ -n "$LIMIT_DETECT_CMD" ] && sh -c ": >/dev/null"; then
    REAL_OUT="$(sh -c "$LIMIT_DETECT_CMD" 2>/dev/null)"; real_rc=$?
    case "$real_rc" in
      20) real_word=AT ;;  0) real_word=OK ;;  3) real_word=UNKNOWN ;;
      127) real_word=n/a; real_rc="" ;;  *) real_word="exit-$real_rc" ;;
    esac
  else
    real_word=n/a; real_rc=""
  fi

  # would_rotate reflects what the LIVE tick WOULD do on this verdict — the whole
  # point of calibration is to compare "would_rotate" against "real_signal".
  case "$poll_rc" in 10|20) would="yes" ;; *) would="no" ;; esac

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  log "OBSERVE ts=$ts proxy_verdict=$pv proxy_exit=$poll_rc $metrics real_signal=$real_word real_exit=${real_rc} would_rotate=$would (NOT rotating: observe-mode)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2) ROUTE — branch on the verdict. Only NEAR(10)/AT(20) reach a rotation.
# ---------------------------------------------------------------------------
ROTATE_REASON=""     # non-empty => we intend to rotate; holds the reason word
ROTATE_FORCE=0       # 1 => pass --force to the actuator (AT + opt-in only)
case "$poll_rc" in
  0)
    log "verdict OK (exit 0) — headroom remains; no rotation."
    exit 0
    ;;
  10)
    ROTATE_REASON="NEAR-LIMIT"
    ROTATE_FORCE=0    # NEAR rotates at the next CLEAN boundary; never forces.
    ;;
  20)
    ROTATE_REASON="AT-LIMIT"
    if [ "$AT_FORCE" = "1" ]; then ROTATE_FORCE=1; else ROTATE_FORCE=0; fi
    ;;
  3)
    log "verdict UNKNOWN (exit 3) — probe failure; fail-safe, no rotation."
    exit 0
    ;;
  2)
    warn "poll reported a CONFIG ERROR (exit 2) — not rotating. Fix the threshold/probe spec."
    exit 2
    ;;
  *)
    warn "poll returned an UNEXPECTED code ($poll_rc) — not rotating (only NEAR/AT trip a rotation)."
    exit 0
    ;;
esac

log "verdict $ROTATE_REASON (exit $poll_rc) — a rotation is warranted."

# ---------------------------------------------------------------------------
# 3) STATE (before) — read the active account, export it for the actuator.
# ---------------------------------------------------------------------------
# swarm-rotate.sh computes "next" from SWARM_ACTIVE_ACCOUNT; feed it the stored
# current so the ring math is correct. An empty/failed read is non-fatal: the
# actuator cold-starts onto the first ring member if active is unset.
ACTIVE_BEFORE="$(sh -c "$STATE_CMD get" 2>/dev/null)" || ACTIVE_BEFORE=""
ACTIVE_BEFORE="$(printf '%s' "$ACTIVE_BEFORE" | tr -d '[:space:]')"
if [ -n "$ACTIVE_BEFORE" ]; then
  log "active account (before): '$ACTIVE_BEFORE' (from account-state store)"
else
  log "active account (before): <unknown> — actuator will cold-start onto the ring's first."
fi

# Compute the target the actuator WILL rotate to, deterministically, via the
# same code path the actuator uses (`swarm-rotate.sh --next`). We use this only
# for logging and for the post-rotate state write — the actuator independently
# recomputes it, so the two cannot disagree.
NEXT_ACCOUNT="$(SWARM_ACTIVE_ACCOUNT="$ACTIVE_BEFORE" sh -c "$ROTATE_CMD --next" 2>/dev/null | tail -n1)"
NEXT_ACCOUNT="$(printf '%s' "$NEXT_ACCOUNT" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 4) DRY-RUN — log the plan, mutate NOTHING. No actuator, no state write.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  _force_note=""
  [ "$ROTATE_FORCE" -eq 1 ] && _force_note=" (with --force)"
  log "DRY-RUN — WOULD rotate '${ACTIVE_BEFORE:-<unknown>}' -> '${NEXT_ACCOUNT:-<computed-by-actuator>}'${_force_note} via the actuator, then record the new active."
  log "DRY-RUN — performing NOTHING live (no swap, no fleet restart, no state write)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5) ROTATE — delegate to the actuator. ALL mechanism lives there.
# ---------------------------------------------------------------------------
# We pass --force only for the AT + opt-in case. The actuator owns the
# clean-boundary guard, checkpoint, credential swap, and fleet relaunch. We never
# do any of that here. The actuator inherits SWARM_ACTIVE_ACCOUNT (exported) so
# its ring math matches what we logged above.
if [ "$ROTATE_FORCE" -eq 1 ]; then
  log "invoking actuator to rotate (--force)."
  ROTATE_OUT="$(SWARM_ACTIVE_ACCOUNT="$ACTIVE_BEFORE" sh -c "$ROTATE_CMD --force" 2>&1)"; rot_rc=$?
else
  log "invoking actuator to rotate (clean-boundary; no --force)."
  ROTATE_OUT="$(SWARM_ACTIVE_ACCOUNT="$ACTIVE_BEFORE" sh -c "$ROTATE_CMD" 2>&1)"; rot_rc=$?
fi
[ -n "$ROTATE_OUT" ] && log "actuator: $ROTATE_OUT"

# ---------------------------------------------------------------------------
# 6) OUTCOME — map the actuator's result; update state ONLY on a clean success.
# ---------------------------------------------------------------------------
case "$rot_rc" in
  0)
    # Rotated. Persist the new active so the next tick starts from it. If we
    # couldn't compute the target (rare — actuator's --next failed), fall back to
    # re-reading the store after the rotate is out of scope here, so we log a
    # warning rather than guess. A bad state write is non-fatal to THIS tick.
    if [ -n "$NEXT_ACCOUNT" ]; then
      if sh -c "$STATE_CMD set '$NEXT_ACCOUNT'" >/dev/null 2>&1; then
        log "rotated -> '$NEXT_ACCOUNT'; recorded as the new active account."
      else
        warn "rotated -> '$NEXT_ACCOUNT' but FAILED to persist it to the account-state store. Next tick may recompute from a stale active."
      fi
    else
      warn "rotated, but could not determine the new active account to persist (actuator --next gave nothing). Account-state store left unchanged."
    fi
    exit 0
    ;;
  3)
    # Clean-boundary refusal. Not an error: a swarm was working. Next tick retries.
    log "actuator REFUSED at the clean-boundary guard (a swarm is working) — will retry next tick. State unchanged."
    exit 3
    ;;
  6)
    # RING EXHAUSTED — the actuator rotated to a target that authenticates but is
    # itself rate-limited; every reachable account is capped. This is TERMINAL,
    # not a retry: re-rotating next tick would thrash across a ring of capped
    # accounts. We ESCALATE and STOP. The account-state store is left whatever the
    # actuator left it (the swap was kept — the credential is valid, just capped).
    warn "RING EXHAUSTED — actuator reports the rotate target authenticates but is RATE-LIMITED (exit 6); every reachable account is capped. Rotation has nowhere fresh to go."
    _reason="swarm rotation RING EXHAUSTED — every account in the ring is rate-limited; the fleet has no un-capped account to rotate to. Add capacity or wait for a reset."
    if [ -n "${SWARM_ATTENTION_CMD:-}" ]; then
      if sh -c "${SWARM_ATTENTION_CMD}" _ "$_reason" >/dev/null 2>&1; then
        warn "raised operator attention flag (SWARM_ATTENTION_CMD)."
      else
        warn "SWARM_ATTENTION_CMD FAILED — ring exhaustion is UN-escalated. Operator must intervene manually."
      fi
    else
      warn "no SWARM_ATTENTION_CMD wired — ring exhaustion is surfaced on stderr/exit-6 only. Wire it (e.g. to bin/swarm-attention.sh from inside a swarm session) so a capped ring raises the attention flag the iOS widget consumes."
    fi
    warn "TERMINAL — NOT retrying the rotation (would thrash across a capped ring). Operator action required."
    exit 6
    ;;
  *)
    warn "actuator FAILED (exit $rot_rc) — rotation did not complete. Account-state store left unchanged. Check the actuator output above."
    exit 4
    ;;
esac
