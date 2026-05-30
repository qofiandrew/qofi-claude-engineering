#!/usr/bin/env bash
# test-permission-gate-repo-scope.sh — regression tests for the repo-scope
# confinement added to templates/_base/hooks/permission-gate-prelude.sh.
#
# Why this exists: the gate is the ONLY boundary keeping a swarm inside its own
# repo (no OS sandbox — swarms run as the user under tmux). Before this floor,
# reads (Read/Glob/Grep/LS and Bash cat/find/ls) were auto-allowed for ANY path,
# and Bash redirects (echo > /outside) could write outside the repo. This test
# pins the confinement: in-repo allowed, out-of-repo deferred to a human,
# in-repo secret files denied. Runs against the COMPOSED gate (prelude + policy
# + tail) — what a stamped repo actually executes.
#
# Run from $SWARM_HOME:  bash tests/test-permission-gate-repo-scope.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../templates"
REPO="/Users/aschettino/qofirepos/some-product"   # stand-in for a swarm's $CWD

GATE="$(mktemp -t permission-gate-scope-test.XXXXXX)" || { echo "mktemp failed"; exit 1; }
trap 'rm -f "$GATE"' EXIT INT TERM

# Test the engineering-cto composition (the prelude floor under test is shared
# by every archetype, so one composition exercises the new lines fully).
for fragment in \
  _base/hooks/permission-gate-prelude.sh \
  engineering-cto/hooks/permission-gate-policy.sh \
  _base/hooks/permission-gate-tail.sh
do
  [ -r "$TEMPLATES/$fragment" ] || { echo "cannot read $TEMPLATES/$fragment" >&2; exit 1; }
  cat "$TEMPLATES/$fragment" >> "$GATE"
done

PASS=0; FAIL=0; FAILURES=""

# decide TOOL ARG [CWD]  -> allow | deny | defer
decide() {
  local tool="$1" arg="$2" cwd="${3:-$REPO}" event out
  event="$(python3 -c '
import json, sys
tool=sys.argv[1]
ti={"command":sys.argv[2]} if tool=="Bash" else ({"file_path":sys.argv[2]} if sys.argv[2] else {})
print(json.dumps({"tool_name":tool,"tool_input":ti,"cwd":sys.argv[3]}))
' "$tool" "$arg" "$cwd")"
  out="$(printf '%s' "$event" | bash "$GATE" 2>/dev/null)"
  if   [ -z "$out" ]; then echo defer
  elif printf '%s' "$out" | grep -q '"behavior":"allow"'; then echo allow
  elif printf '%s' "$out" | grep -q '"behavior":"deny"';  then echo deny
  else echo "unknown:$out"; fi
}
assert() {
  if [ "$1" = "$2" ]; then printf '  PASS  [%s] %s\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  expected=%s got=%s  %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1))
    FAILURES="${FAILURES}
  - $3 (expected=$1 got=$2)"; fi
}

echo "=== Read/Glob/Grep/LS — in-repo allowed, out-of-repo deferred ==="
assert allow "$(decide Read "$REPO/src/app.js")"                  'Read in-repo file'
assert allow "$(decide Read "src/app.js")"                        'Read relative (under cwd)'
assert defer "$(decide Read "/Users/aschettino/qofirepos/other-repo/x.js")" 'Read another repo -> defer'
assert deny  "$(decide Read "/Users/aschettino/.ssh/known_hosts")" 'Read .ssh file -> deny (secret), even out-of-repo'
assert defer "$(decide Read "/Users/aschettino/notes.txt")"        'Read non-secret home file -> defer (out of scope)'
assert allow "$(decide Read "/etc/hostname")"                     'Read system file (read-allowlist)'
assert defer "$(decide Read "$REPO/../sibling/secrets.txt")"      'Read via .. traversal -> defer'
assert allow "$(decide LS "$REPO/src")"                           'LS in-repo dir'
assert defer "$(decide LS "/Users/aschettino/qofirepos/other-repo")" 'LS another repo -> defer'
assert allow "$(decide Grep "")"                                  'Grep with no path -> cwd -> allow'
assert defer "$(decide Glob "/var/log")"                          'Glob into /var/log -> defer (not read-allowlisted)'

echo ""
echo "=== Secret files in-repo — denied for reads too ==="
assert deny  "$(decide Read "$REPO/.env")"                        'Read in-repo .env'
assert deny  "$(decide Read "$REPO/.env.local")"                  'Read in-repo .env.local'
assert allow "$(decide Read "$REPO/.env.example")"                'Read .env.example (template, allowed)'
assert deny  "$(decide Read "$REPO/config/access.json")"          'Read access.json (pairing secrets)'
assert deny  "$(decide Read "/Users/aschettino/qofirepos/qofi-claude-engineering/tokens.env")" 'Read tokens.env -> deny'

echo ""
echo "=== Bash utilities — in-scope allowed, out-of-scope deferred ==="
assert allow "$(decide Bash 'cat src/app.js')"                    'cat relative in-repo'
assert allow "$(decide Bash "cat $REPO/src/app.js")"              'cat absolute in-repo'
assert defer "$(decide Bash 'cat ../other-repo/x')"               'cat ../other-repo -> defer'
assert defer "$(decide Bash 'cat /Users/aschettino/qofirepos/other-repo/x')" 'cat absolute other-repo -> defer'
assert allow "$(decide Bash 'cat /etc/hostname')"                 'cat system file -> allow (read scope)'
assert allow "$(decide Bash 'find . -name "*.js"')"               'find . in-repo'
assert defer "$(decide Bash 'find / -name passwd')"               'find / -> defer'

echo ""
echo "=== Bash writes/redirects — cwd + /tmp only ==="
assert allow "$(decide Bash 'echo hi > out.txt')"                 'echo > relative (cwd)'
assert allow "$(decide Bash 'echo hi > /tmp/x.txt')"              'echo > /tmp'
assert defer "$(decide Bash 'echo hi > ../sibling/x')"            'echo > ../sibling -> defer'
assert defer "$(decide Bash 'echo pwned > /Users/aschettino/.bashrc')" 'echo > home dotfile -> defer'
assert defer "$(decide Bash 'cat /etc/hostname > /Users/aschettino/x')" 'read system but write outside -> defer'
assert allow "$(decide Bash 'mkdir sub')"                         'mkdir relative (cwd)'
assert defer "$(decide Bash 'mkdir ../sub')"                      'mkdir ../ -> defer'
assert allow "$(decide Bash 'touch /tmp/marker')"                 'touch /tmp'

echo ""
echo "=== Edit/Write floor — unchanged (regression guard) ==="
assert allow "$(decide Edit "$REPO/src/app.js")"                  'Edit in-repo'
assert deny  "$(decide Edit "/Users/aschettino/other/x.js")"      'Edit outside repo -> deny (floor)'
assert deny  "$(decide Edit "$REPO/.env")"                        'Edit .env -> deny (floor)'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
