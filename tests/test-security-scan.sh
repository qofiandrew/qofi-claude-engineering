#!/usr/bin/env bash
# test-security-scan.sh — orchestration tests for the deterministic security pass.
# Pins the three behaviors that matter regardless of scanner version: a missing
# scanner FAILS CLOSED (exit 2 + install step), a clean run passes (exit 0), and
# any finding fails loudly (exit 1). Uses STUB scanners (configurable exit) so it
# never depends on gitleaks/semgrep being installed.
#
# Run from $SWARM_HOME:  bash tests/test-security-scan.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SS="$ROOT/bin/security-scan.sh"

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qiF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sec-scan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin"
# Stub scanners — exit code is configurable via GL_RC / SG_RC.
printf '#!/usr/bin/env bash\nexit ${GL_RC:-0}\n' > "$TMP/bin/gitleaks"; chmod +x "$TMP/bin/gitleaks"
printf '#!/usr/bin/env bash\nexit ${SG_RC:-0}\n' > "$TMP/bin/semgrep";  chmod +x "$TMP/bin/semgrep"

run_ss(){ # envstr -> sets OUT, RC
  local envstr="$1"; shift
  OUT="$( env -i PATH="$PATH" $envstr bash "$SS" "$@" 2>&1 )"; RC=$?
}

echo "=== fail-closed: missing scanner is a config defect ==="
run_ss 'GITLEAKS_BIN=/nope/gitleaks SEMGREP_BIN=/nope/semgrep'
assert_eq 2 "$RC" 'both scanners missing -> exit 2 (fail closed)'
assert_has 'gitleaks' "$OUT" 'missing -> names gitleaks'
assert_has 'semgrep'  "$OUT" 'missing -> names semgrep'
assert_has 'brew install gitleaks semgrep' "$OUT" 'missing -> prints the install step'
run_ss "GITLEAKS_BIN=$TMP/bin/gitleaks SEMGREP_BIN=/nope/semgrep"
assert_eq 2 "$RC" 'one scanner missing -> still exit 2'

echo ""
echo "=== installed scanners: clean vs findings ==="
run_ss "GITLEAKS_BIN=$TMP/bin/gitleaks SEMGREP_BIN=$TMP/bin/semgrep GL_RC=0 SG_RC=0"
assert_eq 0 "$RC" 'both clean -> exit 0'
assert_has 'clean' "$OUT" 'clean -> says clean'
run_ss "GITLEAKS_BIN=$TMP/bin/gitleaks SEMGREP_BIN=$TMP/bin/semgrep GL_RC=1 SG_RC=0"
assert_eq 1 "$RC" 'gitleaks finding -> exit 1'
assert_has 'FINDINGS' "$OUT" 'gitleaks finding -> loud FINDINGS'
run_ss "GITLEAKS_BIN=$TMP/bin/gitleaks SEMGREP_BIN=$TMP/bin/semgrep GL_RC=0 SG_RC=1"
assert_eq 1 "$RC" 'semgrep finding -> exit 1'

echo ""
echo "=== bare --range (no value) exits cleanly, never hangs (bash-3.2 shift guard) ==="
run_ss '' --range
assert_eq 2 "$RC" 'bare --range -> exit 2 (usage error, not an infinite loop)'

echo ""
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; }
exit 0
