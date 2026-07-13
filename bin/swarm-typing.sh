#!/usr/bin/env bash
# swarm-typing.sh — PERSISTENT multi-swarm typing-indicator pinger.
#
# launchd starts this once with KeepAlive=true; it loops forever (NOT a
# one-shot like swarm-watch.sh). Every ~8s, for each swarm in swarm.conf
# that is *actively working*, POST to Discord /channels/<id>/typing using
# that swarm's bot token. Discord's "is typing…" expires ~10s; an 8s
# cadence keeps the bubble continuous.
#
# Working == the exact same predicate swarm-watch.sh paints as 🟢 working:
# alive AND pane shows "esc to interrupt" AND transcript fresh. All three
# required.
#
# Pane gate (PRIMARY signal — pane_working from swarm-lib.sh):
#   The Claude TUI footer ends with "esc to interrupt" iff a turn is in
#   flight; at the prompt it ends with "← for agents". We grep the whole
#   capture for that substring. This replaces the earlier age-only gate.
#   Age cannot distinguish "replied N seconds ago, now idle" from
#   "actively producing" — for the full STALE_SECONDS window after any
#   reply, an idle lead reads as fresh and would false-fire typing.
#
# Transcript-fresh gate (belt-and-suspenders): if the pane says working
# but the transcript hasn't moved within STALE_SECONDS, the swarm is
# STALLED (rate-limited, hung tool, or crashed). Forever-typing on a
# hung swarm is the worst UX, so we also require recent transcript
# activity. Matches swarm-watch's STALLED state — typing stays silent
# while the heartbeat shows 🔴 STALLED.
#
# Uncertain pane (tmux missing / capture failed) → silent. Same with
# unreadable transcript age. The fail-safe is silence everywhere.
#
# Why a separate process from swarm-watch: the watcher fires once every
# 90s; typing expires in ~10s. The two cadences are incompatible. This
# script owns the typing bubble; the watcher owns the heartbeat. Run
# swarm-watch.sh with SWARM_ENABLE_TYPING=0 so they don't double-fire.
#
# Failure mode honesty:
#   - If this script EXITS, launchd's KeepAlive relaunches it.
#   - If this script HANGS, KeepAlive cannot detect it. We use
#     `curl --max-time 5` on every network call so a stalled Discord
#     request can't wedge the loop — the curl returns nonzero, we
#     swallow it, and the next 8s sweep proceeds.
#   - Liveness/heartbeat is unaffected by typing failures — that lives
#     in the separate swarm-watch.sh process.
#
# bash 3.2-safe (macOS default). python3 for mtime.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-typing: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
CONF="$SWARM_HOME/swarm.conf"
TOKENS="$SWARM_HOME/tokens.env"
# Projects dir is resolved PER-SWARM inside the sweep loop (multi-account
# partition): each row's account label (field 6) maps to THAT swarm's projects
# dir via swarm_account_resolve. A single global dir would read the WRONG
# account's transcripts for a labeled swarm — here that would silently SUPPRESS
# the typing bubble (transcript reads as stale). The default (empty) account
# resolves to ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}, byte-identical to
# the value this script used before partitioning.
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
API="${SWARM_DISCORD_API:-https://discord.com/api/v10}"
SLEEP_SECONDS="${SWARM_TYPING_SLEEP:-8}"
CURL_MAX_TIME="${SWARM_TYPING_CURL_TIMEOUT:-5}"

# Clean exit on SIGTERM (launchd stop / unload) and SIGINT (Ctrl-C in dev).
# Curl already has --max-time, so any in-flight network call returns in
# well under the launchd KillMode timeout.
trap 'echo "swarm-typing: exiting on signal" >&2; exit 0' TERM INT

# Shared repo_activity helper. Fires typing when ANY transcript (lead or
# per-teammate worktree) is fresher than STALE_SECONDS — the watcher uses
# the same helper for its 🟢-working decision, so the typing bubble and the
# heartbeat can never disagree on "is this swarm producing?". See swarm-lib.sh.
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/swarm-lib.sh"

session_alive() {  # name -> 0 alive, 1 absent, 2 tmux unknown
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 2
  "$TMUX_BIN" has-session -t "${PREFIX}-$1" 2>/dev/null
}

