#!/usr/bin/env bash
# Focused operator-shell contract for the global App Server manager.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d /private/tmp/qofi-manager-shell-test.XXXXXX)"
trap 'test -z "${SOCKET_PID:-}" || kill "$SOCKET_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
HOME="$TMP/home"; SWARM_HOME="$TMP/swarm"; STUB="$TMP/stub"
mkdir -m 700 "$HOME" "$SWARM_HOME" "$SWARM_HOME/bin" "$STUB"
export HOME SWARM_HOME

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected=[$1] got=[$2])"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" && ok "$3" || bad "$3 (missing [$2])"; }

# The fixture changes only the local attestation target/owner expectation. The
# tmux command remains the production fixed sudo launcher and is asserted below.
/usr/bin/sed \
  -e "s#local _launcher=\"/usr/local/libexec/qofi-codex-manager-launcher\"#local _launcher=\"$TMP/fixed-launcher\"#" \
  -e 's/s.st_uid == 0/s.st_uid == os.getuid()/' \
  "$ROOT/bin/swarm-lib.sh" > "$SWARM_HOME/bin/swarm-lib.sh"
chmod 700 "$SWARM_HOME/bin/swarm-lib.sh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/fixed-launcher"; chmod 700 "$TMP/fixed-launcher"

CONTROL_LOG="$TMP/control.log"; : > "$CONTROL_LOG"
cat > "$SWARM_HOME/bin/codex-manager-control.py" <<PY
#!/usr/bin/python3 -I
import os,sys
command=sys.argv[-1]
with open('$CONTROL_LOG','a') as out: out.write(command+'\n')
if command in ('ready','health') and os.path.exists('$TMP/fail-control') and not os.path.exists('$TMP/launched'):
    raise SystemExit(1)
print('{}')
PY
chmod 700 "$SWARM_HOME/bin/codex-manager-control.py"

TMUX_LOG="$TMP/tmux.log"; : > "$TMUX_LOG"
cat > "$STUB/tmux" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> '$TMUX_LOG'
case "\${1:-}" in
  has-session) test -f '$TMP/session' ;;
  new-session) : > '$TMP/session'; : > '$TMP/launched'; exit 0 ;;
  display-message) printf '\$77\n' ;;
  capture-pane) printf 'fixture diagnostic\n' ;;
  kill-session) rm -f '$TMP/session' ;;
esac
SH
chmod 700 "$STUB/tmux"
SWARM_TMUX_BIN="$STUB/tmux"; export SWARM_TMUX_BIN

# shellcheck source=/dev/null
. "$SWARM_HOME/bin/swarm-lib.sh"

echo "=== fixed private state ==="
swarm_codex_manager_state_validate prepare >/dev/null; rc=$?
eq 0 "$rc" "manager state is created through the strict validator"
eq 700 "$(stat -f %Lp "$HOME/.codex/app-server-manager")" "manager state is exact mode 0700"

MANAGER_SOCKET="$HOME/.codex/app-server-manager/control.sock"
/usr/bin/python3 - "$MANAGER_SOCKET" <<'PY' &
import signal,socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
signal.signal(signal.SIGTERM,lambda *_: sys.exit(0))
while True: time.sleep(1)
PY
SOCKET_PID=$!
for _ in 1 2 3 4 5; do [ -S "$MANAGER_SOCKET" ] && break; sleep 1; done
chmod 600 "$MANAGER_SOCKET"

echo "=== existing manager drains around root preflight ==="
PREFLIGHT_LOG="$TMP/preflight.log"; : > "$PREFLIGHT_LOG"
swarm_codex_host_preflight(){ echo preflight >> "$PREFLIGHT_LOG"; return "${PREFLIGHT_RC:-0}"; }
: > "$CONTROL_LOG"
swarm_codex_manager_host_preflight "$TMP/repo"; rc=$?
eq 0 "$rc" "healthy manager permits a bounded host preflight"
eq $'health\ndrain\nresume\nready' "$(cat "$CONTROL_LOG")" "manager is health-checked, drained, resumed, and re-attested"

: > "$CONTROL_LOG"; PREFLIGHT_RC=9
swarm_codex_manager_host_preflight "$TMP/repo"; rc=$?
eq 9 "$rc" "host preflight failure is preserved"
eq $'health\ndrain\nresume' "$(cat "$CONTROL_LOG")" "failed preflight still resumes the established manager"
unset PREFLIGHT_RC

if grep -qF 'if swarm_codex_manager_host_preflight "$REPO"; then' \
    "$ROOT/bin/swarm-doctor.sh"; then
  ok "doctor drains the shared manager around its root preflight"
else
  bad "doctor bypasses the manager-aware root preflight wrapper"
fi

echo "=== stale socket recovery is launcher-owned ==="
: > "$TMP/fail-control"; rm -f "$TMP/session" "$TMP/launched"; : > "$TMUX_LOG"; : > "$CONTROL_LOG"
SWARM_CODEX_MANAGER_START_TIMEOUT=3 swarm_codex_manager_ensure; rc=$?
eq 0 "$rc" "stale socket with no manager session is recovered"
TMUX_CALLS="$(cat "$TMUX_LOG")"
has "$TMUX_CALLS" "new-session -d -s qofi-codex-app-server-manager" "recovery creates only the dedicated non-swarm session"
has "$TMUX_CALLS" "/usr/bin/sudo -n -- /usr/local/libexec/qofi-codex-manager-launcher" "recovery invokes the fixed launcher with zero arguments"
if printf '%s' "$TMUX_CALLS" | grep -qE 'app-server-manager\.(ts|js)|--state-dir|--swarm-home'; then
  bad "shell never launches workspace manager source or supplies manager arguments"
else
  ok "shell never launches workspace manager source or supplies manager arguments"
fi

echo "codex-manager-shell: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
