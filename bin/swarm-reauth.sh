#!/usr/bin/env bash
# swarm-reauth.sh — the NO-RESTART rotation actuator. Slots into the rotation
# tick's SWARM_ROTATE_CMD seam (swarm-rotate-tick.sh) exactly where swarm-rotate.sh
# used to sit, but expresses a fundamentally different model: re-authenticate the
# fleet's SHARED credential in place — WITHOUT checkpointing, WITHOUT a clean-
# boundary guard, and WITHOUT restarting a single lead.
#
# ── WHY (the operator's model) ───────────────────────────────────────────────
# The whole fleet runs on ONE shared keychain credential (~/.claude; all
# swarm.conf rows are default-lane). A single `/login` re-auths that credential
# fleet-wide, and running leads keep their in-RAM state. So a rotation does not
# need the checkpoint→swap→relaunch machinery swarm-rotate.sh performs (which
# exists to survive a fleet RESTART and its RAM-state loss). It only needs:
#   1. run `/login` in an ISOLATED session (swarm-login-relay.sh --dedicated) so
#      NO CTO pane is touched — the OAuth URL is posted to the product Discord
#      channel and the operator authenticates the next account in their browser;
#   2. verify the fresh credential;
#   3. done — no restart, no guard, no commit.
# The one risk this model carries (a running lead that does NOT adopt the fresh
# credential in place) is caught by swarm-reauth-verify.sh, which the tick runs
# STANDING every tick — it is NOT this actuator's concern.
#
# ── ACTUATOR CONTRACT (so the tick needs ZERO changes) ───────────────────────
# swarm-rotate-tick.sh calls its actuator three ways; we honor all three:
#   <cmd> --next     print the next account handle for the tick to log/persist.
#                    Under the login-relay model the account is chosen in the
#                    operator's BROWSER, not from a ring — so we print NOTHING and
#                    exit 0. The tick treats an empty --next as "actuator decides"
#                    and writes no account-state (correct: there is no ring here).
#   <cmd> [--force]  perform the re-auth. --force is ACCEPTED but inert: there is
#                    no clean-boundary guard to override (we touch no CTO pane).
#   <cmd> --dry-run  print the plan; run nothing.
#
# ── EXIT CODES (mapped to what the tick's outcome switch expects) ─────────────
#   0 — re-auth complete and the credential verifies. Tick records success.
#   6 — RING EXHAUSTED: the account the operator logged into authenticates but is
#       itself RATE-LIMITED (relay exit 7). Terminal — the tick escalates
#       (SWARM_ATTENTION_CMD) and STOPS; it does NOT retry.
#   5 — re-auth did NOT complete (relay returned any other non-zero: refused /
#       lock contention / URL never rendered / Discord post failed / verify failed
#       / operator auth timeout). The tick maps this to its exit 4 and retries on
#       a later tick. NOTE the deliberate remap: the relay's OWN exit 6 means
#       "Discord post failed", NOT ring exhaustion — only the relay's exit 7 maps
#       to our 6. Collapsing them here is the entire reason this wrapper exists.
#   2 — usage/config error (bad flag, SWARM_HOME wrong).
#
# ── SEAMS ────────────────────────────────────────────────────────────────────
#   SWARM_REAUTH_LOGIN_CMD  the re-auth command. Default:
#                           "$SCRIPT_DIR/swarm-login-relay.sh --dedicated".
#                           Run via `sh -c`; its exit code is mapped as above.
#                           Tests point this at a stub.
#   SWARM_REAUTH_POSTSWAP_CMD  run (best-effort) AFTER a successful re-auth. It
#                           recycles the /usage PROBE session so the next poll
#                           reads the NEW account. This matters because the probe
#                           is itself a long-lived `claude`, and a running claude
#                           may NOT adopt an externally-rotated credential in
#                           place — a stale probe would keep reporting the OLD
#                           (capped) account and re-trigger this re-auth forever.
#                           Killing the STATELESS probe forces the adapter to
#                           recreate it fresh on the new credential next tick (no
#                           CTO pane is touched — only the throwaway probe).
#                           Default: "<tmux> kill-session -t <usage-probe>".
#                           Set to "true" (or empty) to skip.
#
# This script performs NO checkpoint, NO fleet restart, and touches NO CTO pane
# or credential directly — all of that is the relay's (isolated) business.
# Bash 3.2-safe (macOS default). CWD-independent.

