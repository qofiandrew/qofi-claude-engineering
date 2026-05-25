#!/usr/bin/env bash
# test-swarm-type-dispatch.sh — guarantees the swarm-type marker + --type
# flag actually make the per-archetype dispatch usable.
#
# The cpo archetype workstream depends on this: without --type stamping
# .claude/swarm-type, every swarm silently defaults to engineering-cto
# regardless of any templates/cpo/ that gets shipped.
#
# Assertions:
#   (a) swarm-init --type <known> writes .claude/swarm-type with that value
#       AND manifest_apply resolves to templates/<type>/manifest.tsv
#       (proves dispatch is wired end-to-end, not just the marker)
#   (b) swarm-init without --type writes NO marker; swarm_type_of() falls
#       back to engineering-cto (back-compat — existing swarms unaffected)
#   (c) swarm-init --type <unknown> is refused with a clear error and
#       leaves the repo untouched (no partial-state, no silent
#       misclassification)
#   (d) swarm-init --type <name> against an already-stamped repo with a
#       DIFFERENT type is refused (archetype-switching is not supported)
#   (e) swarm-init --type <name> against an already-stamped repo with the
#       SAME type is a no-op (idempotent)
#   (f) the --type=<val> form works in addition to --type <val>
#
# Strategy: isolated SWARM_HOME with a minimal `cpo` archetype, so we can
# test --type cpo end-to-end without polluting the real templates/cpo/
# (which the parallel CPO workstream owns and hasn't built yet).

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

FAKE_HOME="$(mktemp -d -t swarm-test-type-home.XXXXXX)" || { echo "mktemp FAKE_HOME failed"; exit 1; }
touch "$FAKE_HOME/swarm.conf"

# Minimal `cpo` archetype: just a gitignore line so manifest_apply has at
# least one entry to walk. The point is to prove --type cpo dispatches
# to this manifest.
mkdir -p "$FAKE_HOME/templates/cpo"
cat > "$FAKE_HOME/templates/cpo/manifest.tsv" <<'EOF'
gitignore | .claude/worktrees/ | .gitignore
EOF

# Minimal `engineering-cto` archetype, distinguishable from cpo: a unique
# gitignore line. If --type=engineering-cto dispatches to this manifest
# instead of cpo's, we see the .claude/from-engineering-cto entry.
mkdir -p "$FAKE_HOME/templates/engineering-cto"
cat > "$FAKE_HOME/templates/engineering-cto/manifest.tsv" <<'EOF'
gitignore | .claude/from-engineering-cto | .gitignore
EOF

export SWARM_HOME="$FAKE_HOME"

# ---------------------------------------------------------------------------
echo "==> (a) --type cpo stamps marker AND dispatches to templates/cpo/"
REPO="$(mktemp -d -t swarm-test-type-a.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"

"$ROOT/bin/swarm-init.sh" "$REPO" --type cpo >/tmp/swarm-type-a.out 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fail "swarm-init --type cpo failed (rc=$RC); output:"
  sed 's/^/    /' /tmp/swarm-type-a.out
else
  pass "swarm-init --type cpo succeeded"
fi

if [ -f "$REPO/.claude/swarm-type" ]; then
  MARKER="$(cat "$REPO/.claude/swarm-type")"
  if [ "$MARKER" = "cpo" ]; then
    pass ".claude/swarm-type contains 'cpo'"
  else
    fail ".claude/swarm-type contains '$MARKER', want 'cpo'"
  fi
else
  fail ".claude/swarm-type was not written"
fi

# Dispatch proof: the cpo manifest has the unique gitignore line
# `.claude/worktrees/`, not `.claude/from-engineering-cto`. If --type cpo
# truly dispatched to templates/cpo/, the repo's .gitignore should contain
# the cpo entry and NOT the engineering-cto entry.
if grep -qxF ".claude/worktrees/" "$REPO/.gitignore" 2>/dev/null \
   && ! grep -qxF ".claude/from-engineering-cto" "$REPO/.gitignore" 2>/dev/null; then
  pass "manifest_apply dispatched to templates/cpo/manifest.tsv (not engineering-cto)"
else
  fail "dispatch did NOT route to templates/cpo/manifest.tsv:"
  sed 's/^/    /' "$REPO/.gitignore"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (b) without --type, no marker is written; default resolves to engineering-cto"
REPO="$(mktemp -d -t swarm-test-type-b.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"

