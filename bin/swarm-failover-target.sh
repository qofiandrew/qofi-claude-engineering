#!/usr/bin/env bash
# swarm-failover-target.sh — pick the account a capped swarm should FAIL OVER to
# (ADR-0018). This is the SELECTOR the failover router consults once per swarm it
# needs to move. v1 ships the FALLBACK policy (least-recently-capped round-robin
# among non-capped accounts); the true lowest-USE selector is the Phase-4 seam —
# swapping it in is purely additive (the router calls SWARM_FAILOVER_TARGET_CMD,
# this is just the default).
#
# THE POLICY (v1 fallback):
#   account universe = the distinct NON-EMPTY ACCOUNT labels in swarm.conf (the
#       default/empty account is never a failover TARGET — that is what --reset is
#       for). eligible = universe − capped − excluded.
#   choose the eligible account that is LEAST-RECENTLY-CAPPED: a never-capped
#       account (no last-capped marker) wins over one that capped recently; ties
#       break by swarm.conf order. The markers live in the LRC store
#       ($SWARM_ACCOUNT_CAPS_DIR, written by the router each time an account caps),
#       so "least-recently-capped" naturally round-robins the fleet across accounts
#       and avoids re-targeting an account that just capped.
#   NEVER target a capped account; if eligible is empty -> RING EXHAUSTED (exit 6),
#       the same terminal signal swarm-rotate.sh raises (the router escalates).
#
# HYSTERESIS + THE EVACUATION CARVE-OUT (the load-bearing safety property):
#   A headroom-margin hysteresis (default 15%) exists to damp PROACTIVE,
#   not-yet-capped moves so a swarm doesn't thrash toward a target only marginally
#   better. It gates ONLY the proactive path (--proactive --source <acct>) and
#   ONLY when a headroom signal is wired (SWARM_ACCOUNT_HEADROOM_CMD — the Phase-4
#   telemetry seam). It NEVER gates an EVACUATION: a swarm whose account is capped
#   has zero headroom and MUST move now, regardless of any margin. Evacuation
#   (the default mode) does not consult headroom at all — the carve-out is
#   structural, not a special case. Without a headroom signal, proactive moves are
#   declined (we don't churn on guesses); evacuation is unaffected.
#
# Usage:
#   swarm-failover-target.sh --capped "<labels>" [--exclude "<labels>"] \
#                            [--for-swarm <name>]              # EVACUATION (default)
#   swarm-failover-target.sh --proactive --source <acct> --capped "<labels>" ...
#   swarm-failover-target.sh -h | --help
# On success prints the chosen account label to stdout and exits 0.
#
# Exit codes:
#   0  printed the chosen target account label
#   1  usage / SWARM_HOME wrong
#   5  PROACTIVE move declined (no headroom signal, or margin < hysteresis) — the
#      swarm stays put. NEVER returned for an evacuation.
#   6  RING EXHAUSTED — every account is capped/excluded; nowhere to fail over to.
#
# bash 3.2-safe (macOS default). Read-only: never swaps a credential, never
# restarts anything, never writes the LRC store (the router owns that).

set -uo pipefail

PROG="swarm-failover-target"

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME so swarm.conf is found." >&2
  exit 1
fi
CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

CAPS_DIR="${SWARM_ACCOUNT_CAPS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/swarm/account-caps}"
# Normalize to a clean decimal int (strip any non-digits / leading-zero octal trap).
HYSTERESIS="$(printf '%s' "${SWARM_HYSTERESIS_PCT:-15}" | tr -dc '0-9')"; [ -z "$HYSTERESIS" ] && HYSTERESIS=15

usage() { sed -n '1,52p' "$0"; exit "${1:-0}"; }

CAPPED=""
EXCLUDE=""
PROACTIVE=0
SOURCE=""
FOR_SWARM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --capped)    CAPPED="${2:-}"; shift 2 ;;
    --exclude)   EXCLUDE="${2:-}"; shift 2 ;;
    --source)    SOURCE="${2:-}"; shift 2 ;;
    --for-swarm) FOR_SWARM="${2:-}"; shift 2 ;;
    --proactive) PROACTIVE=1; shift ;;
    -h|--help)   usage 0 ;;
    --*) echo "$PROG: unknown flag: $1" >&2; usage 1 ;;
    *)   echo "$PROG: unexpected arg: $1" >&2; usage 1 ;;
  esac
done

