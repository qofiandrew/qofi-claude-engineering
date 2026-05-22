#!/usr/bin/env bash
# swarm-attach.sh — convenience wrapper around `tmux attach` for swarm sessions.
#
# Usage:
#   swarm-attach.sh              # if exactly one swarm in swarm.conf, attach it.
#                                # if zero or 2+, list and exit 1 with a hint.
#   swarm-attach.sh <name>       # attach the tmux session "swarm-<name>".
#
# Why a dedicated script: tmux's own "no current client" / "session not found"
# error messages are noisy, and the operator shouldn't have to remember the
# "swarm-<name>" tmux session prefix. swarm-up.sh's `attach` subcommand also
# attaches, but it doesn't auto-attach the single-swarm case and doesn't print
# the detach reminder.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-attach: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"   # matches swarm-up.sh
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

command -v "$TMUX_BIN" >/dev/null 2>&1 || {
  echo "swarm-attach: tmux not on PATH (set SWARM_TMUX_BIN or install tmux)" >&2; exit 1; }

NAME="${1:-}"

# No-arg path: if exactly one swarm is configured, attach it. Otherwise list
# and bail with a hint — operators should pick one explicitly when there's
# ambiguity, the same way `git checkout` won't guess your branch.
if [ -z "$NAME" ]; then
  NAMES="$(grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }')"
  count="$(printf '%s\n' "$NAMES" | grep -c .)"
  case "$count" in
    0)
      echo "swarm-attach: no swarms in $CONF — register one with swarm-add.sh" >&2
      exit 1
      ;;
    1)
      NAME="$NAMES"
      echo "swarm-attach: one swarm configured ($NAME) — attaching" >&2
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

SESS="${PREFIX}-${NAME}"

if ! "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
  echo "swarm-attach: no running session $SESS — start it with swarm-up.sh up" >&2
  exit 1
fi

echo "attached to $SESS · detach with Ctrl-b then d (never Ctrl-C)" >&2
exec "$TMUX_BIN" attach -t "$SESS"
