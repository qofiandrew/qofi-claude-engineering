#!/usr/bin/env bash
# Idempotent lifecycle for the root-attested dedicated Codex service account.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HELPER="$SCRIPT_DIR/swarm-codex-runtime.py"
FIXED="/usr/local/libexec/qofi-codex-runtime"
SWARM_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MANAGER="$SCRIPT_DIR/swarm-codex-manager.sh"
MANAGER_SOCKET="${HOME:-}/.codex/app-server-manager/control.sock"
MANAGER_SESSION="qofi-codex-app-server-manager"
MANAGER_WAS_ACTIVE=0
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

manager_session_exists() {
  if [ "$TMUX_BIN" = tmux ]; then command -v tmux >/dev/null 2>&1; else [ -x "$TMUX_BIN" ]; fi && \
    "$TMUX_BIN" has-session -t "$MANAGER_SESSION" 2>/dev/null
}

manager_endpoint_present() {
  [ -e "$MANAGER_SOCKET" ] || [ -L "$MANAGER_SOCKET" ]
}

manager_drain_if_active() {
  MANAGER_WAS_ACTIVE=0
  # A direct-root invocation has no trustworthy way to infer which operator's
  # manager owns the global runner. Normal lifecycle use reaches this wrapper
  # as the operator and only the fixed subcommand is elevated below.
  [ "$(/usr/bin/id -u)" -ne 0 ] || return 0
  if manager_endpoint_present; then
    [ -x "$MANAGER" ] || { echo "swarm-codex-runtime: manager control is missing" >&2; return 1; }
    if ! "$MANAGER" health >/dev/null 2>&1; then
      manager_session_exists && return 1
      "$MANAGER" start || return 1
    fi
    "$MANAGER" drain >/dev/null || return 1
    MANAGER_WAS_ACTIVE=1
  elif manager_session_exists; then
    echo "swarm-codex-runtime: manager session exists without an attested endpoint; refusing root lifecycle work" >&2
    return 1
  fi
}

manager_resume_if_needed() {
  [ "$MANAGER_WAS_ACTIVE" -eq 1 ] || return 0
  "$MANAGER" resume >/dev/null && "$MANAGER" ready >/dev/null
}

root_recover_stopped_manager() {
  # Recovery itself always executes the freshly published root-owned helper.
  # The root operation binds admission, argv, socket inode, and kernel peer PID
  # before it signals anything; shell/tmux observations never authorize it.
  [ -x "$FIXED" ] && /usr/bin/cmp -s "$HELPER" "$FIXED" || {
    echo "swarm-codex-runtime: fixed lifecycle lacks manager recovery; refresh failed" >&2
    return 1
  }
  /usr/bin/sudo -H -- "$FIXED" recover-manager --swarm-home "$SWARM_HOME"
}

refresh_fixed_for_manager_recovery() {
  [ -x "$FIXED" ] && /usr/bin/cmp -s "$HELPER" "$FIXED" && return 0
  # A stopped ambiguous manager has no live hidden runner, so the established
  # password-authorized one-file migration can publish the recovery command.
  # It does not replace the manager bundle or admission authority.
  /usr/bin/sudo -H -- /usr/bin/python3 -I -B "$HELPER" \
    refresh-lifecycle --swarm-home "$SWARM_HOME"
}

manager_shutdown_for_replacement() {
  [ "$(/usr/bin/id -u)" -ne 0 ] || return 0
  if manager_endpoint_present; then
    [ -x "$MANAGER" ] || { echo "swarm-codex-runtime: manager control is missing" >&2; return 1; }
    if ! "$MANAGER" health >/dev/null 2>&1; then
      manager_session_exists && return 1
      "$MANAGER" start || return 1
    fi
    if ! "$MANAGER" shutdown; then
      refresh_fixed_for_manager_recovery || return 1
      root_recover_stopped_manager || return 1
    fi
  elif manager_session_exists; then
    echo "swarm-codex-runtime: manager session exists without an attested endpoint; refusing root lifecycle work" >&2
    return 1
  fi
}

