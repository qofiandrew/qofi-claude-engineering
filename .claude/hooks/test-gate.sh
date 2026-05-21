#!/usr/bin/env bash
# test-gate.sh — TaskCompleted hook.
# Blocks a teammate (or the lead) from marking a task complete while tests are red.
#
# Wired in settings.json under hooks.TaskCompleted. Invoked as:
#   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/test-gate.sh"
#
# Contract: hook JSON arrives on stdin. Exit 0 = allow completion.
# Exit 2 = BLOCK completion; whatever we write to stderr is fed back to the agent
# so it can fix the failure and retry.

set -uo pipefail

# Consume the stdin payload (we don't need fields here, but must drain it).
cat >/dev/null

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" || { echo "test-gate: cannot cd to project root ($ROOT)" >&2; exit 2; }

# Resolve the test command, in priority order:
#   1) $CLAUDE_TEST_CMD  2) .claude/test-cmd file  3) auto-detect.
TEST_CMD="${CLAUDE_TEST_CMD:-}"
if [ -z "$TEST_CMD" ] && [ -f .claude/test-cmd ]; then
  TEST_CMD="$(cat .claude/test-cmd)"
fi
if [ -z "$TEST_CMD" ]; then
  if [ -f package.json ] && grep -q '"test"' package.json; then
    TEST_CMD="npm test --silent"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; then
    TEST_CMD="pytest -q"
  fi
fi

# No tests configured anywhere: don't block (so it works on day-1 repos), but make
# the gap loud so it gets fixed.
if [ -z "$TEST_CMD" ]; then
  echo "test-gate: NO TEST COMMAND FOUND. Set CLAUDE_TEST_CMD in settings.json or write .claude/test-cmd. This task shipped UNGATED." >&2
  exit 0
fi

# Run the gate.
OUTPUT="$(eval "$TEST_CMD" 2>&1)"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
  {
    echo "test-gate: BLOCKED — task cannot be completed."
    echo "Command: $TEST_CMD  (exit $STATUS)"
    echo "Fix the failing tests, then mark the task complete again. Last 40 lines:"
    echo "----"
    echo "$OUTPUT" | tail -n 40
  } >&2
  exit 2
fi

exit 0
