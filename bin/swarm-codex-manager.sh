#!/usr/bin/env bash
# Operator lifecycle for the one global Codex App Server manager.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SWARM_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
export SWARM_HOME
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

usage() {
  echo "usage: swarm-codex-manager.sh {start|health|ready|drain|resume|shutdown|status}" >&2
  exit 2
}

manager_session_exists() {
  if [ "$TMUX_BIN" = tmux ]; then command -v tmux >/dev/null 2>&1; else [ -x "$TMUX_BIN" ]; fi && \
    "$TMUX_BIN" has-session -t "$SWARM_CODEX_MANAGER_SESSION" 2>/dev/null
}

manager_shutdown() {
  local _had_socket=0 _elapsed=0 _timeout="${SWARM_CODEX_MANAGER_STOP_TIMEOUT:-30}"
  case "$_timeout" in ''|*[!0-9]*) _timeout=30 ;; esac
  [ "$_timeout" -ge 1 ] && [ "$_timeout" -le 120 ] || _timeout=30
  if swarm_codex_manager_socket_present; then
    _had_socket=1
    swarm_codex_manager_control shutdown >/dev/null
  elif manager_session_exists; then
    echo "Codex manager: session exists without an attested control endpoint; refusing an unauthenticated stop" >&2
    return 1
  else
    return 0
  fi
  while [ "$_elapsed" -lt "$_timeout" ]; do
    if ! swarm_codex_manager_socket_present && ! manager_session_exists; then
      return 0
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
  [ "$_had_socket" -eq 0 ] || \
    echo "Codex manager: shutdown was acknowledged but the manager session did not exit" >&2
  return 1
}

case "${1:-}" in
  start)
    [ "$#" -eq 1 ] || usage
    swarm_codex_manager_ensure
    ;;
  health|ready|drain|resume)
    [ "$#" -eq 1 ] || usage
    swarm_codex_manager_socket_present || {
      echo "Codex manager: no control endpoint" >&2
      exit 1
    }
    swarm_codex_manager_control "$1"
    ;;
  shutdown)
    [ "$#" -eq 1 ] || usage
    manager_shutdown
    ;;
  status)
    [ "$#" -eq 1 ] || usage
    if swarm_codex_manager_socket_present; then
      swarm_codex_manager_control health
    elif manager_session_exists; then
      echo "Codex manager: STARTING-OR-MALFORMED (tmux session exists; no attested endpoint)" >&2
      exit 1
    else
      echo "Codex manager: DOWN"
    fi
    ;;
  *) usage ;;
esac