set -uo pipefail

PROG="swarm-reauth"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGIN_CMD="${SWARM_REAUTH_LOGIN_CMD:-$SCRIPT_DIR/swarm-login-relay.sh --dedicated}"
_TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
_USAGE_PROBE="${SWARM_USAGE_PROBE_SESSION:-swarm-usage-probe}"
# Default post-swap action: recycle the /usage probe so the next poll reads the
# NEW account (see SWARM_REAUTH_POSTSWAP_CMD in the header). The variable may be
# UNSET (use the default), empty (skip), or "true" (skip).
POSTSWAP_CMD="${SWARM_REAUTH_POSTSWAP_CMD-$_TMUX_BIN kill-session -t $_USAGE_PROBE}"

usage() { sed -n '2,60p' "$0"; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
FORCE=0
DRY_RUN=0
PRINT_NEXT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --next)    PRINT_NEXT=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)         echo "$PROG: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

# --next: the account is chosen in the operator's browser, not from a ring.
# Print nothing (exit 0) — the tick then records no account-state, which is
# exactly right under this model.
if [ "$PRINT_NEXT" -eq 1 ]; then
  exit 0
fi

# --dry-run: describe the plan, run nothing.
if [ "$DRY_RUN" -eq 1 ]; then
  echo "$PROG: DRY-RUN — WOULD re-auth in place via: $LOGIN_CMD"
  echo "$PROG: DRY-RUN — no checkpoint, no clean-boundary guard, no fleet restart. Running leads keep their state."
  echo "$PROG: DRY-RUN — performing NOTHING."
  exit 0
fi

# ---------------------------------------------------------------------------
# Re-auth in place. ALL mechanism (isolated session, /login, URL relay, operator
# wait, credential verify) lives in the login relay. We only map its exit code.
# ---------------------------------------------------------------------------
if [ "$FORCE" -eq 1 ]; then
  echo "$PROG: --force accepted but inert — a dedicated-session re-auth has no clean-boundary guard to override (it touches no CTO pane)."
fi
echo "$PROG: re-authenticating the shared credential in place (no restart) via: $LOGIN_CMD"

sh -c "$LOGIN_CMD"; rc=$?

case "$rc" in
  0)
    # Recycle the /usage probe so the NEXT poll reads the new account (best-effort;
    # the probe is stateless and the adapter recreates it). Never touches a CTO pane.
    if [ -n "$POSTSWAP_CMD" ] && [ "$POSTSWAP_CMD" != "true" ]; then
      if sh -c "$POSTSWAP_CMD" >/dev/null 2>&1; then
        echo "$PROG: recycled the /usage probe session so the next poll reads the new account."
      else
        echo "$PROG: NOTE — post-swap probe recycle returned non-zero (probe may not have been running); harmless."
      fi
    fi
    echo "$PROG: DONE — re-auth complete; credential verified. No lead was restarted."
    exit 0
    ;;
  7)
    # RING EXHAUSTED — the account the operator logged into authenticates but is
    # rate-limited. Remap the relay's 7 to our 6 (the tick's ring-exhaustion code)
    # so the tick escalates and STOPS instead of retrying.
    echo "$PROG: RING EXHAUSTED — the re-authed account authenticates but is RATE-LIMITED (relay exit 7)." >&2
    echo "$PROG: nowhere fresh to rotate to; signalling the tick to escalate and stop (exit 6)." >&2
    exit 6
    ;;
  *)
    # Any other non-zero: the re-auth did not complete. Deliberately DO NOT pass
    # the relay's own exit 6 (Discord-post-failed) through as our 6 — that would
    # be misread as ring exhaustion. Collapse every non-0/non-7 relay code to 5.
    echo "$PROG: re-auth did NOT complete (relay exit $rc). No credential change is assumed; the tick will retry on a later tick." >&2
    exit 5
    ;;
esac
