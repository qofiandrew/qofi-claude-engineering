#!/usr/bin/env bash
# Isolated operator-shell contract for manager replacement recovery. The
# production wrapper is copied with only its absolute privileged executables
# redirected into this fixture, so this test can never invoke real sudo or the
# live App Server manager.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d /private/tmp/qofi-runtime-recovery-shell.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/home"; SWARM_HOME="$TMP/swarm"; STUB="$TMP/stub"
FIXED="$TMP/fixed-runtime"; MANAGER_LOG="$TMP/manager.log"
SUDO_LOG="$TMP/sudo.log"; PYTHON_LOG="$TMP/python.log"
HELPER_LOG="$TMP/helper.log"
mkdir -m 700 "$HOME" "$SWARM_HOME" "$SWARM_HOME/bin" "$STUB"
export HOME MANAGER_LOG SUDO_LOG PYTHON_LOG HELPER_LOG FIXED_TARGET="$FIXED"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected=[$1] got=[$2])"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" && ok "$3" || bad "$3 (missing [$2])"; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected [$2])"; else ok "$3"; fi; }

# Redirect only commands that would otherwise cross the fixture boundary.
/usr/bin/sed \
  -e "s#/usr/local/libexec/qofi-codex-runtime#$FIXED#g" \
  -e "s#/usr/bin/sudo#$STUB/sudo#g" \
  -e "s#/usr/bin/python3#$STUB/python3#g" \
  "$ROOT/bin/swarm-codex-runtime.sh" > "$SWARM_HOME/bin/swarm-codex-runtime.sh"
chmod 700 "$SWARM_HOME/bin/swarm-codex-runtime.sh"

cat > "$STUB/sudo" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
test "${1:-}" != -H || shift
test "${1:-}" != -- || shift
exec "$@"
SH
chmod 700 "$STUB/sudo"

cat > "$STUB/python3" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PYTHON_LOG"
test "${1:-}" != -I || shift
test "${1:-}" != -B || shift
exec "$@"
SH
chmod 700 "$STUB/python3"

cat > "$SWARM_HOME/bin/swarm-codex-runtime.py" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HELPER_LOG"
case "${1:-}" in
  recover-manager) exit "${RECOVERY_RC:-0}" ;;
  refresh-lifecycle)
    test "${REFRESH_RC:-0}" -eq 0 || exit "$REFRESH_RC"
    /bin/cp "$0" "$FIXED_TARGET" || exit
    /bin/chmod 700 "$FIXED_TARGET" || exit
    ;;
  install) exit "${INSTALL_RC:-0}" ;;
esac
SH
chmod 700 "$SWARM_HOME/bin/swarm-codex-runtime.py"

cat > "$SWARM_HOME/bin/swarm-codex-manager.sh" <<'SH'
#!/bin/sh
printf '%s\n' "${1:-}" >> "$MANAGER_LOG"
case "${1:-}" in
  health) exit "${MANAGER_HEALTH_RC:-0}" ;;
  shutdown) exit "${MANAGER_SHUTDOWN_RC:-0}" ;;
  start) exit "${MANAGER_START_RC:-0}" ;;
esac
SH
chmod 700 "$SWARM_HOME/bin/swarm-codex-manager.sh"

reset_case() {
  : > "$MANAGER_LOG"; : > "$SUDO_LOG"; : > "$PYTHON_LOG"; : > "$HELPER_LOG"
  mkdir -p "$HOME/.codex/app-server-manager"
  : > "$HOME/.codex/app-server-manager/control.sock"
  /bin/cp "$SWARM_HOME/bin/swarm-codex-runtime.py" "$FIXED"
  chmod 700 "$FIXED"
}

run_install() {
  MANAGER_SHUTDOWN_RC="${MANAGER_SHUTDOWN_RC:-0}" \
  RECOVERY_RC="${RECOVERY_RC:-0}" \
  REFRESH_RC="${REFRESH_RC:-0}" \
    bash "$SWARM_HOME/bin/swarm-codex-runtime.sh" install --repo /fixture/repo
}

echo "=== clean shutdown takes no recovery path ==="
reset_case
MANAGER_SHUTDOWN_RC=0 RECOVERY_RC=91 run_install >/dev/null 2>&1; rc=$?
eq 0 "$rc" "clean replacement succeeds even when recovery would fail"
eq $'health\nshutdown\nstart' "$(cat "$MANAGER_LOG")" "clean replacement shuts down and restarts the manager"
SUDO_CALLS="$(cat "$SUDO_LOG")"
lacks "$SUDO_CALLS" "recover-manager" "clean shutdown never invokes root recovery"
has "$SUDO_CALLS" "$FIXED install --swarm-home $SWARM_HOME --repo /fixture/repo" "clean shutdown proceeds through the fixed installer"

