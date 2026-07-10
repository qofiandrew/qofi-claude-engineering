#!/usr/bin/env bash
# test-swarm-tick-alert.sh — regression tests for the SWARM_TICK_ALERT_CMD
# standing step added to bin/swarm-rotate-tick.sh (the no-restart stuck-pane net).
#
# WHAT THIS PINS:
#   - The alert runs on EVERY live verdict, INCLUDING OK — it must fire before the
#     OK early-return, because the stuck-pane case is precisely "verdict OK but a
#     lead is parked". (If it ran only on NEAR/AT it would never catch the bug.)
#   - It receives the verdict word in SWARM_TICK_POLL_VERDICT (the headroom gate).
#   - It is SKIPPED in --dry-run.
#   - It NEVER changes routing or the tick's exit code: an alert that fails is
#     logged and ignored; a NEAR verdict still reaches the actuator.
#   - Default (unset SWARM_TICK_ALERT_CMD) = no-op (covered by the existing
#     test-swarm-rotate-tick.sh staying green).
#
# All external commands are stubs. bash 3.2-safe.
# Run from anywhere:  bash tests/test-swarm-tick-alert.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TICK="$ROOT/bin/swarm-rotate-tick.sh"

PASS=0; FAIL=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_empty(){ if [ -z "$1" ]; then ok "$2"; else bad "$2 (got [$1])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tick-alert-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ALERT_LOG="$TMP/alert.log"
ROTATE_LOG="$TMP/rotate.log"

# Stub actuator: records that it ran; --next prints nothing (no ring here).
ROTATE_STUB="$TMP/rotate.sh"
cat > "$ROTATE_STUB" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --next) exit 0 ;;
  *) echo "rotate ran \$*" >> "$ROTATE_LOG"; exit 0 ;;
esac
EOF
chmod +x "$ROTATE_STUB"

# run POLL_RC [tick-args...] : run the tick with a poll that exits POLL_RC and an
# alert stub that records the verdict it was handed.
run_tick() {
  local poll_rc="$1"; shift
  : > "$ALERT_LOG"; : > "$ROTATE_LOG"
  OUT="$(
    export SWARM_POLL_CMD="exit $poll_rc"
    export SWARM_ROTATE_CMD="$ROTATE_STUB"
    export SWARM_ACCOUNT_STATE_CMD="true"
    export SWARM_LIMIT_DETECT_CMD=""
    export SWARM_TICK_ALERT_CMD="printf '%s\n' \"\${SWARM_TICK_POLL_VERDICT:-<unset>}\" >> $ALERT_LOG"
    bash "$TICK" "$@" 2>&1
  )"; rc=$?
}

echo "=== alert fires on an OK verdict (the stuck-pane case) and tick still exits 0 ==="
run_tick 0
assert_eq 0 "$rc" "OK tick exits 0"
assert_eq "OK" "$(cat "$ALERT_LOG" 2>/dev/null)" "alert ran and was handed verdict=OK"
assert_empty "$(cat "$ROTATE_LOG" 2>/dev/null)" "OK verdict does not rotate"

echo "=== alert fires on NEAR, BEFORE routing, and the actuator still runs ==="
run_tick 10
assert_eq "NEAR" "$(cat "$ALERT_LOG" 2>/dev/null)" "alert ran and was handed verdict=NEAR"
assert_has "$(cat "$ROTATE_LOG" 2>/dev/null)" "rotate ran" "NEAR still reaches the actuator after the alert"

echo "=== alert is SKIPPED in --dry-run ==="
run_tick 0 --dry-run
assert_empty "$(cat "$ALERT_LOG" 2>/dev/null)" "no alert in --dry-run"

echo "=== a FAILING alert never changes the tick's exit or routing ==="
: > "$ROTATE_LOG"
OUT="$(
  export SWARM_POLL_CMD="exit 10"
  export SWARM_ROTATE_CMD="$ROTATE_STUB"
  export SWARM_ACCOUNT_STATE_CMD="true"
  export SWARM_TICK_ALERT_CMD="exit 3"
  bash "$TICK" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "NEAR tick exits 0 even though the alert cmd exited non-zero"
assert_has "$(cat "$ROTATE_LOG" 2>/dev/null)" "rotate ran" "routing proceeded despite the alert failure"

echo "=== unset SWARM_TICK_ALERT_CMD = no-op (no error) ==="
OUT="$(
  export SWARM_POLL_CMD="exit 0"
  export SWARM_ROTATE_CMD="$ROTATE_STUB"
  export SWARM_ACCOUNT_STATE_CMD="true"
  bash "$TICK" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "no alert cmd -> tick still exits 0"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
