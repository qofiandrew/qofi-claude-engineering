#!/usr/bin/env bash
# test-swarm-checkpoint.sh — regression tests for bin/swarm-checkpoint.sh, the
# SWARM_CHECKPOINT_CMD adapter (commit + branch-push before a fleet rotation).
#
# SAFETY PROPERTY OF THIS TEST FILE. It NEVER pushes to a real remote and NEVER
# touches a real swarm repo. Every test builds a THROWAWAY git repo under a
# mktemp dir with `git init`, and uses a LOCAL BARE repo as the "remote" (origin).
# All git identity/refs are local to $TMP, cleaned on exit. No network, no creds.
#
# WHAT THIS PROTECTS (the safety envelope of the checkpoint adapter):
#   1. CLEAN TREE -> NO-OP: a repo with nothing to commit exits 0, creates no new
#      commit (idempotent). Re-running changes nothing.
#   2. DIRTY TREE -> COMMIT + PUSH: uncommitted work is committed and the swarm's
#      OWN branch is pushed to the local bare remote; the remote ref now matches.
#   3. NEVER main: a repo whose HEAD is `main` is REFUSED (exit 3) — no commit
#      lands on main, the remote main is NOT advanced.
#   4. NEVER dev (shared staging): HEAD `dev` is likewise refused.
#   5. NEVER --force: the push uses no force flag — proven by a divergent remote
#      that a checkpoint must NOT overwrite (push fails, exit 5, remote intact).
#   6. PROTECTED soft-skip: SWARM_CHECKPOINT_STRICT=0 turns the refusal into a
#      clean skip (exit 0) so one protected repo doesn't abort a fleet rotation.
#   7. DETACHED HEAD -> refuse/skip (no branch to checkpoint).
#   8. COMMIT-ONLY: SWARM_CHECKPOINT_PUSH=0 commits but does not push.
#   9. SEAM: swarm-rotate-style `sh -c "<hook>" _ <repo>` invocation works.
#  10. --no-verify: a repo pre-commit hook that would reject does NOT block the
#      crash-safety checkpoint.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-checkpoint.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CKPT="$ROOT/bin/swarm-checkpoint.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

