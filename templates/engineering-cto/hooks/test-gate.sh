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

# --- QOFI quality-hook runtime control -------------------------------------
# QUALITY gates honor QOFI_HOOK_PROFILE / QOFI_DISABLED_HOOKS so an operator can
# turn advisory quality gates off for a fast or experimental session. The
# permission gate is the SECURITY FLOOR and is deliberately immune — it never
# consults these vars (proof: tests/test-hook-runtime-controls.sh). A disabled
# quality hook is surfaced LOUDLY at swarm-up preflight (the harness-audit gate),
# so an off gate is never silent.
__qofi_hook="test-gate"
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

# Resolve the work tree this hook is invoked against. In worktree topology
# (TEAM_LEAD.md §*Pre-spawn provisioning*) the teammate works in
# .claude/worktrees/<name>/ on its own branch — a first-class git work
# tree, distinct from the lead's main repo. `git rev-parse --show-toplevel`
# returns the toplevel of whichever work tree the subprocess is invoked
# from, so the same call gives the right answer for both lead and teammates.
#
# Why not trust $CLAUDE_PROJECT_DIR alone (the original bug): that env var
# is set once at Claude Code launch (to the lead's project dir) and does
# not rebind per-teammate. Until this fix, the gate silently ran against
# the lead's main tree from every teammate invocation — false-PASSING any
# task whose tests broke only in the teammate's worktree (load-bearing
# gate that wasn't gating), and false-FAILING tasks whose new tests
# existed only in the worktree. See tests/test-hooks-worktree-resolution.sh
# for the regression proof.
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  cd "$ROOT" || { echo "test-gate: cannot cd to git toplevel ($ROOT)" >&2; exit 2; }
else
  ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
  cd "$ROOT" || { echo "test-gate: cannot cd to project root ($ROOT)" >&2; exit 2; }
fi

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

# No tests configured anywhere: FAIL CLOSED. A missing test command is a
# config defect, not "no tests to run" — leaving the gate open means an agent
# can mark anything done without proving it works. Block until the operator
# wires the test command.
if [ -z "$TEST_CMD" ]; then
  {
    echo "test-gate: BLOCKED — no test command resolved."
    echo "Set CLAUDE_TEST_CMD in .claude/settings.json, or write the command"
    echo "into .claude/test-cmd, or add a 'test' script to package.json."
    echo "An ungated done is not done; refusing to pass with no gate."
  } >&2
  exit 2
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
