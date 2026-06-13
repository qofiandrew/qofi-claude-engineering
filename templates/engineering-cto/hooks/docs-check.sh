#!/usr/bin/env bash
# docs-check.sh — TeammateIdle hook.
# Stops a teammate from going idle if it changed source code without updating any
# docs or the build log. This enforces docs-as-you-go as a floor (the real
# instruction lives in CLAUDE.md / the lead brief).
#
# Wired in settings.json under hooks.TeammateIdle. Invoked as:
#   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/docs-check.sh"
#
# Contract: hook JSON on stdin. Exit 0 = allow idle. Exit 2 = BLOCK idle; stderr is
# fed back to the teammate. Idempotent: as soon as the teammate touches any *.md or
# docs path, the check passes — so it cannot loop forever.

set -uo pipefail
cat >/dev/null   # drain stdin payload

# --- QOFI quality-hook runtime control (see test-gate.sh for the rationale) -
__qofi_hook="docs-check"
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
if __qofi_disabled; then
  echo "${__qofi_hook}: SKIPPED — disabled (QOFI_HOOK_PROFILE=${QOFI_HOOK_PROFILE:-default}, QOFI_DISABLED_HOOKS='${QOFI_DISABLED_HOOKS:-}')" >&2
  exit 0
fi
# --- end QOFI quality-hook runtime control ---------------------------------

# Same worktree-topology fix as test-gate.sh — the teammate's actual
# changes (which this hook inspects via `git status`) live in the worktree,
# not the lead's main tree. Trusting $CLAUDE_PROJECT_DIR ran `git status`
# in the lead's clean tree from every teammate invocation, false-ALLOWING
# idle even when the teammate had modified source without touching docs.
# See tests/test-hooks-worktree-resolution.sh.
#
# Preserves docs-check's existing fail-OPEN posture: any environment
# oddity (no git, can't cd) silently exits 0 — this is a nudge, not a
# hard gate. Both branches keep that behavior.
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  cd "$ROOT" || exit 0
else
  ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
  cd "$ROOT" 2>/dev/null || exit 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
fi

# Uncommitted changes (staged + unstaged), as porcelain paths.
CHANGED="$(git status --porcelain 2>/dev/null | sed 's/^...//')"
[ -z "$CHANGED" ] && exit 0   # nothing changed → fine to idle

SRC_CHANGED=0
DOC_CHANGED=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.md|docs/*|*/docs/*|*.mdx|ADR-*|PROJECT_SPEC*) DOC_CHANGED=1 ;;
    *)                                              SRC_CHANGED=1 ;;
  esac
done <<< "$CHANGED"

if [ "$SRC_CHANGED" -eq 1 ] && [ "$DOC_CHANGED" -eq 0 ]; then
  {
    echo "docs-check: BLOCKED — you changed source but updated no docs."
    echo "Before going idle:"
    echo "  1. Update the docs your change affects (README / API docs / inline)."
    echo "  2. Add a build-log entry to PROJECT_SPEC.md (section 10)."
    echo "  3. If you made a one-way-door decision, record it as an ADR."
    echo "Then you may idle. (This clears as soon as any .md/docs file is touched.)"
  } >&2
  exit 2
fi

exit 0
