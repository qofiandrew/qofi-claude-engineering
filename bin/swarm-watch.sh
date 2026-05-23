#!/usr/bin/env bash
# swarm-watch.sh — EXTERNAL multi-swarm liveness monitor + active alerter.
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
# Per-swarm heartbeat state (pane content is the PRIMARY working signal;
# transcript freshness disambiguates working-vs-stalled):
#   no tmux session                     -> ⚪ down
#   session, no transcript              -> 🟡 starting
#   session, pane mid-turn, fresh       -> 🟢 working
#   session, pane mid-turn, stale       -> 🔴 STALLED  (turn in flight, no writes)
#   session, pane idle, fresh           -> 🟢 ready · waiting for input (just replied)
#   session, pane idle, stale           -> 🟢 ready · waiting for input (idle Nm)
#   session, pane unreadable            -> 🟢 ready  (fail-safe — never claim working
#                                                    off transcript age alone)
#
# Why pane content, not age alone: transcript age cannot distinguish
# "replied N seconds ago, now idle" from "actively producing". For the
# full STALE_SECONDS window after any reply, an idle lead reads as fresh
# — and used to false-paint 🟢 working. The TUI footer ends with
# "esc to interrupt" iff a turn is interruptible (in flight); at the
# prompt it ends with "← for agents". See pane_working in swarm-lib.sh.
# False-ready is preferred over false-stalled — bad alarms train operators
# to ignore the heartbeat.
#
# The heartbeat is also PINNED to the channel after its first POST so it stays
# visible as conversation accumulates. Subsequent ticks edit in place; the pin
# is sticky on edits and is only re-applied on a (re)post.
#
# ACTIVE ALERTER (the reason "edits to a pinned message" wasn't enough).
# The heartbeat is PASSIVE — Discord edits don't trigger a notification, so a
# silently-failed swarm produces DEAD SILENCE in the operator's feed. The
# overnight pain: a usage throttle paused work, the CTO (Claude making tool
# calls) couldn't report its own throttle because it had no tool calls to
# make, and the heartbeat just sat there edited to "ready". When the CTO is
# down, NOTHING that depends on Claude can alert. So this script — a plain
# shell process that already curls Discord directly with the bot token —
# also POSTs a NEW alert message when the swarm transitions into a known-
# bad state. The same direct-curl path that edits the heartbeat fires the
# alert; it shares zero fate with the CTO/bridge/access.json.
#
# Alertable states (each posts ONE new message on transition into the
# state; subsequent ticks in the same state are change-guarded silent):
#   paused-limit  pane shows a known Claude Code limit substring
#                 (usage limit / 5-hour limit / limit reached / rate limit /
#                 approaching usage). Process alive, just capped.
#   stalled       pane mid-turn ("esc to interrupt") but transcript stale —
#                 hung tool, rate-limited mid-turn, or crashed. This is the
#                 case the heartbeat already paints 🔴; alerting it actively
#                 closes the same "Claude can't self-report" gap.
#   silent        pane in unknown/uncertain state AND transcript stale
#                 beyond SWARM_SILENCE_SECONDS. The case that bit the
#                 operator — TUI in a state our matchers don't recognize,
#                 nothing being produced, nobody alerting.
#   down          tmux session is gone. Process dead.
#
# Recovery is silent: a bad → ok transition does NOT post (heartbeat
# already returns to 🟢; channel-as-event-log stays readable). The
# alerter does track ok so re-entering a bad state from ok will fire
# a fresh alert.
#
# Trust root. The alerter assumes the WATCHER ITSELF is alive — that is
# what makes it independent of the CTO. launchd's StartInterval=10 keeps
# this script firing; if launchd or this binary dies, nothing alerts. The
# alerter cannot detect its own death. Out of scope here; flagged so the
# operator knows where the chain ends.
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
CURL_MAX_TIME="${SWARM_WATCH_CURL_TIMEOUT:-5}"
# Active-alert thresholds. SILENCE_SECONDS is the transcript-staleness floor
# under which we DON'T fire a "silent" alert — chosen meaningfully above
# STALE_SECONDS (5m by default) so a briefly-quiet swarm only paints the
# heartbeat's 🔴 STALLED and doesn't also push. Override in env if a fleet
# has known longer healthy quiet windows.
SILENCE_SECONDS="${SWARM_SILENCE_SECONDS:-900}"
# Optional Discord mention prefix for active alerts. Empty by default —
# Discord's new-message badge already fires on any POST to a channel the
# operator is subscribed to. Set to "@here" (or a role mention) if the
# default channel notification is not enough.
ALERT_MENTION="${SWARM_ALERT_MENTION:-}"

