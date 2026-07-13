#!/usr/bin/env bash
# test-codex-review.sh — proves the Codex contrarian lane's HARD money-path floor:
# subscription auth only, NEVER metered API-key billing, advisory-down (never a
# gate) on any failure. Uses a STUB codex on PATH so it never spends real money.
#
# Run from $SWARM_HOME:  bash tests/test-codex-review.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROD_CR="$ROOT/bin/codex-review.sh"

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qiF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }
assert_absent(){ if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3 (unexpected [$1])"; else pass "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stub codex: logs every invocation's argv; `login status` is configurable;
# exec/review drains stdin and prints a canned contrarian review. NEVER spends.
mkdir -p "$TMP/bin"
ARGVLOG="$TMP/argv.log"
CONTROL="$TMP/control"
INPUTLOG="$TMP/input.log"
mkdir -p "$CONTROL"
cat > "$TMP/bin/codex" <<EOF
#!/usr/bin/env bash
echo "ARGV: \$*" >> "$ARGVLOG"
last=""
for arg in "\$@"; do last="\$arg"; done
if [ "\${1:-}" = "login" ] && [ "\$last" = "status" ]; then
  [ -f "$CONTROL/login-status" ] && /bin/cat "$CONTROL/login-status" || printf '%s\n' 'Logged in using ChatGPT'
  [ -f "$CONTROL/login-rc" ] && exit "\$(/bin/cat "$CONTROL/login-rc")"
  exit 0
fi
if [ "\${1:-}" = "--version" ]; then
  printf 'codex-cli %s\n' "\$([ -f "$CONTROL/version" ] && /bin/cat "$CONTROL/version" || printf 0.144.1)"
  [ -f "$CONTROL/version-rc" ] && exit "\$(/bin/cat "$CONTROL/version-rc")"
  exit 0
fi
/bin/cat > "$INPUTLOG"
printf 'CONTRARIAN-REVIEW: one risky assumption; otherwise fine.\n'
if [ -f "$CONTROL/exec-rc" ]; then exit "\$(/bin/cat "$CONTROL/exec-rc")"; fi
exit 0
EOF
chmod +x "$TMP/bin/codex"

# Production has no fake-binary or fake-home switch. The mechanical harness
# copies the canonical wrapper and supplies a fixture host-preflight executable
# implementing the same 16-field v2/review-mode contract. No /private/etc or
# sudo mutation is needed and no real Codex process can run.
HARNESS="$TMP/harness"
RUNTIME_REVIEW="$TMP/runtime/.tmp/review"
mkdir -p "$HARNESS" "$TMP/home/.codex" "$RUNTIME_REVIEW"
chmod 700 "$TMP/home/.codex"
cp "$PROD_CR" "$ROOT/bin/review-runner.py" "$HARNESS/"
cat > "$HARNESS/codex-host-preflight.py" <<PY
#!/usr/bin/python3 -I
import os,re,subprocess,sys
codex='$TMP/bin/codex'
home='$TMP/home'
review='$RUNTIME_REVIEW'
control='$CONTROL'
args=sys.argv[1:]
mode=args[0] if args and args[0].startswith('--') else ''
if mode == '--review-check' and os.path.exists('$CONTROL/dedicated-down'):
    print('codex host preflight: dedicated runtime unavailable',file=sys.stderr); raise SystemExit(2)
version_run=subprocess.run([codex,'--version'],text=True,capture_output=True)
raw=(version_run.stdout+version_run.stderr).strip()
match=re.fullmatch(r'(?:codex-cli|codex) (\d+)\.(\d+)\.(\d+)',raw)
if version_run.returncode != 0:
    print('codex host preflight: could not query the Codex CLI version',file=sys.stderr); raise SystemExit(2)
version=tuple(map(int,match.groups())) if match else ()
if not version or not ((0,144,1) <= version < (0,145,0)):
    print('codex host preflight: Codex version must be >=0.144.1 and <0.145.0',file=sys.stderr); raise SystemExit(2)
auth=subprocess.run([
    codex,'login',
    '-c','forced_login_method="chatgpt"',
    '-c','cli_auth_credentials_store="file"',
    'status',
],text=True,capture_output=True)
status=(auth.stdout+auth.stderr).strip()
if auth.returncode != 0:
    print("codex host preflight: codex is not logged in — run 'codex login' (subscription)",file=sys.stderr); raise SystemExit(2)
if re.search(r'api[ -]?key|metered',status,re.I):
    print('codex host preflight: subscription auth required',file=sys.stderr); raise SystemExit(2)
if status != 'Logged in using ChatGPT':
    print('codex host preflight: login status is not a recognized ChatGPT subscription session',file=sys.stderr); raise SystemExit(2)
if mode in ('--review-exec','--operator-review-exec','--exec'):
    marker=args.index('--')
    child=args[marker+1:]
    for i,value in enumerate(child[:-1]):
        if value in ('-C','--cd','--cwd'):
            child[i+1]=review
    os.execv(codex,[codex,*child])
dedicated_canary = ('fixture_operator_canary-1234567890'
                    if not os.path.exists(control+'/canary')
                    else open(control+'/canary', encoding='utf-8').read())
print('|'.join([
    codex, '$TMP/bin/bun', home, home+'/.codex', '.'.join(match.groups()),
    codex, '$TMP/bin:/usr/bin:/bin', '65001', '_qofi_test',
    '$TMP/runtime', '$TMP/runtime/.codex', '65002',
    '_qofi_test_shared',
    ('operator-review-direct' if mode.startswith('--operator-review-') else '/usr/local/libexec/qofi-codex-runner'),
    ('qofi-codex-operator-review/v1' if mode.startswith('--operator-review-') else 'qofi-codex-runtime/v2'),
    ('' if mode.startswith('--operator-review-') else dedicated_canary),
]))
PY
chmod +x "$HARNESS/codex-host-preflight.py"
chmod +x "$HARNESS/codex-review.sh"
CR="$HARNESS/codex-review.sh"

# Git repo with a 2-commit diff so HEAD~1..HEAD is non-empty.
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\n' > f.txt && git add f.txt && git commit -qm one \
  && printf 'a\nb\n' > f.txt && git add f.txt && git commit -qm two )
# run_cr ENVSTR ARGS... -> sets OUT (merged stdout+stderr) and RC
run_cr(){
  : > "$ARGVLOG"
  rm -f "$CONTROL"/* "$INPUTLOG"
  local envstr="$1"; shift
  local outer=""
  case "$envstr" in
    OPENAI_API_KEY=*) outer="$envstr" ;;
    CODEX_API_KEY=*) outer="$envstr" ;;
    CODEX_BIN=*) outer="$envstr" ;;
    CODEX_EXEC_ARGS=*) outer="$envstr" ;;
    STUB_CODEX_VERSION=*) printf '%s' "${envstr#*=}" > "$CONTROL/version" ;;
    STUB_VERSION_RC=*) printf '%s' "${envstr#*=}" > "$CONTROL/version-rc" ;;
    STUB_LOGIN_STATUS=*) printf '%s\n' "${envstr#*=}" > "$CONTROL/login-status" ;;
    STUB_LOGIN_RC=*) printf '%s' "${envstr#*=}" > "$CONTROL/login-rc" ;;
    STUB_EXEC_RC=*) printf '%s' "${envstr#*=}" > "$CONTROL/exec-rc" ;;
    STUB_DEDICATED_DOWN=*) printf '%s' "${envstr#*=}" > "$CONTROL/dedicated-down" ;;
    STUB_CANARY=*) printf '%s' "${envstr#*=}" > "$CONTROL/canary" ;;
    '') ;;
    *) fail "test harness received unknown scenario: $envstr" ;;
  esac
  if [ -n "$outer" ]; then
    OUT="$( cd "$REPO" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
        "$outer" bash "$CR" "$@" 2>&1 )"; RC=$?
  else
    OUT="$( cd "$REPO" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
        bash "$CR" "$@" 2>&1 )"; RC=$?
  fi
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

run_cr 'STUB_CODEX_VERSION=0.143.9' --check
assert_eq 3 "$RC" 'old Codex CLI -> advisory-down before permission-profile use'
assert_has '>=0.144.1' "$OUT" 'old Codex refusal names the verified version floor'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" 'old Codex refusal never invokes exec'

run_cr 'STUB_CODEX_VERSION=0.145.0' --check
assert_eq 3 "$RC" 'untested future Codex minor -> advisory-down'
assert_has '<0.145.0' "$OUT" 'future Codex refusal names the compatibility ceiling'

run_cr 'STUB_LOGIN_STATUS=api-key-session' --check
assert_eq 3 "$RC" 'login status reports api-key -> advisory-down'
assert_has 'subscription auth required' "$OUT" 'api-key session -> demands subscription'

run_cr 'STUB_LOGIN_RC=1' --check
assert_eq 3 "$RC" 'codex not logged in (status rc!=0) -> advisory-down'

run_cr 'STUB_LOGIN_STATUS=unknown-auth-mode' --check
assert_eq 3 "$RC" 'unknown successful auth status -> advisory-down'
assert_has 'recognized ChatGPT' "$OUT" 'unknown auth cannot bypass subscription floor'

run_cr 'STUB_LOGIN_STATUS=Not logged in using ChatGPT' --check
assert_eq 3 "$RC" 'negated ChatGPT text cannot satisfy positive auth floor'

echo ""
echo "=== happy path: subscription verified (stub, no real spend) ==="
run_cr '' --check
assert_eq 0 "$RC" '--check with subscription -> exit 0'
assert_has 'auth OK' "$OUT" '--check -> prints the auth-OK plan'
assert_has 'cli_auth_credentials_store="file"' "$(cat "$ARGVLOG")" '--check -> pins file-backed login status'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" '--check -> does NOT invoke codex exec'

run_cr 'STUB_CANARY=' --check
assert_eq 3 "$RC" 'dedicated review refuses a missing canary contract field'
assert_has 'invalid dedicated canary witness' "$OUT" 'missing dedicated witness is explicit'

run_cr 'STUB_CANARY=fixture|operator-canary-1234567890' --check
assert_eq 3 "$RC" 'dedicated review refuses a delimiter-bearing canary witness'

run_cr ''
assert_eq 0 "$RC" 'full run with subscription -> exit 0'
assert_has 'CONTRARIAN-REVIEW' "$OUT" 'full run -> emits the codex advisory output'
assert_has 'NEVER a gate' "$OUT" 'full run -> footer reminds advisory, not a gate'
assert_has 'ARGV: exec' "$(cat "$ARGVLOG")" 'full run -> invoked codex exec'
assert_has 'default_permissions="qofi-review-readonly"' "$(cat "$ARGVLOG")" 'full run -> workspace-confined read-only profile'
assert_has ':root' "$(cat "$ARGVLOG")" 'full run -> denies host filesystem reads'
assert_has '--disable hooks' "$(cat "$ARGVLOG")" 'full run -> disables project hooks'
assert_has '--disable shell_snapshot' "$(cat "$ARGVLOG")" 'full run -> disables host shell snapshots'
assert_has '--disable shell_tool' "$(cat "$ARGVLOG")" 'full run -> disables model shell commands'
assert_has '--disable unified_exec' "$(cat "$ARGVLOG")" 'full run -> disables alternate command execution'
assert_has '--ignore-rules' "$(cat "$ARGVLOG")" 'full run -> ignores project execpolicy'
assert_has 'web_search="disabled"' "$(cat "$ARGVLOG")" 'full run -> disables provider web search'
assert_has 'forced_login_method="chatgpt"' "$(cat "$ARGVLOG")" 'full run -> pins ChatGPT subscription auth at invocation'
assert_has 'cli_auth_credentials_store="file"' "$(cat "$ARGVLOG")" 'full run -> pins the hardened auth.json credential store'
assert_absent '--sandbox' "$(cat "$ARGVLOG")" 'full run -> does not mix legacy sandbox with permission profile'
assert_has '--ignore-user-config' "$(cat "$ARGVLOG")" 'full run -> ignores operator config'
assert_has '--ephemeral' "$(cat "$ARGVLOG")" 'full run -> does not retain advisory session'
assert_has "$RUNTIME_REVIEW" "$(cat "$ARGVLOG")" 'full run -> root runner replaces repo cwd with the private runtime review dir'
assert_has 'model="gpt-5.6-sol"' "$(cat "$ARGVLOG")" 'full run -> review model pinned to GPT-5.6 Sol'
assert_has 'model_reasoning_effort="ultra"' "$(cat "$ARGVLOG")" 'full run -> review effort pinned to Ultra'
assert_has 'review' "$(cat "$ARGVLOG")" 'full run -> uses Codex built-in review mode'
assert_absent 'with-api-key' "$(cat "$ARGVLOG")" 'full run -> NEVER passes --with-api-key (no metered fallback)'

run_cr 'STUB_DEDICATED_DOWN=1' --check
assert_eq 0 "$RC" 'Claude-only host -> current-user subscription review remains available'
assert_has 'current-user compatibility' "$OUT" 'fallback is explicit rather than silently weakening authority'

run_cr 'STUB_DEDICATED_DOWN=1'
assert_eq 0 "$RC" 'current-user compatibility route completes a bounded advisory review'
assert_has 'CONTRARIAN-REVIEW' "$OUT" 'current-user compatibility route returns reviewer output'
assert_has '--disable shell_tool' "$(cat "$ARGVLOG")" 'current-user compatibility route remains tool-less'

echo ""
echo "=== CODEX_EXEC_ARGS is validated (money-path floor holds even with override) ==="
run_cr 'CODEX_EXEC_ARGS=login' --check
assert_eq 3 "$RC" 'CODEX_EXEC_ARGS=login -> advisory-down (command is fixed)'
# a forbidden flag token alongside a valid subcommand — passed directly so the value can carry a space
run_cr 'CODEX_EXEC_ARGS=exec --with-api-key'
assert_eq 3 "$RC" 'CODEX_EXEC_ARGS="exec --with-api-key" -> advisory-down (forbidden token)'
assert_has 'only be the literal' "$OUT" 'unsafe override -> fixed-command reason is explicit'
assert_absent 'ARGV: exec --with-api-key' "$(cat "$ARGVLOG")" 'forbidden token -> codex exec never invoked'

echo ""
echo "=== invocation and git failures are advisory-down, never false success ==="
run_cr 'STUB_EXEC_RC=17'
assert_eq 3 "$RC" 'codex nonzero -> advisory-down'
assert_has 'invocation failed (exit 17)' "$OUT" 'codex nonzero -> preserves failure status'
assert_absent 'advisory output above' "$OUT" 'codex nonzero -> no false success footer'

run_cr '' --range does-not-exist..HEAD
assert_eq 3 "$RC" 'invalid git range -> advisory-down'
assert_has 'endpoints did not resolve' "$OUT" 'invalid git range -> reports commit-resolution failure'

echo ""
echo "=== bare --range (no value) exits cleanly, never hangs (bash-3.2 shift guard) ==="
run_cr '' --range
assert_eq 2 "$RC" 'bare --range -> exit 2 (usage error, not an infinite loop)'

echo ""
echo "=== oversized diff is refused before reviewer invocation ==="
python3 - "$REPO/f.txt" <<'PY'
import sys
open(sys.argv[1], 'w').write(('x' * 100 + '\n') * 51_000)
PY
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm oversized
run_cr ''
assert_eq 3 "$RC" 'diff above 5MB -> advisory-down'
assert_has 'limited to 5000000 bytes' "$OUT" 'oversized diff reports the bound'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" 'oversized diff never invokes codex exec'
git -C "$REPO" reset -q --hard HEAD~1

echo ""
echo "=== Claude-authored CPO directives use trusted bounded Codex review ==="
printf '[cto-7] Build reconciliation per requirements v3.\n' > "$REPO/directive.md"
run_cr '' --directive-file "$REPO/directive.md"
assert_eq 0 "$RC" 'repo-local directive review -> exit 0'
assert_has 'CONTRARIAN-REVIEW' "$OUT" 'directive review output surfaced'
assert_has 'DRAFT DIRECTIVE' "$(cat "$INPUTLOG")" 'directive is labeled distinctly from a diff'
assert_has 'Build reconciliation' "$(cat "$INPUTLOG")" 'directive body reaches Codex'

printf 'outside-secret' > "$TMP/outside.md"
run_cr '' --directive-file "$TMP/outside.md"
assert_eq 3 "$RC" 'outside directive file is advisory-down'
assert_has 'outside the allowed root' "$OUT" 'outside path refusal is explicit'
ln -s "$TMP/outside.md" "$REPO/directive-link.md"
run_cr '' --directive-file "$REPO/directive-link.md"
assert_eq 3 "$RC" 'symlink directive file is advisory-down'
mkfifo "$REPO/directive-fifo"
run_cr '' --directive-file "$REPO/directive-fifo"
assert_eq 3 "$RC" 'FIFO directive file is refused without blocking'
rm -f "$REPO/directive-fifo" "$REPO/directive-link.md"

python3 - "$REPO/directive.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 5_000_001)
PY
run_cr '' --directive-file "$REPO/directive.md"
assert_eq 3 "$RC" 'oversized directive -> advisory-down'
assert_has '5000000 bytes' "$OUT" 'oversized directive reports the bound'
assert_absent 'ARGV: exec' "$(cat "$ARGVLOG")" 'oversized directive never invokes Codex'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; }
exit 0
