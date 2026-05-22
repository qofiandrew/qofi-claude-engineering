#!/usr/bin/env bash
# swarm-up.sh — run one persistent Agent Teams lead per repo in tmux on the
# always-on host (Mac mini), each with its own Discord bot identity, supervised.
#
# Avoids bash-4 features so it runs on macOS's default bash 3.2 (brew bash is fine too).
#
# Config: $SWARM_HOME/swarm.conf — one repo per line, pipe-separated, FOUR fields:
#     session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID
#   TOKEN_VAR_NAME names an env var (defined in $SWARM_HOME/tokens.env) holding
#   that repo's DISCORD_BOT_TOKEN. CHANNEL_ID is the Discord channel this swarm is
#   bound to (used by swarm-watch.sh for the per-channel heartbeat; swarm-up itself
#   doesn't need it, but it must be present so the field is parsed cleanly).
#   Blank lines and #-comments are ignored.
#
# Usage:
#   swarm-up.sh up       # start any sessions not already running
#   swarm-up.sh down     # stop all swarm sessions
#   swarm-up.sh status   # list running swarm sessions
#   swarm-up.sh watch    # foreground supervisor: relaunch dead leads (Ctrl-C to stop)
#   swarm-up.sh attach <name>   # attach the terminal to a running swarm to watch /
#                               # interact live; Ctrl-b d detaches without stopping it.

set -euo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-up: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
CONF="$SWARM_HOME/swarm.conf"
TOKENS="$SWARM_HOME/tokens.env"
PREFIX="swarm"                              # tmux session name prefix (no ':' allowed)
# Custom-marketplace channel plugin. Research-preview channels require the dev flag
# (a marketplace you publish yourself is not on Anthropic's approved allowlist), and
# the plugin must be fully qualified with @<marketplace>.
PLUGIN="${SWARM_PLUGIN:-plugin:discord-b2b@qofi-swarm}"

# Poll the pane for `pattern` until it appears or `timeout` seconds elapse.
# Used to wait for prompts/states instead of fixed-duration sleeps. bash 3.2-safe.
_wait_for() {  # session pattern timeout
  local sess="$1" pat="$2" tmo="${3:-15}" i=0
  while [ "$i" -lt "$tmo" ]; do
    tmux capture-pane -t "$sess" -p 2>/dev/null | grep -qF -- "$pat" && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

[ -f "$CONF" ] || { echo "swarm-up: missing $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
[ -f "$TOKENS" ] && . "$TOKENS"

launch_one() {  # name repo tokvar
  local name="$1" repo="$2" tokvar="$3"
  local sess="${PREFIX}-${name}"
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "  running: $sess"; return 0
  fi
  [ -d "$repo" ] || { echo "  ERROR: repo not found: $repo" >&2; return 1; }
  local token="${!tokvar:-}"
  [ -z "$token" ] && { echo "  ERROR: no token in \$$tokvar (check tokens.env)" >&2; return 1; }

  echo "  launching: $sess  ($repo)"
  tmux new-session -d -s "$sess" -c "$repo"
  # CRITICAL: unset ANTHROPIC_API_KEY so the lead bills against Max, not metered API.
  # Source tokens.env INSIDE the pane and dereference by var name so the literal
  # token value never appears on the command line / pane scrollback.
  tmux send-keys -t "$sess" "unset ANTHROPIC_API_KEY; set -a; . '$TOKENS'; export DISCORD_BOT_TOKEN=\"\$$tokvar\"; set +a" C-m
  # CRITICAL: --dangerously-load-development-channels (not --channels) because the
  # qofi-swarm marketplace is self-published, not on Anthropic's approved allowlist.
  tmux send-keys -t "$sess" "claude --dangerously-load-development-channels $PLUGIN" C-m

  # --dangerously-load-development-channels opens an interactive warning prompt:
  #   ❯ 1. I am using this for local development
  #     2. Exit
  # Option 1 is preselected; a single Enter accepts it. Wait for the prompt to
  # render rather than guessing how long the CLI takes to start.
  if ! _wait_for "$sess" "I am using this for local development" 20; then
    echo "  WARN: dev-channels prompt didn't appear in 20s — lead may not start" >&2
  fi
  tmux send-keys -t "$sess" Enter

  # After accepting, claude needs a moment to load plugins and render the main
  # input prompt. The "auto mode" hint in the footer is a reliable readiness marker.
  if ! _wait_for "$sess" "auto mode" 20; then
    echo "  WARN: main input didn't render in 20s — brief may not land" >&2
  fi

  # Send the brief, then submit. A trailing C-m on the same send-keys call gets
  # absorbed into the input (treated as part of the paste) and does NOT fire
  # submission — observed empirically. Send text and Enter as separate calls.
  tmux send-keys -t "$sess" "Read TEAM_LEAD.md, ESCALATION.md, CLAUDE.md and PROJECT_SPEC.md. You are the team lead (CTO) for this repo; operate per TEAM_LEAD.md. The human will hold a product design conversation with you over Discord and the spec may be empty for now — do NOT build during the conversation. When the human says to build, first author PROJECT_SPEC.md and the one-way-door ADRs from the conversation, confirm them with the human, then decompose and spawn the team. Keep the docs reconciled with the implementation as it proceeds, and message the human for any major spec decision."
  sleep 1
  tmux send-keys -t "$sess" Enter
}

cmd_up() {
  while IFS='|' read -r name repo tokvar channel; do
    name="$(echo "${name:-}"     | xargs)"
    repo="$(echo "${repo:-}"     | xargs)"
    tokvar="$(echo "${tokvar:-}" | xargs)"
    channel="$(echo "${channel:-}" | xargs)"   # consumed so it isn't merged into tokvar; used by swarm-watch.sh
    [ -z "$name" ] && continue
    launch_one "$name" "$repo" "$tokvar" || true
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
}

cmd_down() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}-" | while read -r s; do
    echo "  killing: $s"; tmux kill-session -t "$s" 2>/dev/null || true
  done
}

cmd_status() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}-" || echo "  (no swarm sessions running)"
}

cmd_attach() {  # [name]
  local name="${1:-}"
  if [ -z "$name" ]; then
    {
      echo "running swarm sessions:"
      cmd_status
      echo "usage: swarm-up.sh attach <name>"
    } >&2
    exit 1
  fi
  local sess="${PREFIX}-${name}"
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "swarm-up: no running swarm '$sess' — start it with swarm-up.sh up" >&2
    exit 1
  fi
  exec tmux attach -t "$sess"
}

cmd_watch() {
  echo "Supervising swarm (Ctrl-C to stop). Checking every 30s."
  echo "Note: teammates do NOT survive a relaunch — a respawned lead recreates them per TEAM_LEAD.md."
  echo "Liveness = tmux session exists; when claude exits the pane closes the session, so this is a fair proxy."
  while true; do cmd_up >/dev/null 2>&1 || true; sleep 30; done
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  watch)  cmd_watch ;;
  attach) cmd_attach "${2:-}" ;;
  *) echo "usage: swarm-up.sh {up|down|status|watch|attach <name>}" >&2; exit 1 ;;
esac
