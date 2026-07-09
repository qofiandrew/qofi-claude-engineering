#!/usr/bin/env bash
# test-claude-review.sh — proves the Claude (Fable) contrarian lane's HARD
# money-path floor: subscription auth only, NEVER metered API billing,
# advisory-down (never a gate) on any failure. Mirror of test-codex-review.sh
# for the CODEX-engine swarms' reviewer. Uses a STUB claude on PATH so it never
# spends real money.
#
# Run from $SWARM_HOME:  bash tests/test-claude-review.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CR="$ROOT/bin/claude-review.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qiF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stub claude: logs argv, drains stdin, prints a canned review. Never spends.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "ARGV: $*" >> "$CLAUDE_ARGV_LOG"
cat >/dev/null
echo "STUB-REVIEW: looks risky in one place; otherwise fine."
EOF
chmod +x "$TMP/bin/claude"
export CLAUDE_ARGV_LOG="$TMP/argv.log"

# A repo with a real diff so the lane reaches the invocation step.
REPO="$TMP/repo"
git init -q -b dev "$REPO"
( cd "$REPO" \
  && printf 'a\n' > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -q -m one \
  && printf 'b\n' > f.txt \
  && git -c user.email=t@t -c user.name=t commit -q -am two )

run() {  # env-prefix... — runs claude-review in $REPO with stub PATH
  ( cd "$REPO" && PATH="$TMP/bin:$PATH" "$@" bash "$CR" --range HEAD~1..HEAD 2>&1 )
}

echo "=== metered credentials refuse loudly (advisory-down, no spend) ==="
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=sk-meter bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "ANTHROPIC_API_KEY set -> exit 3"
assert_has "ADVISORY-DOWN" "$out" "advisory-down notice printed"
assert_has "subscription-only" "$out" "names the floor"
[ -f "$CLAUDE_ARGV_LOG" ] && fail "claude was invoked despite metered key" || pass "claude never invoked (no spend)"

out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" ANTHROPIC_AUTH_TOKEN=tok bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "ANTHROPIC_AUTH_TOKEN set -> exit 3"

echo ""
echo "=== missing claude CLI -> advisory-down ==="
out="$( ( cd "$REPO" && CLAUDE_BIN=claude-definitely-not-installed bash "$CR" 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "absent CLI -> exit 3"
assert_has "not found" "$out" "says CLI not found"

echo ""
echo "=== --check: guard passes, plan printed, no invocation ==="
rm -f "$CLAUDE_ARGV_LOG"
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --range HEAD~1..HEAD --check 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "--check exit 0"
assert_has "claude-fable-5" "$out" "plan pins the Fable model"
[ -f "$CLAUDE_ARGV_LOG" ] && fail "--check must not invoke claude" || pass "--check never invokes claude"

echo ""
echo "=== real run through the stub ==="
out="$(run)"; rc=$?
assert_eq 0 "$rc" "review run exit 0"
assert_has "STUB-REVIEW" "$out" "review output surfaced"
assert_has "NEVER a gate" "$out" "advisory framing printed"
argv="$(cat "$CLAUDE_ARGV_LOG")"
assert_has "-p" "$argv" "headless print mode"
assert_has "--model claude-fable-5" "$argv" "Fable model passed"

echo ""
echo "=== model override honored ==="
rm -f "$CLAUDE_ARGV_LOG"
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" CLAUDE_REVIEW_MODEL=claude-opus-4-8 bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"
assert_has "--model claude-opus-4-8" "$(cat "$CLAUDE_ARGV_LOG")" "CLAUDE_REVIEW_MODEL override"

echo ""
echo "=== empty diff is a clean no-op ==="
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --range HEAD..HEAD 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "empty diff -> exit 0"
assert_has "nothing to review" "$out" "says nothing to review"

echo ""
echo "claude-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
