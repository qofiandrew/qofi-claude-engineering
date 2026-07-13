#!/usr/bin/env bash
# test-swarm-sync-operator-owned-dirty.sh — swarm-sync.sh's dirty-tree refusal is
# OPERATOR-OWNED-AWARE (ADR-0018 follow-up).
#
# THE BUG THIS GUARDS: the CPO continuously writes product specs into products/
# (operator-owned), so its tree is near-always dirty. The old refusal blocked ANY
# non-empty `git status`, so every routine sync refused it and it silently stayed
# on STALE doctrine. But manifest_apply SKIPS operator-owned in sync mode and the
# commit set EXCLUDES it — so the refusal blocked a sync that provably wouldn't
# touch the dirty files.
#
# ASSERTIONS:
#   UNIT (swarm_dirty_classify_oo + _swarm_load_oo_from_list):
#     - dirty ONLY under products/  -> classified all-operator-owned (rc 0, no foreign)
#     - dirty on a managed doctrine file -> foreign reported (rc 1)
#     - missing operator-owned-paths list -> empty set -> dirt is foreign (fail-safe)
#   INTEGRATION (swarm-sync.sh end-to-end):
#     (A) dirty ONLY under products/ -> PROCEEDS (no REFUSED), syncs the doctrine,
#         and NEVER stages/commits the products/ dirt
#     (A2) already-staged products/ work remains staged and outside the sync commit
#     (A3) configured sync retains the lifecycle lock through its Git commit
#     (A4) the real engineering manifest's untracked .git hook is not a commit pathspec
#     (B) dirty on a managed doctrine file -> still REFUSES, commits nothing
#     (C) --force still overrides a managed-path dirty refusal
#
# Strategy: isolated SWARM_HOME (mktemp) with a minimal `test-oo` archetype — a
# refresh-class doctrine file (managed) + a products/ operator-owned subtree.
# No pollution of the real templates.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-sync-operator-owned-dirty.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 (found [$2])"; else pass "$3"; fi; }

FAKE_HOME="$(mktemp -d -t swarm-oo-dirty-home.XXXXXX)" || exit 1
REPO="$(mktemp -d -t swarm-oo-dirty-repo.XXXXXX)"      || exit 1
trap 'rm -rf "$FAKE_HOME" "$REPO"' EXIT INT TERM

# --- minimal test-oo archetype: a managed doctrine file + a products/ subtree ---
mkdir -p "$FAKE_HOME/templates/test-oo"
touch "$FAKE_HOME/swarm.conf"
cat > "$FAKE_HOME/templates/test-oo/manifest.tsv" <<'EOF'
refresh        | test-oo/doc.md       | DOC.md
operator-owned | test-oo/products-keep | products/.keep
gitignore      | .claude/worktrees/   | .gitignore
EOF
printf 'DOCTRINE v1\n' > "$FAKE_HOME/templates/test-oo/doc.md"
printf 'products/ is operator-owned (subtree).\n' > "$FAKE_HOME/templates/test-oo/products-keep"

# --- test repo stamped type=test-oo, seeded + committed clean ---
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"
mkdir -p "$REPO/.claude"
echo test-oo > "$REPO/.claude/swarm-type"
export SWARM_HOME="$FAKE_HOME"
# shellcheck source=/dev/null
. "$ROOT/bin/swarm-lib.sh"
manifest_apply "$REPO" init >/dev/null
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "seed (baseline clean)"

reset_repo() { git -C "$REPO" checkout -q -- . 2>/dev/null; git -C "$REPO" clean -qfd >/dev/null 2>&1; }

# ===========================================================================
echo "=== UNIT: swarm_dirty_classify_oo ==="
# operator-owned-paths stamped by init should be exactly 'products/'
OO_LIST="$(cat "$REPO/.claude/operator-owned-paths" 2>/dev/null)"
assert_eq "products/" "$OO_LIST" "init stamped operator-owned-paths = products/"

_swarm_load_oo_from_list "$REPO"
assert_has " $SWARM_OO_PREFIXES" "products/" "loader populated SWARM_OO_PREFIXES with products/"

# dirty ONLY under products/ (untracked operator work) -> all operator-owned
mkdir -p "$REPO/products/alpha"; printf 'spec\n' > "$REPO/products/alpha/spec.md"
out="$(swarm_dirty_classify_oo "$REPO")"; rc=$?
assert_eq "0" "$rc" "classify rc=0 when dirt is products/-only"
assert_eq "" "$out" "classify reports NO foreign paths for products/-only dirt"

# additionally dirty a managed doctrine file -> foreign reported
printf 'local edit\n' >> "$REPO/DOC.md"
_swarm_load_oo_from_list "$REPO"
out="$(swarm_dirty_classify_oo "$REPO")"; rc=$?
assert_eq "1" "$rc" "classify rc=1 when a managed file is dirty"
assert_has "$out" "DOC.md" "classify reports DOC.md as foreign (sync-managed)"
assert_lacks "$out" "products/alpha/spec.md" "classify does NOT report the products/ dirt as foreign"
reset_repo