mkdir -p "$STATE_DIR"

# Single-instance lock. At StartInterval=10 the chance of an overlap
# fire grows with the fleet size — a slow capture or rate-limited curl
# in tick N can outlive tick N+1's launch. Without a guard, two
# instances race on heartbeat-$channel.id and heartbeat-$channel.content
# and on the Discord PATCH itself. mkdir is atomic on POSIX; exactly one
# caller wins. Stale-lock recovery covers abnormal exits (kill -9,
# reboot mid-run) via the PID-alive check.
LOCK="$STATE_DIR/swarm-watch.lock"
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  local owner=""
  [ -f "$LOCK/pid" ] && owner="$(tr -d '[:space:]' < "$LOCK/pid" 2>/dev/null)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    return 1   # honest contention — caller bails (no-op this tick)
  fi
  # Stale lock (owner dead or never wrote PID). Clean and retry once.
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  return 1   # lost the cleanup race; bail
}
acquire_lock || { echo "swarm-watch: previous instance still running — skipping this tick" >&2; exit 0; }
trap 'rm -rf "$LOCK"' EXIT
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

post_heartbeat() {  # channel token content
  local channel="$1" token="$2" content="$3"
  local idfile="$STATE_DIR/heartbeat-$channel.id"
  local contentfile="$STATE_DIR/heartbeat-$channel.content"
  local msgid=""
  [ -r "$idfile" ] && msgid="$(tr -d '[:space:]' < "$idfile")"

  # Change-guard. The pinned heartbeat is edited via PATCH; at a 10s
  # StartInterval an unconditional edit is 8,640 API calls/day/channel
  # — straight into Discord rate limits and pure waste while state is
  # stable. We compare the new rendered content against the last
  # successfully-posted content (persisted alongside the message id);
  # identical → no-op. Operators read liveness off Discord's native
  # "edited Nm ago" indicator on the pinned message, which is more
  # honest than a script-written timestamp anyway. Realistic post-fix
  # volume: ~edits per state transition (working → ready → working …),
  # measured in dozens/day, not thousands.
  if [ -n "$msgid" ] && [ -r "$contentfile" ]; then
    local prior; prior="$(cat "$contentfile" 2>/dev/null)"
    if [ "$prior" = "$content" ]; then
      return 0
    fi
  fi

  local payload; payload="$(json_content "$content")"
  if [ -n "$msgid" ]; then
    local code
    # --max-time bounds each network call so a hung Discord request
    # can't make this fire outlive the 10s launchd interval (instance
    # overlap risk; the lock catches the rest).
    code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X PATCH \
      -H "Authorization: Bot $token" -H "Content-Type: application/json" \
      -d "$payload" "$API/channels/$channel/messages/$msgid")"
    # 200 = edited in place; pin (set on initial POST) is sticky on edits.
    if [ "$code" = "200" ]; then
      printf '%s' "$content" > "$contentfile"
      return 0
    fi
    # Anything else (404 deleted, timeout, etc.): fall through to POST + re-pin.
  fi
  local newid
  newid="$(curl --max-time "$CURL_MAX_TIME" -s -X POST -H "Authorization: Bot $token" -H "Content-Type: application/json" \
    -d "$payload" "$API/channels/$channel/messages" | extract_id)"
  if [ -z "$newid" ]; then
    echo "swarm-watch: heartbeat POST returned no id for channel $channel" >&2
    return 0
  fi
  printf '%s' "$newid" > "$idfile"
  printf '%s' "$content" > "$contentfile"
  pin_message "$channel" "$token" "$newid"
}

