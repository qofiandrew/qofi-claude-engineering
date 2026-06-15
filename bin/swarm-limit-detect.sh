#!/usr/bin/env bash
# swarm-limit-detect.sh — detect the REAL rate-limit signal (the actual usage-cap
# message the active account is shown) and emit it as the poller's AT-LIMIT
# verdict. This is the AUTHORITATIVE "on-limit" detector; the token-burn estimate
# in swarm-usage-poll.sh remains the early NEAR warning.
#
# ── WHY THIS EXISTS (real signal vs. proxy) ──────────────────────────────────
# swarm-usage-poll.sh decides "near a cap" from a token-BURN estimate vs. a
# budget. That's a forward-looking PROXY: good for an early NEAR warning, but it
# is not the cap itself. The authoritative "you are capped" signal is the actual
# usage-limit message Claude Code shows when the account hits its 5h/weekly limit
# (or a provider 429). THIS deployment already OBSERVES that message: the watcher
# (swarm-watch.sh) reads it via pane_state() in swarm-lib.sh, which returns rc=2
# ("paused-limit") when a live tmux pane shows a known limit substring
# ("usage limit" / "5-hour limit" / "limit reached" / "rate limit" / ...). Those
# substrings are the same ones the watcher alerts on, and they are overridable via
# SWARM_LIMIT_PATTERNS. So the real signal IS reliably observable here, and this
# detector simply turns "any live swarm pane is paused on a limit" into the
# poller's AT verdict.
#
# ── HOW IT FITS THE SEAMS (feeds the poller's AT verdict; rewrites nothing) ──
# This is a NEW detector behind the poll seam, NOT a rewrite of swarm-usage-poll.
# The orchestrator (swarm-rotate-tick.sh) consults the poll via SWARM_POLL_CMD.
# To make the REAL signal authoritative while keeping the burn estimate as the
# NEAR early-warning, wire the tick's poll seam to this combiner form:
#
#     export SWARM_POLL_CMD='swarm-limit-detect.sh --or-poll'
#
# In --or-poll mode we first check the real signal:
#   * real limit observed  -> emit AT (exit 20) immediately. The cap is real; the
#                             estimate is moot.
#   * no real limit         -> DELEGATE to swarm-usage-poll.sh and pass through its
#                             verdict (so NEAR/OK/UNKNOWN from the burn proxy still
#                             flows). The proxy is the early warning; the real
#                             signal is the hard stop.
# Without --or-poll the detector reports ONLY the real signal (AT or OK/UNKNOWN),
# which is useful for observe-mode logging alongside the proxy.
#
# ── EXIT CODES (same contract as swarm-usage-poll.sh, so it drops into the seam)─
#   20 — AT-LIMIT   a live swarm pane is showing a known usage/rate-limit message
#                   (pane_state rc=2). The active account is really capped.
#   0  — OK         no live pane shows a limit message (real signal: not capped).
#                   In --or-poll this is never emitted directly — we delegate.
#   3  — UNKNOWN    cannot observe (no tmux, no live sessions, capture failed). A
#                   detector that cannot see must NOT claim "not capped"; it yields
#                   to the proxy. Fail-safe: never trips a rotation on its own.
#   2  — config/usage error.
#
# ── OBSERVABILITY OVERRIDE (testability) ─────────────────────────────────────
#   SWARM_PANE_STATE_CMD  Optional. A command run via `sh -c` with a session name
#                         in $1; its EXIT CODE is interpreted as pane_state's
#                         (0 working / 1 at-prompt / 2 paused-limit / 3 unknown /
#                         4 uncertain), and its STDOUT (if any) is the matched
#                         limit line. Tests inject this so no real tmux is needed.
#                         Default: the real pane_state() from swarm-lib.sh.
#   SWARM_POLL_CMD_INNER  In --or-poll mode, the proxy poller to delegate to.
#                         Default: "$SCRIPT_DIR/swarm-usage-poll.sh".
#   SWARM_TMUX_PREFIX     tmux session prefix (default "swarm"), as elsewhere.
#   SWARM_TMUX_BIN        tmux binary (default "tmux").
#
# Usage:
#   swarm-limit-detect.sh             # real signal only -> AT(20)/OK(0)/UNKNOWN(3)
#   swarm-limit-detect.sh --or-poll   # AT if real cap, else delegate to the proxy
#   swarm-limit-detect.sh --json      # one JSON line describing what was seen
#   swarm-limit-detect.sh -h | --help
#
# bash 3.2-safe (macOS default). Read-only: never swaps a credential, never
# restarts anything. python3 only via the delegated poller (not here).

set -uo pipefail

PROG="swarm-limit-detect"
usage() { sed -n '1,80p' "$0"; exit "${1:-0}"; }

