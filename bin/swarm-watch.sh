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
# Per-swarm state (combines tmux liveness + transcript freshness):
#   no tmux session            -> ⚪ down       (stopped on purpose, or pane closed)
#   session, no transcript     -> 🟡 starting   (just launched, no activity yet)
#   session, fresh transcript  -> 🟢 working
#   session, stale transcript  -> 🔴 STALLED    (alive but stuck/rate-limited)
#
# Why external: a crashed/stuck swarm cannot report its own death. This shares no
# fate with any swarm and has no terminal. It posts via the bot token to the
# Discord REST API directly (not through the bridge/access.json — that gates inbound).
#
# bash 3.2-safe (macOS default). python3 for mtime + JSON.

set -uo pipefail

SWARM_HOME="${SWARM_HOME:-$HOME/claude-swarm}"
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
[ -f "$CONF" ] || { echo "swarm-watch: no $CONF" >&2; exit 0; }
# shellcheck disable=SC1090
[ -f "$TOKENS" ] && . "$TOKENS"

file_mtime() { python3 -c 'import os,sys
try: print(int(os.path.getmtime(sys.argv[1])))
except Exception: print(0)' "$1" 2>/dev/null; }
json_content() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))'; }
extract_id() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")'; }

session_alive() {  # name -> 0 alive, 1 absent, 2 tmux unknown
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 2
  "$TMUX_BIN" has-session -t "${PREFIX}-$1" 2>/dev/null
}

newest_transcript() {  # repo -> path or nonzero
  local base; base="$(basename "$1")"
  local t; t="$(ls -t "$CLAUDE_PROJECTS"/*/*.jsonl 2>/dev/null | grep -iF -- "$base" | head -1)"
  [ -z "$t" ] && return 1
  printf '%s' "$t"
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
    [ "$code" = "200" ] && return 0
  fi
  local newid
  newid="$(curl -s -X POST -H "Authorization: Bot $token" -H "Content-Type: application/json" \
    -d "$payload" "$API/channels/$channel/messages" | extract_id)"
  [ -n "$newid" ] && printf '%s' "$newid" > "$idfile"
}

now="$(date +%s)"

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

  transcript="$(newest_transcript "$repo" || true)"

  if [ "$alive" -eq 0 ]; then
    status="⚪ swarm down (no session)"; age="—"
  elif [ -z "$transcript" ]; then
    if [ "$alive" -eq 1 ]; then status="🟡 swarm starting (no transcript yet)"; else status="⚪ no active session"; fi
    age="—"
  else
    mt="$(file_mtime "$transcript")"; mt="${mt//[^0-9]/}"; [ -z "$mt" ] && mt=0
    a=$(( now - mt )); [ "$a" -lt 0 ] && a=0
    if [ "$a" -lt 60 ]; then age="${a}s"; else age="$(( a/60 ))m"; fi
    if [ "$a" -le "$STALE_SECONDS" ]; then
      status="🟢 swarm working"
      [ "$ENABLE_TYPING" = "1" ] && curl -s -X POST -H "Authorization: Bot $token" "$API/channels/$channel/typing" >/dev/null 2>&1 || true
    else
      status="🔴 swarm STALLED — no activity for $(( a/60 ))m (stuck, rate-limited, or crashed)"
    fi
  fi

  content="$status · $name · last activity $age ago · checked $(date '+%H:%M:%S')"
  post_heartbeat "$channel" "$token" "$content"
done

exit 0