# fail-safe: no operator-owned-paths list -> empty set -> products/ dirt is foreign
mv "$REPO/.claude/operator-owned-paths" "$REPO/.claude/operator-owned-paths.bak"
mkdir -p "$REPO/products/beta"; printf 'x\n' > "$REPO/products/beta/spec.md"
_swarm_load_oo_from_list "$REPO"
out="$(swarm_dirty_classify_oo "$REPO")"; rc=$?
assert_eq "1" "$rc" "fail-safe: missing OO list -> rc=1 (refuse) even for products/ dirt"
# (porcelain collapses a wholly-untracked dir to 'products/beta/')
assert_has "$out" "products/beta" "fail-safe: products/ dirt is foreign when OO list absent"
mv "$REPO/.claude/operator-owned-paths.bak" "$REPO/.claude/operator-owned-paths"
reset_repo

# ===========================================================================
echo ""
echo "=== INTEGRATION (A): dirty ONLY under products/ -> sync PROCEEDS, products/ untouched ==="
# Make the managed doctrine drift (bump the template) so sync has real work.
printf 'DOCTRINE v2 (bumped)\n' > "$FAKE_HOME/templates/test-oo/doc.md"
# Operator dirt under products/, BOTH porcelain forms:
#   - a TRACKED modified file (full path:  ' M products/.keep')
#   - a wholly-untracked dir (collapsed:   '?? products/gamma/')
printf 'operator edit to the keep\n' >> "$REPO/products/.keep"
KEEP_SHA_BEFORE="$(shasum "$REPO/products/.keep" | awk '{print $1}')"
mkdir -p "$REPO/products/gamma"; printf 'operator spec body\n' > "$REPO/products/gamma/spec.md"
PRODUCT_SHA_BEFORE="$(shasum "$REPO/products/gamma/spec.md" | awk '{print $1}')"

OUT="$("$ROOT/bin/swarm-sync.sh" "$REPO" 2>&1)"; RC=$?
assert_eq "0" "$RC" "swarm-sync exit 0 on products/-only dirt (tracked + untracked)"
assert_lacks "$OUT" "REFUSED" "did NOT refuse a products/-only dirty tree"
assert_has  "$OUT" "ONLY under operator-owned paths" "printed the operator-owned proceed NOTE"
# doctrine got synced:
assert_eq "DOCTRINE v2 (bumped)" "$(cat "$REPO/DOC.md")" "DOC.md synced to the bumped template (doctrine refreshed)"
# products/ dirt NEVER staged or committed (still showing as dirty after sync):
if git -C "$REPO" status --porcelain | grep -q 'products/gamma'; then
  pass "untracked products/gamma/ is STILL dirty (not staged/committed by sync)"
else
  fail "products/gamma/ vanished from status (sync swept it up)"
fi
if git -C "$REPO" status --porcelain | grep -q 'products/.keep'; then
  pass "tracked products/.keep edit is STILL dirty (not staged/committed by sync)"
else
  fail "products/.keep no longer dirty (sync swept up a tracked operator-owned edit)"
fi
assert_eq "$PRODUCT_SHA_BEFORE" "$(shasum "$REPO/products/gamma/spec.md" | awk '{print $1}')" "untracked products/ file byte-unchanged"
assert_eq "$KEEP_SHA_BEFORE" "$(shasum "$REPO/products/.keep" | awk '{print $1}')" "tracked products/.keep byte-unchanged"
SYNC_TOUCHED_PROD="$(git -C "$REPO" log -1 --name-only --pretty=format:'' 2>/dev/null | grep -c '^products/' || true)"
assert_eq "0" "$SYNC_TOUCHED_PROD" "the sync commit contains NO products/ files"
assert_has "$(git -C "$REPO" log -1 --name-only --pretty=format:'')" "DOC.md" "the sync commit DID include the doctrine file DOC.md"
rm -rf "$REPO/products/gamma"; reset_repo

echo ""
echo "=== INTEGRATION (A2): pre-staged operator work stays staged and uncommitted ==="
printf 'DOCTRINE v2.1 (bumped)\n' > "$FAKE_HOME/templates/test-oo/doc.md"
printf 'pre-staged operator edit\n' >> "$REPO/products/.keep"
git -C "$REPO" add -- products/.keep
OPERATOR_INDEX_BEFORE="$(git -C "$REPO" show :products/.keep)"
OUT="$("$ROOT/bin/swarm-sync.sh" "$REPO" 2>&1)"; RC=$?
assert_eq "0" "$RC" "sync succeeds with pre-staged operator-owned work"
assert_eq "DOCTRINE v2.1 (bumped)" "$(cat "$REPO/DOC.md")" "managed doctrine still syncs beside a staged operator edit"
assert_lacks "$(git -C "$REPO" log -1 --name-only --pretty=format:'')" "products/.keep" "sync commit excludes the pre-staged operator path"
assert_has "$(git -C "$REPO" diff --cached --name-only)" "products/.keep" "pre-staged operator path remains staged after sync"
assert_eq "$OPERATOR_INDEX_BEFORE" "$(git -C "$REPO" show :products/.keep)" "operator index bytes are preserved"
assert_lacks "$(git -C "$REPO" show HEAD:products/.keep)" "pre-staged operator edit" "sync HEAD retains the prior operator-owned content"
git -C "$REPO" reset --hard -q HEAD

