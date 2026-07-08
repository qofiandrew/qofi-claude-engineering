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
# Posture (three cases, decided at the cwd-extraction point):
#   1. Payload PRESENT but unparseable as JSON → BLOCK (exit 2), the pre-fix
#      couldn't-verify posture: a done-gate must not fail-soft (pass) on a garbage
#      payload it cannot read to resolve the tree.
#   2. Payload parsed but no usable cwd (dict without cwd, a non-dict payload, a
#      null/non-string cwd), OR cwd present but not a git tree, OR python3 absent
#      (nothing to parse WITH) → fail-soft (exit 0 + stderr note): topology is
#      genuinely unresolvable, and an advisory-local gate must never false-block
#      on a tree it cannot locate (the CI referee is the real gate). Note the
#      asymmetry: permission-gate — a SECURITY floor — fail-CLOSES on python3
#      absent; this advisory gate fail-softs. Both are correct for their tier.
#   3. Tree resolves → a missing/malformed affirmation BLOCKS (exit 2) as always;
#      never fail open on a resolvable done-gate.

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

# Worktree-topology resolution — the teammate's HEAD commit (where the [DoD-*]
# block naturally lives) is on the worktree-<name> branch in the teammate's OWN
# work tree, not the lead's main tree. Resolve that tree from the hook payload's
# `cwd` field (the invoking session's working directory, per the Claude Code
# hook contract), NOT from `git rev-parse` on the process's inherited CWD: a
# hook subprocess does not inherit the teammate's worktree CWD, so the old
# `git rev-parse --show-toplevel` / $CLAUDE_PROJECT_DIR resolution read the
# WRONG tree's HEAD from every teammate invocation and false-BLOCKED the
# teammate whose own commit carried the affirmation. Extract cwd with python3
# (repo idiom — permission-gate.sh does the same; no jq dependency). See
# tests/test-hooks-worktree-resolution.sh for the regression proof.
# Extract cwd AND classify the payload in one python3 pass (repo idiom — no jq).
# Emits exactly one of: <cwd> (a usable string) | __NO_CWD__ (parsed OK but no
# usable cwd — dict without cwd, a non-dict payload, or a null/non-string cwd) |
# __PARSE_FAILED__ (the payload did not parse as JSON at all). An EMPTY result
# means python3 itself was unavailable (nothing to parse WITH).
PAYLOAD_RAW="$(printf '%s' "$EVENT" | python3 -c '
import sys, json
try:
    e = json.loads(sys.stdin.read())
except Exception:
    print("__PARSE_FAILED__"); sys.exit(0)
cwd = e.get("cwd") if isinstance(e, dict) else None
print(cwd if (isinstance(cwd, str) and cwd) else "__NO_CWD__")
' 2>/dev/null || true)"

# Case 1 — PRESENT-but-unparseable payload → BLOCK (couldn't-verify): a done-gate
# must not fail-soft on a garbage payload it cannot read to resolve the tree.
if [ "$PAYLOAD_RAW" = "__PARSE_FAILED__" ]; then
  {
    echo "dod-affirm: BLOCKED — couldn't verify affirmation, rerun."
    echo ""
    echo "The TaskCompleted event payload did not parse as JSON, so the work tree"
    echo "(and its HEAD commit) could not be resolved to check the affirmation."
    echo "Re-run the task; include the six [DoD-1]..[DoD-6] lines in your task"
    echo "summary or commit message. See CLAUDE.md §Definition of done."
  } >&2
  exit 2
fi
# Case 2 — parsed but no usable cwd / cwd not a git tree / python3 absent →
# FAIL-SOFT: topology genuinely unresolvable; never false-block on a tree we
# cannot locate (the CI referee is the real gate).
if [ "$PAYLOAD_RAW" = "__NO_CWD__" ] || [ -z "$PAYLOAD_RAW" ] \
   || ! ROOT="$(git -C "$PAYLOAD_RAW" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "dod-affirm: SKIPPED — no work tree resolvable from payload cwd; advisory hook fail-soft (CI referee remains the gate)." >&2
  exit 0
fi

# Collect candidate text to search in: every string-valued field of the stdin
# JSON event, joined with newlines. We only reach this point once the payload
# has parsed as JSON (the cwd resolution above succeeded on the same $EVENT), so
# a parse-failure sentinel is unnecessary — an unparseable payload fail-softed
# out already.
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

# Every item must be present on its own line, affirmed as "yes" or "n/a:<reason>".
# The match is anchored to the exact tag so "almost-DoD" prose doesn't pass.
# "yes" may be followed by " | <detail>" — the commit-summary template renders
# the choice as "yes | n/a:<reason>", and agents legitimately read the "|" as a
# separator and append detail after "yes". An affirmative with trailing detail
# is still an affirmative; only the leading verdict token is load-bearing.
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
  pat="^\[DoD-${n}\] ${label}: (yes([[:space:]]*\|.*)?|n/a:.+)$"
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
    echo "Each line must affirm either 'yes' (optionally 'yes | <detail>') or"
    echo "'n/a:<reason>' — for example:"
    echo "  [DoD-1] Contract: yes"
    echo "  [DoD-2] Tests: yes | 42 passing, suite green"
    echo "  [DoD-4] Operability: n/a:doc-only task, no module surface"
    echo ""
    echo "See CLAUDE.md §Definition of done for what each item means. Item 7"
    echo "(CTO-reviewed) is the CTO's signoff, not self-affirmed."
  } >&2
  exit 2
fi

exit 0
