#!/usr/bin/env bash
# swarm-watch.sh — EXTERNAL multi-swarm liveness monitor.
#
# launchd fires this on an interval. It reads the SAME $SWARM_HOME/swarm.conf that
# swarm-up.sh uses, and posts a per-channel heartbeat for EACH configured swarm,
# using that swarm's own bot token. ONE launchd job covers all swarms.
#
# swarm.conf line (pipe-separated, 4 fields):
#     name | /path/to/repo | TOKEN_VAR | CHANNEL_ID
# Token resolved from $SWARM_HOME/tokens.env (TOKEN_VAR -> bot token), exactly as
# swarm-up.sh does. The heartbeat for a swarm is posted by that swarm's own bot,
# into that swarm's channel.
#
# Per-swarm state (combines tmux liveness + transcript freshness + pane footer):
#   no tmux session            -> ⚪ down       (stopped on purpose, or pane closed)
#   session, no transcript     -> 🟡 starting   (just launched, no activity yet)
#   session, fresh transcript  -> 🟢 working
#   session, stale, pane idle  -> 🟢 ready · waiting for input (HEALTHY)
#   session, stale, mid-turn   -> 🔴 STALLED    (turn in flight but no writes)
#
# Idle vs stalled: the claude TUI footer contains "esc to interrupt" iff a turn
# is actually in flight. Stale transcript + no "esc to interrupt" = healthy idle.
# False-ready is preferred over false-stalled — bad alarms train operators to
# ignore the heartbeat.
#
# The heartbeat is also PINNED to the channel after its first POST so it stays
# visible as conversation accumulates. Subsequent ticks edit in place; the pin
# is sticky on edits and is only re-applied on a (re)post.
#
# Why external: a crashed/stuck swarm cannot report its own death. This shares no
# fate with any swarm and has no terminal. It posts via the bot token to the
# Discord REST API directly (not through the bridge/access.json — that gates inbound).
#
# bash 3.2-safe (macOS default). python3 for mtime + JSON.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-watch: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
CONF="$SWARM_HOME/swarm.conf"
TOKENS="$SWARM_HOME/tokens.env"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"            # may need full path under launchd
API="${SWARM_DISCORD_API:-https://discord.com/api/v10}"
ENABLE_TYPING="${SWARM_ENABLE_TYPING:-0}"

mkdir -p "$STATE_DIR"
# shellcheck disable=SC1090
[ -f "$TOKENS" ] && . "$TOKENS"

# Shared repo_activity helper. Walks the lead's project dir AND every teammate
# worktree dir recursively (including subagents/) for the newest *.jsonl mtime
# and a count of distinct teammate dirs with a fresh transcript. Both signals
# are needed for the state machine below — see swarm-lib.sh for details.
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/swarm-lib.sh"

json_content() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))'; }
extract_id() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")'; }

session_alive() {  # name -> 0 alive, 1 absent, 2 tmux unknown
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 2
  "$TMUX_BIN" has-session -t "${PREFIX}-$1" 2>/dev/null
}

# Idle-ready vs mid-turn signal: the claude TUI footer ends with
# "esc to interrupt" iff a turn is interruptible (in flight). When the lead is
# at the prompt waiting for input, the footer ends with "← for agents". Returns
# 0 = mid-turn, 1 = not mid-turn (idle / unknown — safe default).
pane_mid_turn() {  # name
  local sess="${PREFIX}-$1"
  "$TMUX_BIN" capture-pane -t "$sess" -p 2>/dev/null \
    | grep -qF 'esc to interrupt'
}

post_heartbeat() {  # channel token content
  local channel="$1" token="$2" content="$3"
  local idfile="$STATE_DIR/heartbeat-$channel.id"
  local payload; payload="$(json_content "$content")"
  local msgid=""
  [ -r "$idfile" ] && msgid="$(tr -d '[:space:]' < "$idfile")"
  if [ -n "$msgid" ]; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
      -H "Authorization: Bot $token" -H "Content-Type: application/json" \
      -d "$payload" "$API/channels/$channel/messages/$msgid")"
    # 200 = edited in place; pin (set on initial POST) is sticky on edits.
    [ "$code" = "200" ] && return 0
    # Anything else (404 deleted, etc.): fall through to POST + re-pin.
  fi
  local newid
  newid="$(curl -s -X POST -H "Authorization: Bot $token" -H "Content-Type: application/json" \
    -d "$payload" "$API/channels/$channel/messages" | extract_id)"
  if [ -z "$newid" ]; then
    echo "swarm-watch: heartbeat POST returned no id for channel $channel" >&2
    return 0
  fi
  printf '%s' "$newid" > "$idfile"
  pin_message "$channel" "$token" "$newid"
}