echo ""
echo "=== INTEGRATION (A3): configured sync holds lifecycle lock through commit ==="
printf 'DOCTRINE v2.2 (bumped)\n' > "$FAKE_HOME/templates/test-oo/doc.md"
printf 'oo-row | %s | BOT_OO | 123 | | | claude\n' "$REPO" > "$FAKE_HOME/swarm.conf"
LOCK_MARKER="$FAKE_HOME/lock-observed"
mkdir -p "$REPO/.git/hooks"
cat > "$REPO/.git/hooks/pre-commit" <<EOF
#!/bin/sh
[ -d '$FAKE_HOME/swarm.conf.mutation.lock' ] || exit 42
: > '$LOCK_MARKER'
EOF
chmod +x "$REPO/.git/hooks/pre-commit"
OUT="$("$ROOT/bin/swarm-sync.sh" oo-row 2>&1)"; RC=$?
assert_eq "0" "$RC" "configured sync commits while holding the lifecycle lock"
if [ -f "$LOCK_MARKER" ]; then
  pass "pre-commit observed the lifecycle lock"
else
  fail "pre-commit did not observe the lifecycle lock"
fi
assert_eq "DOCTRINE v2.2 (bumped)" "$(cat "$REPO/DOC.md")" "configured sync committed the intended managed surface"
rm -f "$REPO/.git/hooks/pre-commit" "$LOCK_MARKER"

echo ""
echo "=== INTEGRATION (A4): real engineering git-hook target stays outside commit pathset ==="
ENG_REPO="$FAKE_HOME/engineering-manifest-repo"
mkdir -p "$ENG_REPO"
git -C "$ENG_REPO" init -q
git -C "$ENG_REPO" config user.email "test@example.com"
git -C "$ENG_REPO" config user.name "Test"
SWARM_HOME="$ROOT" "$ROOT/bin/swarm-init.sh" "$ENG_REPO" --type engineering-cto >/dev/null 2>&1
git -C "$ENG_REPO" add -A && git -C "$ENG_REPO" commit -q -m "engineering baseline"
printf 'intentionally stale doctrine\n' > "$ENG_REPO/CLAUDE.md"
git -C "$ENG_REPO" add CLAUDE.md && git -C "$ENG_REPO" commit -q -m "make doctrine stale"
OUT="$(SWARM_HOME="$ROOT" "$ROOT/bin/swarm-sync.sh" "$ENG_REPO" 2>&1)"; RC=$?
assert_eq "0" "$RC" "real engineering manifest sync commits successfully"
assert_has "$OUT" "committed:" "engineering sync reports its managed commit"
assert_lacks "$(git -C "$ENG_REPO" log -1 --name-only --pretty=format:'')" ".git/hooks/pre-commit" "untracked managed Git hook is excluded from commit pathspec"
if [ -x "$ENG_REPO/.git/hooks/pre-commit" ]; then
  pass "engineering managed pre-commit hook remains installed"
else
  fail "engineering managed pre-commit hook is missing"
fi

# ===========================================================================
echo ""
echo "=== INTEGRATION (B): dirty on a MANAGED doctrine file -> still REFUSES ==="
printf 'DOCTRINE v3 (bumped again)\n' > "$FAKE_HOME/templates/test-oo/doc.md"
printf 'uncommitted local edit to a managed file\n' >> "$REPO/DOC.md"
DOC_SHA_BEFORE="$(shasum "$REPO/DOC.md" | awk '{print $1}')"
OUT="$("$ROOT/bin/swarm-sync.sh" "$REPO" 2>&1)"; RC=$?
assert_has  "$OUT" "REFUSED" "refused: a managed doctrine file is dirty"
assert_has  "$OUT" "DOC.md" "the refusal names the sync-managed dirty path"
assert_eq "$DOC_SHA_BEFORE" "$(shasum "$REPO/DOC.md" | awk '{print $1}')" "DOC.md byte-unchanged (sync did not run/commit)"
if git -C "$REPO" status --porcelain | grep -q 'DOC.md'; then
  pass "DOC.md still dirty after refusal (nothing committed)"
else
  fail "DOC.md no longer dirty (sync ran despite the managed-file dirt)"
fi

echo ""
echo "=== INTEGRATION (C): --force still overrides a managed-path dirty ==="
OUT="$("$ROOT/bin/swarm-sync.sh" "$REPO" --force 2>&1)"; RC=$?
assert_lacks "$OUT" "REFUSED" "--force bypassed the managed-path dirty refusal"
assert_has  "$OUT" "proceeding anyway (--force)" "--force printed the override warning"
reset_repo

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
