#!/usr/bin/env bash
# swarm-watch.sh — EXTERNAL multi-swarm liveness monitor + active alerter.
#
# launchd fires this on an interval. It reads the SAME $SWARM_HOME/swarm.conf that
# swarm-up.sh uses, and posts a per-channel heartbeat for EACH configured swarm,
# using that swarm's own bot token. ONE launchd job covers all swarms.
#
# swarm.conf line (pipe-separated, 5 fields):
#     name | /path/to/repo | TOKEN_VAR | CHANNEL_ID | GUILD_ID
# Token resolved from $SWARM_HOME/tokens.env (TOKEN_VAR -> bot token), exactly as
# swarm-up.sh does. The heartbeat for a swarm is posted by that swarm's own bot,
# into that swarm's channel. GUILD_ID is the Discord guild (server) snowflake;
# consumers use channel+guild_id to build `discord://channels/<guild>/<channel>`
# deep-links. Blank GUILD_ID is tolerated (status emit serializes null per the
# frozen swarm-status/v1 contract transition window) but consumers will degrade
# gracefully (no deep-link). The 4-field legacy line shape is no longer
# emitted by swarm-add but still parsed — channel becomes the last present
# field and guild_id is treated as blank.
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
# Projects dir is resolved PER-SWARM inside the loop (multi-account partition):
# each row's account label (field 6) maps to THAT swarm's projects dir via
# swarm_account_resolve. A single global dir would read the WRONG account's
# transcripts for a labeled swarm and disarm the WORKING rail. The default
# (empty) account resolves to ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects},
# byte-identical to the value this script used before partitioning.
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

# iOS-widget status feed. Both optional; both required to enable the POST.
# When unset, $STATE_DIR/status.json is still written locally — it's the
# source-of-truth snapshot that downstream consumers (Railway, future
# local readers) consume. The POST is a separate, best-effort transport
# on top of that file.
STATUS_ENDPOINT="${SWARM_STATUS_ENDPOINT:-}"
STATUS_SECRET="${SWARM_STATUS_SECRET:-}"

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

# Per-tick status accumulator. Each swarm appends one JSON object (one line)
# here; the assembler at the end of the tick wraps the lines into the full
# status.json structure. Truncate at the start so a previous tick's content
# never leaks into this one.
STATUS_SWARMS_TMP="$STATE_DIR/status.swarms.tmp"
: > "$STATUS_SWARMS_TMP"

# Append one swarm's status JSON to the accumulator. Per-line build delegated
# to bin/swarm-status-emit.py — a standalone helper so the wire shape can be
# unit-tested against the frozen swarm-status/v1 schema examples without
# standing up the whole watcher. Two-source needs_attention rule + compound-
# reason format live in that script (single source of truth for the emit).
emit_status() {  # name channel guild_id state age_or_empty reset_or_empty
  local name="$1" channel="$2" guild_id="$3" state="$4" age="$5" reset="$6"
  local flagfile="$STATE_DIR/attention-$channel.flag"
  local cto_reason=""
  if [ -r "$flagfile" ]; then
    # Trim trailing newline; length-capped on write so we don't re-cap here.
    cto_reason="$(tr -d '\000-\037' < "$flagfile")"
  fi
  python3 "$(cd "$(dirname "$0")" && pwd)/swarm-status-emit.py" \
    "$name" "$channel" "$guild_id" "$state" "$age" "$reset" "$cto_reason" \
    >> "$STATUS_SWARMS_TMP"
}

