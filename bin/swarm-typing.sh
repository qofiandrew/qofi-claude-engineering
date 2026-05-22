#!/usr/bin/env bash
# swarm-typing.sh — PERSISTENT multi-swarm typing-indicator pinger.
#
# launchd starts this once with KeepAlive=true; it loops forever (NOT a
# one-shot like swarm-watch.sh). Every ~8s, for each swarm in swarm.conf
# that is *actively working* (tmux session alive AND newest transcript
# mtime within STALE_SECONDS), POST to Discord /channels/<id>/typing using
# that swarm's bot token. Discord's "is typing…" expires ~10s; an 8s
# cadence keeps the bubble continuous.
#
# Working == the exact same predicate swarm-watch.sh paints as 🟢 working
# (line 155–157): alive + has-transcript + age <= STALE_SECONDS. The
# "🟢 ready · waiting for input" branch (stale + not mid-turn) is
# deliberately EXCLUDED — typing means "actively producing," not "alive
# at the prompt." Down / starting / stalled are also skipped.
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
CLAUDE_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
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
while IFS='|' read -r name repo tokvar channel; do
  name="$(echo "${name:-}" | xargs)"
  tokvar="$(echo "${tokvar:-}" | xargs)"
  channel="$(echo "${channel:-}" | xargs)"
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

  while IFS='|' read -r name repo tokvar channel; do
    name="$(echo "${name:-}" | xargs)"
    repo="$(echo "${repo:-}" | xargs)"
    tokvar="$(echo "${tokvar:-}" | xargs)"
    channel="$(echo "${channel:-}" | xargs)"
    [ -z "$name" ] && continue
    [ -z "$channel" ] && continue

    token="${!tokvar:-}"
    [ -z "$token" ] && continue

    case "$repo" in "~"*) repo="$HOME${repo#\~}";; esac

    # Predicate: tmux session alive AND newest transcript (lead OR any
    # teammate worktree) is within STALE_SECONDS. The teammate-count field
    # the watcher uses is irrelevant here — typing is a boolean.
    #
    # FAIL-SAFE IS SILENCE. If repo_activity returns anything other than
    # an unambiguously-fresh age, we DO NOT fire. Empty/non-numeric (the
    # function shouldn't produce these, but defend in depth) and the
    # SWARM_NO_TRANSCRIPT_AGE sentinel both fall through the stale check
    # because the sentinel is much larger than any plausible
    # STALE_SECONDS. The previous "empty → skip" branch was correct, but
    # `[ "$age" -gt N ]` errors loudly on non-numeric input under
    # `set -u`, so we screen with a pattern match first.
    session_alive "$name" || continue   # rc 1 (down) or 2 (no tmux) → skip
    activity="$(repo_activity "$repo" "$CLAUDE_PROJECTS" "$STALE_SECONDS")"
    age="${activity%%|*}"
    case "$age" in
      ''|*[!0-9]*) continue ;;          # blank / non-numeric → uncertain → silent
    esac
    [ "$age" -gt "$STALE_SECONDS" ] && continue   # stale, starting, or sentinel → skip

    # Fire and forget. --max-time guards against a wedged Discord request
    # hanging the loop. Output is dropped; the next sweep retries 8s later.
    curl --max-time "$CURL_MAX_TIME" -s -X POST \
      -H "Authorization: Bot $token" \
      "$API/channels/$channel/typing" \
      >/dev/null 2>&1 || true
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

  sleep "$SLEEP_SECONDS"
done
