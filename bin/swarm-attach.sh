#!/usr/bin/env bash
# swarm-attach.sh — attach (or launch-then-attach) a swarm's tmux session.
#
# Usage:
#   swarm-attach.sh              # if exactly one swarm in swarm.conf, attach-
#                                # or-launch it. If 0 or 2+, list and exit 1.
#   swarm-attach.sh <name>       # attach swarm-<name>; if not running, launch
#                                # it first via swarm-up.sh up <name>, wait
#                                # until the tmux session exists, then attach.
#
# Behavior:
#   - <name> not in swarm.conf       → error, exit 1 (does NOT try to launch).
#   - session swarm-<name> running   → attach directly.
#   - session swarm-<name> NOT running and name IS in swarm.conf
#                                    → heads-up, swarm-up.sh up <name>, poll
#                                      for session existence, then attach.
#
# Why this exists: tmux's own "session not found" error is noisy and there's
# no obvious next step. swarm-up.sh's `attach` subcommand exits 1 when the
# session is down — operators were repeatedly running swarm-up.sh up + then
# swarm-up.sh attach by hand. This wraps that in one command.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-attach: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# SWARM_UP_BIN override exists so tests can substitute a stub; in normal use
# this resolves to the sibling swarm-up.sh.
SWARM_UP="${SWARM_UP_BIN:-$SCRIPT_DIR/swarm-up.sh}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"   # matches swarm-up.sh
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
LAUNCH_WAIT_SECONDS="${SWARM_ATTACH_LAUNCH_WAIT:-10}"  # how long to poll for the session after launch

command -v "$TMUX_BIN" >/dev/null 2>&1 || {
  echo "swarm-attach: tmux not on PATH (set SWARM_TMUX_BIN or install tmux)" >&2; exit 1; }

# List the names declared in swarm.conf, one per line. Used both for the
# no-arg single-swarm shortcut and to validate that a given <name> is real.
list_swarm_names() {
  grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }'
}

# Is this name declared in swarm.conf? Exit 0 yes, 1 no.
name_in_conf() {  # name
  list_swarm_names | grep -qxF "$1"
}

NAME="${1:-}"

# No-arg path: single configured swarm → use it. Otherwise list and bail.
if [ -z "$NAME" ]; then
  NAMES="$(list_swarm_names)"
  count="$(printf '%s\n' "$NAMES" | grep -c .)"
  case "$count" in
    0)
      echo "swarm-attach: no swarms in $CONF — register one with swarm-add.sh" >&2
      exit 1
      ;;
    1)
      NAME="$NAMES"
      echo "swarm-attach: one swarm configured ($NAME) — using it" >&2
      ;;
    *)
      {
        echo "swarm-attach: multiple swarms configured — pick one:"
        printf '  %s\n' $NAMES
        echo "usage: swarm-attach.sh <name>"
      } >&2
      exit 1
      ;;
  esac
fi

# Explicit-name path: validate against swarm.conf BEFORE doing anything else.
# A typo'd name must not silently launch nothing and then hang in the poll.
if ! name_in_conf "$NAME"; then
  {
    echo "swarm-attach: no swarm named '$NAME' in $CONF"
    echo "configured swarms:"
    list_swarm_names | sed 's/^/  /'
  } >&2
  exit 1
fi

SESS="${PREFIX}-${NAME}"

# Attach-or-launch.
if "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
  echo "attached to $SESS · detach with Ctrl-b then d (never Ctrl-C)" >&2
else
  echo "swarm-attach: session $SESS not running — launching with swarm-up.sh up $NAME" >&2
  echo "swarm-attach: heads-up — you'll land mid-bringup. If the dev-channels prompt is" >&2
  echo "swarm-attach: still waiting when you attach, press Enter to accept it." >&2
  # swarm-up.sh launch_one is synchronous: by the time it returns, tmux
  # new-session has run and the brief has been sent. The poll below is a
  # short defensive check in case launch_one fails partway (missing token,
  # missing repo, etc.) and we should NOT attach to a non-existent session.
  "$SWARM_UP" up "$NAME" || true
  i=0
  while [ "$i" -lt "$LAUNCH_WAIT_SECONDS" ]; do
    "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null && break
    sleep 1
    i=$((i+1))
  done
  if ! "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
    echo "swarm-attach: session $SESS did not come up within ${LAUNCH_WAIT_SECONDS}s — re-run swarm-up.sh up $NAME and watch for errors (token, repo path)" >&2
    exit 1
  fi
  echo "attached to $SESS · detach with Ctrl-b then d (never Ctrl-C)" >&2
fi

exec "$TMUX_BIN" attach -t "$SESS"
