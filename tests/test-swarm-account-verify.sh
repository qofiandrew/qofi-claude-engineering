#!/usr/bin/env bash
# test-swarm-account-verify.sh — bin/swarm-account-verify.sh, the independence
# CANARY (ADR-0018).
#
# SAFETY PROPERTY: read-only on accounts; never reads a token VALUE. HOME is a
# temp dir; the usage signal is an injected stub (SWARM_ACCOUNT_USAGE_CMD) reading
# per-label counter files, so no ccusage / real account is touched. A decoy token
# value in the vault is asserted absent from output.
#
# WHAT THIS PROTECTS:
#   1. No labeled accounts -> exit 1 (nothing to verify).
#   2. --dry-run -> exit 0, touches nothing.
#   3. Probe mode: provisioned + token present -> PASS per account; missing token
#      -> SKIP (handles no token); unprovisioned dir -> SKIP. Token VALUE hidden.
#   4. baseline + check --moved <L>: only the exercised account advancing -> PASS;
#      a DIFFERENT account advancing -> FAIL (exit 2); the exercised account NOT
#      advancing -> FAIL (exit 2).
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account-verify.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VER="$ROOT/bin/swarm-account-verify.sh"
PROV="$ROOT/bin/swarm-account-provision.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export SWARM_HOME="$ROOT"

# A two-account labeled conf + a vault with both tokens (+ decoy value).
LABCONF="$TMP/swarm.conf"
cat > "$LABCONF" <<'EOF'
a | /tmp/a | BOT_A | 1001 | 2001 | max-a
b | /tmp/b | BOT_B | 1002 | 2002 | max-b
EOF
VAULT="$TMP/tokens.env"
printf 'export OAUTH_TOKEN_MAX_A=DECOY-A-SECRET\nexport OAUTH_TOKEN_MAX_B=DECOY-B-SECRET\n' > "$VAULT"

# usage stub: prints the per-label counter file's contents (default 0).
STUB='cat "'"$TMP"'/u-$1" 2>/dev/null || echo 0'
echo 5 > "$TMP/u-max-a"; echo 9 > "$TMP/u-max-b"

# Provision both isolated dirs under the temp HOME.
HOME="$TMP" SWARM_CONF="$LABCONF" bash "$PROV" max-a >/dev/null 2>&1
HOME="$TMP" SWARM_CONF="$LABCONF" bash "$PROV" max-b >/dev/null 2>&1

run() { HOME="$TMP" SWARM_CONF="$LABCONF" SWARM_TOKENS_ENV="$VAULT" SWARM_ACCOUNT_USAGE_CMD="$STUB" bash "$VER" "$@" 2>&1; }

# ---------------------------------------------------------------------------
echo "=== no labeled accounts -> exit 1 ==="
DEFCONF="$TMP/default.conf"; printf 'x | /tmp/x | BOT_X | 1 | 2 |\n' > "$DEFCONF"
OUT="$(HOME="$TMP" SWARM_CONF="$DEFCONF" bash "$VER" 2>&1)"; RC=$?
assert_eq "1" "$RC" "all-default conf -> exit 1"
assert_has "$OUT" "no labeled accounts" "explains there is nothing to verify"

echo "=== --dry-run touches nothing, exit 0 ==="
OUT="$(run --dry-run)"; RC=$?
assert_eq "0" "$RC" "--dry-run exit 0"
assert_has "$OUT" "max-a" "--dry-run lists the labeled accounts"
[ -f "$TMP/.swarm-account-usage-baseline" ] && bad "--dry-run wrote a baseline" || ok "--dry-run wrote no baseline"

echo "=== probe mode: both provisioned + token -> PASS; value hidden ==="
OUT="$(run)"; RC=$?
assert_eq "0" "$RC" "probe both-good -> exit 0 (PASS)"
assert_has  "$OUT" "PASS  max-a" "max-a PASS (isolated dir + token + usage)"
assert_has  "$OUT" "PASS  max-b" "max-b PASS"
assert_has  "$OUT" "usage=5" "reads max-a usage via the stub"
assert_lacks "$OUT" "DECOY-A-SECRET" "token VALUE never appears in output"

echo "=== handles no token: missing OAUTH var -> SKIP ==="
HALFVAULT="$TMP/half.env"; printf 'export OAUTH_TOKEN_MAX_A=DECOY-A-SECRET\n' > "$HALFVAULT"
OUT="$(HOME="$TMP" SWARM_CONF="$LABCONF" SWARM_TOKENS_ENV="$HALFVAULT" SWARM_ACCOUNT_USAGE_CMD="$STUB" bash "$VER" 2>&1)"; RC=$?
assert_has "$OUT" "SKIP  max-b" "max-b with no token -> SKIP (not a crash)"
assert_has "$OUT" "PASS  max-a" "max-a still PASS"
assert_eq "0" "$RC" "a SKIP does not fail the run"

echo "=== baseline + check: only the exercised account moved -> PASS ==="
run --baseline "$TMP/base" >/dev/null
echo 25 > "$TMP/u-max-a"     # max-a advances; max-b stays 9
OUT="$(run --check "$TMP/base" --moved max-a)"; RC=$?
assert_eq "0" "$RC" "only max-a moved, expected max-a -> exit 0"
assert_has "$OUT" "MOVED max-a" "max-a reported as moved"
assert_has "$OUT" "flat  max-b" "max-b reported flat"

echo "=== check: a DIFFERENT account moved -> FAIL ==="
OUT="$(run --check "$TMP/base" --moved max-b)"; RC=$?
assert_eq "2" "$RC" "max-a moved but max-b expected -> exit 2 (FAIL)"
assert_has "$OUT" "FAIL  max-a" "the unexpected mover is flagged"

echo "=== check: the exercised account did NOT move -> FAIL ==="
cp "$TMP/u-max-a" "$TMP/_keep"; echo 25 > "$TMP/base.dummy"
# rebuild a baseline where max-a is already 25 (so it will appear flat), expect it to move
run --baseline "$TMP/base2" >/dev/null   # base2: max-a=25, max-b=9
OUT="$(run --check "$TMP/base2" --moved max-a)"; RC=$?
assert_eq "2" "$RC" "expected max-a to move but it was flat -> exit 2 (FAIL)"
assert_has "$OUT" "FAIL  max-a" "the non-moving exercised account is flagged"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