# Active push-alert. Posts a NEW message (no edit, no pin) to the channel
# when a swarm transitions into a known-bad state. Change-guarded against
# $STATE_DIR/alert-$channel.state — the file holds the LAST state we
# posted about. Transitions:
#   ok           -> bad          POST + record bad
#   bad-A        -> bad-B        POST + record bad-B  (state changed)
#   bad          -> ok           record ok (no post — heartbeat already
#                                returns to 🟢; bad-as-event-log stays
#                                readable in the channel)
#   ok           -> ok           no-op
# The state file is created on first observation, so even on the very
# first watcher run an immediate bad state fires exactly once.
post_alert() {  # channel token state content
  local channel="$1" token="$2" state="$3" content="$4"
  local statefile="$STATE_DIR/alert-$channel.state"
  local prior=""
  [ -r "$statefile" ] && prior="$(tr -d '[:space:]' < "$statefile" 2>/dev/null)"
  if [ "$prior" = "$state" ]; then
    return 0
  fi
  # Only POST on transition INTO a bad state (or bad-to-different-bad).
  # Bad-to-ok updates the state file but stays quiet.
  if [ "$state" != "ok" ]; then
    local body="$content"
    [ -n "$ALERT_MENTION" ] && body="$ALERT_MENTION $content"
    local payload; payload="$(json_content "$body")"
    local code
    code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bot $token" -H "Content-Type: application/json" \
      -d "$payload" "$API/channels/$channel/messages")"
    case "$code" in
      200|201) ;;
      *)
        echo "swarm-watch: alert POST failed for channel $channel (HTTP $code, state=$state)" >&2
        # On POST failure we do NOT update the state file — next tick
        # will retry. This is the only place where we want to RE-attempt
        # the same transition; cap-at-once relies on the post succeeding.
        return 0
        ;;
    esac
  fi
  printf '%s' "$state" > "$statefile"
}

