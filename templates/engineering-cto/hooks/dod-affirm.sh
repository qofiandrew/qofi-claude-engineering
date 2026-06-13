#!/usr/bin/env bash
# dod-affirm.sh — TaskCompleted hook.
# Blocks a task from being marked complete unless the agent's summary explicitly
# affirms the Definition-of-Done checklist (CLAUDE.md §Definition of done).
#
# Wired in settings.json under hooks.TaskCompleted alongside test-gate.sh.
# Invoked as:
#   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/dod-affirm.sh"
#
# Contract: hook JSON arrives on stdin. Exit 0 = allow completion.
# Exit 2 = BLOCK; whatever we write to stderr is fed back to the agent.
#
# What this enforces (mechanical floor):
#   The agent's summary OR the HEAD commit message contains, on six separate
#   lines, the six DoD self-affirmations 1..6 in this exact form:
#     [DoD-1] Contract: yes
#     [DoD-1] Contract: n/a:<reason>          # also accepted
#     [DoD-2] Tests: yes
#     ...etc up to [DoD-6] No conflicts: yes
#
# What this does NOT enforce: truth. The agent can write "yes" while the
# answer is no — that is a §Honesty violation that the CTO must catch at
# review. This hook is the mechanical floor; honesty + review is the ceiling.
#
# Fail-safe: on any parse failure or read error, BLOCK (exit 2) and surface
# "couldn't verify affirmation, rerun". Never fail open on a done-gate.

set -uo pipefail

EVENT="$(cat 2>/dev/null || true)"

# --- QOFI quality-hook runtime control (see test-gate.sh for the rationale) -
__qofi_hook="dod-affirm"
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

# Same worktree-topology fix as test-gate.sh — the teammate's HEAD commit
# (where the [DoD-*] block should live) is on the worktree-<name> branch
# in the teammate's worktree, NOT on whatever branch the lead's main tree
# happens to have checked out. Trusting $CLAUDE_PROJECT_DIR read the lead's
# HEAD from every teammate invocation, false-BLOCKING the teammate whose
# own commit had the affirmation. See tests/test-hooks-worktree-resolution.sh.
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

# Collect candidate text to search in: every string-valued field of the stdin
# JSON event, joined with newlines. A parse failure (non-JSON stdin or empty
# stdin) emits the sentinel "__PARSE_FAILED__" so the bash side can distinguish
# "agent didn't write the affirmation" from "we couldn't read what the agent
# said" — those need different surfaced messages, even though both block.
CANDIDATES_RAW="$(printf '%s' "$EVENT" | python3 -c '
import sys, json
try:
    e = json.loads(sys.stdin.read())
    out = []
    def walk(v):
        if isinstance(v, str): out.append(v)
        elif isinstance(v, dict):
            for x in v.values(): walk(x)
        elif isinstance(v, list):
            for x in v: walk(x)
    walk(e)
    print("\n".join(out))
except Exception:
    print("__PARSE_FAILED__")
' 2>/dev/null || echo "__PARSE_FAILED__")"

PARSE_FAILED=0
CANDIDATES=""
if [ "$CANDIDATES_RAW" = "__PARSE_FAILED__" ]; then
  PARSE_FAILED=1
else
  CANDIDATES="$CANDIDATES_RAW"
fi

# Also pull the most recent commit message on HEAD (if this is a git repo and
# there is at least one commit). Tasks routinely end in a commit, so the
# affirmation lives there naturally.
HEAD_MSG=""
if cd "$ROOT" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HEAD_MSG="$(git log -1 --pretty=%B 2>/dev/null || true)"
fi

CORPUS="$(printf '%s\n%s\n' "$CANDIDATES" "$HEAD_MSG")"

# Every item must be present on its own line with either "yes" or "n/a:<reason>".
# The match is anchored to the exact tag so "almost-DoD" prose doesn't pass.
missing=""
for n in 1 2 3 4 5 6; do
  case "$n" in
    1) label="Contract" ;;
    2) label="Tests" ;;
    3) label="Docs" ;;
    4) label="Operability" ;;
    5) label="Scale" ;;
    6) label="No conflicts" ;;
  esac
  pat="^\[DoD-${n}\] ${label}: (yes|n/a:.+)$"
  if ! printf '%s\n' "$CORPUS" | grep -Eq "$pat"; then
    missing="${missing}  [DoD-${n}] ${label}\n"
  fi
done

if [ -n "$missing" ]; then
  if [ "$PARSE_FAILED" -eq 1 ]; then
    # Stdin wasn't parseable AND the HEAD commit also lacks affirmation — we
    # genuinely couldn't verify. Distinct from "agent forgot lines" so the
    # surfaced guidance points at the right fix.
    {
      echo "dod-affirm: BLOCKED — couldn't verify affirmation, rerun."
      echo ""
      echo "Could not parse the TaskCompleted event payload, and the HEAD"
      echo "commit message does not contain the Definition-of-Done affirmation"
      echo "either. Re-run the task; include the six [DoD-1]..[DoD-6] lines"
      echo "in your task summary or your commit message before marking complete."
      echo "See CLAUDE.md §Definition of done for the exact format."
    } >&2
    exit 2
  fi
  {
    echo "dod-affirm: BLOCKED — Definition-of-Done affirmation incomplete."
    echo ""
    echo "Missing or malformed lines (must appear in your task summary or the"
    echo "HEAD commit message, each on its own line, exactly as shown):"
    echo ""
    printf '%b' "$missing"
    echo ""
    echo "Each line must end with either 'yes' or 'n/a:<reason>' — for example:"
    echo "  [DoD-1] Contract: yes"
    echo "  [DoD-4] Operability: n/a:doc-only task, no module surface"
    echo ""
    echo "See CLAUDE.md §Definition of done for what each item means. Item 7"
    echo "(CTO-reviewed) is the CTO's signoff, not self-affirmed."
  } >&2
  exit 2
fi

exit 0
