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
# Posture (decided at the tree-resolution point; operator ruling 2026-07-08):
#   1. Payload unparseable / no tree resolvable / no assigned worktree for the
#      named teammate / python3 absent → BLOCK (exit 2, cannot-verify). A
#      done-gate never passes or silently skips on wrong-tree ambiguity — the
#      fail-open corner (passing against a sibling's clean tree while the real
#      assigned tree holds an unverified completion) is exactly the live
#      failure this closes. Supersedes the earlier fail-soft-on-no-cwd posture.
#   2. Tree resolves (teammate events: the ASSIGNED tree, never the session's
#      possibly re-homed cwd) → a missing/malformed affirmation BLOCKS (exit 2)
#      as always; never fail open on a resolvable done-gate.

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
      echo "dod-affirm: BLOCKED — could not parse the TaskCompleted payload, so the work"
      echo "tree this gate must verify could not be resolved. Re-run the task."
    } >&2
    exit 2 ;;
  NO_ASSIGNMENT)
    {
      echo "dod-affirm: BLOCKED — cannot verify: no assigned worktree resolvable for teammate [$TM_NAME]."
      echo "Provisioning gap (TEAM_LEAD.md section *Worktree isolation*): expected .claude/worktrees/$TM_NAME/,"
      echo "or a .claude/worktree-assignments.tsv row [$TM_NAME<TAB><path>] (path [.] maps to the main tree)."
      echo "A gate never passes on wrong-tree ambiguity — provision/record the worktree, then re-run."
    } >&2
    exit 2 ;;
  *)
    {
      echo "dod-affirm: BLOCKED — cannot verify: no work tree resolvable from the payload."
      echo "A gate never passes on a tree it cannot locate. Re-run from the assigned tree."
    } >&2
    exit 2 ;;
esac
if [ "$TREE_MISMATCH" = "1" ]; then
  echo "dod-affirm: NOTE — session cwd is not the assigned tree of teammate [$TM_NAME] (harness re-homing); acting on the ASSIGNED tree: $ROOT" >&2
fi

# Collect candidate text to search in: every string-valued field of the stdin
# JSON event, joined with newlines. We only reach this point once the payload
# has parsed as JSON (the tree resolution above succeeded on the same $EVENT),
# so a parse-failure sentinel is unnecessary — an unparseable payload BLOCKED
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
