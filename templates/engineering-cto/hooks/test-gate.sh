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

# Capture the stdin payload — we need its `cwd` field to resolve the work tree
# this task was completed in (see the worktree-topology note below).
EVENT="$(cat)"

# --- QOFI quality-hook runtime control -------------------------------------
# QUALITY gates honor QOFI_HOOK_PROFILE / QOFI_DISABLED_HOOKS so an operator can
# turn advisory quality gates off for a fast or experimental session. The
# permission gate is the SECURITY FLOOR and is deliberately immune — it never
# consults these vars (verify by grep: permission-gate.sh references neither
# QOFI_HOOK_PROFILE nor QOFI_DISABLED_HOOKS). A disabled quality hook is surfaced
# LOUDLY at swarm-up preflight (the harness-audit gate), so an off gate is never
# silent.
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

# Resolve the work tree this task was completed in. In worktree topology
# (TEAM_LEAD.md §*Pre-spawn provisioning*) the teammate works in
# .claude/worktrees/<name>/ on its own branch — a first-class git work tree,
# distinct from the lead's main repo — and that is where the tests to run live.
#
# Resolve it from the hook payload's `cwd` field (the invoking session's working
# directory, per the Claude Code hook contract), NOT from `git rev-parse` on the
# process's inherited CWD nor from $CLAUDE_PROJECT_DIR. A hook subprocess does
# not inherit the teammate's worktree CWD, and $CLAUDE_PROJECT_DIR is set once at
# launch to the lead's project dir and never rebinds per-teammate. The old
# resolution therefore ran the suite in the WRONG tree from every teammate
# invocation — false-PASSING a task whose tests broke only in the worktree
# (load-bearing gate that wasn't gating) and false-FAILING one whose new tests
# existed only there. Extract cwd with python3 (repo idiom — permission-gate.sh
# does the same; no jq dependency). See tests/test-hooks-worktree-resolution.sh.
#
# Extract cwd AND classify the payload in one pass. Emits exactly one of: <cwd> (a
# usable string) | __NO_CWD__ (parsed OK but no usable cwd — dict without cwd, a
# non-dict payload, or a null/non-string cwd) | __PARSE_FAILED__ (did not parse as
# JSON at all). An EMPTY result means python3 itself was unavailable.
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
# must not fail-soft on a garbage payload it cannot read to find which tree to test.
if [ "$PAYLOAD_RAW" = "__PARSE_FAILED__" ]; then
  {
    echo "test-gate: BLOCKED — could not parse the TaskCompleted payload."
    echo "The work tree to run the suite in could not be resolved. Re-run the task."
  } >&2
  exit 2
fi
# Case 2 — parsed but no usable cwd / cwd not a git tree / python3 absent →
# FAIL-SOFT: a gate hook must never false-block on topology it cannot resolve (the
# CI referee is the real gate; this hook is advisory-local). Note the asymmetry:
# permission-gate — a SECURITY floor — fail-CLOSES when python3 is absent; this
# advisory gate fail-softs. When cwd DOES resolve, the test command runs at full
# strictness in THAT tree, and a missing test command or a failing run still
# BLOCKS (below): we fix WHERE the gate runs, never weaken WHAT it checks.
if [ "$PAYLOAD_RAW" = "__NO_CWD__" ] || [ -z "$PAYLOAD_RAW" ] \
   || ! ROOT="$(git -C "$PAYLOAD_RAW" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "test-gate: SKIPPED — no work tree resolvable from payload cwd; advisory hook fail-soft (CI referee remains the gate)." >&2
  exit 0
fi
# cd-failure after a SUCCESSFUL resolution is near-unreachable, but it is a gate:
# BLOCK (exit 2), never invert to a pass.
cd "$ROOT" || { echo "test-gate: BLOCKED — cannot cd to resolved tree ($ROOT)." >&2; exit 2; }

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