# Pin the heartbeat so it stays reachable via the channel's pin icon as the
# conversation scrolls. Only called when (re)posting fresh; subsequent edits
# don't re-pin. Failures are logged, never fatal.
pin_message() {  # channel token messageid
  local channel="$1" token="$2" msgid="$3"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: Bot $token" \
    "$API/channels/$channel/pins/$msgid")"
  case "$code" in
    204) ;;  # ok
    403) echo "swarm-watch: pin failed for channel $channel (HTTP 403) — bot needs 'Manage Messages' permission in Discord" >&2 ;;
    *)   echo "swarm-watch: pin failed for channel $channel (HTTP $code)" >&2 ;;
  esac
}

grep -vE '^[[:space:]]*(#|$)' "$CONF" | while IFS='|' read -r name repo tokvar channel; do
  name="$(echo "${name:-}" | xargs)"
  repo="$(echo "${repo:-}" | xargs)"
  tokvar="$(echo "${tokvar:-}" | xargs)"
  channel="$(echo "${channel:-}" | xargs)"
  [ -z "$name" ] && continue
  [ -z "$channel" ] && { echo "swarm-watch: $name has no CHANNEL_ID (4th field) — skipping" >&2; continue; }

  token="${!tokvar:-}"
  [ -z "$token" ] && { echo "swarm-watch: no token in \$$tokvar for $name — skipping" >&2; continue; }

  case "$repo" in "~"*) repo="$HOME${repo#\~}";; esac

  session_alive "$name"; rc=$?
  if [ "$rc" -eq 0 ]; then alive=1; elif [ "$rc" -eq 2 ]; then alive=2; else alive=0; fi

  # repo_activity returns "<newest_age_seconds>|<active_teammate_count>".
  # The age scan covers the lead's project dir AND every teammate worktree
  # dir recursively — so "fresh" fires when *anyone* (lead or any teammate)
  # is producing, not just the lead. See swarm-lib.sh.
  #
  # Age is ALWAYS a number now (no more blank). When no transcript exists
  # at all the function returns $SWARM_NO_TRANSCRIPT_AGE — a sentinel
  # larger than any plausible STALE_SECONDS, so threshold-based callers
  # naturally treat it as stale. We compare against the sentinel here
  # only to preserve the more-specific "🟡 starting (no transcript yet)"
  # message; everything else flows through the existing predicate.
  activity="$(repo_activity "$repo" "$CLAUDE_PROJECTS" "$STALE_SECONDS")"
  a="${activity%%|*}"
  tn="${activity##*|}"
  case "$a" in ''|*[!0-9]*) a="$SWARM_NO_TRANSCRIPT_AGE" ;; esac  # paranoia

  if [ "$alive" -eq 0 ]; then
    status="⚪ swarm down (no session)"; age="—"
  elif [ "$a" -eq "$SWARM_NO_TRANSCRIPT_AGE" ]; then
    if [ "$alive" -eq 1 ]; then status="🟡 swarm starting (no transcript yet)"; else status="⚪ no active session"; fi
    age="—"
  else
    if [ "$a" -lt 60 ]; then age="${a}s"; else age="$(( a/60 ))m"; fi
    if [ "$a" -le "$STALE_SECONDS" ]; then
      # Working — lead OR any teammate has written within STALE_SECONDS.
      # If teammates are the ones producing, surface the count so the
      # heartbeat distinguishes "lead is hot" from "lead idle, N teammates
      # cranking" (the very state that motivated this change).
      if [ "${tn:-0}" -gt 0 ]; then
        if [ "$tn" -eq 1 ]; then plural=""; else plural="s"; fi
        status="🟢 swarm working · $tn teammate${plural} active"
      else
        status="🟢 swarm working"
      fi
      [ "$ENABLE_TYPING" = "1" ] && curl -s -X POST -H "Authorization: Bot $token" "$API/channels/$channel/typing" >/dev/null 2>&1 || true
    elif pane_mid_turn "$name"; then
      # Footer says "esc to interrupt" — a turn IS in flight, but neither
      # the lead nor any teammate has written for > STALE_SECONDS. Stuck.
      status="🔴 swarm STALLED — turn in flight but no transcript write for $(( a/60 ))m (rate-limited, hung tool, or crashed)"
    else
      # Stale across the board + lead not mid-turn — lead at prompt and
      # no teammate is producing. Healthy idle. (See swarm-lib.sh: the
      # known limitation is that "every teammate hung simultaneously"
      # would also paint as ready; parity with the previous lead-only
      # implementation, no regression.)
      status="🟢 swarm ready · waiting for input (idle $(( a/60 ))m)"
    fi
  fi

  content="$status · $name · last activity $age ago · checked $(date '+%H:%M:%S')"
  post_heartbeat "$channel" "$token" "$content"
done

exit 0
