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

# --- Work-tree resolution: ASSIGNED tree, fail-closed -----------------------
# Resolve the tree this gate must act on. In worktree topology (TEAM_LEAD.md
# section *Worktree isolation*) each teammate is ASSIGNED
# .claude/worktrees/<name>/ on branch worktree-<name>. The harness can RE-HOME
# a session into a tree that is NOT its assignment (seen live 2026-07-08:
# gates checked a sibling tree — false-blocking clean agents against a
# sibling red tree AND fail-OPEN passing while the real assigned tree held an
# unverified completion). So for a teammate event the payload cwd is a hint,
# never the authority:
#   * teammate_name present (TaskCompleted payloads carry it) -> act on the
#     teammate ASSIGNED tree: the optional .claude/worktree-assignments.tsv
#     override (name<TAB>path, relative to the main root; "." = main tree)
#     else the .claude/worktrees/<name> convention. The main root is reachable
#     from ANY sibling tree via git rev-parse --git-common-dir, else
#     $CLAUDE_PROJECT_DIR.
#   * no teammate_name (solo/lead event) -> the payload cwd toplevel.
#   * anything unresolvable -> BLOCK (cannot-verify), NEVER pass or skip: a
#     gate that cannot locate the assigned tree must not pass on a sibling
#     clean tree. Operator ruling 2026-07-08 — supersedes the earlier
#     fail-soft posture for unresolvable topology on this hook.
# One python3 pass (repo idiom, no jq; single-quote-free for the bash 3.2 -c
# form). Emits STATUS|ROOT|MISMATCH|NAME with STATUS one of
# OK|PARSE_FAILED|NO_TREE|NO_ASSIGNMENT; empty output = python3 absent.
RES="$(printf '%s' "$EVENT" | python3 -c 'import sys, json, os, subprocess

def toplevel(p):
    if not p or not os.path.isdir(p):
        return ""
    try:
        r = subprocess.run(["git", "-C", p, "rev-parse", "--show-toplevel"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    except Exception:
        return ""
    return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""

def emit(status, root="", mismatch="0", name=""):
    print("%s|%s|%s|%s" % (status, root, mismatch, name))
    sys.exit(0)

try:
    e = json.loads(sys.stdin.read())
except Exception:
    emit("PARSE_FAILED")
if not isinstance(e, dict):
    emit("PARSE_FAILED")
cwd = e.get("cwd") if isinstance(e.get("cwd"), str) else ""
name = (e.get("teammate_name") if isinstance(e.get("teammate_name"), str) else "").strip()
cwd_root = toplevel(cwd)

if not name:                     # solo/lead event: no assignment to enforce
    if cwd_root:
        emit("OK", cwd_root)
    emit("NO_TREE")

# Teammate event: resolve the ASSIGNED tree; never trust cwd (the harness can
# re-home a session into a sibling tree, and gating there is wrong-tree). Any
# sibling tree still shares the main repo, so the main root is reachable via
# --git-common-dir even from a wrongly-homed cwd; CLAUDE_PROJECT_DIR (set at
# launch to the lead project dir) is the fallback.
main_root = ""
if cwd_root:
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-common-dir"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        if r.returncode == 0:
            gd = r.stdout.decode("utf-8", "replace").strip()
            if gd:
                if not os.path.isabs(gd):
                    gd = os.path.join(cwd, gd)
                main_root = os.path.dirname(os.path.realpath(gd))
    except Exception:
        pass
if not main_root:
    main_root = os.environ.get("CLAUDE_PROJECT_DIR", "")

assigned = ""
if main_root:
    # Optional override table .claude/worktree-assignments.tsv: one row per
    # teammate, name<TAB>path (path relative to the main root; "." maps a
    # named agent to the main tree, a conscious visible exception). An
    # unreadable table means cannot-verify; never guess past a corrupt record.
    tsv = os.path.join(main_root, ".claude", "worktree-assignments.tsv")
    if os.path.exists(tsv):
        try:
            with open(tsv, encoding="utf-8") as fh:
                for line in fh:
                    line = line.split("#", 1)[0].rstrip("\n")
                    if not line.strip():
                        continue
                    parts = line.split("\t", 1) if "\t" in line else line.split(None, 1)
                    if len(parts) == 2 and parts[0].strip() == name:
                        p = parts[1].strip()
                        assigned = p if os.path.isabs(p) else os.path.normpath(os.path.join(main_root, p))
                        break
        except Exception:
            emit("NO_ASSIGNMENT", name=name)
    if not assigned:
        conv = os.path.join(main_root, ".claude", "worktrees", name)
        if os.path.isdir(conv):
            assigned = conv
if not assigned:
    emit("NO_ASSIGNMENT", name=name)
aroot = toplevel(assigned)
if not aroot:
    emit("NO_ASSIGNMENT", name=name)
mismatch = "1" if (cwd_root and os.path.realpath(cwd_root) != os.path.realpath(aroot)) else "0"
emit("OK", aroot, mismatch, name)' 2>/dev/null)"
STATUS="${RES%%|*}"; _r1="${RES#*|}"; ROOT="${_r1%%|*}"
_r2="${_r1#*|}"; TREE_MISMATCH="${_r2%%|*}"; TM_NAME="${_r2#*|}"
case "$STATUS" in
  OK) : ;;
  PARSE_FAILED)
    {
      echo "test-gate: BLOCKED — could not parse the TaskCompleted payload, so the work"
      echo "tree this gate must verify could not be resolved. Re-run the task."
    } >&2
    exit 2 ;;
  NO_ASSIGNMENT)
    {
      echo "test-gate: BLOCKED — cannot verify: no assigned worktree resolvable for teammate [$TM_NAME]."
      echo "Provisioning gap (TEAM_LEAD.md section *Worktree isolation*): expected .claude/worktrees/$TM_NAME/,"
      echo "or a .claude/worktree-assignments.tsv row [$TM_NAME<TAB><path>] (path [.] maps to the main tree)."
      echo "A gate never passes on wrong-tree ambiguity — provision/record the worktree, then re-run."
    } >&2
    exit 2 ;;
  *)
    {
      echo "test-gate: BLOCKED — cannot verify: no work tree resolvable from the payload."
      echo "A gate never passes on a tree it cannot locate. Re-run from the assigned tree."
    } >&2
    exit 2 ;;
esac
if [ "$TREE_MISMATCH" = "1" ]; then
  echo "test-gate: NOTE — session cwd is not the assigned tree of teammate [$TM_NAME] (harness re-homing); acting on the ASSIGNED tree: $ROOT" >&2
fi
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