OR_POLL=0
JSON=0
BY_ACCOUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --or-poll)    OR_POLL=1; shift ;;
    --json)       JSON=1; shift ;;
    --by-account) BY_ACCOUNT=1; shift ;;
    -h|--help) usage 0 ;;
    --*) echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)   echo "$PROG: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME so swarm.conf is found." >&2
  exit 2
fi
CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
POLL_INNER="${SWARM_POLL_CMD_INNER:-$SCRIPT_DIR/swarm-usage-poll.sh}"

# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # pane_state, swarm_conf_parse_line, SWARM_PANE_STATE_DETAIL

# probe_pane SESSION -> sets PANE_RC and PANE_DETAIL
# Uses the injectable SWARM_PANE_STATE_CMD seam if set (tests), else the real
# pane_state() from swarm-lib.sh. Either way the rc encodes the same states.
probe_pane() {
  local sess="$1"
  if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
    PANE_DETAIL="$(sh -c "$SWARM_PANE_STATE_CMD" _ "$sess" 2>/dev/null)"; PANE_RC=$?
  else
    pane_state "$sess" "$TMUX_BIN"; PANE_RC=$?
    PANE_DETAIL="$SWARM_PANE_STATE_DETAIL"
  fi
}

# ── Scan live swarms for the real limit signal ───────────────────────────────
# We consider only sessions that look live (tmux has-session), exactly as the
# rotate clean-boundary guard does. Any one paused-limit pane means the ACTIVE
# account (single-account deployment) is capped — that's the whole fleet's cap.
SAW_LIMIT=0           # 1 once any pane shows a known limit message
SAW_ANY_PANE=0        # 1 once we could read at least one live pane
LIMIT_DETAIL=""       # first matched limit line (for logging/JSON)
LIMIT_SWARM=""        # which swarm showed it

have_tmux=0
if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
  have_tmux=1         # injected probe stands in for tmux
elif command -v "$TMUX_BIN" >/dev/null 2>&1; then
  have_tmux=1
fi

# ── --by-account: per-ACCOUNT cap grouping (the failover router's detector) ───
# The single-account scan below collapses the whole fleet to one verdict and
# BREAKS on the first capped pane. The failover model (ADR-0018) needs the
# OPPOSITE: scan EVERY live swarm, GROUP by its swarm.conf field-6 account, and
# report each account's verdict — an account is AT if ANY of its swarms shows a
# limit pane, OK if any of its swarms is readable-and-not-capped, else UNKNOWN.
# We emit one stable line per account; the router parses these to decide which
# accounts must evacuate. The aggregate exit mirrors the single-account contract
# (20 if any account is capped / 0 if any readable-not-capped / 3 if none
# observable) so a caller that only checks the exit code still gets a sane signal.
if [ "$BY_ACCOUNT" -eq 1 ]; then
  # Always iterate the conf to build the account UNIVERSE (so an account whose
  # swarms are all down still reports UNKNOWN rather than vanishing). Probe each
  # live swarm; record observations as TAB-delimited "<acctkey> <rc> <swarm> <detail>".
  OBS=""
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _name="$SWARM_CONF_F_NAME"
    [ -z "$_name" ] && continue
    _key="$SWARM_CONF_F_ACCOUNT"; [ -z "$_key" ] && _key="_default_"
    _sess="${PREFIX}-${_name}"
    _rc=4; _det=""
    if [ "$have_tmux" -eq 1 ]; then
      if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
        probe_pane "$_sess"; _rc="$PANE_RC"; _det="$PANE_DETAIL"
      elif "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null; then
        probe_pane "$_sess"; _rc="$PANE_RC"; _det="$PANE_DETAIL"
      fi
    fi
    OBS="$OBS$_key	$_rc	$_name	$_det
"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

  if [ "$JSON" -eq 1 ]; then
    printf '%s' "$OBS" | python3 -c '
import json,sys
acc={}   # key -> dict; preserves first-seen order (py3.7+ dict is ordered)
for raw in sys.stdin.read().splitlines():
    if not raw.strip(): continue
    parts=raw.split("\t")
    while len(parts)<4: parts.append("")
    key,rc,sw,det=parts[0],parts[1],parts[2],parts[3]
    a=acc.setdefault(key,{"account":(None if key=="_default_" else key),"verdict":"UNKNOWN","swarm":None,"limit_line":None,"_readable":False})
    if rc=="2" and a["verdict"]!="AT":
        a["verdict"]="AT"; a["swarm"]=sw; a["limit_line"]=(det or None)
    if rc!="4" and a["verdict"]!="AT":
        a["verdict"]="OK"; a["_readable"]=True
out=[]
anyAT=anyOK=False
for k,a in acc.items():
    if a["verdict"]=="AT": anyAT=True
    elif a["verdict"]=="OK": anyOK=True
    a.pop("_readable",None)
    out.append(a)
