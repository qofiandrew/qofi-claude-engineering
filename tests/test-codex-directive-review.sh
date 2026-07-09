#!/usr/bin/env bash
# test-codex-directive-review.sh — proves the CPO Codex adversarial-review lane's
# HARD money-path floor: subscription auth only, NEVER metered API-key billing,
# advisory-down (never a block) on any failure — plus the draft-input plumbing
# (stdin and file). Uses a STUB codex on PATH so it never spends real money.
#
# Run from $SWARM_HOME:  bash tests/test-codex-directive-review.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CR="$ROOT/templates/cpo/bin/codex-directive-review.sh"

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qiF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }
assert_absent(){ if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3 (unexpected [$1])"; else pass "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-directive-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stub codex: logs every invocation's argv; `login status` is configurable;
# exec/review drains stdin and prints a canned adversarial review. NEVER spends.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "ARGV: $*" >> "$CODEX_ARGV_LOG"
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
  printf '%s\n' "${STUB_LOGIN_STATUS:-Logged in using ChatGPT (subscription)}"
  exit "${STUB_LOGIN_RC:-0}"
fi
cat >/dev/null
printf 'ADVERSARIAL-REVIEW: one unstated assumption; otherwise fine.\n'
exit 0
EOF
chmod +x "$TMP/bin/codex"

mkdir -p "$TMP/home"
ARGVLOG="$TMP/argv.log"
DRAFT="$TMP/draft.md"
printf '[cto-7] Build the reconciliation module per requirements.md v3.\n' > "$DRAFT"

# run_cr ENVSTR ARGS... -> sets OUT (merged stdout+stderr) and RC. Draft on stdin.
run_cr(){
  : > "$ARGVLOG"
  local envstr="$1"; shift
  OUT="$( env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
      CODEX_BIN=codex CODEX_ARGV_LOG="$ARGVLOG" $envstr \
      bash "$CR" "$@" < "$DRAFT" 2>&1 )"; RC=$?
}

echo "=== money-path floor: subscription only, never metered ==="
run_cr 'OPENAI_API_KEY=sk-test' --check
assert_eq 3 "$RC" 'OPENAI_API_KEY set -> advisory-down (exit 3)'
assert_has 'ADVISORY-DOWN' "$OUT" 'OPENAI_API_KEY -> loud advisory-down'
assert_has 'OPENAI_API_KEY' "$OUT" 'OPENAI_API_KEY -> names the offending var'
assert_eq '' "$(cat "$ARGVLOG")" 'OPENAI_API_KEY -> codex never invoked at all'

run_cr 'CODEX_API_KEY=sk-test' --check
assert_eq 3 "$RC" 'CODEX_API_KEY set -> advisory-down'
assert_eq '' "$(cat "$ARGVLOG")" 'CODEX_API_KEY -> codex never invoked'

run_cr 'CODEX_BIN=/nonexistent/codex' --check
assert_eq 3 "$RC" 'codex CLI absent -> advisory-down'

run_cr 'STUB_LOGIN_STATUS=api-key-session' --check
assert_eq 3 "$RC" 'login status reports api-key -> advisory-down'
assert_has 'subscription auth required' "$OUT" 'api-key session -> demands subscription'

run_cr 'STUB_LOGIN_RC=1' --check
assert_eq 3 "$RC" 'codex not logged in (status rc!=0) -> advisory-down'

echo ""
echo "=== advisory-down wording: ship-the-directive, never a block ==="
run_cr 'OPENAI_API_KEY=sk-test' --check
assert_has 'NOT a block' "$OUT" 'advisory-down -> says it is not a block'
assert_has 'ship the directive' "$OUT" 'advisory-down -> tells the CPO to ship anyway'

echo ""
echo "=== happy path: subscription verified (stub, no real spend) ==="
run_cr '' --check
assert_eq 0 "$RC" '--check with subscription -> exit 0'
assert_has 'auth OK' "$OUT" '--check -> prints the auth-OK plan'
assert_has 'ARGV: login status' "$(cat "$ARGVLOG")" '--check -> did call login status'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" '--check -> does NOT invoke codex exec'

run_cr ''
assert_eq 0 "$RC" 'full run (draft on stdin) -> exit 0'
assert_has 'ADVERSARIAL-REVIEW' "$OUT" 'full run -> emits the codex advisory output'
assert_has 'NEVER a gate' "$OUT" 'full run -> footer reminds advisory, not a gate'
assert_has 'ARGV: exec' "$(cat "$ARGVLOG")" 'full run -> invoked codex exec'
assert_has 'model_reasoning_effort=xhigh' "$(cat "$ARGVLOG")" 'full run -> effort pinned to MAX (xhigh)'
assert_absent 'with-api-key' "$(cat "$ARGVLOG")" 'full run -> NEVER passes --with-api-key (no metered fallback)'

# file-arg form
: > "$ARGVLOG"
OUT="$( env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" CODEX_BIN=codex CODEX_ARGV_LOG="$ARGVLOG" bash "$CR" "$DRAFT" 2>&1 )"; RC=$?
assert_eq 0 "$RC" 'full run (draft as file arg) -> exit 0'
assert_has 'ADVERSARIAL-REVIEW' "$OUT" 'file-arg run -> emits the codex advisory output'

# empty draft is a clean no-op, not an invocation
: > "$ARGVLOG"
OUT="$( env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" CODEX_BIN=codex CODEX_ARGV_LOG="$ARGVLOG" bash "$CR" < /dev/null 2>&1 )"; RC=$?
assert_eq 0 "$RC" 'empty draft -> exit 0 (nothing to review)'
assert_has 'empty draft' "$OUT" 'empty draft -> says so'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" 'empty draft -> codex exec never invoked'

echo ""
echo "=== CODEX_EXEC_ARGS is validated (money-path floor holds even with override) ==="
run_cr 'CODEX_EXEC_ARGS=login' --check
assert_eq 3 "$RC" 'CODEX_EXEC_ARGS=login -> advisory-down (subcommand not exec|review)'
# a forbidden flag token alongside a valid subcommand — passed directly so the value can carry a space
: > "$ARGVLOG"
OUT="$( env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" CODEX_BIN=codex CODEX_ARGV_LOG="$ARGVLOG" CODEX_EXEC_ARGS='exec --with-api-key' bash "$CR" < "$DRAFT" 2>&1 )"; RC=$?
assert_eq 3 "$RC" 'CODEX_EXEC_ARGS="exec --with-api-key" -> advisory-down (forbidden token)'
assert_has 'forbidden token' "$OUT" 'forbidden token -> named in the advisory-down'
assert_absent 'ARGV: exec --with-api-key' "$(cat "$ARGVLOG")" 'forbidden token -> codex exec never invoked'

echo ""
echo "=== unknown flag exits cleanly ==="
run_cr '' --bogus
assert_eq 2 "$RC" 'unknown flag -> exit 2 (usage error)'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; }
exit 0
