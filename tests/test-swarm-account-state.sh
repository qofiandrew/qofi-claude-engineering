#!/usr/bin/env bash
# test-swarm-account-state.sh — regression tests for bin/swarm-account-state.sh,
# the active-account persistence used by swarm-rotate's ring math.
#
# SAFETY PROPERTY OF THIS TEST FILE. It NEVER touches the real
# ~/.config/swarm/active-account. Every call points SWARM_ACCOUNT_STATE_FILE at a
# fresh path under a mktemp dir, so a set/get round-trip exercises the real code
# without writing the operator's actual state. HOME is also redirected as a
# belt-and-braces guard so a missing-override bug could never reach the real file.
#
# WHAT THIS PROTECTS:
#   1. set/get ROUND-TRIP: `set max-b` then `get` prints max-b, exit 0.
#   2. MISSING file: `get` with no state file prints nothing, exits 1 (a signal
#      the caller turns into a cold-start default — NOT a hard error).
#   3. OVERWRITE: a second `set` replaces the handle; `get` returns the new one.
#   4. PERMS: the state file is chmod 600, and its parent dir is created on set.
#   5. VALIDATION: a bogus handle (slash / metacharacter / empty) is REFUSED
#      (exit 2) and does not write the file.
#   6. `path` prints the resolved override path; unknown subcommand -> exit 2.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account-state.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE="$ROOT/bin/swarm-account-state.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-account-state.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Belt-and-braces: redirect HOME so even a broken override can't reach the real
# ~/.config/swarm/active-account. The tests still ALWAYS pass an explicit override.
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"

# run_state STATE_FILE ARGS...  — invoke the script with the given override path
# and capture $OUT + $rc. The override is the WHOLE contract for test isolation.
run_state() {
  local sf="$1"; shift
  OUT="$(
    export HOME="$FAKE_HOME"
    export SWARM_ACCOUNT_STATE_FILE="$sf"
    bash "$STATE" "$@" 2>&1
  )"; rc=$?
}

# ---------------------------------------------------------------------------
echo "=== 1) missing-file get: empty output, exit 1 (signal, not error) ==="
SF="$TMP/state-1"   # never created
run_state "$SF" get
assert_eq 1 "$rc" "get on a missing file -> exit 1"
assert_eq "" "$OUT" "get on a missing file prints nothing"
[ -f "$SF" ] && bad "get must NOT create the state file" || ok "get does not create the file"

# ---------------------------------------------------------------------------
echo "=== 2) set/get round-trip ==="
SF="$TMP/sub/dir/state-2"   # parent dirs do not exist yet -> set must create them
run_state "$SF" set max-b
assert_eq 0 "$rc" "set max-b -> exit 0"
assert_has "$OUT" "max-b" "set echoes the new active account"
[ -f "$SF" ] && ok "set created the state file (and its parent dirs)" || bad "set did not create the state file"
run_state "$SF" get
assert_eq 0 "$rc" "get after set -> exit 0"
assert_eq "max-b" "$OUT" "get returns exactly the handle that was set"

# ---------------------------------------------------------------------------
echo "=== 3) state file is a single line + chmod 600 ==="
LINES="$(wc -l < "$SF" | tr -d '[:space:]')"
assert_eq "1" "$LINES" "state file holds a single line"
PERMS="$(stat -f '%Lp' "$SF" 2>/dev/null || stat -c '%a' "$SF" 2>/dev/null || echo '???')"
assert_eq "600" "$PERMS" "state file is chmod 600"

# ---------------------------------------------------------------------------
echo "=== 4) overwrite: second set replaces the handle ==="
run_state "$SF" set max-c
assert_eq 0 "$rc" "overwrite set -> exit 0"
run_state "$SF" get
assert_eq "max-c" "$OUT" "get returns the OVERWRITTEN handle (max-c, not max-b)"
LINES="$(wc -l < "$SF" | tr -d '[:space:]')"
assert_eq "1" "$LINES" "overwrite leaves a single line (no append)"

# ---------------------------------------------------------------------------
echo "=== 5) validation: bogus handles are refused, file untouched ==="
SF="$TMP/state-valid"
run_state "$SF" set max-a   # seed a known-good value first
run_state "$SF" set "bad/handle"
assert_eq 2 "$rc" "set with a slash in the handle -> exit 2"
assert_has "$OUT" "suspicious" "explains the refusal"
run_state "$SF" get
assert_eq "max-a" "$OUT" "a refused set leaves the prior value intact"
run_state "$SF" set ""
assert_eq 2 "$rc" "set with an empty handle -> exit 2"
run_state "$SF" set 'a;b'
assert_eq 2 "$rc" "set with a metacharacter -> exit 2"

# ---------------------------------------------------------------------------
echo "=== 6) path + bad subcommand ==="
SF="$TMP/state-path"
run_state "$SF" path
assert_eq 0 "$rc" "path -> exit 0"
assert_eq "$SF" "$OUT" "path prints the resolved override path"
run_state "$SF" frobnicate
assert_eq 2 "$rc" "unknown subcommand -> exit 2"
run_state "$SF"   # no subcommand at all
assert_eq 2 "$rc" "no subcommand -> exit 2"

# ---------------------------------------------------------------------------
echo "=== 7) default path uses HOME/.config (no override) — read-only probe ==="
# Without an override, the resolved path must be under the (redirected) HOME so
# the real one is never the target. `path` makes NO writes, so this is safe.
OUT="$(
  export HOME="$FAKE_HOME"
  unset SWARM_ACCOUNT_STATE_FILE
  unset XDG_CONFIG_HOME
  bash "$STATE" path 2>&1
)"; rc=$?
assert_eq 0 "$rc" "path with no override -> exit 0"
assert_eq "$FAKE_HOME/.config/swarm/active-account" "$OUT" "default path is HOME/.config/swarm/active-account"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
