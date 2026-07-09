#!/usr/bin/env bash
# test-session-doctrine-hook.sh — regression tests for the SessionStart
# doctrine-read hook (templates/_base/hooks/session-doctrine.sh).
#
# What this pins: every swarm session — up/restart/update relaunch, manual
# claude, resume, post-compact — gets the doctrine-read directive injected as
# additionalContext, with the per-archetype file list mirroring
# swarm_launch_brief:
#   engineering-cto (and unknown markers): TEAM_LEAD.md, ESCALATION.md, PROJECT_SPEC.md
#   cpo: CONVERSATION.md, EVALUATION.md, SURFACING.md, MEMORY.md, READINESS_BAR.md, ESCALATION.md
# The hook must be fail-open (exit 0 on any input) and must emit valid hook
# JSON (hookSpecificOutput.hookEventName == SessionStart).
#
# Also pins the stamping wiring: both archetype manifests carry the hook and
# both settings.example.json templates register it under hooks.SessionStart.
#
# Pure bash + python3. Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/templates/_base/hooks/session-doctrine.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found: $HOOK" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-doctrine.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# run_hook <project-dir> <event-json> — stdout captured to $OUT, exit to $RC.
run_hook() {
  OUT="$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null)"
  RC=$?
}

# ctx <json> — extract additionalContext via python (empty on parse failure).
ctx() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["hookSpecificOutput"]
    assert d["hookEventName"] == "SessionStart"
    print(d["additionalContext"])
except Exception:
    print("")
'
}

echo "=== engineering-cto (marker present) ==="
mkdir -p "$WORK/eng/.claude"
printf 'engineering-cto\n' > "$WORK/eng/.claude/swarm-type"
run_hook "$WORK/eng" '{"source":"startup"}'
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
CTX="$(ctx "$OUT")"
case "$CTX" in *TEAM_LEAD.md*ESCALATION.md*PROJECT_SPEC.md*) ok "engineering file list" ;; *) bad "engineering file list: $CTX" ;; esac
case "$CTX" in *"source: startup"*) ok "source echoed" ;; *) bad "source echoed" ;; esac
case "$CTX" in *"Do NOT delegate"*) ok "inline-read (no-delegation) directive present" ;; *) bad "no-delegation directive" ;; esac

echo ""
echo "=== missing marker falls back to engineering (same as swarm_launch_brief) ==="
mkdir -p "$WORK/bare"
run_hook "$WORK/bare" '{"source":"resume"}'
CTX="$(ctx "$OUT")"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
case "$CTX" in *TEAM_LEAD.md*) ok "fallback file list" ;; *) bad "fallback file list: $CTX" ;; esac

echo ""
echo "=== cpo marker ==="
mkdir -p "$WORK/cpo/.claude"
printf 'cpo\n' > "$WORK/cpo/.claude/swarm-type"
run_hook "$WORK/cpo" '{"source":"compact"}'
CTX="$(ctx "$OUT")"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
case "$CTX" in *CONVERSATION.md*EVALUATION.md*SURFACING.md*MEMORY.md*READINESS_BAR.md*ESCALATION.md*) ok "cpo file list" ;; *) bad "cpo file list: $CTX" ;; esac
case "$CTX" in *TEAM_LEAD.md*) bad "cpo must not name TEAM_LEAD in its file list" ;; *) ok "no TEAM_LEAD in cpo list" ;; esac

echo ""
echo "=== fail-open on garbage / empty input ==="
run_hook "$WORK/eng" 'not json at all'
[ "$RC" -eq 0 ] && ok "garbage input exits 0" || bad "garbage input exits 0 (got $RC)"
CTX="$(ctx "$OUT")"
[ -n "$CTX" ] && ok "still emits directive on garbage input" || bad "still emits directive on garbage input"
run_hook "$WORK/eng" ''
[ "$RC" -eq 0 ] && ok "empty input exits 0" || bad "empty input exits 0 (got $RC)"

echo ""
echo "=== stamping wiring: manifests + settings templates ==="
for m in engineering-cto cpo; do
  if grep -q 'session-doctrine\.sh' "$REPO_ROOT/templates/$m/manifest.tsv"; then
    ok "$m manifest carries session-doctrine.sh"
  else
    bad "$m manifest carries session-doctrine.sh"
  fi
  if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d["hooks"]["SessionStart"]
cmds = [h["command"] for g in hooks for h in g["hooks"]]
assert any("session-doctrine.sh" in c for c in cmds)
' "$REPO_ROOT/templates/$m/settings.example.json" 2>/dev/null; then
    ok "$m settings wires SessionStart -> session-doctrine.sh"
  else
    bad "$m settings wires SessionStart -> session-doctrine.sh"
  fi
done

echo ""
echo "session-doctrine: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