"$ROOT/bin/swarm-init.sh" "$REPO" >/tmp/swarm-type-b.out 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fail "swarm-init (no --type) failed (rc=$RC)"
  sed 's/^/    /' /tmp/swarm-type-b.out
fi

if [ ! -f "$REPO/.claude/swarm-type" ]; then
  pass "no marker written when --type absent (back-compat)"
else
  fail "marker was written without --type: $(cat "$REPO/.claude/swarm-type")"
fi

# Dispatch proof: should land on engineering-cto's manifest (unique line).
if grep -qxF ".claude/from-engineering-cto" "$REPO/.gitignore" 2>/dev/null; then
  pass "markerless repo dispatches to engineering-cto (default)"
else
  fail "markerless repo did NOT dispatch to engineering-cto; .gitignore:"
  sed 's/^/    /' "$REPO/.gitignore" 2>/dev/null
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (c) unknown --type is refused; no partial-state in the repo"
REPO="$(mktemp -d -t swarm-test-type-c.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"

"$ROOT/bin/swarm-init.sh" "$REPO" --type cpoo >/tmp/swarm-type-c.out 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  pass "swarm-init --type cpoo refused (rc=$RC)"
else
  fail "swarm-init --type cpoo was accepted (should have refused)"
fi

if grep -qF "unknown --type 'cpoo'" /tmp/swarm-type-c.out; then
  pass "error message names the bad type"
else
  fail "error message didn't name the bad type; output:"
  sed 's/^/    /' /tmp/swarm-type-c.out
fi

# Partial-state check: no marker, no .gitignore written.
if [ ! -f "$REPO/.claude/swarm-type" ] && [ ! -f "$REPO/.gitignore" ]; then
  pass "no partial state — refusal happened before any write"
else
  fail "refusal left partial state:"
  ls -la "$REPO/.claude/" "$REPO/.gitignore" 2>&1 | sed 's/^/    /'
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (d) --type against repo with DIFFERENT marker is refused"
REPO="$(mktemp -d -t swarm-test-type-d.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"
mkdir -p "$REPO/.claude"
echo "cpo" > "$REPO/.claude/swarm-type"

"$ROOT/bin/swarm-init.sh" "$REPO" --type engineering-cto >/tmp/swarm-type-d.out 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  pass "--type engineering-cto against a cpo-stamped repo refused"
else
  fail "--type engineering-cto against a cpo-stamped repo was accepted"
fi

if grep -qF "is already 'cpo'" /tmp/swarm-type-d.out; then
  pass "error mentions the existing type"
else
  fail "error doesn't mention existing type; output:"
  sed 's/^/    /' /tmp/swarm-type-d.out
fi

# Marker not touched.
if [ "$(cat "$REPO/.claude/swarm-type")" = "cpo" ]; then
  pass "existing marker preserved on refusal"
else
  fail "existing marker was clobbered"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (e) --type matching existing marker is a no-op (idempotent re-stamp)"
REPO="$(mktemp -d -t swarm-test-type-e.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"
"$ROOT/bin/swarm-init.sh" "$REPO" --type cpo >/dev/null 2>&1

# Re-run with matching --type — should succeed.
"$ROOT/bin/swarm-init.sh" "$REPO" --type cpo >/tmp/swarm-type-e.out 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  pass "re-stamp with matching --type succeeded"
else
  fail "re-stamp with matching --type failed (rc=$RC):"
  sed 's/^/    /' /tmp/swarm-type-e.out
fi

if [ "$(cat "$REPO/.claude/swarm-type")" = "cpo" ]; then
  pass "marker still 'cpo' after re-stamp"
else
  fail "marker was changed on idempotent re-stamp"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (f) --type=<val> form also works"
REPO="$(mktemp -d -t swarm-test-type-f.XXXXXX)"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"
git -C "$REPO" commit --allow-empty -q -m "init"

"$ROOT/bin/swarm-init.sh" "$REPO" --type=cpo >/tmp/swarm-type-f.out 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$REPO/.claude/swarm-type" 2>/dev/null)" = "cpo" ]; then
  pass "--type=cpo (equals form) stamps the marker"
else
  fail "--type=cpo did not work (rc=$RC); output:"
  sed 's/^/    /' /tmp/swarm-type-f.out
fi
rm -rf "$REPO"
REPO=""  # so cleanup doesn't try to remove it twice

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL ($FAIL failure(s))"
  exit 1
fi
echo "OK"