# Startup config sanity: warn (once) about any rows missing a token var or
# channel, so misconfiguration is visible at launchd-load time. Inside the
# loop we're silent to avoid log explosion (~10k sweeps/day).
echo "swarm-typing: starting (sleep=${SLEEP_SECONDS}s, stale=${STALE_SECONDS}s, conf=$CONF)" >&2
# shellcheck disable=SC1090
[ -f "$TOKENS" ] && . "$TOKENS"
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  name="$SWARM_CONF_F_NAME"
  tokvar="$SWARM_CONF_F_TOKVAR"
  channel="$SWARM_CONF_F_CHANNEL"
  [ -z "$name" ] && continue
  if [ -z "$channel" ]; then
    echo "swarm-typing: $name has no CHANNEL_ID (4th field) — will skip" >&2
    continue
  fi
  if [ -z "${!tokvar:-}" ]; then
    echo "swarm-typing: no token in \$$tokvar for $name — will skip" >&2
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

while :; do
  # Re-source tokens.env each sweep so a token rotation propagates without
  # restart. Cheap (one shell-include of a small file).
  # shellcheck disable=SC1090
  [ -f "$TOKENS" ] && . "$TOKENS"

  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    name="$SWARM_CONF_F_NAME"
    repo="$SWARM_CONF_F_REPO"
    tokvar="$SWARM_CONF_F_TOKVAR"
    channel="$SWARM_CONF_F_CHANNEL"
    engine="$SWARM_CONF_F_ENGINE"
    [ -z "$name" ] && continue
    [ -z "$channel" ] && continue

    token="${!tokvar:-}"
    [ -z "$token" ] && continue

    case "$repo" in "~"*) repo="$HOME${repo#\~}";; esac

    if [ "$engine" = "codex" ]; then
      # The Codex bridge owns an engine-native active bit; no Claude footer or
      # transcript exists. Any missing/stale/malformed state fails silent.
      session_alive "$name" || continue
      swarm_codex_runtime_read "$name" || continue
      [ "$SWARM_CODEX_RUNTIME_READY" -eq 1 ] || continue
      [ "$SWARM_CODEX_RUNTIME_ACTIVE" -eq 1 ] || continue
      curl --max-time "$CURL_MAX_TIME" -s -X POST \
        -H "Authorization: Bot $token" \
        "$API/channels/$channel/typing" \
        >/dev/null 2>&1 || true
      continue
    fi

    # Resolve THIS swarm's projects dir from ITS account (field 6). Empty
    # account → ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects} (default,
    # byte-identical to the pre-partition global). Labeled →
    # $HOME/.claude-accounts/<label>/projects. swarm_account_resolve is the SOLE
    # constructor; resolving per-swarm keeps the freshness gate reading the right
    # account so the typing bubble matches the watcher's 🟢-working decision.
    if ! swarm_account_resolve "$SWARM_CONF_F_ACCOUNT"; then
      # Invalid account → resolver rejected (path NOT built; stale globals). Don't
      # probe a stale/foreign dir; skip (typing's fail-safe is already silence).
      continue
    fi
    projects="$SWARM_ACCT_PROJECTS_DIR"

    # Predicate: session alive AND pane shows "esc to interrupt" AND
    # transcript fresh. All three required; any uncertainty → silent.
    #
    # 1) session_alive: cheap tmux has-session probe; bail early on down.
    # 2) pane_working: PRIMARY signal — was the original bug's missing
    #    piece. rc=0 working, rc=1 idle (at prompt), rc=2 uncertain
    #    (capture failed / tmux missing / empty pane). Only rc=0 fires.
    # 3) transcript freshness: belt-and-suspenders. If the pane reads
    #    mid-turn but the transcript hasn't moved for STALE_SECONDS,
    #    the swarm is STALLED — typing would lie to Discord. The
    #    NO_TRANSCRIPT sentinel naturally fails the `<= STALE_SECONDS`
    #    test; non-numeric output is screened first so set -u stays happy.
    session_alive "$name" || continue
    pane_working "${PREFIX}-$name" "$TMUX_BIN" || continue
    activity="$(repo_activity "$repo" "$projects" "$STALE_SECONDS")"
    age="${activity%%|*}"
    case "$age" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$age" -gt "$STALE_SECONDS" ] && continue   # stalled, starting, or sentinel → skip

    # Fire and forget. --max-time guards against a wedged Discord request
    # hanging the loop. Output is dropped; the next sweep retries 8s later.
    curl --max-time "$CURL_MAX_TIME" -s -X POST \
      -H "Authorization: Bot $token" \
      "$API/channels/$channel/typing" \
      >/dev/null 2>&1 || true
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

  # Deterministic one-sweep seam for regression tests and manual diagnostics;
  # the launchd/default path remains the historical infinite loop.
  [ "${SWARM_TYPING_ONCE:-0}" = "1" ] && break
  sleep "$SLEEP_SECONDS"
done
