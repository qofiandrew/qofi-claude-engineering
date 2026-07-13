#!/usr/bin/env bash
# Pure regression for the shared codex-bridge runtime.json consumer contract.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-runtime.XXXXXX")"
SHORT_HOME="$(/usr/bin/python3 -c 'import os; print(os.path.realpath("/tmp"))')/codexrt.$$"
trap 'rm -rf "$TMP" "$SHORT_HOME"' EXIT
HOME="$SHORT_HOME"; export HOME
mkdir -p "$HOME/.codex/channels/discord-alpha"
chmod 700 "$HOME" "$HOME/.codex" "$HOME/.codex/channels" "$HOME/.codex/channels/discord-alpha"
. "$ROOT/bin/swarm-lib.sh"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected=$1 got=$2)"; }

FILE="$HOME/.codex/channels/discord-alpha/runtime.json"
write_state(){
  python3 - "$FILE" "$1" "$2" "$3" "$4" "$5" <<'PY'
import datetime as d, json, os, sys
p,pid,age,active,queue,endpoint=sys.argv[1:]
now=d.datetime.now(d.timezone.utc)
ts=(now-d.timedelta(seconds=int(age))).isoformat().replace('+00:00','Z')
json.dump({"schema":"codex-bridge-runtime/v1","pid":int(pid),"started_at":ts,
 "updated_at":ts,"ready":True,"active":active=="1","queue_depth":int(queue),
 "child_pid":int(pid) if active=="1" else None,"turn_started_at":ts if active=="1" else None,
 "last_completed_at":ts,"last_error":None,"backend":"app-server" if endpoint else "exec",
 "app_server_endpoint":endpoint or None},open(p,"w"))
os.chmod(p,0o600)
PY
}

SOCKET="$HOME/.codex/channels/discord-alpha/app-server.sock"
make_socket(){
  rm -f "$SOCKET"
  python3 - "$SOCKET" <<'PY'
import os, socket, sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close(); os.chmod(sys.argv[1], 0o600)
PY
}

echo "=== healthy active state ==="
make_socket
write_state "$$" 0 1 2 "unix://$SOCKET"
swarm_codex_runtime_read alpha; rc=$?
eq 0 "$rc" "fresh state accepted"
eq healthy "$SWARM_CODEX_RUNTIME_STATUS" "status healthy"
eq 1 "$SWARM_CODEX_RUNTIME_ACTIVE" "active parsed"
eq 2 "$SWARM_CODEX_RUNTIME_QUEUE_DEPTH" "waiting queue parsed"
eq "$$" "$SWARM_CODEX_RUNTIME_CHILD_PID" "child pid parsed"
eq "unix://$SOCKET" "$SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT" "private Unix App Server endpoint parsed"

write_state "$$" 0 0 0 ""
swarm_codex_runtime_read alpha; rc=$?
eq 0 "$rc" "fresh idle state accepted"
eq 0 "$SWARM_CODEX_RUNTIME_QUEUE_DEPTH" "zero queue remains numeric zero"

mkdir -m 700 "$HOME/.codex/channels/discord-alpha/tool-tmp" "$HOME/.codex/channels/discord-alpha/inbox"
mkdir -m 755 "$HOME/.codex/channels/discord-alpha/tool-tmp/cache" "$HOME/.codex/channels/discord-alpha/inbox/active-turn"
printf 'cache\n' > "$HOME/.codex/channels/discord-alpha/tool-tmp/cache/item"
printf 'attachment\n' > "$HOME/.codex/channels/discord-alpha/inbox/active-turn/file"
chmod 644 "$HOME/.codex/channels/discord-alpha/tool-tmp/cache/item" "$HOME/.codex/channels/discord-alpha/inbox/active-turn/file"
swarm_codex_runtime_read alpha; rc=$?
eq 0 "$rc" "private opaque tool/inbox roots allow active-turn 0755/0644 cache layout"
rm -rf "$HOME/.codex/channels/discord-alpha/tool-tmp" "$HOME/.codex/channels/discord-alpha/inbox"

if [ "$(uname -s)" = "Darwin" ]; then
  echo "=== extended ACLs never widen sensitive state ==="
  write_state "$$" 0 0 0 ""
  /bin/chmod +a 'everyone allow read' "$FILE"
  swarm_codex_runtime_read alpha; rc=$?
  eq 2 "$rc" "mode-0600 runtime state with an everyone-read ACL is refused"
  /bin/chmod -N "$FILE"

  make_socket
  write_state "$$" 0 0 0 "unix://$SOCKET"
  /bin/chmod +a 'everyone allow read' "$SOCKET"
  swarm_codex_runtime_read alpha; rc=$?
  eq 2 "$rc" "mode-0600 Unix socket with an everyone-read ACL is refused"
  /bin/chmod -N "$SOCKET"
fi

echo "=== stale/dead/malformed/missing fail closed ==="
write_state "$$" 60 0 0 ""
swarm_codex_runtime_read alpha; rc=$?
eq 3 "$rc" "stale heartbeat rejected"
eq stale "$SWARM_CODEX_RUNTIME_STATUS" "stale reason surfaced"

write_state 99999999 0 0 0 ""
swarm_codex_runtime_read alpha; rc=$?
eq 3 "$rc" "dead daemon pid rejected"
eq dead "$SWARM_CODEX_RUNTIME_STATUS" "dead reason surfaced"

printf '{"schema":"wrong"}\n' > "$FILE"
swarm_codex_runtime_read alpha; rc=$?
eq 2 "$rc" "wrong schema rejected"
eq malformed "$SWARM_CODEX_RUNTIME_STATUS" "malformed reason surfaced"

echo "=== malformed activity/capability fields never coerce to idle ==="
mutate(){
  python3 - "$FILE" "$1" "$2" <<'PY'
import json, sys
p,key,raw=sys.argv[1:]
d=json.load(open(p)); d[key]=json.loads(raw); json.dump(d,open(p,"w"))
PY
}
for spec in 'active|"yes"' 'queue_depth|-1' 'queue_depth|"2"' 'child_pid|0'; do
  write_state "$$" 0 0 0 ""
  mutate "${spec%%|*}" "${spec#*|}"
  swarm_codex_runtime_read alpha; rc=$?
  eq 2 "$rc" "invalid ${spec%%|*} is rejected as malformed"
done

write_state "$$" 0 0 0 ""
mutate backend '"app-server"'
mutate app_server_endpoint '"ws://example.com:9999"'
swarm_codex_runtime_read alpha; rc=$?
eq 2 "$rc" "remote App Server endpoint is malformed"

write_state "$$" 0 0 0 ""
mutate backend '"app-server"'
mutate app_server_endpoint '"ws://127.0.0.1:9999"'
swarm_codex_runtime_read alpha; rc=$?
eq 2 "$rc" "loopback TCP App Server endpoint is rejected as unauthenticated"

make_socket
chmod 666 "$SOCKET"
write_state "$$" 0 0 0 "unix://$SOCKET"
swarm_codex_runtime_read alpha; rc=$?
eq 2 "$rc" "non-private Unix socket is rejected"
rm -f "$SOCKET"

write_state "$$" 0 0 0 ""
mutate app_server_endpoint '"ws://127.0.0.1:9999"'
swarm_codex_runtime_read alpha; rc=$?
eq 2 "$rc" "exec backend cannot advertise an App Server endpoint"

rm -f "$FILE"
swarm_codex_runtime_read alpha; rc=$?
eq 1 "$rc" "missing file rejected"
eq missing "$SWARM_CODEX_RUNTIME_STATUS" "missing reason surfaced"

echo "codex-runtime-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
