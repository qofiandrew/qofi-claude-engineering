#!/usr/bin/env bash
# test-hooks-worktree-resolution.sh — regression proof for the worktree-topology
# resolution of the SIX gate/advisory hooks that inspect a git work tree:
#   .claude/hooks/dod-affirm.sh      (TaskCompleted — scans HEAD commit message)
#   .claude/hooks/test-gate.sh       (TaskCompleted — runs the test command in-tree)
#   .claude/hooks/canon-check.sh     (TaskCompleted — validates external-canon packs)
#   .claude/hooks/docs-check.sh      (TeammateIdle  — scans `git status` src-vs-doc)
#   .claude/hooks/session-summary.sh (Stop          — writes the resume aid in-tree)
#   .claude/hooks/quality-check.sh   (PostToolUse   — per-file lint in-tree)
#
# THE BUG THIS PINS
# ----------------
# In a multi-worktree session the lead runs in one work tree and each teammate
# in its own .claude/worktrees/<name>/ tree. A hook subprocess does NOT inherit
# the invoking teammate's working directory — so resolving the tree via
# `git rev-parse --show-toplevel` on the process's inherited CWD (the old code)
# picks the WRONG tree (a sibling worktree, or the lead's main tree): dod-affirm
# scanned the wrong HEAD, docs-check scanned a dirty sibling, test-gate ran the
# suite in the wrong tree, canon-check validated the wrong tree's packs,
# session-summary wrote the resume aid to the wrong tree, quality-check linted
# against the wrong toolchain. Each hook now resolves from the payload's `cwd`
# field (the invoking session's working directory, per the Claude Code hook
# contract) via `git -C "$cwd" rev-parse --show-toplevel`, and acts on THAT tree.
# Strictness of WHAT each hook checks is unchanged; only WHERE it looks is fixed.
#
# POSTURE ON UNRESOLVABLE TOPOLOGY (the spec the next maintainer needs)
# --------------------------------------------------------------------
#   permission-gate.sh    fail-CLOSED  — SECURITY floor (not exercised here).
#   canon-check.sh        fail-CLOSED  — TaskCompleted gate with NO CI backstop
#                                        (the canon repo is never checked out on
#                                        runners) and canon consistency is this
#                                        repo's spine → no fail-open corner: ANY
#                                        unresolvable cwd BLOCKS (exit 2).
#   dod-affirm.sh /       fail-CLOSED on a PRESENT-but-unparseable payload (a
#   test-gate.sh           couldn't-verify done-gate BLOCK), fail-SOFT (exit 0) on
#                          genuine cwd-absence / non-git cwd / python3-absent —
#                          these two ARE CI-referee-backstopped, so a degenerate
#                          topology miss must not false-block.
#   docs-check.sh /       fail-OPEN — advisory nudges / resume aid, never gate:
#   session-summary.sh /   every unresolvable case → exit 0.
#   quality-check.sh
#
# This test builds a throwaway main repo (tree A, the "lead/sibling") plus a
# linked worktree (tree B, the "teammate's own"), invokes each hook with the
# process CWD pointed at tree A and a synthetic stdin payload whose `cwd` points
# at tree B, and asserts each hook acts on tree B — plus the per-hook
# unresolvable-topology posture above.
# Run against the UNFIXED hooks it is RED; against the fixed hooks it is GREEN.
#
# Pure git + bash + python3 — no external services, safe in any sandbox.
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

# --- locate the hooks under test (repo-relative; invocation-CWD independent) --
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_TPL="$REPO_ROOT/templates/engineering-cto/hooks"
HOOK_DOD="$HOOKS_TPL/dod-affirm.sh"
HOOK_TEST="$HOOKS_TPL/test-gate.sh"
HOOK_DOCS="$HOOKS_TPL/docs-check.sh"
HOOK_CANON="$HOOKS_TPL/canon-check.sh"
HOOK_SUMMARY="$HOOKS_TPL/session-summary.sh"
HOOK_QUALITY="$HOOKS_TPL/quality-check.sh"
for h in "$HOOK_DOD" "$HOOK_TEST" "$HOOK_DOCS" "$HOOK_CANON" "$HOOK_SUMMARY" "$HOOK_QUALITY"; do
  [ -f "$h" ] || { echo "FATAL: hook not found: $h" >&2; exit 1; }
done