command -v git >/dev/null 2>&1 || { echo "test-swarm-checkpoint: git not found — cannot run" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-checkpoint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: identity + config confined to $TMP so we never read/write the
# operator's ~/.gitconfig, and `git init` never trips on a missing user.name.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=ckpt-test GIT_AUTHOR_EMAIL=ckpt@test.local
export GIT_COMMITTER_NAME=ckpt-test GIT_COMMITTER_EMAIL=ckpt@test.local
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name  ckpt-test     >/dev/null 2>&1 || true
git config --global user.email ckpt@test.local >/dev/null 2>&1 || true
# Keep protocol.file unrestricted so file:// / bare-path pushes work under newer git.
git config --global protocol.file.allow always >/dev/null 2>&1 || true

# new_remote NAME -> path to a fresh local BARE repo (our stand-in "origin").
new_remote() {
  local p="$TMP/$1.git"
  git init --bare -q "$p"
  printf '%s' "$p"
}

# new_repo NAME BRANCH REMOTE -> a fresh work repo on BRANCH with one initial
# commit already PUSHED to REMOTE (so the bare remote has the branch to compare
# against). Echoes the repo path. Leaves the work tree CLEAN.
new_repo() {
  local name="$1" branch="$2" remote="$3" r="$TMP/$1"
  git init -q "$r"
  git -C "$r" checkout -q -b "$branch"
  printf 'seed\n' > "$r/seed.txt"
  git -C "$r" add -A
  git -C "$r" commit -q -m "seed"
  git -C "$r" remote add origin "$remote"
  git -C "$r" push -q -u origin "$branch" 2>/dev/null || true
  printf '%s' "$r"
}

# remote_sha REMOTE BRANCH -> the bare remote's tip sha for BRANCH (empty if none).
remote_sha() { git --git-dir="$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || true; }
local_sha()  { git -C "$1" rev-parse -q --verify HEAD 2>/dev/null || true; }
count_commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }

# run_ckpt REPO [ARGS/ENV...] — invoke the checkpoint script on REPO and capture
# $OUT + $rc. Extra leading `VAR=val` pairs (before the repo) are exported into
# the subshell so per-test seams (remote/strict/push) are easy to set.
run_ckpt() {
  local repo="$1"; shift
  OUT="$(bash "$CKPT" "$repo" "$@" 2>&1)"; rc=$?
}

# ---------------------------------------------------------------------------
echo "=== 1) CLEAN TREE -> no-op, exit 0, no new commit ==="
REMOTE1="$(new_remote remote1)"
REPO1="$(new_repo repo1 worktree-feat "$REMOTE1")"
before="$(count_commits "$REPO1")"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO1" 2>&1)"; rc=$?
assert_eq 0 "$rc" "clean tree -> exit 0"
assert_has "$OUT" "clean working tree" "announces the clean no-op"
assert_eq "$before" "$(count_commits "$REPO1")" "clean tree creates NO new commit"

# ---------------------------------------------------------------------------
echo "=== 2) DIRTY TREE -> commit + push own branch to the bare remote ==="
REMOTE2="$(new_remote remote2)"
REPO2="$(new_repo repo2 worktree-feat "$REMOTE2")"
printf 'work in progress\n' > "$REPO2/wip.txt"          # untracked
printf 'changed\n' >> "$REPO2/seed.txt"                 # modified tracked
before="$(count_commits "$REPO2")"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO2" 2>&1)"; rc=$?
assert_eq 0 "$rc" "dirty tree -> exit 0"
assert_has "$OUT" "committed:" "reports a commit"
assert_has "$OUT" "pushed:" "reports a push"
after="$(count_commits "$REPO2")"
[ "$after" -gt "$before" ] && ok "dirty tree created a new commit" || bad "no new commit on dirty tree (before=$before after=$after)"
# Untracked file got committed (clean tree afterward).
assert_eq "" "$(git -C "$REPO2" status --porcelain)" "working tree is clean after checkpoint"
# The remote's worktree-feat now equals the local HEAD.
assert_eq "$(local_sha "$REPO2")" "$(remote_sha "$REMOTE2" worktree-feat)" "remote worktree-feat == local HEAD after push"

echo "--- 2b) re-run is idempotent: clean now, no-op ---"
again_before="$(count_commits "$REPO2")"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO2" 2>&1)"; rc=$?
assert_eq 0 "$rc" "second run -> exit 0"
assert_eq "$again_before" "$(count_commits "$REPO2")" "second run adds no commit (idempotent)"

# ---------------------------------------------------------------------------
echo "=== 3) NEVER main: HEAD=main is REFUSED (exit 3), main NOT advanced ==="
REMOTE3="$(new_remote remote3)"
REPO3="$(new_repo repo3 main "$REMOTE3")"
main_remote_before="$(remote_sha "$REMOTE3" main)"
main_local_before="$(local_sha "$REPO3")"
printf 'must not be committed to main\n' > "$REPO3/danger.txt"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO3" 2>&1)"; rc=$?
assert_eq 3 "$rc" "HEAD=main -> REFUSED (exit 3)"
assert_has "$OUT" "protected branch 'main'" "names main as the protected branch"
assert_eq "$main_local_before" "$(local_sha "$REPO3")" "no commit landed on main (local HEAD unchanged)"
assert_eq "$main_remote_before" "$(remote_sha "$REMOTE3" main)" "remote main NOT advanced"
assert_has "$(git -C "$REPO3" status --porcelain)" "danger.txt" "the dirty file is still uncommitted on main"

echo "--- 3b) NEVER dev (shared staging): HEAD=dev refused too ---"
REMOTE3b="$(new_remote remote3b)"
REPO3b="$(new_repo repo3b dev "$REMOTE3b")"
printf 'x\n' > "$REPO3b/x.txt"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO3b" 2>&1)"; rc=$?
assert_eq 3 "$rc" "HEAD=dev -> REFUSED (exit 3)"
assert_has "$OUT" "protected branch 'dev'" "names dev as protected"

# ---------------------------------------------------------------------------
echo "=== 4) NEVER --force: a divergent remote is NOT overwritten (exit 5) ==="
# Set the remote's branch tip to an UNRELATED history so a plain push is a
# non-fast-forward. A checkpoint must NOT --force past that; it must fail and
# leave the remote history intact.
REMOTE4="$(new_remote remote4)"
REPO4="$(new_repo repo4 worktree-feat "$REMOTE4")"
# Diverge the remote: clone the bare, add an extra commit, push it so remote tip
# moves ahead of REPO4's knowledge.
OTHER="$TMP/other4"
git clone -q "$REMOTE4" "$OTHER" 2>/dev/null   # cosmetic 'nonexistent HEAD' warn (bare default branch absent)
git -C "$OTHER" checkout -q worktree-feat
printf 'remote-only\n' > "$OTHER/remote-only.txt"
git -C "$OTHER" add -A && git -C "$OTHER" commit -q -m "remote diverges"
git -C "$OTHER" push -q origin worktree-feat
remote_tip_before="$(remote_sha "$REMOTE4" worktree-feat)"
# Now make REPO4 dirty and checkpoint — its push should be a non-ff and FAIL
# (no force). The work is committed locally; the remote is untouched.
printf 'local wip\n' > "$REPO4/local.txt"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO4" 2>&1)"; rc=$?
assert_eq 5 "$rc" "non-ff push without --force -> exit 5"
assert_has "$OUT" "push FAILED" "reports the push failure"
assert_has "$OUT" "committed locally" "notes the work IS committed locally"
assert_eq "$remote_tip_before" "$(remote_sha "$REMOTE4" worktree-feat)" "remote history INTACT (not force-overwritten)"
# Hard proof no force flag is reachable: strip comments (everything from the first
# '#'), then assert no remaining CODE line carries a git force/destructive push.
# (Comment text like "No --force, ever" must not trip this — only executable code.)
if sed 's/#.*$//' "$CKPT" | grep -nE 'git[^|&;]*push[^|&;]*(--force|--force-with-lease|--force-if-includes|--mirror|--all|[[:space:]]-f([[:space:]]|u|$))' >/dev/null 2>&1; then
  bad "checkpoint script must never reference a force/destructive push in code"
else
  ok "checkpoint script contains NO force-push form in code"
fi

# ---------------------------------------------------------------------------
echo "=== 5) PROTECTED soft-skip: STRICT=0 turns refusal into a clean skip (exit 0) ==="
REMOTE5="$(new_remote remote5)"
REPO5="$(new_repo repo5 main "$REMOTE5")"
# new_repo already pushed the seed main; capture that tip so we can prove the
# checkpoint does not ADVANCE it (the soft-skip must add no commit to main).
main_tip5="$(remote_sha "$REMOTE5" main)"
printf 'y\n' > "$REPO5/y.txt"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin SWARM_CHECKPOINT_STRICT=0 bash "$CKPT" "$REPO5" 2>&1)"; rc=$?
assert_eq 0 "$rc" "protected branch + STRICT=0 -> clean skip (exit 0)"
assert_has "$OUT" "skipping" "announces the clean skip"
assert_eq "$main_tip5" "$(remote_sha "$REMOTE5" main)" "remote main NOT advanced on soft-skip (no checkpoint push to main)"
assert_has "$(git -C "$REPO5" status --porcelain)" "y.txt" "the dirty file stays uncommitted (nothing saved onto main)"

