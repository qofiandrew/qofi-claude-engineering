#!/usr/bin/env bash
# test-operator-owned-protection.sh — guarantees the `operator-owned` manifest
# class actually protects operator-authored content from being overwritten,
# touched, or accidentally committed by a teammate.
#
# This is the load-bearing test for the cpo product-vision.md use case. If
# any assertion here regresses, an operator's product vision (or any future
# operator-owned content) could be silently destroyed by swarm-init --force
# or auto-staged into a sync/teammate commit.
#
# Assertions:
#   (a) init seeds the operator-owned file when absent
#   (b) swarm-init --force on a present file leaves it BYTE-UNCHANGED
#       (the critical difference from `seed`, which DOES re-seed on --force)
#   (c) swarm-sync (even with --force past the dirty-tree refusal) leaves
#       the file BYTE-UNCHANGED and never auto-stages it
#   (d) the auto-stamped .claude/operator-owned-paths list matches the
#       manifest's operator-owned entries
#   (e) removing operator-owned entries from the manifest causes the list
#       to be deleted on next apply (no stale block-list)
#   (f) the pre-commit hook (Layer 3) blocks a teammate-worktree commit
#       that stages an operator-owned path
#
# Strategy: isolated SWARM_HOME (mktemp) with a minimal test archetype that
# contains a single operator-owned entry. No pollution of the real
# templates/engineering-cto/ manifest.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
note() { printf '  %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }
pass() { printf '  ok   %s\n' "$*"; }

FAKE_HOME=""
REPO=""
cleanup() {
  [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
  [ -n "$REPO" ]      && rm -rf "$REPO"
}
trap cleanup EXIT INT TERM

FAKE_HOME="$(mktemp -d -t swarm-test-oo-home.XXXXXX)" || { echo "mktemp FAKE_HOME failed"; exit 1; }
REPO="$(mktemp -d -t swarm-test-oo-repo.XXXXXX)"      || { echo "mktemp REPO failed";      exit 1; }

# ---------------------------------------------------------------------------
# Fake SWARM_HOME with a minimal `test-oo` archetype.
# Only operator-owned + a no-op gitignore line (manifest_apply requires
# behaviors actually exist; gitignore is the lightest "real" entry).
# ---------------------------------------------------------------------------
mkdir -p "$FAKE_HOME/templates/test-oo"
touch "$FAKE_HOME/swarm.conf"

cat > "$FAKE_HOME/templates/test-oo/manifest.tsv" <<'EOF'
# minimal test archetype for operator-owned protection
operator-owned | test-oo/vision-template.md | docs/product-vision.md
gitignore      | .claude/worktrees/         | .gitignore
EOF

cat > "$FAKE_HOME/templates/test-oo/vision-template.md" <<'EOF'
# Product Vision (operator authors this)
Placeholder seeded by swarm-init. The operator replaces this body.
EOF

# ---------------------------------------------------------------------------
# Test repo: a real git working tree stamped as type=test-oo.
# ---------------------------------------------------------------------------
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"
mkdir -p "$REPO/.claude"
echo test-oo > "$REPO/.claude/swarm-type"

export SWARM_HOME="$FAKE_HOME"

# Source the lib so we can drive manifest_apply directly. (swarm-init also
# runs it, but driving the lib means the test is independent of swarm-init's
# wrapper logic and works with the same primitives in the lib.)
# shellcheck source=/dev/null
. "$ROOT/bin/swarm-lib.sh"

echo "==> (a) init seeds operator-owned file when absent"
manifest_apply "$REPO" init >/dev/null
if [ -f "$REPO/docs/product-vision.md" ]; then
  pass "docs/product-vision.md seeded by init"
else
  fail "docs/product-vision.md NOT seeded by init"
fi

# Commit the seed so subsequent dirty-tree detection works correctly.
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "initial seed"

# Operator modifies the seeded file.
echo "" >> "$REPO/docs/product-vision.md"
echo "## My real vision (operator edit)" >> "$REPO/docs/product-vision.md"
echo "This MUST survive any swarm operation." >> "$REPO/docs/product-vision.md"

ORIG_SHA="$(shasum "$REPO/docs/product-vision.md" | awk '{print $1}')"

# ---------------------------------------------------------------------------
echo ""
echo "==> (b) swarm-init --force does NOT clobber operator-owned content"

# SWARM_FORCE_SEED=1 is exactly what swarm-init.sh --force sets. If the
# operator-owned helper honored SWARM_FORCE_SEED (the way `seed` does), the
# file would be replaced here — that is the regression this test exists to
# catch.
SWARM_FORCE_SEED=1 manifest_apply "$REPO" init >/dev/null
NEW_SHA="$(shasum "$REPO/docs/product-vision.md" | awk '{print $1}')"
if [ "$ORIG_SHA" = "$NEW_SHA" ]; then
  pass "file byte-unchanged after manifest_apply init with SWARM_FORCE_SEED=1"
else
  fail "file CHANGED after --force re-seed (regression: operator content clobbered)"
fi
unset SWARM_FORCE_SEED

# ---------------------------------------------------------------------------
echo ""
echo "==> (c) sync does NOT touch operator-owned content AND does NOT auto-stage it"

# manifest_apply sync (the lib-level call sync would make).
manifest_apply "$REPO" sync >/dev/null
NEW_SHA="$(shasum "$REPO/docs/product-vision.md" | awk '{print $1}')"
if [ "$ORIG_SHA" = "$NEW_SHA" ]; then
  pass "file byte-unchanged after manifest_apply sync"
else
  fail "file CHANGED after sync (regression: sync touched operator content)"
fi

# Now drive swarm-sync.sh end-to-end with --force (proceed despite dirty
# operator-owned edit). It must commit anything legitimate but never stage
# the operator-owned file.
if git -C "$REPO" status --porcelain | grep -q '^.M docs/product-vision.md'; then
  pass "operator-owned file is dirty before sync (test precondition)"
else
  fail "expected operator-owned file to be dirty before sync"
fi

"$ROOT/bin/swarm-sync.sh" "$REPO" --force >/tmp/swarm-sync-oo.out 2>&1
SYNC_RC=$?
if [ "$SYNC_RC" -ne 0 ]; then
  fail "swarm-sync exited with rc=$SYNC_RC (see /tmp/swarm-sync-oo.out)"
fi

# File must still be dirty (proves it was not auto-staged + committed).
if git -C "$REPO" status --porcelain | grep -q '^.M docs/product-vision.md'; then
  pass "operator-owned file is STILL dirty after swarm-sync (proves not staged + not committed)"
else
  fail "operator-owned file no longer dirty after swarm-sync (regression: sync swept it up)"
fi

# Sha still matches the operator's edit.
NEW_SHA="$(shasum "$REPO/docs/product-vision.md" | awk '{print $1}')"
if [ "$ORIG_SHA" = "$NEW_SHA" ]; then
  pass "file byte-unchanged after swarm-sync --force"
else
  fail "file content changed after swarm-sync --force"
fi

# Verify the file does not appear in any commit made by sync. The sync
# commit message format is `sync swarm system from manifest @ ...`.
SYNC_TOUCHED="$(git -C "$REPO" log --all --grep='sync swarm system from manifest' --name-only --pretty=format:'' 2>/dev/null | grep -xF 'docs/product-vision.md' || true)"
if [ -z "$SYNC_TOUCHED" ]; then
  pass "no sync commit touched docs/product-vision.md"
else
  fail "a sync commit included docs/product-vision.md"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> (d) .claude/operator-owned-paths is stamped + matches the manifest"

if [ -f "$REPO/.claude/operator-owned-paths" ]; then
  pass "operator-owned-paths list exists"
else
  fail "operator-owned-paths list MISSING"
fi
EXPECT="docs/product-vision.md"
ACTUAL="$(cat "$REPO/.claude/operator-owned-paths" 2>/dev/null)"
if [ "$ACTUAL" = "$EXPECT" ]; then
  pass "operator-owned-paths content == $EXPECT"
else
  fail "operator-owned-paths content mismatch: got '$ACTUAL', want '$EXPECT'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> (e) removing the manifest's operator-owned entry deletes the list"

cat > "$FAKE_HOME/templates/test-oo/manifest.tsv" <<'EOF'
# no operator-owned entries left
gitignore | .claude/worktrees/ | .gitignore
EOF
manifest_apply "$REPO" sync >/dev/null
if [ -f "$REPO/.claude/operator-owned-paths" ]; then
  fail "operator-owned-paths still present after manifest no longer references it"
else
  pass "operator-owned-paths removed on next apply (no stale block-list)"
fi

# Restore the entry for the staging-exclusion test below.
cat > "$FAKE_HOME/templates/test-oo/manifest.tsv" <<'EOF'
operator-owned | test-oo/vision-template.md | docs/product-vision.md
gitignore      | .claude/worktrees/         | .gitignore
EOF
manifest_apply "$REPO" sync >/dev/null
git -C "$REPO" add .claude/operator-owned-paths 2>/dev/null
git -C "$REPO" commit -q -m "restamp operator-owned-paths" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo ""
echo "==> (f) pre-commit hook blocks operator-owned commits from a teammate worktree"

# Install the standard pre-commit hook (the test archetype doesn't include
# a git-hook entry; copy it directly from the engineering-cto template since
# Layer 3 logic is the unit under test).
mkdir -p "$REPO/.git/hooks"
cp "$ROOT/templates/engineering-cto/git-hooks/pre-commit" "$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"

# Create a teammate worktree at .claude/worktrees/<name> — the exact pattern
# the hook detects.
WT_NAME="alice"
WT_PATH="$REPO/.claude/worktrees/$WT_NAME"
git -C "$REPO" worktree add -q -b "worktree-$WT_NAME" "$WT_PATH" >/dev/null 2>&1 || {
  fail "could not create teammate worktree (skipping Layer 3 test)"
  WT_PATH=""
}

if [ -n "$WT_PATH" ]; then
  # Sanity: the worktree should contain the operator-owned-paths list (it's
  # a tracked file — git checks it out automatically).
  if [ -f "$WT_PATH/.claude/operator-owned-paths" ]; then
    pass "teammate worktree has .claude/operator-owned-paths (tracked file)"
  else
    fail "teammate worktree missing .claude/operator-owned-paths"
  fi

  # Teammate edits the operator-owned file (the scenario we're protecting
  # against — an agent sweeping a fix-everything change that touches it).
  # Pair with a doc edit so Layer 1 (docs-touched) is satisfied.
  echo "# unauthorized teammate edit" >> "$WT_PATH/docs/product-vision.md"
  git -C "$WT_PATH" add docs/product-vision.md
  # Layer 1 (docs-touched) is satisfied trivially: product-vision.md is itself
  # a .md file, so Layer 1 sees a doc staged.

  HOOK_OUT="$(git -C "$WT_PATH" commit -m "teammate touches operator vision" 2>&1)"
  HOOK_RC=$?
  if [ "$HOOK_RC" -ne 0 ] && printf '%s' "$HOOK_OUT" | grep -q 'operator-owned content'; then
    pass "pre-commit hook BLOCKED teammate-worktree commit of operator-owned file"
  else
    fail "pre-commit hook did NOT block teammate commit (rc=$HOOK_RC, out=$HOOK_OUT)"
  fi

  # Defense for the inverse: commits OUTSIDE teammate worktrees must still
  # work (the operator/CTO own the main tree and can update operator content).
  git -C "$WT_PATH" restore --staged docs/product-vision.md 2>/dev/null
  git -C "$WT_PATH" checkout -- docs/product-vision.md 2>/dev/null

  echo "# operator's own edit from main tree" >> "$REPO/docs/product-vision.md"
  git -C "$REPO" add docs/product-vision.md
  if git -C "$REPO" commit -q -m "operator edits vision from main tree" 2>/dev/null; then
    pass "main-tree commits of operator-owned content are NOT blocked"
  else
    fail "main-tree commit of operator-owned content was blocked (false positive)"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL ($FAIL failure(s))"
  exit 1
fi
echo "OK"
