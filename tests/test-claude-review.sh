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
PROD_CR="$ROOT/bin/claude-review.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qiF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }
assert_absent(){ if [ -e "$1" ]; then fail "$2"; else pass "$2"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stub claude: positively reports subscription auth, logs review argv/cwd,
# drains stdin, and prints a canned review. Never spends.
mkdir -p "$TMP/bin"
CLAUDE_ARGV_LOG="$TMP/argv.log"
CLAUDE_CWD_LOG="$TMP/cwd.log"
CLAUDE_ENV_LOG="$TMP/env.log"
CLAUDE_AUTH_ENV_LOG="$TMP/auth-env.log"
CLAUDE_INPUT_LOG="$TMP/input.log"
CONTROL="$TMP/control"
mkdir -p "$CONTROL"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "status" ]; then
  printf 'config=%s project=%s oauth=%s\n' "\${CLAUDE_CONFIG_DIR:-}" "\${CLAUDE_PROJECT_DIR:-}" "\${CLAUDE_CODE_OAUTH_TOKEN:-}" >> "$CLAUDE_AUTH_ENV_LOG"
  if [ -f "$CONTROL/auth-json" ]; then
    /bin/cat "$CONTROL/auth-json"
  else
    printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
  fi
  [ -f "$CONTROL/auth-rc" ] && exit "\$(/bin/cat "$CONTROL/auth-rc")"
  exit 0
fi
printf '<%s>\n' "\$@" >> "$CLAUDE_ARGV_LOG"
printf '%s\n' "\$PWD" >> "$CLAUDE_CWD_LOG"
printf 'provider=%s aws=%s project=%s\n' "\${CLAUDE_CODE_USE_BEDROCK:-}" "\${AWS_ACCESS_KEY_ID:-}" "\${CLAUDE_PROJECT_DIR:-}" >> "$CLAUDE_ENV_LOG"
/bin/cat > "$CLAUDE_INPUT_LOG"
echo "STUB-REVIEW: looks risky in one place; otherwise fine."
EOF
chmod +x "$TMP/bin/claude"

# Test a mechanical copy with resolver/home outputs replaced. Production has no
# fake-binary environment or argument seam.
HARNESS="$TMP/harness"
mkdir -p "$HARNESS" "$TMP/home/.claude"
chmod 700 "$TMP/home/.claude"
TEST_HOME="$(cd "$TMP/home" && pwd -P)"
sed -e "s|^CLAUDE_PLAN=.*|CLAUDE_PLAN='$TMP/bin/claude'|" \
    -e "s|^REAL_HOME=.*|REAL_HOME='$TEST_HOME'|" \
    "$PROD_CR" > "$HARNESS/claude-review.sh"
cp "$ROOT/bin/review-runner.py" "$ROOT/bin/trusted-cli.py" "$HARNESS/"
chmod +x "$HARNESS/claude-review.sh"
CR="$HARNESS/claude-review.sh"

# A repo with a real diff so the lane reaches the invocation step.
REPO="$TMP/repo"
git init -q -b dev "$REPO"
( cd "$REPO" \
  && printf 'a\n' > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -q -m one \
  && printf 'b\n' > f.txt \
  && git -c user.email=t@t -c user.name=t commit -q -am two )