# --- isolated workspace -------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hooks-wt.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"   # canonicalize (macOS /var -> /private/var)
trap 'rm -rf "$WORK"' EXIT
MAIN="$WORK/main"   # tree A — the "lead / sibling" tree
WT="$WORK/wt"       # tree B — the "teammate's own" worktree
STDERR_LOG="$WORK/stderr.log"; : >"$STDERR_LOG"

git -C "$WORK" 2>/dev/null init -q "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name "Hook Test"
git -C "$MAIN" config commit.gpgsign false
printf 'source\n' >"$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m "init: no DoD block here"
# Linked worktree on its own branch — tree B.
git -C "$MAIN" worktree add -q -b wtbranch "$WT" >/dev/null 2>&1
# A commit in tree B whose message carries the full six-line DoD affirmation.
printf 'wt source\n' >"$WT/wtfile.txt"
git -C "$WT" add wtfile.txt
git -C "$WT" commit -q -F - <<'MSG'
feat: teammate work in its own worktree

[DoD-1] Contract: yes
[DoD-2] Tests: yes
[DoD-3] Docs: yes
[DoD-4] Operability: yes
[DoD-5] Scale: yes
[DoD-6] No conflicts: yes
MSG
# session-summary.sh / canon-check.sh preconditions: a `.claude/` dir in each tree.
mkdir -p "$MAIN/.claude" "$WT/.claude"

# --- helpers ------------------------------------------------------------------
PASS=0; FAIL=0
check() {  # check <desc> <actual_exit> <expected_exit>
  if [ "$2" -eq "$3" ]; then
    printf '  PASS  %s (exit %s)\n' "$1" "$2"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (exit %s, expected %s)\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}
check_empty() {    # check_empty <desc> <value>  (PASS when empty)
  if [ -z "$2" ]; then printf '  PASS  %s (nothing surfaced)\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s (unexpected output surfaced)\n' "$1"; FAIL=$((FAIL+1)); fi
}
check_nonempty() { # check_nonempty <desc> <value>  (PASS when non-empty)
  if [ -n "$2" ]; then printf '  PASS  %s (surfaced)\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s (nothing surfaced, expected findings)\n' "$1"; FAIL=$((FAIL+1)); fi
}
check_file() {     # check_file <desc> <path>  (PASS when file exists)
  if [ -f "$2" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s (missing: %s)\n' "$1" "$2"; FAIL=$((FAIL+1)); fi
}
check_nofile() {   # check_nofile <desc> <path>  (PASS when file absent)
  if [ ! -f "$2" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s (present, should be absent: %s)\n' "$1" "$2"; FAIL=$((FAIL+1)); fi
}
check_contains() { # check_contains <desc> <haystack> <needle>  (PASS when present)
  case "$2" in
    *"$3"*) printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)) ;;
    *)      printf '  FAIL  %s (output lacked %s)\n' "$1" "$3"; FAIL=$((FAIL+1)) ;;
  esac
}

# invoke <hook> <process_cwd> <stdin_payload> [extra env KEY=VAL ...]
# Runs the hook with its process CWD at <process_cwd> and <stdin_payload> on
# stdin. Neutralizes ambient QOFI_* / CLAUDE_* so we test the real logic, then
# lets any caller-supplied env override. Returns the hook's exit code; the hook's
# STDOUT / STDERR are captured into the globals LAST_STDOUT / LAST_STDERR (for
# the non-blocking hooks that signal via stdout, and for asserting SKIP text).
LAST_STDOUT=""; LAST_STDERR=""
invoke() {
  local hook="$1" pcwd="$2" payload="$3"; shift 3
  local outf="$WORK/last_stdout" errf="$WORK/last_stderr"
  (
    cd "$pcwd" || exit 127
    printf '%s' "$payload" | env \
      QOFI_HOOK_PROFILE=default QOFI_DISABLED_HOOKS= \
      CLAUDE_PROJECT_DIR= CLAUDE_TEST_CMD= QOFI_QUALITY_CMD= "$@" \
      bash "$hook"
  ) >"$outf" 2>"$errf"
  local ec=$?
  LAST_STDOUT="$(cat "$outf" 2>/dev/null)"
  LAST_STDERR="$(cat "$errf" 2>/dev/null)"
  { [ -s "$outf" ] && sed 's/^/  [stdout] /' "$outf"; [ -s "$errf" ] && sed 's/^/  [stderr] /' "$errf"; } >>"$STDERR_LOG"
  return $ec
}