echo "=== failed shutdown uses the matching fixed recovery helper ==="
reset_case
MANAGER_SHUTDOWN_RC=23 RECOVERY_RC=0 run_install >/dev/null 2>&1; rc=$?
eq 0 "$rc" "fixed-helper recovery permits replacement to continue"
SUDO_CALLS="$(cat "$SUDO_LOG")"
has "$SUDO_CALLS" "-H -- $FIXED recover-manager --swarm-home $SWARM_HOME" "matching fixed helper performs recovery"
lacks "$SUDO_CALLS" "$STUB/python3 -I -B" "matching fixed helper does not elevate mutable source"
eq $'health\nshutdown\nstart' "$(cat "$MANAGER_LOG")" "successful recovery reaches exactly one manager restart"

echo "=== stale fixed helper is published before fixed recovery ==="
reset_case
printf '#!/bin/sh\nexit 99\n' > "$FIXED"; chmod 700 "$FIXED"
MANAGER_SHUTDOWN_RC=23 RECOVERY_RC=0 run_install >/dev/null 2>&1; rc=$?
eq 0 "$rc" "stale fixed helper is refreshed before recovery"
SUDO_CALLS="$(cat "$SUDO_LOG")"
SOURCE_REFRESH="$STUB/python3 -I -B $SWARM_HOME/bin/swarm-codex-runtime.py refresh-lifecycle --swarm-home $SWARM_HOME"
has "$SUDO_CALLS" "-H -- $SOURCE_REFRESH" "stale fixed helper is explicitly refreshed through sudo python -I -B"
has "$SUDO_CALLS" "-H -- $FIXED recover-manager --swarm-home $SWARM_HOME" "stale source is published before fixed recovery executes"
lacks "$SUDO_CALLS" "$STUB/python3 -I -B $SWARM_HOME/bin/swarm-codex-runtime.py recover-manager" "mutable source never executes recovery"
has "$SUDO_CALLS" "$FIXED install --swarm-home $SWARM_HOME --repo /fixture/repo" "refreshed fixed generation performs install"
EXPECTED_SUDO="-H -- $SOURCE_REFRESH
-H -- $FIXED recover-manager --swarm-home $SWARM_HOME
-H -- $FIXED install --swarm-home $SWARM_HOME --repo /fixture/repo"
eq "$EXPECTED_SUDO" "$SUDO_CALLS" "stale lifecycle is refreshed, recovered, then installed in order"

echo "=== missing fixed helper is published before fixed recovery ==="
reset_case; rm -f "$FIXED"
MANAGER_SHUTDOWN_RC=23 RECOVERY_RC=0 run_install >/dev/null 2>&1; rc=$?
eq 0 "$rc" "missing fixed helper is published through the bounded refresh bridge"
SUDO_CALLS="$(cat "$SUDO_LOG")"
has "$SUDO_CALLS" "-H -- $SOURCE_REFRESH" "missing fixed helper is explicitly published"
has "$SUDO_CALLS" "-H -- $FIXED recover-manager --swarm-home $SWARM_HOME" "newly published fixed helper performs recovery"
lacks "$SUDO_CALLS" "$STUB/python3 -I -B $SWARM_HOME/bin/swarm-codex-runtime.py recover-manager" "missing fixed helper never falls back to source recovery"
has "$SUDO_CALLS" "$FIXED install --swarm-home $SWARM_HOME --repo /fixture/repo" "newly published fixed helper performs install"
eq $'health\nshutdown\nstart' "$(cat "$MANAGER_LOG")" "fixed recovery and install restart the manager once"
eq "$EXPECTED_SUDO" "$SUDO_CALLS" "missing lifecycle is published, recovered, then installed in order"

echo "=== failed refresh blocks recovery, install, and restart ==="
reset_case; rm -f "$FIXED"
MANAGER_SHUTDOWN_RC=23 REFRESH_RC=42 RECOVERY_RC=0 run_install >/dev/null 2>&1; rc=$?
eq 1 "$rc" "refresh rejection fails closed before recovery"
eq $'health\nshutdown' "$(cat "$MANAGER_LOG")" "failed refresh never restarts the manager"
SUDO_CALLS="$(cat "$SUDO_LOG")"
has "$SUDO_CALLS" "-H -- $SOURCE_REFRESH" "failed refresh was attempted through the bounded source bridge"
lacks "$SUDO_CALLS" "recover-manager" "failed refresh blocks recovery"
eq "-H -- $SOURCE_REFRESH" "$SUDO_CALLS" "failed refresh is the only privileged command"
HELPER_CALLS="$(cat "$HELPER_LOG")"
lacks "$HELPER_CALLS" "install" "failed refresh blocks install"

echo "=== failed recovery blocks mutation and restart ==="
reset_case
MANAGER_SHUTDOWN_RC=23 RECOVERY_RC=47 run_install >/dev/null 2>&1; rc=$?
eq 1 "$rc" "recovery rejection fails the wrapper before install"
eq $'health\nshutdown' "$(cat "$MANAGER_LOG")" "failed recovery never restarts the manager"
HELPER_CALLS="$(cat "$HELPER_LOG")"
has "$HELPER_CALLS" "recover-manager --swarm-home $SWARM_HOME" "failed recovery was attempted"
lacks "$HELPER_CALLS" "install" "failed recovery blocks install"

echo "codex-runtime-recovery-shell: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
