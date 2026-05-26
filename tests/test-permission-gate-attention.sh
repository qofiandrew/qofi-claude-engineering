#!/usr/bin/env bash
# test-permission-gate-attention.sh — regression tests for the swarm-attention
# allow/deny rules added to templates/engineering-cto/hooks/permission-gate.sh.
#
# Why this exists: the helper is the CTO's ONE scoped capability for writing
# into the watcher's state dir. If the regex drifts from the canonical
# invocation form pinned in templates/ESCALATION.md, the CTO will hit
# permission-denied at a real blocked-escalation moment — the worst possible
# time to discover a mismatch. Run this whenever the gate or the doctrine
# changes.
#
# Run from $SWARM_HOME:
#     bash tests/test-permission-gate-attention.sh
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure (details on
# stderr). bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../templates"

# The engineering-cto permission-gate hook is now COMPOSED from three
# fragments (per templates/engineering-cto/manifest.tsv) — the same compose
# path swarm-init/sync drive. We exercise the composed result, not any
# fragment in isolation, so this test stays faithful to what a real stamped
# repo actually executes.
GATE="$(mktemp -t permission-gate-attention-test.XXXXXX)" || { echo "mktemp failed"; exit 1; }
cleanup_gate() { rm -f "$GATE"; }
trap cleanup_gate EXIT INT TERM

for fragment in \
  _base/hooks/permission-gate-prelude.sh \
  engineering-cto/hooks/permission-gate-policy.sh \
  _base/hooks/permission-gate-tail.sh
do
  if [ ! -r "$TEMPLATES/$fragment" ]; then
    echo "test: cannot read $TEMPLATES/$fragment" >&2
    exit 1
  fi
  cat "$TEMPLATES/$fragment" >> "$GATE"
done

PASS=0
FAIL=0
FAILURES=""

# decide TOOL CMD [CWD]
#   Build the permission-gate event JSON, pipe it in, capture stdout, and
#   classify the decision: allow | deny | defer.
decide() {
  local tool="$1" cmd="$2" cwd="${3:-/tmp/some-repo}"
  local event
  event="$(python3 -c '
import json, sys
e = {"tool_name": sys.argv[1],
     "tool_input": {"command": sys.argv[2]} if sys.argv[1] == "Bash" else {"file_path": sys.argv[2]},
     "cwd": sys.argv[3]}
print(json.dumps(e))
' "$tool" "$cmd" "$cwd")"
  local out
  out="$(printf '%s' "$event" | bash "$GATE" 2>/dev/null)"
  if [ -z "$out" ]; then
    echo "defer"; return
  fi
  if printf '%s' "$out" | grep -q '"behavior":"allow"'; then
    echo "allow"; return
  fi
  if printf '%s' "$out" | grep -q '"behavior":"deny"'; then
    echo "deny"; return
  fi
  echo "unknown:$out"
}

# assert EXPECTED GOT LABEL
assert() {
  local expected="$1" got="$2" label="$3"
  if [ "$expected" = "$got" ]; then
    printf '  PASS  [%s] %s\n' "$expected" "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  expected=%s got=%s  %s\n' "$expected" "$got" "$label" >&2
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}
  - $label  (expected=$expected, got=$got)"
  fi
}

echo "=== CANONICAL doctrine form (must ALLOW) ==="
# The exact form pinned in templates/ESCALATION.md §Attention flag.
assert allow "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh" raise "needs operator decision on rotation"')" \
  'canonical: whole-quoted $SWARM_HOME, raise with reason'
assert allow "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh" clear')" \
  'canonical: whole-quoted $SWARM_HOME, clear'
assert allow "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh" status')" \
  'canonical: whole-quoted $SWARM_HOME, status'

echo ""
echo "=== TOLERATED variant forms (must ALLOW — defense in depth) ==="
# These are not the canonical doctrine form, but the regex tolerates them
# so a CTO that quotes slightly differently doesn't fail at a blocked moment.
assert allow "$(decide Bash '"$SWARM_HOME"/bin/swarm-attention.sh raise "x"')" \
  'env-quoted, path bare'
assert allow "$(decide Bash '$SWARM_HOME/bin/swarm-attention.sh raise "x"')" \
  'fully unquoted (works when $SWARM_HOME has no spaces)'