# ---------------------------------------------------------------------------
echo "=== 6) DETACHED HEAD -> refuse (exit 3) / soft-skip ==="
REMOTE6="$(new_remote remote6)"
REPO6="$(new_repo repo6 worktree-feat "$REMOTE6")"
# Add a second commit then detach onto the first.
printf 'second\n' > "$REPO6/second.txt"; git -C "$REPO6" add -A; git -C "$REPO6" commit -q -m second
first_sha="$(git -C "$REPO6" rev-list --max-parents=0 HEAD | head -n1)"
git -C "$REPO6" checkout -q "$first_sha"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO6" 2>&1)"; rc=$?
assert_eq 3 "$rc" "detached HEAD -> REFUSED (exit 3)"
assert_has "$OUT" "DETACHED HEAD" "names the detached-HEAD condition"

# ---------------------------------------------------------------------------
echo "=== 7) COMMIT-ONLY: SWARM_CHECKPOINT_PUSH=0 commits but does not push ==="
REMOTE7="$(new_remote remote7)"
REPO7="$(new_repo repo7 worktree-feat "$REMOTE7")"
remote_before="$(remote_sha "$REMOTE7" worktree-feat)"
printf 'wip\n' > "$REPO7/wip.txt"
OUT="$(SWARM_CHECKPOINT_PUSH=0 bash "$CKPT" "$REPO7" 2>&1)"; rc=$?
assert_eq 0 "$rc" "commit-only -> exit 0"
assert_has "$OUT" "committed:" "commit-only still commits"
assert_has "$OUT" "not pushing" "announces it is not pushing"
assert_eq "$remote_before" "$(remote_sha "$REMOTE7" worktree-feat)" "remote NOT advanced when push disabled"