# Pin the heartbeat so it stays reachable via the channel's pin icon as the
# conversation scrolls. Only called when (re)posting fresh; subsequent edits
# don't re-pin. Failures are logged, never fatal.
pin_message() {  # channel token messageid
  local channel="$1" token="$2" msgid="$3"
  local code
  code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X PUT \
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

  # Alert-state token. Default ok; bumped by the branches below when the
  # swarm is in a known-bad state. Held alongside the heartbeat status so
  # the existing heartbeat-content rendering is left intact and we don't
  # have to derive two parallel state machines from raw signals.
  alert_state="ok"
  alert_msg=""

  if [ "$alive" -eq 0 ]; then
    status="⚪ swarm down (no session)"; age="—"
    alert_state="down"
    alert_msg="⚪ swarm \`$name\` · DOWN — tmux session gone. Process dead; \`swarm-up.sh up $name\` to restart."
  elif [ "$a" -eq "$SWARM_NO_TRANSCRIPT_AGE" ]; then
    if [ "$alive" -eq 1 ]; then status="🟡 swarm starting (no transcript yet)"; else status="⚪ no active session"; fi
    age="—"
  else
    if [ "$a" -lt 60 ]; then age="${a}s"; else age="$(( a/60 ))m"; fi
    # Pane state — the finer-grained pane_state replaces pane_working
    # here because the alerter needs to distinguish "paused on a known
    # limit" from "pane in unknown state". pane_working semantics are
    # preserved via the 0/working and !=0/not-working split below; the
    # extra cases (paused-limit / unknown / at-prompt) feed the alerter.
    pane_state "${PREFIX}-$name" "$TMUX_BIN"; ps=$?
    pane_detail="$SWARM_PANE_STATE_DETAIL"
    fresh=0; [ "$a" -le "$STALE_SECONDS" ] && fresh=1
    if [ "$ps" -eq 0 ] && [ "$fresh" -eq 1 ]; then
      # Pane mid-turn AND transcript fresh — actually producing. If
      # teammates are the writers, surface the count so the heartbeat
      # distinguishes "lead is hot" from "lead in tool call, N teammates
      # cranking" (the original motivation for the teammate scan).
      if [ "${tn:-0}" -gt 0 ]; then
        if [ "$tn" -eq 1 ]; then plural=""; else plural="s"; fi
        status="🟢 swarm working · $tn teammate${plural} active"
      else
        status="🟢 swarm working"
      fi
      [ "$ENABLE_TYPING" = "1" ] && curl --max-time "$CURL_MAX_TIME" -s -X POST -H "Authorization: Bot $token" "$API/channels/$channel/typing" >/dev/null 2>&1 || true
    elif [ "$ps" -eq 0 ] && [ "$fresh" -eq 0 ]; then
      # Footer says "esc to interrupt" but no transcript write for
      # STALE_SECONDS+ — turn in flight from the TUI's view but nothing
      # is being produced. Rate-limited, hung tool, or crashed.
      status="🔴 swarm STALLED — turn in flight but no transcript writes (rate-limited, hung tool, or crashed)"
      alert_state="stalled"
      alert_msg="🔴 swarm \`$name\` · STALLED — turn in flight (\"esc to interrupt\") but no transcript writes for ${age}. Hung tool, rate-limited mid-turn, or crashed. Investigate the tmux pane."
    elif [ "$ps" -eq 2 ]; then
      # Paused on a known Claude Code usage/rate limit. Process alive,
      # just capped. This is the case the CTO can NOT self-report —
      # no tool calls possible while throttled — so the watcher must.
      reset_hint="$(parse_limit_reset "$pane_detail")"
      if [ -n "$reset_hint" ]; then
        status="🟡 swarm paused on usage limit (resets $reset_hint)"
        alert_msg="🟡 swarm \`$name\` · PAUSED ON USAGE LIMIT — resets $reset_hint. Not a crash; work will resume at reset."
      else
        status="🟡 swarm paused on usage limit"
        alert_msg="🟡 swarm \`$name\` · PAUSED ON USAGE LIMIT — reset time not parseable; check the tmux pane. Not a crash."
      fi
      alert_state="paused-limit"
    elif [ "$ps" -eq 1 ]; then
      # Pane at clean prompt ("← for agents"). Idle-at-prompt is a
      # LEGITIMATE state — the operator hasn't sent a turn in N minutes.
      # Never alert on this no matter how stale; fail-safe to "ready".
      if [ "$fresh" -eq 1 ]; then
        status="🟢 swarm ready · waiting for input (just replied)"
      else
        status="🟢 swarm ready · waiting for input"
      fi
    else
      # ps=3 (unknown footer) or ps=4 (capture failed) — the pane is
      # not readable as any known state. While transcript is fresh,
      # treat as benign (something IS being written, the footer is
      # just in a sub-UI). If transcript exceeds SILENCE_SECONDS — well
      # above the heartbeat's 5m STALE — push a SILENT alert. This is
      # the case that produced DEAD SILENCE overnight: TUI in a state
      # we don't recognize, nothing being produced, no Claude to
      # self-report.
      if [ "$fresh" -eq 1 ]; then
        status="🟢 swarm ready · waiting for input (just replied)"
      else
        status="🟢 swarm ready · waiting for input"
      fi
      if [ "$a" -gt "$SILENCE_SECONDS" ]; then
        if [ "$a" -lt 3600 ]; then silence_age="$(( a/60 ))m"; else silence_age="$(( a/3600 ))h"; fi
        alert_state="silent"
        alert_msg="🔴 swarm \`$name\` · SILENT — no recognized pane state, no working signal, no known limit message, transcript stale ${silence_age}. The CTO can't self-report; investigate the tmux pane (\`tmux attach -t ${PREFIX}-$name\`)."
      fi
    fi
  fi

  # No dynamic-time substrings in the rendered content — they would defeat
  # the change-guard (any per-second tick → content always "changes" →
  # unconditional edits → rate-limit trap). Discord's native "(edited Nm
  # ago)" indicator on the pinned message is the operator's elapsed-time
  # signal, and it's the real last-edit time, not a script claim. The age
  # variable above is still used by the predicate but does NOT appear in
  # rendered output.
  content="$status · $name"
  post_heartbeat "$channel" "$token" "$content"
  # Active push-alert AFTER the heartbeat update. Order matters only for
  # operator narrative — they see the heartbeat reflect the new state at
  # the same tick as the alert. Both flow through the watcher's direct
  # curl to Discord; neither depends on the swarm/CTO being responsive.
  post_alert "$channel" "$token" "$alert_state" "$alert_msg"
done

exit 0