grep -vE '^[[:space:]]*(#|$)' "$CONF" | while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  name="$SWARM_CONF_F_NAME"
  repo="$SWARM_CONF_F_REPO"
  tokvar="$SWARM_CONF_F_TOKVAR"
  channel="$SWARM_CONF_F_CHANNEL"
  guild_id="$SWARM_CONF_F_GUILD"
  [ -z "$name" ] && continue
  [ -z "$channel" ] && { echo "swarm-watch: $name has no CHANNEL_ID (4th field) — skipping" >&2; continue; }

  token="${!tokvar:-}"
  [ -z "$token" ] && { echo "swarm-watch: no token in \$$tokvar for $name — skipping" >&2; continue; }

  case "$repo" in "~"*) repo="$HOME${repo#\~}";; esac

  # Resolve THIS swarm's projects dir from ITS account (field 6). Empty account
  # → ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects} (default, byte-identical to
  # the pre-partition global). Labeled → $HOME/.claude-accounts/<label>/projects.
  # swarm_account_resolve is the SOLE constructor of these paths; resolving here
  # — per swarm, after the parse — is what keeps the WORKING rail (repo_activity)
  # pointed at the right account so a live swarm is never read as stale.
  if ! swarm_account_resolve "$SWARM_CONF_F_ACCOUNT"; then
    # Invalid account label → resolver rejected (path NOT built; $SWARM_ACCT_* is
    # STALE from a prior row). Don't probe a stale/foreign projects dir. Skip this
    # swarm's activity read this tick (fail-safe — a missed heartbeat is harmless,
    # a wrong-dir read that paints a live swarm STALLED is not).
    echo "swarm-watch: WARN — '$name' has an invalid account '$SWARM_CONF_F_ACCOUNT'; skipping its activity probe. Fix the swarm.conf ACCOUNT field." >&2
    continue
  fi
  projects="$SWARM_ACCT_PROJECTS_DIR"

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
  activity="$(repo_activity "$repo" "$projects" "$STALE_SECONDS")"
  a="${activity%%|*}"
  tn="${activity##*|}"
  case "$a" in ''|*[!0-9]*) a="$SWARM_NO_TRANSCRIPT_AGE" ;; esac  # paranoia

  # Alert-state token. Default ok; bumped by the branches below when the
  # swarm is in a known-bad state. Held alongside the heartbeat status so
  # the existing heartbeat-content rendering is left intact and we don't
  # have to derive two parallel state machines from raw signals.
  alert_state="ok"
  alert_msg=""

  # status_state — the enum the iOS-widget status.json schema uses. Parallel
  # to alert_state (which is alert/no-alert), this names the swarm's
  # condition for downstream consumers. age_secs_for_status carries the raw
  # seconds integer (or empty when no transcript). limit_reset_for_status
  # holds the reset hint when state is paused-limit.
  status_state="ready"
  age_secs_for_status=""
  limit_reset_for_status=""

  if [ "$alive" -eq 0 ]; then
    status="⚪ swarm down (no session)"; age="—"
    alert_state="down"
    alert_msg="⚪ swarm \`$name\` · DOWN — tmux session gone. Process dead; \`swarm-up.sh up $name\` to restart."
    status_state="down"
  elif [ "$a" -eq "$SWARM_NO_TRANSCRIPT_AGE" ]; then
    if [ "$alive" -eq 1 ]; then status="🟡 swarm starting (no transcript yet)"; status_state="starting"; else status="⚪ no active session"; status_state="down"; fi
    age="—"
  else
    if [ "$a" -lt 60 ]; then age="${a}s"; else age="$(( a/60 ))m"; fi
    age_secs_for_status="$a"
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
      status_state="working"
    elif [ "$ps" -eq 0 ] && [ "$fresh" -eq 0 ]; then
      # Footer says "esc to interrupt" but no transcript write for
      # STALE_SECONDS+ — turn in flight from the TUI's view but nothing
      # is being produced. Rate-limited, hung tool, or crashed.
      status="🔴 swarm STALLED — turn in flight but no transcript writes (rate-limited, hung tool, or crashed)"
      alert_state="stalled"
      alert_msg="🔴 swarm \`$name\` · STALLED — turn in flight (\"esc to interrupt\") but no transcript writes for ${age}. Hung tool, rate-limited mid-turn, or crashed. Investigate the tmux pane."
      status_state="stalled"
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
      status_state="paused-limit"
      limit_reset_for_status="$reset_hint"
    elif [ "$ps" -eq 1 ]; then
      # Pane at clean prompt ("← for agents"). Idle-at-prompt is a
      # LEGITIMATE state — the operator hasn't sent a turn in N minutes.
      # Never alert on this no matter how stale; fail-safe to "ready".
      if [ "$fresh" -eq 1 ]; then
        status="🟢 swarm ready · waiting for input (just replied)"
      else
        status="🟢 swarm ready · waiting for input"
      fi
      status_state="ready"
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
      status_state="ready"
      if [ "$a" -gt "$SILENCE_SECONDS" ]; then
        if [ "$a" -lt 3600 ]; then silence_age="$(( a/60 ))m"; else silence_age="$(( a/3600 ))h"; fi
        alert_state="silent"
        alert_msg="🔴 swarm \`$name\` · SILENT — no recognized pane state, no working signal, no known limit message, transcript stale ${silence_age}. The CTO can't self-report; investigate the tmux pane (\`tmux attach -t ${PREFIX}-$name\`)."
        status_state="silent"
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
  # iOS-widget status fragment. emit_status reads the CTO's attention flag
  # file (if any) and writes one JSON line per swarm into the accumulator.
  # The assembler after the loop wraps the lines and writes status.json.
  emit_status "$name" "$channel" "$guild_id" "$status_state" "$age_secs_for_status" "$limit_reset_for_status"