run() {  # env-prefix... — runs claude-review in $REPO with stub PATH
  ( cd "$REPO" && "$@" bash "$CR" --range HEAD~1..HEAD 2>&1 )
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
assert_has "overrides are not accepted" "$out" "untrusted CLI override is explicit"

echo ""
echo "=== provider overrides and non-subscription auth fail closed ==="
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" CLAUDE_CODE_USE_BEDROCK=1 bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "Bedrock selector -> exit 3"
assert_has "Claude.ai subscription route" "$out" "provider override names allowed route"

bad_auth='{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","subscriptionType":"max"}'
printf '%s\n' "$bad_auth" > "$CONTROL/auth-json"
out="$( ( cd "$REPO" && bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"; rc=$?
rm -f "$CONTROL/auth-json"
assert_eq 3 "$rc" "non-Claude.ai auth -> exit 3"
assert_has "not a recognized Claude.ai subscription" "$out" "auth mismatch is explicit"

echo ""
echo "=== --check: guard passes, plan printed, no invocation ==="
rm -f "$CLAUDE_ARGV_LOG"
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" CLAUDE_CONFIG_DIR="$REPO/.claude" CLAUDE_PROJECT_DIR="$REPO" bash "$CR" --range HEAD~1..HEAD --check 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "--check exit 0"
assert_has "claude-fable-5" "$out" "plan pins the Fable model"
[ -f "$CLAUDE_ARGV_LOG" ] && fail "--check must not invoke claude" || pass "--check never invokes claude"
assert_has "config= project=" "$(tail -n 1 "$CLAUDE_AUTH_ENV_LOG")" "auth probe uses the same isolated config environment"
out="$( ( cd "$REPO" && CLAUDE_CODE_OAUTH_TOKEN=subscription-oauth bash "$CR" --range HEAD~1..HEAD --check 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "subscription OAuth token route remains supported"
assert_has "oauth=subscription-oauth" "$(tail -n 1 "$CLAUDE_AUTH_ENV_LOG")" "only the subscription token crosses the clean environment"

echo ""
echo "=== every Python helper ignores reviewed-cwd/PYTHONPATH preload code ==="
PRELOAD_MARKER="$TMP/python-preload-ran"
/usr/bin/python3 -I -B - "$REPO/json.py" "$REPO/sitecustomize.py" "$PRELOAD_MARKER" <<'PY'
from pathlib import Path
import sys

json_path, site_path, marker = sys.argv[1:]
Path(json_path).write_text(
    f"open({marker!r}, 'w').write('json preload ran')\n"
    "raise RuntimeError('reviewed repo json.py loaded')\n",
    encoding="utf-8",
)
Path(site_path).write_text(
    f"open({marker!r}, 'w').write('sitecustomize ran')\n",
    encoding="utf-8",
)
PY
rm -f "$PRELOAD_MARKER"
out="$( ( cd "$REPO" && PYTHONPATH="$REPO" bash "$CR" --range HEAD~1..HEAD --check 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "hostile Python preload surface is ignored"
assert_absent "$PRELOAD_MARKER" "no reviewed-cwd/PYTHONPATH module executes"
rm -f "$REPO/json.py" "$REPO/sitecustomize.py"

echo ""
echo "=== real run through the stub ==="
out="$(run)"; rc=$?
assert_eq 0 "$rc" "review run exit 0"
assert_has "STUB-REVIEW" "$out" "review output surfaced"
assert_has "NEVER a gate" "$out" "advisory framing printed"
argv="$(cat "$CLAUDE_ARGV_LOG")"
assert_has "<-p>" "$argv" "headless print mode"
assert_has "<--model>" "$argv" "model option passed"
assert_has "<claude-fable-5>" "$argv" "Fable model passed"
for flag in --safe-mode --tools --strict-mcp-config --mcp-config --disable-slash-commands --no-chrome --no-session-persistence; do
  assert_has "<$flag>" "$argv" "isolated invocation pins $flag"
done
review_cwd="$(tail -n 1 "$CLAUDE_CWD_LOG")"
case "$review_cwd" in
  "$TEST_HOME/.claude/qofi-review-tmp/"*) pass "review runs in private empty cwd" ;;
  *) fail "review runs in private empty cwd (got: $review_cwd)" ;;
esac
[ "$review_cwd" != "$REPO" ] && pass "review never starts in reviewed repo" || fail "review never starts in reviewed repo"
assert_has "provider= aws= project=" "$(tail -n 1 "$CLAUDE_ENV_LOG")" "provider/project routing env is stripped"

echo ""
echo "=== model override honored ==="
rm -f "$CLAUDE_ARGV_LOG"
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" CLAUDE_REVIEW_MODEL=claude-opus-4-8 bash "$CR" --range HEAD~1..HEAD 2>&1 ) )"
assert_has "<claude-opus-4-8>" "$(cat "$CLAUDE_ARGV_LOG")" "CLAUDE_REVIEW_MODEL override"

echo ""
echo "=== empty diff is a clean no-op ==="
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --range HEAD..HEAD 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "empty diff -> exit 0"
assert_has "nothing to review" "$out" "says nothing to review"

echo ""
echo "=== invalid git range is advisory-down, not an empty success ==="
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --range no-such-ref..HEAD 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "invalid git range -> exit 3"
assert_has "did not resolve to exact commits" "$out" "invalid range failure is explicit"

