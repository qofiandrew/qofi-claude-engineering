#!/usr/bin/env bash
# swarm-reauth-verify.sh — the STUCK-PANE safety net for no-restart rotation.
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# The no-restart re-auth model (swarm-reauth.sh) re-authenticates the shared
# credential in place and does NOT restart the fleet. That rests on ONE unproven
# assumption: a running `claude` lead ADOPTS the freshly-rotated keychain
# credential without a restart. If a lead does NOT, it keeps hammering the OLD
# (now rate-limited) account until it caps and PARKS on a "usage limit reached"
# banner — silently, forever, since nothing restarts it.
#
# This script is the fail-LOUD net the operator chose over a guard/restart: on
# every tick it scans the live CTO panes and, if any is PARKED on a cap banner
# while the account still has HEADROOM (so the park is anomalous, not a genuine
# fleet-wide cap), it posts ONE alert to the product Discord channel naming the
# stuck leads. It NEVER restarts anything — it only tells the operator "these
# leads didn't pick up the new login; they need a manual nudge."
#
# ── THE HEADROOM GATE (why we don't alert on every parked pane) ──────────────
# A parked pane during a GENUINE account cap (every lead capped, ring exhausted)
# is expected — swarm-reauth.sh already escalates that (ring exhaustion). Alerting
# then would be redundant noise. So we alert only when the tick's poll verdict
# says the account is NOT at its limit: the tick passes its verdict in
# SWARM_TICK_POLL_VERDICT and we SUPPRESS the alert for the verdicts in
# SWARM_REAUTH_VERIFY_SUPPRESS (default "AT UNKNOWN"). An unset verdict (a manual
# run) is NOT suppressed — fail loud.
#
# ── DEDUP (don't spam every 300s) ────────────────────────────────────────────
# We alert once per distinct PARKED SET. The sorted set is stored in a marker
# ($SWARM_STATE_DIR/swarm-reauth-verify.last); we re-alert only when the set
# CHANGES. When all panes recover (parked set empty) we clear the marker, so a
# later re-park alerts again. A suppressed tick leaves the marker untouched, so a
# suppress→eligible transition still alerts if it hasn't been alerted yet.
#
# ── SEAMS (tests inject all external effects) ────────────────────────────────
#   SWARM_TMUX_BIN            tmux binary. Default "tmux".
#   SWARM_TMUX_PREFIX         session prefix. Default "swarm".
#   SWARM_STATE_DIR           dedup-marker dir. Default "$HOME/.config/swarm".
#   SWARM_REAUTH_VERIFY_SWARM which swarm row supplies the alert channel + token.
#                             Default "qofi-product".
#   SWARM_TICK_POLL_VERDICT   the tick's current verdict (OK|NEAR|AT|UNKNOWN).
#                             The headroom gate. Unset → not suppressed.
#   SWARM_REAUTH_VERIFY_SUPPRESS  space-separated verdicts that SUPPRESS the alert.
#                             Default "AT UNKNOWN".
#   SWARM_REAUTH_VERIFY_POST_CMD  full override of the Discord post. Run via
#                             `sh -c "$cmd" _ <channel> <content>`; exit 0 =
#                             delivered. When set, the built-in curl (and the
#                             tokens file) is not used. Tests record the payload.
#   SWARM_TOKENS_ENV          bot-token env file. Default "$SWARM_HOME/tokens.env".
#   SWARM_DISCORD_API         REST base. Default "https://discord.com/api/v10".
#   SWARM_REAUTH_VERIFY_CURL_TIMEOUT  --max-time for the built-in curl. Default 10.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0 — ran cleanly (no parked panes, OR alerted, OR suppressed, OR already
#       alerted). This is a best-effort ALERTER: a failed Discord post logs loud
#       and still exits 0 so it never breaks the tick.
#   2 — usage/config error (bad flag, SWARM_HOME wrong, no channel wiring).
#
# SECRET DISCIPLINE: the bot token is resolved by VAR NAME inside a scoped
# subshell and is never echoed, logged, or placed on argv (the swarm-watch.sh
# pattern). This script NEVER restarts, kills, or sends keys to any pane.
# Bash 3.2-safe (macOS default). CWD-independent.

set -uo pipefail

PROG="swarm-reauth-verify"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 2
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # swarm_conf_parse_line, pane_state

