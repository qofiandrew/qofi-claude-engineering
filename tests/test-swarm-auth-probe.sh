#!/usr/bin/env bash
# test-swarm-auth-probe.sh — regression tests for bin/swarm-auth-probe.sh, the
# REAL auth probe that replaces `claude --version` as the credswap VERIFY default.
#
# The probe's whole job is to answer ONE question with THREE answers, so the
# tests pin exactly those three (plus the fail-closed and config edges):
#   (a) authenticates           -> exit 0
#   (b) auth FAILED             -> exit 1   (caller RESTORES)
#   (c) authed-but-rate-limited -> exit 75  (caller KEEPS swap, signals ring-exhaust)
#
# SYNTHETIC-FIXTURE discipline: the probe's actual CALL is injected via
# SWARM_AUTH_PROBE_CMD, so no live `claude` and no real credential are ever
# touched. We only assert how the probe CLASSIFIES a given surface output+exit.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-auth-probe.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE="$ROOT/bin/swarm-auth-probe.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

# run PROBE_CMD [flags...] -> sets OUT (stderr+stdout) and rc
run() { local cmd="$1"; shift; OUT="$(SWARM_AUTH_PROBE_CMD="$cmd" bash "$PROBE" "$@" 2>&1)"; rc=$?; }

echo "=== swarm-auth-probe — the 3-way verdict ==="

echo "--- (a) authenticates: clean probe, exit 0 -> verdict 0 ---"
run 'printf "pong\n"; exit 0'
assert_eq 0 "$rc" "clean success -> exit 0 (a authenticates)"

echo "--- (b) auth FAIL: explicit auth-error text even on a ZERO exit -> verdict 1 ---"
# Some CLIs print the auth error but still exit 0; the auth-error signal must win.
run 'printf "Invalid API key · authentication_error\n"; exit 0'
assert_eq 1 "$rc" "auth-error text on exit 0 -> exit 1 (b auth-fail, fail closed)"

echo "--- (b) auth FAIL: bare non-zero, no message -> verdict 1 (fail closed) ---"
run 'exit 7'
assert_eq 1 "$rc" "non-zero with no signal -> exit 1 (b fail-closed)"

echo "--- (b) auth FAIL: unauthorized text -> verdict 1 ---"
run 'printf "Unauthorized\n" >&2; exit 1'
assert_eq 1 "$rc" "unauthorized -> exit 1 (b)"

echo "--- (c) authed-but-capped: usage-limit text on exit 0 -> verdict 75 ---"
run 'printf "Claude usage limit reached - resets at 11pm\n"; exit 0'
assert_eq 75 "$rc" "usage-limit on exit 0 -> exit 75 (c capped, not a swap failure)"

echo "--- (c) authed-but-capped: rate-limit text on NON-zero exit -> verdict 75 ---"
# A 429 can ride a non-zero exit; the limit signal is authoritative either way.
run 'printf "rate limit\n" >&2; exit 1'
assert_eq 75 "$rc" "rate-limit on non-zero exit -> exit 75 (c wins over generic non-zero)"

echo "--- (c) wins over (b): BOTH a limit AND an auth-error signal -> capped (75), not bad ---"
# A capped-but-authed account is not an auth failure; the limit signal takes
# precedence so we don't thrash-restore a valid credential.
run 'printf "5-hour limit reached. authentication_error noise\n"; exit 1'
assert_eq 75 "$rc" "limit+auth-error together -> exit 75 (c precedence)"

echo "--- override: SWARM_LIMIT_PATTERNS extends the capped classification ---"
OUT="$(SWARM_AUTH_PROBE_CMD='printf "QUOTA-BLOWN-XYZ\n"; exit 1' SWARM_LIMIT_PATTERNS='quota-blown-xyz' bash "$PROBE" 2>&1)"; rc=$?
assert_eq 75 "$rc" "custom limit pattern -> exit 75 (operator-tunable)"

echo "--- override: SWARM_AUTH_FAIL_PATTERNS extends the bad classification ---"
OUT="$(SWARM_AUTH_PROBE_CMD='printf "SESSION-REVOKED-XYZ\n"; exit 0' SWARM_AUTH_FAIL_PATTERNS='session-revoked-xyz' bash "$PROBE" 2>&1)"; rc=$?
assert_eq 1 "$rc" "custom auth-fail pattern on exit 0 -> exit 1 (operator-tunable)"

echo "--- --explain prints the chosen outcome to stderr ---"
run 'printf "pong\n"; exit 0' --explain
assert_has "$OUT" "OUTCOME (a)" "--explain announces outcome (a)"
run 'printf "rate limit\n"; exit 1' --explain
assert_has "$OUT" "OUTCOME (c)" "--explain announces outcome (c)"

echo "--- no probe wired AND no claude on PATH -> fail CLOSED (exit 1, treat as auth-fail) ---"
# With no verifier of any kind, we must NOT report success; failing closed makes
# the caller restore rather than boot on an unverifiable credential.
OUT="$(env -u SWARM_AUTH_PROBE_CMD PATH=/usr/bin:/bin bash "$PROBE" --explain 2>&1)"; rc=$?
assert_eq 1 "$rc" "no probe + no claude -> fail closed (exit 1)"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'Failures:%s\n' "$FAILURES" >&2; exit 1; fi
exit 0
