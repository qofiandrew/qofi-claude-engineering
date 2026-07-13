#!/usr/bin/env bash
# Manager-backed Codex advisory review routing (no real model invocation).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d /private/tmp/qofi-review-manager.XXXXXX)"
SOCKET_PID=""
trap 'test -z "$SOCKET_PID" || kill "$SOCKET_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected=[$1] got=[$2])"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" && ok "$3" || bad "$3 (missing [$2])"; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

HOME="$TMP/home"; HARNESS="$TMP/harness"; REPO="$TMP/repo"
mkdir -m 700 "$HOME" "$HARNESS" "$REPO"
mkdir -m 700 "$HOME/.codex" "$HOME/.codex/app-server-manager"
cp "$ROOT/bin/codex-review.sh" "$ROOT/bin/review-runner.py" "$HARNESS/"
chmod 700 "$HARNESS/codex-review.sh"
CONTROL_LOG="$TMP/control.log"; INPUT_LOG="$TMP/input.log"; FAIL_READY="$TMP/fail-ready"
cat > "$HARNESS/codex-manager-control.py" <<PY
#!/usr/bin/python3 -I
import os,sys
command=sys.argv[-1]
with open('$CONTROL_LOG','a') as out: out.write(command+'\n')
if command == 'ready':
    raise SystemExit(1 if os.path.exists('$FAIL_READY') else 0)
if command == 'review':
    value=sys.stdin.read()
    with open('$INPUT_LOG','w') as out: out.write(value)
    print('MANAGER-REVIEW: serialized tool-less finding')
    raise SystemExit(0)
raise SystemExit(2)
PY
chmod 700 "$HARNESS/codex-manager-control.py"

SOCKET="$HOME/.codex/app-server-manager/control.sock"
/usr/bin/python3 - "$SOCKET" <<'PY' &
import signal,socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
signal.signal(signal.SIGTERM,lambda *_: sys.exit(0))
while True: time.sleep(1)
PY
SOCKET_PID=$!
for _ in 1 2 3 4 5; do [ -S "$SOCKET" ] && break; sleep 1; done
chmod 600 "$SOCKET"

(cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\n' > f && git add f && git commit -qm one \
  && printf 'b\n' >> f && git add f && git commit -qm two)
run_review(){
  OUT="$(cd "$REPO" && /usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$HARNESS/codex-review.sh" "$@" 2>&1)"; RC=$?
}

echo "=== ready manager is the first-class review route ==="
: > "$CONTROL_LOG"; run_review --check
eq 0 "$RC" "manager-backed review check succeeds without a host-preflight file"
has "$OUT" "dedicated App Server manager" "check reports the manager route"
eq ready "$(cat "$CONTROL_LOG")" "check only performs strict manager readiness"

: > "$CONTROL_LOG"; run_review
eq 0 "$RC" "manager-backed advisory turn succeeds"
has "$OUT" "MANAGER-REVIEW" "manager advisory output is surfaced"
eq $'ready\nreview' "$(cat "$CONTROL_LOG")" "review never falls through to direct Codex exec"
INPUT="$(cat "$INPUT_LOG")"
has "$INPUT" "contrarian code reviewer" "bounded manager prompt retains the fixed review doctrine"
has "$INPUT" "--- DIFF" "bounded diff is sent through the manager"

echo "=== a present unhealthy endpoint never downgrades to direct exec ==="
: > "$FAIL_READY"; : > "$CONTROL_LOG"; run_review --check
eq 3 "$RC" "unhealthy present manager is advisory-down"
has "$OUT" "exists but is not ready" "failure names the manager readiness boundary"
lacks "$OUT" "current-user compatibility" "present manager never falls back to operator Codex"
eq ready "$(cat "$CONTROL_LOG")" "failure performs no review turn"

echo "codex-review-manager: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