usage() { sed -n '2,66p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --*) echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)   echo "$PROG: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
ALERT_SWARM="${SWARM_REAUTH_VERIFY_SWARM:-qofi-product}"
VERDICT="${SWARM_TICK_POLL_VERDICT:-}"
SUPPRESS="${SWARM_REAUTH_VERIFY_SUPPRESS:-AT UNKNOWN}"
API="${SWARM_DISCORD_API:-https://discord.com/api/v10}"
TOKENS="${SWARM_TOKENS_ENV:-$SWARM_HOME/tokens.env}"
CURL_MAX_TIME="${SWARM_REAUTH_VERIFY_CURL_TIMEOUT:-10}"
MARKER="$STATE_DIR/swarm-reauth-verify.last"

# Resolve the alert swarm's row (token var = field 3, channel = field 4).
TOKVAR=""; CHANNEL=""; FOUND=0
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$ALERT_SWARM" ]; then
    TOKVAR="$SWARM_CONF_F_TOKVAR"; CHANNEL="$SWARM_CONF_F_CHANNEL"; FOUND=1; break
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
if [ "$FOUND" -ne 1 ]; then
  echo "$PROG: config error — alert swarm '$ALERT_SWARM' not found in $CONF." >&2
  exit 2
fi
if [ -z "$CHANNEL" ] && [ -z "${SWARM_REAUTH_VERIFY_POST_CMD:-}" ]; then
  echo "$PROG: config error — alert swarm '$ALERT_SWARM' has no CHANNEL_ID and no SWARM_REAUTH_VERIFY_POST_CMD override; cannot deliver an alert." >&2
  exit 2
fi

# post_discord CONTENT -> 0 delivered / 1 not. Token resolved by VAR NAME inside
# a scoped subshell — never echoed, never exported here.
post_discord() {
  local content="$1"
  if [ -n "${SWARM_REAUTH_VERIFY_POST_CMD:-}" ]; then
    sh -c "$SWARM_REAUTH_VERIFY_POST_CMD" _ "$CHANNEL" "$content"
    return $?
  fi
  (
    [ -f "$TOKENS" ] || { echo "$PROG: tokens file not found: $TOKENS" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "$TOKENS"
    _token="${!TOKVAR:-}"
    [ -z "$_token" ] && { echo "$PROG: no token in \$$TOKVAR ($TOKENS)" >&2; exit 1; }
    _payload="$(printf '%s' "$content" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')" || exit 1
    _code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bot $_token" -H "Content-Type: application/json" \
      -d "$_payload" "$API/channels/$CHANNEL/messages")"
    case "$_code" in 200|201) exit 0 ;; *) echo "$PROG: Discord POST failed (HTTP $_code)" >&2; exit 1 ;; esac
  )
}

# ---------------------------------------------------------------------------
# Scan the live CTO panes for a PARKED cap banner (pane_state rc=2).
# ---------------------------------------------------------------------------
PARKED=""
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  [ "$SWARM_CONF_F_ENGINE" = "claude" ] || continue
  _name="$SWARM_CONF_F_NAME"
  [ -z "$_name" ] && continue
  _sess="${PREFIX}-${_name}"
  command -v "$TMUX_BIN" >/dev/null 2>&1 || continue
  "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null || continue
  pane_state "$_sess" "$TMUX_BIN"; _ps=$?
  if [ "$_ps" -eq 2 ]; then
    PARKED="$PARKED $_name"
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

# Normalize to a stable, sorted, newline-free identity for dedup comparison.
PARKED="$(printf '%s\n' $PARKED | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//;s/^ *//')"

mkdir -p "$STATE_DIR" 2>/dev/null || true

# No parked panes → clear the dedup marker so a future re-park alerts again.
if [ -z "$PARKED" ]; then
  rm -f "$MARKER" 2>/dev/null || true
  echo "$PROG: OK — no CTO pane is parked on a cap banner."
  exit 0
fi

# Parked panes exist. Headroom gate: suppress if the account is genuinely capped
# (verdict AT) or unknown — those parks are expected/ambiguous, not a stuck lead.
for _s in $SUPPRESS; do
  if [ "$VERDICT" = "$_s" ]; then
    echo "$PROG: parked pane(s) [$PARKED] but poll verdict=$VERDICT (suppressed set: $SUPPRESS) — the account is genuinely at/near its cap; not alerting (expected). Marker untouched."
    exit 0
  fi
done

# Alert-eligible. Dedup: only post when the parked SET changed.
PREV=""
[ -f "$MARKER" ] && PREV="$(tr -d '\n' < "$MARKER" 2>/dev/null)"
if [ "$PARKED" = "$PREV" ]; then
  echo "$PROG: parked pane(s) [$PARKED] already alerted (unchanged set) — not re-posting."
  exit 0
fi

_verdnote=""
[ -n "$VERDICT" ] && _verdnote=" The account still has headroom (poll verdict=$VERDICT), so this is NOT a genuine cap —"
if post_discord "⚠️ **Stuck lead(s) after re-auth** — these swarms are PARKED on a usage-limit banner but did NOT restart:  \`$PARKED\`.${_verdnote} they did not pick up the rotated credential in place and need a manual nudge (restart that lead's pane). No fleet restart was performed."; then
  printf '%s\n' "$PARKED" > "$MARKER" 2>/dev/null || true
  echo "$PROG: ALERTED — posted stuck-lead notice for [$PARKED] to the '$ALERT_SWARM' channel."
else
  echo "$PROG: WARNING — could not post the stuck-lead alert for [$PARKED]. Leaving the marker unchanged so the next tick retries." >&2
fi
exit 0