# Normalize a list: collapse commas/whitespace to single spaces, trim.
norm_list() { printf '%s' "$1" | tr ',' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
CAPPED="$(norm_list "$CAPPED")"
EXCLUDE="$(norm_list "$EXCLUDE")"

# Space-padded membership test.
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Build the account universe: distinct NON-EMPTY labels in swarm.conf order ──
UNIVERSE=""
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  _a="$SWARM_CONF_F_ACCOUNT"
  [ -z "$_a" ] && continue          # default account is never a failover target
  in_list "$_a" "$UNIVERSE" && continue
  UNIVERSE="$UNIVERSE $_a"
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
UNIVERSE="$(norm_list "$UNIVERSE")"

if [ -z "$UNIVERSE" ]; then
  echo "$PROG: no labeled accounts in swarm.conf — nothing to fail over to (single/default account fleet)." >&2
  exit 6
fi

# ── eligible = universe − capped − excluded − source ──────────────────────────
# The SOURCE account (a proactive move's current account) is never a target — you
# don't move a swarm to where it already is. For an evacuation the source is
# capped, so it's already excluded; excluding it explicitly also covers the
# proactive case where the source is NOT capped.
ELIGIBLE=""
for acct in $UNIVERSE; do
  [ -n "$SOURCE" ] && [ "$acct" = "$SOURCE" ] && continue
  in_list "$acct" "$CAPPED"  && continue
  in_list "$acct" "$EXCLUDE" && continue
  ELIGIBLE="$ELIGIBLE $acct"
done
ELIGIBLE="$(norm_list "$ELIGIBLE")"

if [ -z "$ELIGIBLE" ]; then
  echo "$PROG: RING EXHAUSTED — every labeled account is capped or excluded (capped=[$CAPPED] excluded=[$EXCLUDE]); nowhere to fail over to." >&2
  exit 6
fi

# ── Order eligible by LEAST-RECENTLY-CAPPED, ties by swarm.conf order ──────────
# Sort key = last-capped epoch (0 = no marker = never capped, so it sorts FIRST),
# then universe index. The router writes $CAPS_DIR/<label> (mtime) when an account
# caps; a never-capped account has no marker and is preferred.
mtime_of() {  # path -> epoch seconds (0 if absent/unstattable)
  [ -e "$1" ] || { echo 0; return 0; }
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}
idx=0
CHOSEN="$(
  for acct in $ELIGIBLE; do
    idx=$((idx+1))
    m="$(mtime_of "$CAPS_DIR/$acct")"
    printf '%s %s %s\n' "$m" "$idx" "$acct"
  done | sort -n -k1,1 -k2,2n | head -n1 | awk '{print $3}'
)"

# ── PROACTIVE gate (NOT for evacuation) — hysteresis on the headroom margin ────
if [ "$PROACTIVE" -eq 1 ]; then
  if [ -z "$SOURCE" ]; then
    echo "$PROG: --proactive requires --source <current-account>." >&2
    exit 1
  fi
  if [ -z "${SWARM_ACCOUNT_HEADROOM_CMD:-}" ]; then
    echo "$PROG: proactive move for '${FOR_SWARM:-?}' needs a headroom signal (SWARM_ACCOUNT_HEADROOM_CMD is the Phase-4 telemetry seam, currently unwired) — NOT moving (won't churn on guesses)." >&2
    exit 5
  fi
  # The headroom cmd takes the account as its first positional arg; forward it the
  # same way swarm-account.sh forwards a repo to the checkpoint hook (append a
  # literal "$1" so a bare-script cmd receives the account as ITS $1).
  headroom_of() { sh -c "$SWARM_ACCOUNT_HEADROOM_CMD \"\$1\"" _ "$1" 2>/dev/null | tr -dc '0-9'; }
  src_hr="$(headroom_of "$SOURCE")"; [ -z "$src_hr" ] && src_hr=0
  tgt_hr="$(headroom_of "$CHOSEN")"; [ -z "$tgt_hr" ] && tgt_hr=0
  # Force base-10. `tr -dc 0-9` can yield a leading-zero digit string (e.g. "08"
  # from a zero-padded telemetry source); bash 3.2 reads that as INVALID OCTAL, and
  # the arithmetic error would — under `set -uo pipefail` (no set -e) — abort the
  # rest of THIS if-block and fall through to the move below, bypassing the decline
  # gate in the UNSAFE direction (a spurious proactive move = a needless restart =
  # RAM-only teammate work lost). The 10# prefix neutralizes leading zeros; the
  # `|| delta=0` makes any residual arith failure fail SAFE (0 < hysteresis → decline).
  delta=$(( 10#$tgt_hr - 10#$src_hr )) || delta=0
  if [ "$delta" -lt "$HYSTERESIS" ]; then
    echo "$PROG: proactive move for '${FOR_SWARM:-?}' declined — target '$CHOSEN' headroom margin ${delta}% < hysteresis ${HYSTERESIS}% over source '$SOURCE'. Staying put." >&2
    exit 5
  fi
fi

# Evacuation (default) reaches here WITHOUT ever consulting headroom — a capped
# swarm always gets a target if one is eligible (the carve-out).
printf '%s\n' "$CHOSEN"
exit 0