print(json.dumps({"accounts":out}))
sys.exit(20 if anyAT else (0 if anyOK else 3))
' ; exit $?
  fi

  printf '%s' "$OBS" | awk -F'\t' '
    $1=="" { next }
    {
      key=$1; rc=$2; sw=$3; det=$4
      if (!(key in firstseen)) { firstseen[key]=1; order[++n]=key }
      if (rc=="2") { if (!(key in atsw)) { atsw[key]=sw; atdet[key]=det }; at[key]=1 }
      if (rc!="4") readable[key]=1
    }
    END {
      anyAT=0; anyOK=0
      for (i=1;i<=n;i++) {
        k=order[i]
        if (k in at)            { anyAT=1; printf "account=%s verdict=AT swarm=%s detail=%s\n", k, atsw[k], atdet[k] }
        else if (k in readable) { anyOK=1; printf "account=%s verdict=OK\n", k }
        else                    {          printf "account=%s verdict=UNKNOWN\n", k }
      }
      if (anyAT) exit 20; else if (anyOK) exit 0; else exit 3
    }
  '
  exit $?
fi

if [ "$have_tmux" -eq 1 ]; then
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _name="$SWARM_CONF_F_NAME"
    [ -z "$_name" ] && continue
    _sess="${PREFIX}-${_name}"
    # Liveness: with a real tmux, require an actual session; with an injected
    # probe, the stub decides (it returns rc=4 "uncertain" for absent sessions).
    if [ -z "${SWARM_PANE_STATE_CMD:-}" ]; then
      "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null || continue
    fi
    probe_pane "$_sess"
    case "$PANE_RC" in
      4) : ;;                       # uncertain (no session / capture failed) — skip
      *) SAW_ANY_PANE=1 ;;          # we read SOME pane state
    esac
    if [ "$PANE_RC" -eq 2 ]; then
      SAW_LIMIT=1
      LIMIT_DETAIL="$PANE_DETAIL"
      LIMIT_SWARM="$_name"
      break                         # one capped pane is enough — the account is capped
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
fi

# ── Decide the REAL-signal verdict ───────────────────────────────────────────
# AT  if we saw a limit message.
# OK  if we read at least one live pane and none showed a limit (real "not capped").
# UNKNOWN if we could not observe at all (no tmux / no live sessions) — the
#         detector that cannot see yields rather than asserting "not capped".
if [ "$SAW_LIMIT" -eq 1 ]; then
  REAL_VERDICT="AT"; REAL_CODE=20
elif [ "$SAW_ANY_PANE" -eq 1 ]; then
  REAL_VERDICT="OK"; REAL_CODE=0
else
  REAL_VERDICT="UNKNOWN"; REAL_CODE=3
fi

emit_json() {  # verdict source detail
  local v="$1" src="$2" det="$3"
  python3 - "$v" "$src" "$det" "$LIMIT_SWARM" <<'PY' 2>/dev/null || printf '{"verdict":"%s","source":"%s"}\n' "$v" "$src"
import json,sys
print(json.dumps({
  "verdict": sys.argv[1],
  "source": sys.argv[2],
  "limit_line": (sys.argv[3] or None),
  "swarm": (sys.argv[4] or None),
}))
PY
}

# ── --or-poll: real signal is the hard stop; otherwise delegate to the proxy ──
if [ "$OR_POLL" -eq 1 ]; then
  if [ "$REAL_VERDICT" = "AT" ]; then
    if [ "$JSON" -eq 1 ]; then emit_json "AT" "real-limit" "$LIMIT_DETAIL"
    else printf '%s: AT-LIMIT (REAL signal) — swarm %s pane shows: %s\n' "$PROG" "${LIMIT_SWARM:-?}" "${LIMIT_DETAIL:-<limit message>}"; fi
    exit 20
  fi
  # No real cap observed (OK or UNKNOWN): defer to the burn-proxy poller and pass
  # its verdict straight through — NEAR/OK/UNKNOWN/error all flow from there.
  if [ "$JSON" -eq 1 ]; then
    sh -c "$POLL_INNER --json" ; exit $?
  else
    printf '%s: no REAL limit observed (real=%s) — delegating to burn-proxy poller.\n' "$PROG" "$REAL_VERDICT"
    sh -c "$POLL_INNER" ; exit $?
  fi
fi

# ── real-signal-only mode ────────────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  emit_json "$REAL_VERDICT" "real-limit" "$LIMIT_DETAIL"
else
  case "$REAL_VERDICT" in
    AT)      printf '%s: AT-LIMIT (REAL signal) — swarm %s pane shows: %s\n' "$PROG" "${LIMIT_SWARM:-?}" "${LIMIT_DETAIL:-<limit message>}" ;;
    OK)      printf '%s: OK (REAL signal) — no live swarm pane shows a usage-limit message.\n' "$PROG" ;;
    UNKNOWN) printf '%s: UNKNOWN — could not observe any live swarm pane (no tmux / no live sessions). Yielding (no AT claimed).\n' "$PROG" ;;
  esac
fi
exit "$REAL_CODE"