# ---------------------------------------------------------------------------
echo "=== 8) SEAM: swarm-rotate-style 'sh -c \"<hook>\" _ <repo>' invocation ==="
# swarm-rotate runs: sh -c "$SWARM_CHECKPOINT_CMD" _ "$repo"  — so the repo lands
# in $1. The documented wiring is SWARM_CHECKPOINT_CMD='swarm-checkpoint.sh "$1"'.
REMOTE8="$(new_remote remote8)"
REPO8="$(new_repo repo8 worktree-feat "$REMOTE8")"
printf 'seam wip\n' > "$REPO8/wip.txt"
HOOK="$CKPT \"\$1\""
OUT="$(SWARM_CHECKPOINT_REMOTE=origin sh -c "$HOOK" _ "$REPO8" 2>&1)"; rc=$?
assert_eq 0 "$rc" "rotate-style invocation -> exit 0"
assert_has "$OUT" "pushed:" "rotate-style invocation commits + pushes the repo from \$1"
assert_eq "$(local_sha "$REPO8")" "$(remote_sha "$REMOTE8" worktree-feat)" "remote matches local after seam invocation"

# ---------------------------------------------------------------------------
echo "=== 9) --no-verify: a rejecting pre-commit hook does NOT block the checkpoint ==="
REMOTE9="$(new_remote remote9)"
REPO9="$(new_repo repo9 worktree-feat "$REMOTE9")"
# Install a pre-commit hook that ALWAYS fails. A normal commit would be blocked;
# the checkpoint (a crash-safety SAVE) uses --no-verify and must still commit.
# Absolute hooks dir of the TEMP repo — `--git-path hooks` returns a relative
# `.git/hooks` that would resolve against the test's CWD (the real repo) and
# clobber the live hook; `--absolute-git-dir` pins it inside REPO9.
HOOKDIR="$(git -C "$REPO9" rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKDIR"
cat > "$HOOKDIR/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "pre-commit: BLOCK" >&2
exit 1
EOF
chmod +x "$HOOKDIR/pre-commit"
printf 'urgent wip\n' > "$REPO9/wip.txt"
OUT="$(SWARM_CHECKPOINT_REMOTE=origin bash "$CKPT" "$REPO9" 2>&1)"; rc=$?
assert_eq 0 "$rc" "checkpoint commits despite a rejecting pre-commit hook (--no-verify)"
assert_has "$OUT" "committed:" "the save still landed"

# ---------------------------------------------------------------------------
echo "=== 10) usage guards: missing repo / non-git dir -> exit 2 ==="
OUT="$(bash "$CKPT" 2>&1)"; rc=$?
assert_eq 2 "$rc" "no repo given -> exit 2"
PLAINDIR="$TMP/not-a-repo"; mkdir -p "$PLAINDIR"
OUT="$(bash "$CKPT" "$PLAINDIR" 2>&1)"; rc=$?
assert_eq 2 "$rc" "non-git directory -> exit 2"
assert_has "$OUT" "not a git work tree" "explains the non-git refusal"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