done

# ---------------------------------------------------------------------------
# iOS-widget status feed. Two stages:
#   1) Assemble per-swarm fragments into $STATE_DIR/status.json (atomic).
#      This file is the LOCAL source of truth — written every tick, whether
#      or not the Railway endpoint is configured.
#   2) POST to Railway endpoint when both SWARM_STATUS_ENDPOINT and
#      SWARM_STATUS_SECRET are set. Change-guarded against a stable
#      signature so a steady-state fleet produces zero POSTs.
# Failures of either stage log to watch.err and do not disrupt the tick's
# core heartbeat/alert duties — status-feed is best-effort, alerting is not.
# ---------------------------------------------------------------------------
STATUS_FILE="$STATE_DIR/status.json"

if [ -s "$STATUS_SWARMS_TMP" ]; then
  status_tmp="$STATUS_FILE.tmp.$$"
  python3 - "$STATUS_SWARMS_TMP" "$status_tmp" <<'PY' || echo "swarm-watch: status.json assembly failed" >&2
import json, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
swarms = []
with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            swarms.append(json.loads(line))
        except Exception as e:
            # Drop the malformed fragment rather than blow up the whole
            # snapshot. Logged so it surfaces; widget keeps rendering the
            # other swarms.
            sys.stderr.write("swarm-watch: dropping malformed status fragment: " + str(e) + "\n")
out = {
    "schema": "swarm-status/v1",
    "generated_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "swarms": swarms,
}
with open(dst, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
  if [ -f "$status_tmp" ]; then
    mv "$status_tmp" "$STATUS_FILE"
  fi
fi
rm -f "$STATUS_SWARMS_TMP"

# Railway POST — only if BOTH config vars are set. The endpoint URL alone
# isn't enough (no auth means anyone with the URL could spoof); the secret
# alone isn't enough (nowhere to send). Both required.
if [ -n "$STATUS_ENDPOINT" ] && [ -n "$STATUS_SECRET" ] && [ -f "$STATUS_FILE" ]; then
  # Stable signature for the change-guard. EXCLUDES last_activity_age_seconds
  # (drifts every tick — would defeat the guard entirely) and generated_at
  # (timestamp — same problem). INCLUDES state, needs_attention, attention
  # source/reason, and limit_reset_hint per swarm — so transitions and
  # attention changes flip the signature and push promptly, but steady-
  # state produces zero POSTs.
  STATUS_SIG_FILE="$STATE_DIR/status.last-posted.sig"
  current_sig="$(python3 - "$STATUS_FILE" <<'PY'
import json, sys, hashlib
with open(sys.argv[1]) as f:
    s = json.load(f)
parts = []
for sw in s.get("swarms", []):
    parts.append("|".join([
        str(sw.get("name", "")),
        str(sw.get("channel", "")),
        str(sw.get("guild_id") or ""),
        str(sw.get("state", "")),
        str(sw.get("needs_attention", "")),
        str(sw.get("attention_source") or ""),
        str(sw.get("attention_reason") or ""),
        str(sw.get("limit_reset_hint") or ""),
    ]))
sig = hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()
print(sig)
PY
  )"
  prior_sig=""
  [ -r "$STATUS_SIG_FILE" ] && prior_sig="$(cat "$STATUS_SIG_FILE" 2>/dev/null)"
  if [ "$current_sig" != "$prior_sig" ]; then
    # --max-time bounds the POST so a slow Railway response can't wedge
    # the 10s tick. Fail-safe: any non-2xx logs and continues; the sig
    # file isn't updated, so the next tick naturally retries.
    code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $STATUS_SECRET" \
      -H "Content-Type: application/json" \
      --data-binary "@$STATUS_FILE" \
      "$STATUS_ENDPOINT" 2>/dev/null)"
    case "$code" in
      200|201|202|204)
        printf '%s' "$current_sig" > "$STATUS_SIG_FILE"
        ;;
      *)
        echo "swarm-watch: status POST failed (HTTP ${code:-network-error}) — endpoint=$STATUS_ENDPOINT" >&2
        ;;
    esac
  fi
fi

exit 0
