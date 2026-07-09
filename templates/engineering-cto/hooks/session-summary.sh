#!/usr/bin/env bash
# session-summary.sh — Stop hook. On session stop, writes a short, mechanical
# resume aid to an IN-REPO file (.claude/session-summary.md), so a teammate's
# RAM-only state isn't wholly lost when the session cycles.
#
# It is a RESUME AID, NEVER EVIDENCE (CLAUDE.md §Session summary on stop): the
# next session must verify before trusting it. To stay honest AND secret-safe,
# this hook records only what it can OBSERVE mechanically — branch, HEAD, and the
# work-in-flight git state — and NEVER dumps transcript content (which could
# carry secrets/PII). Decisions + the next step live in the build log
# (PROJECT_SPEC.md §10) and the transcript — the durable substrate.
#
# Wired in settings.json under hooks.Stop. ALWAYS exits 0 — it never blocks the
# stop (a resume aid must not trap the agent in a loop; it also respects the
# stop_hook_active guard). Writes to the resolved git toplevel's .claude/, NEVER
# ~/.claude (one-user host → cross-swarm contamination). The output path is
# gitignored, so it never dirties the clean-dev exit state.

set -uo pipefail
EVENT="$(cat 2>/dev/null || true)"

# Stop-hook loop guard: if we're already in a hook-triggered continuation, do
# nothing (belt-and-suspenders — this hook exits 0 / never blocks anyway).
if printf '%s' "$EVENT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# --- QOFI quality-hook runtime control (see test-gate.sh for the rationale) -
__qofi_hook="session-summary"
__qofi_disabled() {
  case "${QOFI_HOOK_PROFILE:-default}" in
    minimal|fast|off) return 0 ;;
  esac
  local _l="${QOFI_DISABLED_HOOKS:-}"; _l="${_l//,/ }"
  local _h
  for _h in $_l; do
    { [ "$_h" = "$__qofi_hook" ] || [ "$_h" = "all" ]; } && return 0
  done
  return 1
}
__qofi_disabled && exit 0
# --- end QOFI quality-hook runtime control ---------------------------------

# Resolve the work tree from the hook payload's `cwd` (the STOPPING session's
# working directory) — NOT `git rev-parse` on the process's inherited CWD, which
# does not rebind to the stopping teammate's worktree and would write this
# session's resume aid into the WRONG tree (a sibling worktree or the lead's main
# tree). Extract cwd with python3 (repo idiom — permission-gate.sh does the same;
# no jq dep). Fail-OPEN (exit 0): any unresolvable cwd → nothing to write —
# unparseable/non-dict payload, no/null/non-string cwd, non-git cwd, or python3
# absent all collapse to exit 0 (this is a resume aid, never a gate). See
# tests/test-hooks-worktree-resolution.sh.
PAYLOAD_CWD="$(printf '%s' "$EVENT" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -n "$PAYLOAD_CWD" ] || exit 0
ROOT="$(git -C "$PAYLOAD_CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" 2>/dev/null || exit 0
[ -d .claude ] || exit 0           # not a stamped swarm repo — leave it alone

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
head="$(git log -1 --pretty='%h %s' 2>/dev/null || echo '(no commits)')"
status="$(git status --porcelain 2>/dev/null || true)"
stash="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
recent="$(git log --oneline -5 2>/dev/null || true)"
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"

OUT=".claude/session-summary.md"
{
  echo "# Session summary — resume aid, NOT evidence"
  echo ""
  echo "_Mechanical snapshot written at session stop. **Verify before trusting**"
  echo "(CLAUDE.md §Session summary on stop) — a snapshot is a starting point, not proof._"
  echo ""
  echo "- **When:** $ts"
  echo "- **Branch:** \`$branch\`"
  echo "- **HEAD:** $head"
  echo "- **Stashes:** $stash"
  echo ""
  echo "## Work in flight (uncommitted)"
  if [ -n "$status" ]; then
    echo '```'
    printf '%s\n' "$status"
    echo '```'
  else
    echo "_clean tree — nothing uncommitted._"
  fi
  echo ""
  echo "## Recent commits on this branch"
  echo '```'
  printf '%s\n' "$recent"
  echo '```'
  echo ""
  echo "_Decisions made + the next step live in the build log (PROJECT_SPEC.md §10)"
  echo "and the session transcript — this snapshot records only observable git"
  echo "state, never transcript content (no secret/PII leakage)._"
} > "$OUT" 2>/dev/null || true

exit 0
