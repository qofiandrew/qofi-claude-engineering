#!/usr/bin/env bash
# swarm-restart.sh — cycle ONE swarm: down then up.
#
# Usage:
#   swarm-restart.sh <name> [--force]
#
# What it does:
#   swarm-up.sh down <name>      # kill only this swarm's tmux session
#   swarm-up.sh up   <name>      # relaunch from the current on-disk state
#
# What it does NOT do:
#   Sync from templates. This is "reload session from disk" only. To pull
#   the latest templates into the repo AND restart the session in one step,
#   use swarm-update.sh instead.
#
# Safety rail (the WORKING check):
#   Before tearing down, query the shared liveness signal (repo_activity
#   in swarm-lib.sh — the same signal swarm-watch.sh uses for the
#   heartbeat). If the swarm has produced a transcript write within
#   ${SWARM_STALE_SECONDS:-300} seconds, it is currently WORKING and
#   restart will lose any uncommitted in-process teammate work. In that
#   case the script REFUSES unless --force is given. Flag-driven, no
#   interactive prompts.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-restart: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so swarm-update.sh can substitute a stub in tests.
SWARM_UP="${SWARM_UP_BIN:-$SCRIPT_DIR/swarm-up.sh}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"

# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

usage() {
  sed -n '1,28p' "$0"
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
NAME=""
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    -h|--help)  usage 0 ;;
    --*)        echo "swarm-restart: unknown flag: $arg" >&2; usage 1 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$arg"
      else echo "swarm-restart: too many positional args ('$NAME' and '$arg')" >&2; usage 1
      fi
      ;;
  esac
done
[ -z "$NAME" ] && { echo "swarm-restart: missing <name>" >&2; usage 1; }

# ---------------------------------------------------------------------------
# Validate <name> against swarm.conf.
# ---------------------------------------------------------------------------
list_swarm_names() {
  grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }'
}
name_in_conf() {
  list_swarm_names | grep -qxF "$1"
}

if ! name_in_conf "$NAME"; then
  {
    echo "swarm-restart: no swarm named '$NAME' in $CONF"
    echo "configured swarms:"
    list_swarm_names | sed 's/^/  /'
  } >&2
  exit 1
fi

# Pull this swarm's repo path from swarm.conf so we can probe its activity.
REPO="$(grep -vE '^[[:space:]]*(#|$)' "$CONF" \
  | awk -F'|' -v n="$NAME" '
      { v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v);
        if (v == n) { r=$2; gsub(/^[ \t]+|[ \t]+$/, "", r); print r; exit } }
  ')"
[ -z "$REPO" ] && { echo "swarm-restart: could not resolve repo path for '$NAME' in $CONF" >&2; exit 1; }

SESS="${PREFIX}-${NAME}"

# ---------------------------------------------------------------------------
# Safety rail — is the swarm currently working?
# ---------------------------------------------------------------------------
ALIVE=0
if command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
  ALIVE=1
fi

if [ "$ALIVE" -eq 0 ]; then
  echo "swarm-restart: no live session '$SESS' — restart degenerates to up only"
elif [ ! -d "$CLAUDE_PROJECTS" ]; then
  echo "swarm-restart: NOTE — Claude projects dir not found ($CLAUDE_PROJECTS); cannot probe activity. Proceeding."
else
  ACT="$(repo_activity "$REPO" "$CLAUDE_PROJECTS" "$STALE_SECONDS")"
  AGE="${ACT%%|*}"
  TN="${ACT##*|}"
  [ -z "${TN:-}" ] && TN=0
  # repo_activity now always returns a numeric age (sentinel
  # SWARM_NO_TRANSCRIPT_AGE when no transcript exists). Defend against
  # any malformed output by coercing non-numeric to the sentinel.
  case "$AGE" in ''|*[!0-9]*) AGE="$SWARM_NO_TRANSCRIPT_AGE" ;; esac

  if [ "$AGE" -eq "$SWARM_NO_TRANSCRIPT_AGE" ]; then
    # No jsonl yet — session is starting; nothing in-flight to lose.
    echo "swarm-restart: session '$SESS' is alive but starting (no transcript yet) — safe to cycle"
  elif [ "$AGE" -le "$STALE_SECONDS" ]; then
    # WORKING — refuse unless --force.
    if [ "$FORCE" -eq 1 ]; then
      cat >&2 <<EOF
swarm-restart: WARNING — '$NAME' is WORKING (transcript write ${AGE}s ago; active teammates: ${TN}).
  Proceeding because --force was given. Any uncommitted teammate progress
  is being discarded. The lead will rebuild from disk on relaunch.
EOF
    else
      if [ "$AGE" -lt 60 ]; then age_fmt="${AGE}s"; else age_fmt="$(( AGE/60 ))m$(( AGE%60 ))s"; fi
      cat >&2 <<EOF
swarm-restart: REFUSED — swarm '$NAME' is currently WORKING.
  Most recent transcript write: ${age_fmt} ago (threshold: ${STALE_SECONDS}s)
  Active teammates: ${TN}

  Restarting will kill the tmux session. In-process teammates are
  RAM-only and do NOT survive a relaunch — uncommitted teammate
  progress is gone. The lead itself rebuilds from disk on relaunch
  (CLAUDE.md, TEAM_LEAD.md, PROJECT_SPEC.md, committed worktree-<name>
  branches), but anything a teammate hadn't committed is lost.

  Either wait for the swarm to idle (>${STALE_SECONDS}s without a
  transcript write — swarm-status + the watcher's heartbeat are
  your signal), or pass --force to proceed anyway.
EOF
      exit 2
    fi
  else
    if [ "$AGE" -lt 60 ]; then age_fmt="${AGE}s"; else age_fmt="$(( AGE/60 ))m"; fi
    echo "swarm-restart: '$NAME' is idle (last transcript write ${age_fmt} ago > ${STALE_SECONDS}s threshold) — safe to cycle"
  fi
fi

# ---------------------------------------------------------------------------
# Down + up.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-restart: cycling '$NAME'"
"$SWARM_UP" down "$NAME"
"$SWARM_UP" up   "$NAME"

# Dev-channels racy-prompt reminder — same text as swarm-attach.sh's heads-up.
cat <<EOF

swarm-restart: heads-up — if the dev-channels prompt is still waiting on
'$SESS' when you attach, press Enter to accept it (the auto-Enter in
swarm-up.sh can race; this is the manual clear):

    tmux send-keys -t $SESS Enter
EOF
