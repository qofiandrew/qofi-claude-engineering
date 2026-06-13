#!/usr/bin/env bash
# test-quality-summary-hooks.sh — behavior tests for the two new engineering-cto
# hooks: quality-check.sh (PostToolUse) and session-summary.sh (Stop).
#
# quality-check: per-file lint nudge — only on source files, only when a checker
# resolves, surfaces findings as additionalContext, NEVER blocks, honors QOFI_*.
# session-summary: writes an in-repo resume aid at stop, honors the
# stop_hook_active loop guard + QOFI_*, never writes to ~/.claude.
#
# Run from $SWARM_HOME:  bash tests/test-quality-summary-hooks.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QC="$ROOT/templates/engineering-cto/hooks/quality-check.sh"
SS="$ROOT/templates/engineering-cto/hooks/session-summary.sh"

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }
assert_has(){ if printf '%s' "$2" | grep -qF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/qs-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

qc_event(){ python3 -c '
import json,sys
print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]},"hook_event_name":"PostToolUse"}))' "$1" "$2"; }

echo "=== quality-check.sh (PostToolUse nudge) ==="
WORK="$TMP/qc"; mkdir -p "$WORK/.claude"
printf "sh -c 'echo lint-problem; exit 1'\n" > "$WORK/.claude/quality-cmd"
printf 'export const x = 1\n' > "$WORK/foo.ts"
printf '# readme\n' > "$WORK/README.md"

run_qc(){ # envstr file -> stdout (runs in non-git WORK, CLAUDE_PROJECT_DIR=WORK)
  local envstr="$1" file="$2"
  ( cd "$WORK" && qc_event Edit "$file" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$WORK" $envstr bash "$QC" 2>/dev/null )
}

out="$(run_qc '' "$WORK/foo.ts")"
assert_has 'additionalContext' "$out" 'ts edit + failing checker -> emits additionalContext'
assert_has 'lint-problem'      "$out" 'ts edit -> includes the checker output'
( cd "$WORK" && qc_event Edit "$WORK/foo.ts" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$WORK" bash "$QC" >/dev/null 2>&1 )
assert_eq 0 "$?" 'ts edit -> exits 0 (PostToolUse never blocks)'
out="$(run_qc '' "$WORK/README.md")"
assert_eq '' "$out" 'README.md edit -> not a source file, no output'
out="$(run_qc 'QOFI_DISABLED_HOOKS=quality-check' "$WORK/foo.ts")"
assert_eq '' "$out" 'quality-check disabled by name -> no output'
out="$(run_qc 'QOFI_HOOK_PROFILE=off' "$WORK/foo.ts")"
assert_eq '' "$out" 'profile=off -> no output'
printf 'true\n' > "$WORK/.claude/quality-cmd"
out="$(run_qc '' "$WORK/foo.ts")"
assert_eq '' "$out" 'clean checker -> no findings, no output'
rm -f "$WORK/.claude/quality-cmd"
out="$(run_qc '' "$WORK/foo.ts")"
assert_eq '' "$out" 'no checker resolved -> fail-open, no output'

# Injection-closed: a model-chosen filename with shell metacharacters must NOT
# execute injected commands — the untrusted path is bound as positional $1, never
# interpolated into the command text. (Pins the eval-injection fix.)
INJ="$TMP/inj"; mkdir -p "$INJ/.claude"
run_inj(){ # quality-cmd file -> (runs the hook; caller checks for the injected sentinel)
  printf '%s\n' "$1" > "$INJ/.claude/quality-cmd"
  ( cd "$INJ" && qc_event Edit "$2" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$INJ" bash "$QC" >/dev/null 2>&1 )
}
# (a) append branch (no {file} token): a quote+semicolon payload in the name
MAL_A='a.js" ; touch INJECTED_A ; "b.js'
touch -- "$INJ/$MAL_A"; rm -f "$INJ/INJECTED_A"
run_inj 'true' "$INJ/$MAL_A"
if [ -f "$INJ/INJECTED_A" ]; then fail 'EVAL INJECTION (append): malicious file_path ran an injected command'; else pass 'append branch: metachar file_path does NOT inject (bound as $1)'; fi
# (b) {file} token branch: a backtick command-substitution payload in the name
MAL_B='c.js`touch INJECTED_B`.js'
touch -- "$INJ/$MAL_B"; rm -f "$INJ/INJECTED_B"
run_inj 'true {file}' "$INJ/$MAL_B"
if [ -f "$INJ/INJECTED_B" ]; then fail 'EVAL INJECTION ({file}): backtick file_path ran an injected command'; else pass '{file} branch: backtick file_path does NOT inject (bound reference)'; fi

echo ""
echo "=== session-summary.sh (Stop resume aid) ==="
REPO="$TMP/repo"; mkdir -p "$REPO/.claude"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
   && printf 'a\n' > a.txt && git add a.txt && git commit -qm init && printf 'b\n' > b.txt )
mkdir -p "$TMP/fakehome"

ss_event(){ printf '{"hook_event_name":"Stop","stop_hook_active":%s}' "${1:-false}"; }
run_ss(){ # envstr stopactive -> exitcode (runs in REPO, HOME=fakehome)
  local envstr="$1" active="$2"
  ( cd "$REPO" && ss_event "$active" | env -i PATH="$PATH" HOME="$TMP/fakehome" CLAUDE_PROJECT_DIR="$REPO" $envstr bash "$SS" >/dev/null 2>&1 ); echo $?
}

rm -f "$REPO/.claude/session-summary.md"
assert_eq 0 "$(run_ss '' false)" 'normal stop -> exits 0'
if [ -f "$REPO/.claude/session-summary.md" ]; then pass 'normal stop -> wrote .claude/session-summary.md'; else fail 'normal stop -> summary file missing'; fi
body="$(cat "$REPO/.claude/session-summary.md" 2>/dev/null || true)"
assert_has 'resume aid, NOT evidence' "$body" 'summary -> carries resume-aid/not-evidence framing'
assert_has 'b.txt' "$body" 'summary -> lists work-in-flight (uncommitted b.txt)'
if [ -f "$TMP/fakehome/.claude/session-summary.md" ]; then fail 'must NOT write to ~/.claude'; else pass 'never writes to ~/.claude (in-repo only)'; fi

rm -f "$REPO/.claude/session-summary.md"
assert_eq 0 "$(run_ss '' true)" 'stop_hook_active=true -> exits 0'
if [ -f "$REPO/.claude/session-summary.md" ]; then fail 'stop_hook_active=true -> must NOT write'; else pass 'stop_hook_active=true -> loop guard, no write'; fi

rm -f "$REPO/.claude/session-summary.md"
run_ss 'QOFI_DISABLED_HOOKS=session-summary' false >/dev/null
if [ -f "$REPO/.claude/session-summary.md" ]; then fail 'disabled -> must NOT write'; else pass 'session-summary disabled -> no write'; fi

NONGIT="$TMP/nongit"; mkdir -p "$NONGIT/.claude"
rc=$( ( cd "$NONGIT" && ss_event false | env -i PATH="$PATH" HOME="$TMP/fakehome" CLAUDE_PROJECT_DIR="$NONGIT" bash "$SS" >/dev/null 2>&1 ); echo $? )
assert_eq 0 "$rc" 'non-git dir -> fail-open exit 0'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
