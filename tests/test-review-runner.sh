#!/usr/bin/env bash
# Resource-bound supervisor regressions for both advisory model lanes.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/review-runner.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-runner.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL + 1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=$1 got=$2)"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

echo "=== successful bounded command ==="
out="$(printf 'payload' | python3 "$RUNNER" --cwd "$TMP" --timeout 2 --max-input 1024 --max-output 1024 -- /bin/sh -c 'read x; printf "seen:%s" "$x"' 2>&1)"; rc=$?
eq 0 "$rc" "successful child status propagates"
has "$out" "seen:payload" "stdin and stdout are relayed"

echo "=== terminal-active reviewer output is rendered inert ==="
out="$(printf '' | /usr/bin/python3 -I -B "$RUNNER" --cwd "$TMP" --timeout 2 \
  --max-input 1024 --max-output 4096 --sanitize-terminal -- /usr/bin/python3 -I -B -c \
  'import sys; sys.stdout.write("before\x1b]52;c;CLIPBOARD\x07middle\x1b[2Jafter\u202esafe")' 2>&1)"; rc=$?
eq 0 "$rc" "sanitized child status propagates"
has "$out" "beforemiddleaftersafe" "visible reviewer text is preserved"
if printf '%s' "$out" | /usr/bin/python3 -I -B -c \
  'import sys; data=sys.stdin.buffer.read(); raise SystemExit(any(x in data for x in (b"CLIPBOARD", b"\x1b", "\u202e".encode())))'; then
  ok "terminal/clipboard/bidi controls are removed"
else
  bad "terminal/clipboard/bidi controls are removed"
fi

echo "=== timeout kills the child process group ==="
out="$(python3 "$RUNNER" --cwd "$TMP" --timeout 1 --max-input 1024 --max-output 1024 -- /bin/sh -c 'sleep 10' </dev/null 2>&1)"; rc=$?
eq 124 "$rc" "timeout has a stable status"
has "$out" "timed out after 1s" "child timeout reason is explicit"

echo "=== leader exit and runner interruption reap descendants ==="
survived="$TMP/background-survived"
python3 "$RUNNER" --cwd "$TMP" --timeout 5 --max-input 1024 --max-output 1024 -- \
  /bin/sh -c "(trap '' TERM; sleep 2; echo bad > '$survived') & exit 0" </dev/null >/dev/null 2>&1
sleep 3
[ ! -e "$survived" ] && ok "normal leader exit kills background descendants" || bad "normal leader exit kills background descendants"

interrupted="$TMP/interrupted-survived"
python3 "$RUNNER" --cwd "$TMP" --timeout 10 --max-input 1024 --max-output 1024 -- \
  /bin/sh -c "(trap '' TERM; sleep 2; echo bad > '$interrupted') & sleep 10" </dev/null >"$TMP/interrupt.out" 2>&1 &
runner_pid=$!
sleep 0.2
kill -TERM "$runner_pid"
wait "$runner_pid"; rc=$?
eq 143 "$rc" "SIGTERM returns conventional interrupted status"
sleep 3
[ ! -e "$interrupted" ] && ok "runner SIGTERM kills child process group" || bad "runner SIGTERM kills child process group"

echo "=== output and input limits fail closed ==="
out="$(python3 "$RUNNER" --cwd "$TMP" --timeout 10 --max-input 1024 --max-output 1024 -- /usr/bin/yes x </dev/null 2>&1)"; rc=$?
eq 125 "$rc" "oversized output is refused"
has "$out" "output exceeded" "output limit reason is explicit"

# Keep the child alive after it reaches RLIMIT_FSIZE. The observed cap is the
# primary failure and must retain its stable status/reason while the child is
# still live; a tiny scheduler-sensitive deadline would make this test flaky.
out="$(python3 "$RUNNER" --cwd "$TMP" --timeout 5 --max-input 1024 --max-output 1024 -- \
  python3 -c 'import os,time
data=b"x"*2048
try:
 while data:
  used=os.write(1,data); data=data[used:]
except OSError:
 pass
time.sleep(10)' </dev/null 2>&1)"; rc=$?
eq 125 "$rc" "output cap takes precedence while the child remains live"
has "$out" "output exceeded" "live-child limit keeps the explicit reason"

out="$(python3 -c 'print("x" * 2000)' | python3 "$RUNNER" --cwd "$TMP" --timeout 2 --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
eq 126 "$rc" "oversized input is refused before child launch"
has "$out" "input exceeded" "input limit reason is explicit"

echo "=== input acquisition is time/signal bounded ==="
fifo="$TMP/held-open.fifo"
mkfifo "$fifo"
( exec 3>"$fifo"; printf x >&3; sleep 10 ) & writer=$!
out="$(python3 "$RUNNER" --cwd "$TMP" --input-timeout 1 --timeout 5 \
  --max-input 1024 --max-output 1024 -- /bin/cat <"$fifo" 2>&1)"; rc=$?
kill "$writer" 2>/dev/null || true; wait "$writer" 2>/dev/null || true
eq 124 "$rc" "held-open producer times out before child launch"
has "$out" "input timed out" "input timeout reason is explicit"

rm -f "$fifo"; mkfifo "$fifo"
( exec 3>"$fifo"; printf x >&3; sleep 10 ) & writer=$!
python3 "$RUNNER" --cwd "$TMP" --input-timeout 20 --timeout 5 \
  --max-input 1024 --max-output 1024 -- /bin/cat <"$fifo" >"$TMP/input-signal.out" 2>&1 &
runner=$!
sleep 0.2; kill -TERM "$runner"; wait "$runner"; rc=$?
kill "$writer" 2>/dev/null || true; wait "$writer" 2>/dev/null || true
eq 143 "$rc" "SIGTERM interrupts held-open input acquisition"

echo "=== file input stays beneath root and never follows links/devices ==="
mkdir -p "$TMP/input-root"
printf 'safe-file' > "$TMP/input-root/draft.md"
out="$(python3 "$RUNNER" --cwd "$TMP" --input-root "$TMP/input-root" \
  --input-file "$TMP/input-root/draft.md" --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
eq 0 "$rc" "regular beneath-root input is accepted"
has "$out" "safe-file" "accepted file bytes are relayed"
printf 'outside-secret' > "$TMP/outside-secret"
out="$(python3 "$RUNNER" --cwd "$TMP" --input-root "$TMP/input-root" \
  --input-file "$TMP/outside-secret" --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
eq 126 "$rc" "outside file is refused"
ln -s "$TMP/outside-secret" "$TMP/input-root/link"
out="$(python3 "$RUNNER" --cwd "$TMP" --input-root "$TMP/input-root" \
  --input-file "$TMP/input-root/link" --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
eq 126 "$rc" "symlink input is refused"
mkfifo "$TMP/input-root/device"
out="$(python3 "$RUNNER" --cwd "$TMP" --input-root "$TMP/input-root" \
  --input-file "$TMP/input-root/device" --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
eq 126 "$rc" "FIFO input is refused without blocking"

echo "=== output storage has no swappable pathname ==="
printf 'do-not-leak' > "$TMP/host-secret"
( while :; do
    for f in "$TMP"/.review-output-*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      rm -f "$f"; ln -s "$TMP/host-secret" "$f" 2>/dev/null || true
    done
  done ) & replacer=$!
out="$(printf payload | python3 "$RUNNER" --cwd "$TMP" --max-input 1024 --max-output 1024 -- /bin/cat 2>&1)"; rc=$?
kill "$replacer" 2>/dev/null || true; wait "$replacer" 2>/dev/null || true
eq 0 "$rc" "adversarial pathname replacer cannot affect output"
has "$out" "payload" "runner returns child output, not host secret"

if find "$TMP" -name '.review-output-*' -print -quit | grep -q .; then
  bad "runner cleans private output files"
else
  ok "runner cleans private output files"
fi

echo "review-runner: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
