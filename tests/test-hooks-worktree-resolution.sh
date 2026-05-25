#!/usr/bin/env bash
# test-hooks-worktree-resolution.sh — regression tests for the worktree-
# topology bug across test-gate / dod-affirm / docs-check.
#
# The bug: each hook used ROOT="${CLAUDE_PROJECT_DIR:-$PWD}" which trusts
# the LEAD's project dir even when the hook is fired inside a teammate's
# worktree at .claude/worktrees/<name>/. CLAUDE_PROJECT_DIR is set once at
# Claude Code launch (to the main repo) and does not rebind per-teammate,
# so the gate silently ran against the wrong tree.
#
# Three failure modes this harness reproduces (each was a silent bug since
# worktree topology was adopted — TEAM_LEAD.md §*Pre-spawn provisioning*):
#
#   1. test-gate FALSE-PASS  — teammate broke tests that exist only in its
#      worktree; main tree's test runner saw them as unchanged and passed
#      the gate. The most important finding: a load-bearing enforcement
#      gate that wasn't gating.
#
#   2. dod-affirm FALSE-BLOCK — teammate's commit on worktree-<name>
#      contained the [DoD-*] block; hook read main's HEAD (no DoD) and
#      blocked. This is the symptom that stranded T1-T6.
#
#   3. docs-check FALSE-ALLOW — teammate modified source without docs in
#      its worktree; hook ran `git status` against main (clean) and let
#      idle through.
#
# The harness builds a synthetic main+worktree pair where the two trees
# disagree on every gate's input, then runs each hook from each context
# under both the OLD trust-CLAUDE_PROJECT_DIR logic (baseline) and the
# NEW git-rev-parse-show-toplevel logic. The contrast is the proof.
#
# Run from $SWARM_HOME:
#     bash tests/test-hooks-worktree-resolution.sh
#
# Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../templates/engineering-cto/hooks"

PASS=0
FAIL=0
FAILURES=""

assert_eq() {  # expected got label
  local expected="$1" got="$2" label="$3"
  if [ "$expected" = "$got" ]; then
    printf '  PASS  [%s] %s\n' "$expected" "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  expected=%s got=%s  %s\n' "$expected" "$got" "$label" >&2
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}
  - $label  (expected=$expected, got=$got)"
  fi
}

# ---------------------------------------------------------------------------
# Synthetic setup. Builds:
#   $TESTROOT/                          main repo, branch main
#     .gitignore                        ignores .claude/worktrees/
#     .claude/test-cmd                  "true"  (main's gate passes)
#     src.txt                           "main"
#     HEAD commit message: NO DoD block
#
#   $TESTROOT/.claude/worktrees/teammate-foo/   on branch worktree-teammate-foo
#     .claude/test-cmd                  "false" (worktree's gate fails)
#     src.txt                           "worktree change"  (committed)
#     docs.md                           "doc" (committed alongside src.txt)
#     HEAD commit message: HAS DoD block
#     UNCOMMITTED: src2.txt added       (for docs-check: source-without-docs)
# ---------------------------------------------------------------------------
setup() {
  TESTROOT="$(mktemp -d -t worktree-hooks-test.XXXXXX)"
  ( cd "$TESTROOT" && \
    git init -q -b main . 2>/dev/null || git init -q . ) >/dev/null 2>&1
  cd "$TESTROOT"
  # Defensive: some old gits create the default branch as "master"; rename
  # so this harness works on either.
  git checkout -q -b main 2>/dev/null || true
  git config user.email "test@hooks.local"
  git config user.name "Hook Test"
  git config commit.gpgsign false 2>/dev/null || true

  mkdir -p .claude
  printf '.claude/worktrees/\n' > .gitignore
  printf 'true\n' > .claude/test-cmd
  printf 'main\n' > src.txt
  git add -A
  # Main HEAD commit message intentionally OMITS the DoD block so dod-affirm
  # would block if it (incorrectly) read main's HEAD from a worktree caller.
  git commit -q -m "init: main tree (no DoD block on purpose)"

  git worktree add -q .claude/worktrees/teammate-foo -b worktree-teammate-foo >/dev/null
  ( cd .claude/worktrees/teammate-foo
    git config user.email "test@hooks.local"
    git config user.name "Hook Test"
    git config commit.gpgsign false 2>/dev/null || true
    printf 'false\n' > .claude/test-cmd
    printf 'worktree change\n' > src.txt
    printf 'doc\n' > docs.md
    git add -A
    # Worktree HEAD message HAS the DoD block so dod-affirm should pass when
    # invoked correctly from the worktree.
    git commit -q -m "teammate: failing test cmd + docs

[DoD-1] Contract: yes
[DoD-2] Tests: yes
[DoD-3] Docs: yes
[DoD-4] Operability: n/a:test fixture
[DoD-5] Scale: n/a:test fixture
[DoD-6] No conflicts: yes
"
    # Uncommitted source-without-docs change for docs-check.
    printf 'second source file\n' > src2.txt
  )
}

