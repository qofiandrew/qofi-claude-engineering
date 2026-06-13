#!/usr/bin/env bash
# test-hook-runtime-controls.sh — proves QOFI_HOOK_PROFILE / QOFI_DISABLED_HOOKS
# gate ONLY the quality hooks and NEVER weaken the permission gate.
#
# HARD CONSTRAINT (robustness handover §3b): the permission gate is the security
# FLOOR and is never env-switchable. This test pins that invariant: with every
# QOFI_* disable flag thrown at it, `git push` (and the hard-floor `rm -rf`) is
# STILL denied. Separately it proves the quality hooks (test-gate, dod-affirm)
# honor the controls — gating by default, passing through when disabled — so a
# regression that either (a) lets an env var disable the floor or (b) makes the
# controls a no-op surfaces here.
#
# Run from $SWARM_HOME:  bash tests/test-hook-runtime-controls.sh
# Exit 0 = all pass. Exit 1 = at least one failure. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$ROOT/templates"
HOOKS="$TEMPLATES/engineering-cto/hooks"

PASS=0; FAIL=0; FAILURES=""
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi
}

# Compose the permission gate exactly as swarm-init/sync do (prelude+policy+tail).
GATE="$(mktemp -t pg-runtime-immune.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-runtime.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -f "$GATE"; rm -rf "$TMP"' EXIT INT TERM
for frag in _base/hooks/permission-gate-prelude.sh \
            engineering-cto/hooks/permission-gate-policy.sh \
            _base/hooks/permission-gate-tail.sh; do
  if [ ! -r "$TEMPLATES/$frag" ]; then echo "missing fragment: $frag" >&2; exit 1; fi
  cat "$TEMPLATES/$frag" >> "$GATE"
done

# gate_decide ENVSTR CMD -> allow|deny|defer  (ENVSTR is extra env for the gate)
gate_decide() {
  local envstr="$1" cmd="$2" out event
  event="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": "/tmp/x"}))' "$cmd")"
  out="$(printf '%s' "$event" | env $envstr bash "$GATE" 2>/dev/null)"
  if   printf '%s' "$out" | grep -q '"behavior":"deny"';  then echo deny
  elif printf '%s' "$out" | grep -q '"behavior":"allow"'; then echo allow
  else echo defer; fi
}

echo "=== Permission gate is IMMUNE to QOFI_* (security floor, never switchable) ==="
assert_eq deny "$(gate_decide '' 'git push origin main')" \
  'git push denied (baseline, no env)'
assert_eq deny "$(gate_decide 'QOFI_HOOK_PROFILE=off' 'git push origin main')" \
  'git push STILL denied with QOFI_HOOK_PROFILE=off'
assert_eq deny "$(gate_decide 'QOFI_HOOK_PROFILE=minimal' 'git push origin main')" \
  'git push STILL denied with QOFI_HOOK_PROFILE=minimal'
assert_eq deny "$(gate_decide 'QOFI_DISABLED_HOOKS=all' 'git push origin main')" \
  'git push STILL denied with QOFI_DISABLED_HOOKS=all'
assert_eq deny "$(gate_decide 'QOFI_DISABLED_HOOKS=permission-gate' 'git push origin main')" \
  'git push STILL denied with QOFI_DISABLED_HOOKS=permission-gate (name has no effect)'
assert_eq deny "$(gate_decide 'QOFI_HOOK_PROFILE=off QOFI_DISABLED_HOOKS=all' 'rm -rf /')" \
  'hard-floor rm -rf / STILL denied with all QOFI disables'

echo ""
echo "=== Quality hooks HONOR the controls (gate by default, pass through when off) ==="
# Each quality hook runs in a clean, non-git temp dir with a wiped env so its
# DEFAULT outcome is a deterministic BLOCK (exit 2): test-gate finds no test
# command; dod-affirm finds no affirmation. The disable flags must flip that to
# pass-through (exit 0) — and an unrelated hook name must NOT flip it.
run_q() { # hookfile envstr -> exitcode (runs in non-git $TMP, env wiped but PATH kept)
  local hook="$1" envstr="$2"
  ( cd "$TMP" && env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$TMP" $envstr \
      bash "$hook" </dev/null >/dev/null 2>&1 ); echo $?
}

assert_eq 2 "$(run_q "$HOOKS/test-gate.sh" '')" \
  'test-gate BLOCKS by default (no test command resolved)'
assert_eq 0 "$(run_q "$HOOKS/test-gate.sh" 'QOFI_DISABLED_HOOKS=test-gate')" \
  'test-gate passes through when disabled by name'
assert_eq 0 "$(run_q "$HOOKS/test-gate.sh" 'QOFI_DISABLED_HOOKS=a,test-gate,b')" \
  'test-gate passes through when in a comma list'
assert_eq 0 "$(run_q "$HOOKS/test-gate.sh" 'QOFI_HOOK_PROFILE=off')" \
  'test-gate passes through under profile=off'
assert_eq 2 "$(run_q "$HOOKS/test-gate.sh" 'QOFI_DISABLED_HOOKS=docs-check')" \
  'test-gate STILL gates when a DIFFERENT hook is disabled'

assert_eq 2 "$(run_q "$HOOKS/dod-affirm.sh" '')" \
  'dod-affirm BLOCKS by default (no affirmation present)'
assert_eq 0 "$(run_q "$HOOKS/dod-affirm.sh" 'QOFI_DISABLED_HOOKS=dod-affirm')" \
  'dod-affirm passes through when disabled by name'
assert_eq 0 "$(run_q "$HOOKS/dod-affirm.sh" 'QOFI_HOOK_PROFILE=minimal')" \
  'dod-affirm passes through under profile=minimal'

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