echo ""
echo "=== diff capture is hash-to-hash and never executes clean filters ==="
FILTER_MARKER="$TMP/git-filter-ran"
FILTER="$TMP/evil-clean-filter.sh"
cat > "$FILTER" <<EOF
#!/usr/bin/env bash
printf ran > "$FILTER_MARKER"
/bin/cat
EOF
chmod +x "$FILTER"
git -C "$REPO" config filter.evil.clean "$FILTER"
printf '*.txt filter=evil\n' > "$REPO/.gitattributes"
git -C "$REPO" add .gitattributes
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m attributes
printf 'filter fixture\n' > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m filter-fixture
rm -f "$FILTER_MARKER" "$CLAUDE_ARGV_LOG"
out="$(run)"; rc=$?
assert_eq 0 "$rc" "tree-to-tree review succeeds with hostile clean filter configured"
assert_absent "$FILTER_MARKER" "review diff never executes repo clean filter"
out="$( ( cd "$REPO" && bash "$CR" --range HEAD 2>&1 ) )"; rc=$?
assert_eq 2 "$rc" "single-revision/worktree diff shape is rejected"
assert_has "A..B or A...B" "$out" "range grammar explains the safe shape"
assert_absent "$FILTER_MARKER" "rejected worktree range never executes repo clean filter"
git -C "$REPO" config --unset filter.evil.clean

echo ""
echo "=== oversized diff is refused before reviewer invocation ==="
python3 - "$REPO/f.txt" <<'PY'
import sys
open(sys.argv[1], 'w').write(('x' * 100 + '\n') * 51_000)
PY
git -C "$REPO" add f.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m oversized
rm -f "$CLAUDE_ARGV_LOG"
out="$(run)"; rc=$?
assert_eq 3 "$rc" "diff above 5MB -> advisory-down"
assert_has "limited to 5000000 bytes" "$out" "oversized diff reports the bound"
[ -f "$CLAUDE_ARGV_LOG" ] && fail "oversized diff must not invoke Claude review" || pass "oversized diff never invokes Claude review"
git -C "$REPO" reset -q --hard HEAD~1

echo ""
echo "=== Codex-authored CPO directives use the bounded Claude/Fable lane ==="
DRAFT="$REPO/directive.md"
printf '[cto-7] Build reconciliation per requirements v3.\n' > "$DRAFT"
rm -f "$CLAUDE_ARGV_LOG" "$CLAUDE_INPUT_LOG"
out="$( ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --directive-file "$DRAFT" 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "directive file review -> exit 0"
assert_has "STUB-REVIEW" "$out" "directive review output surfaced"
assert_has "DRAFT DIRECTIVE" "$(cat "$CLAUDE_INPUT_LOG")" "directive is labeled, not represented as a Git diff"
assert_has "Build reconciliation" "$(cat "$CLAUDE_INPUT_LOG")" "directive body reaches Claude"
assert_has "claude-fable-5" "$(cat "$CLAUDE_ARGV_LOG")" "directive lane pins Fable"

printf 'outside secret' > "$TMP/outside-directive.md"
out="$( ( cd "$REPO" && bash "$CR" --directive-file "$TMP/outside-directive.md" 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "outside directive file -> advisory-down"
assert_has "outside the allowed root" "$out" "outside directive path is refused"
ln -s "$TMP/outside-directive.md" "$REPO/directive-link.md"
out="$( ( cd "$REPO" && bash "$CR" --directive-file "$REPO/directive-link.md" 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "symlink directive is refused before review"
rm -f "$REPO/directive-link.md"

rm -f "$CLAUDE_ARGV_LOG" "$CLAUDE_INPUT_LOG"
out="$(printf 'stdin directive\n' | ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --directive 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "stdin directive review -> exit 0"
assert_has "stdin directive" "$(cat "$CLAUDE_INPUT_LOG")" "stdin directive reaches Claude"

rm -f "$CLAUDE_ARGV_LOG" "$CLAUDE_INPUT_LOG"
out="$(python3 - <<'PY' | ( cd "$REPO" && PATH="$TMP/bin:$PATH" bash "$CR" --directive 2>&1 )
import sys
sys.stdout.write('x' * 5_000_001)
PY
)"; rc=$?
assert_eq 3 "$rc" "oversized directive -> advisory-down"
assert_has "5000000 bytes" "$out" "oversized directive reports the bound"
[ -f "$CLAUDE_ARGV_LOG" ] && fail "oversized directive must not invoke Claude review" || pass "oversized directive never invokes Claude review"

echo ""
echo "claude-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