teardown() {
  cd /
  [ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"
}

# Baseline of the OLD (broken) ROOT resolution — kept here so each test can
# show the buggy outcome side-by-side with the fixed one. The hook source
# files use the new pattern; we replay the OLD logic in-shell to compare.
old_resolve_root() {
  # Mirror exactly what the old hook did: trust CLAUDE_PROJECT_DIR, ignore
  # whatever tree we're actually invoked from.
  printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}"
}

# Env scrubbing. CLAUDE_TEST_CMD, CLAUDE_PROJECT_DIR, GIT_DIR and
# GIT_WORK_TREE can all leak from the runner's session and silently change
# what these hooks do. Strip them and let each test add back only the
# vars it intends to set. (Bash needs at least PATH to find binaries; we
# don't use env -i so PATH survives.)
SCRUB="env -u CLAUDE_TEST_CMD -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE"

# Helper: run a hook script with a given event payload and CWD. Returns
# the script's exit code. Captures stderr but doesn't print it (most hook
# stderr is verbose blocking-message text; we only care about the decision).
run_hook() {  # hook_filename event_json cwd extra_env...
  local hook="$1" event="$2" cwd="$3"; shift 3
  ( cd "$cwd" && printf '%s' "$event" | $SCRUB "$@" bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 )
  return $?
}