assert allow "$(decide Bash '/Users/aschettino/qofirepos/qofi-claude-engineering/bin/swarm-attention.sh raise "x"')" \
  'absolute path (no $SWARM_HOME at all)'

echo ""
echo "=== NEAR-MISS attempts (must NOT auto-ALLOW) ==="
# Direct redirects into the state dir — the hole the new hard-floor deny closes.
# Before this commit, the existing `echo` allowlist would have auto-ALLOWED
# these, bypassing every guarantee the helper provides (channel resolution,
# length-cap, atomic write). Each should now hit the new deny.
assert deny "$(decide Bash 'echo "fake reason" > ~/.config/swarm/attention-1234.flag')" \
  'echo > ~/.config/swarm/attention-N.flag (the canonical near-miss)'
assert deny "$(decide Bash 'echo "x" > $HOME/.config/swarm/attention-1234.flag')" \
  'echo > $HOME/.config/swarm/...'
assert deny "$(decide Bash 'echo "x" > /Users/aschettino/.config/swarm/attention-1234.flag')" \
  'echo > /Users/<you>/.config/swarm/... (absolute)'
assert deny "$(decide Bash 'cat /etc/hostname > ~/.config/swarm/attention-1.flag')" \
  'cat > ~/.config/swarm/... (any cmd, just the redirect)'
assert deny "$(decide Bash 'printf "x" >> ~/.config/swarm/attention-1.flag')" \
  'printf >> ~/.config/swarm/... (append)'

# Bad subcommands on the right script path — must NOT auto-allow (defer to
# human). Not asserting deny because permission-gate's natural mode for
# "unknown" is defer, not deny — fall-through to a human is the safe default.
assert defer "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh" delete')" \
  'helper invoked with unsupported subcommand: delete'
assert defer "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh"')" \
  'helper invoked with no subcommand'
assert defer "$(decide Bash '"$SWARM_HOME/bin/swarm-attention.sh" RAISE "x"')" \
  'helper invoked with wrong-case subcommand (RAISE)'

# Near-miss script paths (similar name, not the helper). Must NOT auto-allow.
assert defer "$(decide Bash '"$SWARM_HOME/bin/swarm-attention-evil.sh" raise "x"')" \
  'similar-name impostor: swarm-attention-evil.sh'
assert defer "$(decide Bash '"$SWARM_HOME/bin/swarm-attention" raise "x"')" \
  'missing .sh suffix (path resolution would 127 anyway, but gate shouldn\''t pre-approve)'

# Chained commands. The new helper allowlist is `^`-anchored, so a chain
# hiding the helper after `&&` does NOT match the new rule. The pre-existing
# `echo` allowlist (templates/engineering-cto/hooks/permission-gate.sh:98) does still allow
# any command-chain whose leading word is `echo`, but that's a pre-existing
# scope, not a regression from this commit. The protection that matters is
# that a chain hiding a REDIRECT into ~/.config/swarm/ is caught by the new
# hard-floor deny (the deny scans the whole command, unanchored) — verified
# in the next assertion.
assert allow "$(decide Bash 'echo hi && "$SWARM_HOME/bin/swarm-attention.sh" raise "x"')" \
  'chained-after-echo: pre-existing echo allowlist accepts the chain (not a new regression)'
assert defer "$(decide Bash 'false && "$SWARM_HOME/bin/swarm-attention.sh" raise "x"')" \
  'chained-after-non-allowed: helper anchor correctly fails to match'
assert deny "$(decide Bash 'echo ok && echo "x" > ~/.config/swarm/attention-1.flag')" \
  'chain hiding redirect-to-swarm-dir: hard-floor wins regardless of prefix'

# Bash-prefixed invocation — also not the canonical form; defers.
assert defer "$(decide Bash 'bash "$SWARM_HOME/bin/swarm-attention.sh" raise "x"')" \
  'bash-prefixed invocation: must use direct execution (canonical doctrine)'

# Other reads/writes elsewhere — should NOT be touched by the new rules
# (validates the new lines didn't regress unrelated paths). echo > /tmp
# is still allowed by the pre-existing echo allowlist; that's correct
# scope — only ~/.config/swarm/ is the protected zone.
assert allow "$(decide Bash 'echo "ok" > /tmp/whatever.txt')" \
  'control: echo > /tmp/... is unaffected (still allowed by pre-existing rule)'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
