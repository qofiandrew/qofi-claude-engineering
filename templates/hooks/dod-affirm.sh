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

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# Collect candidate text to search in: every string-valued field of the stdin
# JSON event, joined with newlines. On any python failure, CANDIDATES stays
# empty and we fall through to the HEAD commit message.
CANDIDATES="$(printf '%s' "$EVENT" | python3 -c '
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
    pass
' 2>/dev/null || true)"

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