# Helper: simulate the OLD test-gate logic in-shell so we can compare
# against the fixed hook output without keeping a copy of the old script.
old_test_gate() {  # cwd extra_env...
  local cwd="$1"; shift
  ( cd "$cwd" && $SCRUB "$@" bash -c '
    set -uo pipefail
    cat >/dev/null
    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    cd "$ROOT" || exit 2
    TEST_CMD=""
    [ -z "$TEST_CMD" ] && [ -f .claude/test-cmd ] && TEST_CMD="$(cat .claude/test-cmd)"
    [ -z "$TEST_CMD" ] && exit 2
    eval "$TEST_CMD" >/dev/null 2>&1
  ' </dev/null )
  return $?
}

old_dod_affirm() {  # cwd event_json extra_env...
  local cwd="$1" event="$2"; shift 2
  ( cd "$cwd" && printf '%s' "$event" | $SCRUB "$@" bash -c '
    set -uo pipefail
    EVENT="$(cat)"
    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    HEAD_MSG=""
    if cd "$ROOT" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      HEAD_MSG="$(git log -1 --pretty=%B 2>/dev/null || true)"
    fi
    # Replay the simplest version of the check: just look for [DoD-1] line
    # in HEAD_MSG. The full hook also walks the event payload; for the
    # baseline we only need to prove ROOT was wrong.
    printf "%s\n" "$HEAD_MSG" | grep -Eq "^\[DoD-1\] Contract: (yes|n/a:.+)$" || exit 2
    exit 0
  ' )
  return $?
}

old_docs_check() {  # cwd extra_env...
  local cwd="$1"; shift
  ( cd "$cwd" && $SCRUB "$@" bash -c '
    set -uo pipefail
    cat >/dev/null
    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    cd "$ROOT" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    CHANGED="$(git status --porcelain 2>/dev/null | sed "s/^...//")"
    [ -z "$CHANGED" ] && exit 0
    SRC_CHANGED=0; DOC_CHANGED=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f" in
        *.md|docs/*|*/docs/*|*.mdx|ADR-*|PROJECT_SPEC*) DOC_CHANGED=1 ;;
        *)                                              SRC_CHANGED=1 ;;
      esac
    done <<< "$CHANGED"
    [ "$SRC_CHANGED" -eq 1 ] && [ "$DOC_CHANGED" -eq 0 ] && exit 2
    exit 0
  ' </dev/null )
  return $?
}

trap 'teardown' EXIT
setup

MAIN="$TESTROOT"
WT="$TESTROOT/.claude/worktrees/teammate-foo"
EMPTY_EVENT='{}'

echo "=== Setup ==="
echo "  main repo:          $MAIN"
echo "  teammate worktree:  $WT"
echo ""

# ---------------------------------------------------------------------------
echo "=== test-gate.sh ==="
# Baseline: OLD logic trusts CLAUDE_PROJECT_DIR=main → runs main's 'true'
# from BOTH contexts, false-passing the worktree case.
old_test_gate "$MAIN" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "old logic from main: runs main's true → 0 (correct baseline)"
old_test_gate "$WT"   "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "old logic from worktree: also runs main's true → 0 (FALSE PASS — the load-bearing bug)"

# Fixed hook: should run the tree it's invoked from.
run_hook test-gate.sh "$EMPTY_EVENT" "$MAIN" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "fixed hook from main: runs main's true → 0"
run_hook test-gate.sh "$EMPTY_EVENT" "$WT"   "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "fixed hook from worktree: runs worktree's false → 2 (false-pass closed)"

# Subdirectory of the worktree: show-toplevel still finds the worktree top.
mkdir -p "$WT/sub/dir"
run_hook test-gate.sh "$EMPTY_EVENT" "$WT/sub/dir" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "fixed hook from worktree subdirectory: still resolves to worktree → 2"

# Fallback path: invoked outside any git tree, with CLAUDE_PROJECT_DIR
# pointing at the main repo. Should fall back to the env var and pass.
NONGIT="$(mktemp -d -t nongit.XXXXXX)"
run_hook test-gate.sh "$EMPTY_EVENT" "$NONGIT" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "fixed hook outside git, env var set: falls back, runs main's true → 0"
rm -rf "$NONGIT"

echo ""
# ---------------------------------------------------------------------------
echo "=== dod-affirm.sh ==="
# Baseline: OLD logic reads main's HEAD (no DoD block) from worktree caller
# → false-blocks the teammate whose worktree HEAD does have DoD.
old_dod_affirm "$MAIN" "$EMPTY_EVENT" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "old logic from main: main HEAD lacks DoD → blocks (correct baseline — there's nothing to affirm here)"
old_dod_affirm "$WT"   "$EMPTY_EVENT" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "old logic from worktree: reads MAIN's HEAD (no DoD) → blocks (FALSE BLOCK — the symptom that stranded T1-T6)"

# Fixed hook: should read the tree's own HEAD.
run_hook dod-affirm.sh "$EMPTY_EVENT" "$MAIN" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "fixed hook from main: main HEAD lacks DoD → blocks (still correct)"
run_hook dod-affirm.sh "$EMPTY_EVENT" "$WT"   "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "fixed hook from worktree: reads WORKTREE's HEAD (has DoD) → passes (false-block fixed)"

echo ""
# ---------------------------------------------------------------------------
echo "=== docs-check.sh ==="
# Baseline: OLD logic runs `git status` in main (clean) from worktree caller
# → false-allows a teammate that modified source without touching docs.
old_docs_check "$MAIN" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "old logic from main: clean tree → allows (correct baseline)"
old_docs_check "$WT"   "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "old logic from worktree: sees MAIN's clean status → allows (FALSE ALLOW — silent gate bypass)"

# Fixed hook: should run `git status` in the tree it's invoked from. The
# worktree has src2.txt uncommitted (source) and no doc touched in that
# uncommitted change → should block.
run_hook docs-check.sh "$EMPTY_EVENT" "$MAIN" "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 0 "$rc" "fixed hook from main: clean → allows"
run_hook docs-check.sh "$EMPTY_EVENT" "$WT"   "CLAUDE_PROJECT_DIR=$MAIN"; rc=$?
assert_eq 2 "$rc" "fixed hook from worktree: sees src2.txt uncommitted source-only → blocks (false-allow fixed)"

# docs-check fail-OPEN posture preserved: invoked outside any git tree
# should NOT block (it's a nudge, not a hard gate).
NONGIT="$(mktemp -d -t nongit.XXXXXX)"
run_hook docs-check.sh "$EMPTY_EVENT" "$NONGIT" "CLAUDE_PROJECT_DIR=$NONGIT"; rc=$?
assert_eq 0 "$rc" "fixed hook outside any git tree (fail-open preserved): allows → 0"
rm -rf "$NONGIT"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