pl_cwd()        { printf '{"session_id":"s","hook_event_name":"%s","cwd":"%s"}' "$1" "$2"; }
pl_no_cwd()     { printf '{"session_id":"s","hook_event_name":"%s"}' "$1"; }
pl_cwd_file()   { printf '{"session_id":"s","hook_event_name":"PostToolUse","cwd":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
pl_nocwd_file() { printf '{"session_id":"s","hook_event_name":"PostToolUse","tool_input":{"file_path":"%s"}}' "$1"; }

# =============================================================================
echo "dod-affirm.sh (TaskCompleted — scans HEAD of the payload's tree):"
# dod-1 (RED on unfixed): affirmation lives ONLY in tree B's HEAD; process CWD is
# tree A (whose HEAD has none) and the payload carries no DoD text. Fixed reads
# tree B via payload cwd -> PASS. Unfixed reads tree A's HEAD -> BLOCK.
invoke "$HOOK_DOD" "$MAIN" "$(pl_cwd TaskCompleted "$WT")"; ec=$?
check "reads teammate worktree HEAD, not inherited-CWD tree" "$ec" 0
# dod-2 (strictness preserved): payload points at tree A, which genuinely lacks
# the affirmation (HEAD and stdin both) -> still BLOCKS.
invoke "$HOOK_DOD" "$WT" "$(pl_cwd TaskCompleted "$MAIN")"; ec=$?
check "still BLOCKS when the payload's tree lacks the affirmation" "$ec" 2
# dod-3 (fail-soft): no cwd, and cwd -> non-git dir, both exit 0.
invoke "$HOOK_DOD" "$MAIN" "$(pl_no_cwd TaskCompleted)"; ec=$?
check "fail-soft (exit 0) when payload has no cwd" "$ec" 0
invoke "$HOOK_DOD" "$MAIN" "$(pl_cwd TaskCompleted "$WORK")"; ec=$?
check "fail-soft (exit 0) when cwd is not a git tree" "$ec" 0

# =============================================================================
echo "docs-check.sh (TeammateIdle — scans git status of the payload's tree):"
# docs-2 (strictness preserved): payload's OWN tree (B) is dirty with source only
# -> BLOCK. (Tree A / process CWD is clean here.)
printf 'more\n' >"$WT/extra.ts"
invoke "$HOOK_DOCS" "$MAIN" "$(pl_cwd TeammateIdle "$WT")"; ec=$?
check "BLOCKS when the payload's own tree changed source without docs" "$ec" 2
rm -f "$WT/extra.ts"
# docs-1 (RED on unfixed): a dirty SIBLING (tree A / process CWD) must NOT block a
# clean teammate tree (B). Fixed checks tree B (clean) -> exit 0. Unfixed checks
# the dirty sibling -> BLOCK.
printf 'sibling churn\n' >"$MAIN/extra.ts"
invoke "$HOOK_DOCS" "$MAIN" "$(pl_cwd TeammateIdle "$WT")"; ec=$?
check "a dirty sibling tree does NOT block a clean payload-cwd tree" "$ec" 0
rm -f "$MAIN/extra.ts"
# docs-3: touching a doc on the payload's tree clears the gate.
printf '# note\n' >"$WT/notes.md"
invoke "$HOOK_DOCS" "$MAIN" "$(pl_cwd TeammateIdle "$WT")"; ec=$?
check "does NOT block when the payload's tree touched a doc" "$ec" 0
rm -f "$WT/notes.md"
# docs-4 (fail-soft): no cwd -> exit 0.
invoke "$HOOK_DOCS" "$MAIN" "$(pl_no_cwd TeammateIdle)"; ec=$?
check "fail-soft (exit 0) when payload has no cwd" "$ec" 0

# =============================================================================
echo "test-gate.sh (TaskCompleted — runs the test command in the payload's tree):"
# The command 'test -f PASS_MARKER' passes only when run in the tree that holds
# the marker. The marker lives in tree B only.
printf '' >"$WT/PASS_MARKER"
# tg-1 (RED on unfixed): process CWD is tree A (no marker); payload cwd is tree B
# (marker present). Fixed cds to tree B -> command passes -> exit 0. Unfixed cds
# to tree A -> command fails -> BLOCK.
invoke "$HOOK_TEST" "$MAIN" "$(pl_cwd TaskCompleted "$WT")" CLAUDE_TEST_CMD='test -f PASS_MARKER'; ec=$?
check "runs the test command in the payload's tree (marker found)" "$ec" 0
# tg-2 (strictness preserved): payload points at tree A (no marker) -> command
# fails there -> BLOCK. Proves a genuinely-failing command still blocks.
invoke "$HOOK_TEST" "$WT" "$(pl_cwd TaskCompleted "$MAIN")" CLAUDE_TEST_CMD='test -f PASS_MARKER'; ec=$?
check "still BLOCKS when the command fails in the payload's tree" "$ec" 2
# tg-3 (fail-soft): no cwd -> exit 0 BEFORE the (failing) command is even resolved.
invoke "$HOOK_TEST" "$MAIN" "$(pl_no_cwd TaskCompleted)" CLAUDE_TEST_CMD='false'; ec=$?
check "fail-soft (exit 0) when payload has no cwd, before running the command" "$ec" 0

# =============================================================================
echo "canon-check.sh (TaskCompleted — validates the payload's tree, external-canon mode):"
# Mark tree B external-canon with NO doc packs -> validation FAILS there. Tree A
# has no marker -> local-canon no-op.
printf 'external\n' >"$WT/.claude/canon-mode"
# cc-1 (RED on unfixed): process CWD is tree A (local-canon); payload cwd is tree
# B (external, missing packs). Fixed validates B -> BLOCK. Unfixed reads A -> pass.
invoke "$HOOK_CANON" "$MAIN" "$(pl_cwd TaskCompleted "$WT")"; ec=$?
check "validates the payload's tree (external-canon + missing packs -> BLOCK)" "$ec" 2
# cc-2 (RED on unfixed): payload points at tree A (local-canon) -> no-op pass, even
# though the process CWD is the external-canon tree B. Fixed passes; unfixed reads
# B and BLOCKS.
invoke "$HOOK_CANON" "$WT" "$(pl_cwd TaskCompleted "$MAIN")"; ec=$?
check "no-ops (exit 0) when the payload's tree is local-canon" "$ec" 0
# cc-3 (fail-CLOSED — no CI backstop): canon-check is a gate the CI referee can
# NEVER run (the canon repo isn't checked out on runners), and canon consistency
# is this repo's spine — so it gets no fail-open corner, not even a degenerate
# one. ANY unresolvable topology BLOCKS (exit 2) with the cause named. These flip
# RED against 455f30d's fail-soft canon-check.
invoke "$HOOK_CANON" "$WT" "$(pl_no_cwd TaskCompleted)"; ec=$?
check "fail-CLOSED (exit 2) when payload has no cwd" "$ec" 2
check_contains "canon-check names the cause on a topology block" "$LAST_STDERR" "BLOCKED"
invoke "$HOOK_CANON" "$MAIN" 'not json {{{'; ec=$?
check "fail-CLOSED (exit 2) on an unparseable payload" "$ec" 2
invoke "$HOOK_CANON" "$MAIN" "$(pl_cwd TaskCompleted "$WORK")"; ec=$?
check "fail-CLOSED (exit 2) when cwd is not a git tree" "$ec" 2
rm -f "$WT/.claude/canon-mode"

# =============================================================================
echo "session-summary.sh (Stop — writes the resume aid into the payload's tree):"
rm -f "$MAIN/.claude/session-summary.md" "$WT/.claude/session-summary.md"
# ss-1 (RED on unfixed): process CWD is tree A; payload cwd is tree B. Fixed writes
# into B; unfixed writes into A.
invoke "$HOOK_SUMMARY" "$MAIN" "$(pl_cwd Stop "$WT")"; ec=$?
check "exits 0 (a resume aid never blocks the stop)" "$ec" 0
check_file "writes the summary into the payload's tree (B)" "$WT/.claude/session-summary.md"
check_nofile "does NOT write into the process-CWD tree (A)" "$MAIN/.claude/session-summary.md"
rm -f "$MAIN/.claude/session-summary.md" "$WT/.claude/session-summary.md"
# ss-2 (fail-soft): no cwd -> exit 0, writes nothing.
invoke "$HOOK_SUMMARY" "$MAIN" "$(pl_no_cwd Stop)"; ec=$?
check "fail-soft (exit 0) when payload has no cwd" "$ec" 0
check_nofile "writes nothing when cwd is unresolvable" "$MAIN/.claude/session-summary.md"

# =============================================================================
echo "quality-check.sh (PostToolUse — runs the per-file check in the payload's tree):"
# The probe command `test -f QC_MARKER` passes only where the marker exists (tree
# B). quality-check always exits 0; it signals findings via stdout (additionalContext).
printf '' >"$WT/QC_MARKER"
printf 'export const x = 1;\n' >"$WT/probe.ts"
# qc-1 (RED on unfixed): process CWD is tree A (no marker); payload cwd is tree B
# (marker). Fixed cds to B -> check passes -> nothing surfaced. Unfixed cds to A ->
# check fails -> surfaces.
invoke "$HOOK_QUALITY" "$MAIN" "$(pl_cwd_file "$WT" "$WT/probe.ts")" QOFI_QUALITY_CMD='sh -c "test -f QC_MARKER" _'; ec=$?
check "exits 0 (PostToolUse never blocks)" "$ec" 0
check_empty "runs the check in the payload's tree (marker found -> nothing surfaced)" "$LAST_STDOUT"
# qc-2 (strictness preserved): payload points at tree A (no marker) -> check fails
# there -> surfaces findings.
invoke "$HOOK_QUALITY" "$WT" "$(pl_cwd_file "$MAIN" "$WT/probe.ts")" QOFI_QUALITY_CMD='sh -c "test -f QC_MARKER" _'; ec=$?
check_nonempty "surfaces findings when the check fails in the payload's tree" "$LAST_STDOUT"
# qc-3 (fail-soft): no cwd -> exit 0, nothing surfaced (check never runs).
invoke "$HOOK_QUALITY" "$MAIN" "$(pl_nocwd_file "$WT/probe.ts")" QOFI_QUALITY_CMD='sh -c "test -f QC_MARKER" _'; ec=$?
check "fail-soft (exit 0) when payload has no cwd" "$ec" 0
check_empty "nothing surfaced when cwd is unresolvable" "$LAST_STDOUT"
rm -f "$WT/QC_MARKER" "$WT/probe.ts"

# =============================================================================
echo "fail-soft-vs-block posture (present-but-unparseable payload; LOW-1/LOW-2):"
# A done-gate must distinguish "payload did not parse as JSON at all" (present but
# unparseable — a couldn't-verify BLOCK) from "parsed as a dict but no usable cwd"
# (topology genuinely unresolvable — fail-soft). These BLOCK cases are RED against
# 1b3a365 (which fail-soft exit 0 on any empty cwd, unparseable included).
BADJSON='this is not json {{{'
invoke "$HOOK_DOD" "$MAIN" "$BADJSON"; ec=$?
check "dod-affirm BLOCKS (exit 2) on an unparseable payload (couldn't-verify)" "$ec" 2
invoke "$HOOK_TEST" "$MAIN" "$BADJSON" CLAUDE_TEST_CMD='true'; ec=$?
check "test-gate BLOCKS (exit 2) on an unparseable payload" "$ec" 2
invoke "$HOOK_DOCS" "$MAIN" "$BADJSON"; ec=$?
check "docs-check stays fail-OPEN (exit 0) on an unparseable payload" "$ec" 0
# The other side of the branch: a parseable dict with NO usable cwd is fail-soft
# (never a block), and it emits the SKIP note on stderr.
invoke "$HOOK_DOD" "$MAIN" '{"hook_event_name":"TaskCompleted"}'; ec=$?
check "dod-affirm fail-soft (exit 0) on a parseable dict with no cwd" "$ec" 0
check_contains "dod-affirm fail-soft emits the SKIP note on stderr" "$LAST_STDERR" "SKIPPED"
invoke "$HOOK_TEST" "$MAIN" '{"hook_event_name":"TaskCompleted"}' CLAUDE_TEST_CMD='true'; ec=$?
check "test-gate fail-soft (exit 0) on a parseable dict with no cwd" "$ec" 0
check_contains "test-gate fail-soft emits the SKIP note on stderr" "$LAST_STDERR" "SKIPPED"
# A null (non-string) cwd is "no usable cwd" -> fail-soft, not a block.
invoke "$HOOK_DOD" "$MAIN" '{"hook_event_name":"TaskCompleted","cwd":null}'; ec=$?
check "dod-affirm fail-soft (exit 0) on a null cwd" "$ec" 0

# =============================================================================
echo ""
echo "-------------------------------------------------------------"
echo "worktree-resolution: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "(hook stderr from the run, for triage:)"
  sed 's/^/    | /' "$STDERR_LOG" | tail -n 60
  exit 1
fi
exit 0