run_with_manager_drain() {  # command argv...
  local _rc=0 _resume_rc=0
  manager_drain_if_active || return 1
  "$@" || _rc=$?
  manager_resume_if_needed || _resume_rc=$?
  [ "$_resume_rc" -eq 0 ] || {
    echo "swarm-codex-runtime: lifecycle command returned but the App Server manager did not resume" >&2
    return 1
  }
  return "$_rc"
}

run_fixed_lifecycle() {
  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    "$FIXED" "$@"
  else
    /usr/bin/sudo -H -- "$FIXED" "$@"
  fi
}

run_install() {
  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    if [ -x "$FIXED" ]; then
      if ! /usr/bin/cmp -s "$HELPER" "$FIXED"; then
        echo "swarm-codex-runtime: the fixed lifecycle is stale; rerun install as the attested operator so it can be explicitly refreshed" >&2
        return 1
      fi
      "$FIXED" install --swarm-home "$SWARM_HOME" "$@"
      return
    fi
    /usr/bin/python3 -I -B "$HELPER" install --swarm-home "$SWARM_HOME" "$@"
    return
  fi
  if [ -x "$FIXED" ]; then
    # A fixed helper may safely replace itself during its old `install`, but
    # that already-running generation cannot execute provisioning steps which
    # only exist in the replacement (for example the first manager bundle and
    # admission authority).  Refresh it explicitly, then execute the new fixed
    # generation so a version migration is complete in one operator command.
    if ! /usr/bin/cmp -s "$HELPER" "$FIXED"; then
      /usr/bin/sudo -H -- /usr/bin/python3 -I -B "$HELPER" \
        refresh-lifecycle --swarm-home "$SWARM_HOME"
    fi
    /usr/bin/sudo -H -- "$FIXED" install --swarm-home "$SWARM_HOME" "$@"
  else
    /usr/bin/sudo -H -- /usr/bin/python3 -I -B "$HELPER" install --swarm-home "$SWARM_HOME" "$@"
  fi
}

restart_manager_after_replacement() {
  [ "$(/usr/bin/id -u)" -ne 0 ] || return 0
  [ -x "$MANAGER" ] || return 1
  "$MANAGER" start
}

case "${1:-}" in
  -h|--help|"") exec /usr/bin/python3 -I -B "$HELPER" --help ;;
  verify)
    run_with_manager_drain /usr/bin/python3 -I -B "$HELPER" "$@"
    ;;
  install)
    manager_shutdown_for_replacement || exit 1
    if run_install "${@:2}"; then
      restart_manager_after_replacement
    else
      exit $?
    fi
    ;;
  refresh-lifecycle)
    manager_shutdown_for_replacement || exit 1
    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
      /usr/bin/python3 -I -B "$HELPER" refresh-lifecycle --swarm-home "$SWARM_HOME"
    else
      /usr/bin/sudo -H -- /usr/bin/python3 -I -B "$HELPER" \
        refresh-lifecycle --swarm-home "$SWARM_HOME"
    fi
    restart_manager_after_replacement
    ;;
  uninstall)
    if [ ! -x "$FIXED" ]; then
      echo "swarm-codex-runtime: fixed lifecycle helper is missing; run install first" >&2
      exit 2
    fi
    manager_shutdown_for_replacement || exit 1
    run_fixed_lifecycle "$@"
    ;;
  login|prepare-workspace|release-workspace|workspace-journal-evidence|quiescence-proof)
    if [ ! -x "$FIXED" ]; then
      echo "swarm-codex-runtime: fixed lifecycle helper is missing; run install first" >&2
      exit 2
    fi
    run_with_manager_drain run_fixed_lifecycle "$@"
    ;;
  *) exec /usr/bin/python3 -I -B "$HELPER" "$@" ;;
esac
