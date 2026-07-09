#!/usr/bin/env bash
# test-canon-mode.sh — the local|external SOURCE-OF-TRUTH axis (canon mode).
#
# Canon mode is an ORTHOGONAL axis on engineering-cto swarms: a per-repo
# .claude/canon-mode marker. 'external' appends the external-canon doctrine
# overlay + the repo-local canon binding to the composed CLAUDE.md and arms
# the canon-check TaskCompleted gate; ANYTHING else ('local', absent, junk)
# is the no-op default — byte-identical compose, no-op gate.
#
# PART 1 — swarm_canon_mode_of() resolution (default posture).
# PART 2 — the REAL compose injection (manifest_apply_compose): external mode
#          appends overlay (+ binding when present); local/absent modes stay
#          byte-identical to the frozen base fixture.
# PART 3 — canon-check.sh gate semantics: no-op in local mode; each
#          external-mode failure class blocks (exit 2) with a named reason;
#          a fully consistent repo passes.
# PART 4 — swarm-canon-enable.sh: seeds marker/binding/root docs/module
#          packs with placeholders filled; write-if-absent (idempotent, never
#          clobbers).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }
pass() { printf '  ok   %s\n' "$*"; }

TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT INT TERM

HOOK="$ROOT/templates/engineering-cto/hooks/canon-check.sh"

# ===========================================================================
echo "==> PART 1: swarm_canon_mode_of() resolution"
PROBE="$(mktemp -d -t canon-mode-probe.XXXXXX)"; TMP_DIRS+=("$PROBE")
mode_of() {
  SWARM_HOME="$ROOT" bash -c 'set +u; source "$1/bin/swarm-lib.sh"; swarm_canon_mode_of "$2"' _ "$ROOT" "$PROBE"
}
[ "$(mode_of)" = "local" ] && pass "markerless -> local (no-op default)" || fail "markerless -> '$(mode_of)', want local"
mkdir -p "$PROBE/.claude"
echo "external" > "$PROBE/.claude/canon-mode"
[ "$(mode_of)" = "external" ] && pass "'external' marker -> external" || fail "external marker misread"
echo "  external " > "$PROBE/.claude/canon-mode"
[ "$(mode_of)" = "external" ] && pass "whitespace-padded 'external' -> external" || fail "padded external misread"
echo "banana" > "$PROBE/.claude/canon-mode"
[ "$(mode_of)" = "local" ] && pass "junk marker -> local (fail-closed to no-op)" || fail "junk marker -> '$(mode_of)', want local"
echo "local" > "$PROBE/.claude/canon-mode"
[ "$(mode_of)" = "local" ] && pass "'local' marker -> local" || fail "local marker misread"

# ===========================================================================
echo ""
echo "==> PART 2: real manifest_apply_compose canon injection"

CLAUDE_SRC_LIST="engineering-cto/CLAUDE.preamble.md+_base/CLAUDE.md+engineering-cto/CLAUDE.md"
FIX_BASE="$ROOT/tests/fixtures/CLAUDE.engineering-cto.expected.md"
OVERLAY="$ROOT/templates/engineering-cto/canon/CLAUDE.external-canon.md"

# real_compose CANON_MODE TYPE [with_binding]
real_compose() {
  local cmode="$1" typ="$2" with_binding="${3:-}" d
  d="$(mktemp -d -t canon-mode-compose.XXXXXX)"; TMP_DIRS+=("$d")
  if [ -n "$with_binding" ]; then
    mkdir -p "$d/.claude"
    printf '\n## Canon binding (this repo)\n\n- test binding body\n' > "$d/.claude/canon-binding.md"
  fi
  SWARM_HOME="$ROOT" SWARM_APPLY_REPO="$d" SWARM_APPLY_MODE="init" \
  SWARM_APPLY_TYPE="$typ" SWARM_APPLY_PROFILE="" SWARM_APPLY_CANON_MODE="$cmode" \
  SWARM_QUIET_UNCHANGED=1 \
  bash -c '
    set +u
    source "$SWARM_HOME/bin/swarm-lib.sh"
    manifest_apply_compose "$1" "CLAUDE.md"
  ' _ "$CLAUDE_SRC_LIST" >/dev/null 2>&1
  printf '%s' "$d"
}

# local mode -> byte-identical to base fixture
D="$(real_compose local engineering-cto)"
cmp -s "$D/CLAUDE.md" "$FIX_BASE" \
  && pass "canon-mode=local composes byte-identical to base fixture" \
  || fail "canon-mode=local drifted from base fixture"

# external mode, no binding -> base + overlay exactly
D="$(real_compose external engineering-cto)"
EXPECT="$(mktemp -t canon-mode-expect.XXXXXX)"; TMP_DIRS+=("$EXPECT")
cat "$FIX_BASE" "$OVERLAY" > "$EXPECT"
cmp -s "$D/CLAUDE.md" "$EXPECT" \
  && pass "canon-mode=external == base + external-canon overlay" \
  || fail "canon-mode=external compose mismatch (base+overlay)"

# external mode + repo-local binding -> base + overlay + binding, binding LAST
D="$(real_compose external engineering-cto with_binding)"
cat "$FIX_BASE" "$OVERLAY" "$D/.claude/canon-binding.md" > "$EXPECT"
cmp -s "$D/CLAUDE.md" "$EXPECT" \
  && pass "external + binding == base + overlay + binding (binding terminates)" \
  || fail "external + binding compose mismatch"
tail -n 1 "$D/CLAUDE.md" | grep -q "test binding body" \
  && pass "binding is the final compose content" \
  || fail "binding is not final in composed CLAUDE.md"

# type guard: external marker on a cpo-type compose -> no injection
D="$(real_compose external cpo with_binding)"
cmp -s "$D/CLAUDE.md" "$FIX_BASE" \
  && pass "type guard: canon overlay never injected for non-engineering-cto" \
  || fail "type guard failed — overlay injected for cpo type"

# ===========================================================================
echo ""
echo "==> PART 3: canon-check.sh gate semantics"

# Build a COMPLETE, passing external-canon fixture repo, then break one
# invariant at a time.
mk_fixture() {
  local d
  d="$(mktemp -d -t canon-check-fix.XXXXXX)"
  mkdir -p "$d/.claude" "$d/src/alpha" "$d/tests" "$d/docs/modules/alpha"
  echo "external" > "$d/.claude/canon-mode"
  touch "$d/src/alpha/main.ts" "$d/tests/alpha.test.ts"
  cat > "$d/docs/CANON_SYNC.md" <<'EOF'
# CANON_SYNC
- **Canon repo:** `/somewhere/canon`
- **Canon commit:** abc1234
- **Last implementation-behavior commit reviewed against canon:** def5678
- **Current implementation repo commit at sync-doc update:** fed8765
EOF
  echo "# MODULE_INDEX" > "$d/docs/MODULE_INDEX.md"
  echo "# TRACEABILITY_LEDGER" > "$d/docs/TRACEABILITY_LEDGER.md"
  printf '# GAP_LEDGER\n| GAP-alpha-001 | alpha | adr-required | x | open |\n' > "$d/docs/GAP_LEDGER.md"
  local p="$d/docs/modules/alpha"
  echo "# README" > "$p/README.md"
  echo "# CANON_MAP" > "$p/CANON_MAP.md"
  echo "# INTERFACES" > "$p/INTERFACES.md"
  printf '# INVARIANTS\n- INV-alpha-001: holds | tests: `tests/alpha.test.ts`\n- INV-alpha-002: pending | gap: GAP-alpha-001\n' > "$p/INVARIANTS.md"
  printf '# OPEN_GAPS\n- GAP-alpha-001 (semantic): pending canon patch [adr-required]\n' > "$p/OPEN_GAPS.md"
  printf '# TEST_MAP\n| `tests/alpha.test.ts` | covers alpha |\n' > "$p/TEST_MAP.md"
  printf '# CODE_MAP\n| `src/alpha/main.ts` | entry |\n' > "$p/CODE_MAP.md"
  printf '%s' "$d"
}

run_hook() { # run_hook DIR -> rc; stderr in $HOOK_ERR
  # The hook resolves its work tree from the TaskCompleted payload's `cwd`
  # (worktree-topology fix) and fail-CLOSES when it isn't a git work tree —
  # so the fixture must be a git repo and the payload must carry its path.
  local d="$1" rc=0 ev
  [ -e "$d/.git" ] || git -C "$d" init -q 2>/dev/null
  ev="$(python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1]}))' "$d")"
  HOOK_ERR="$( (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$HOOK" <<<"$ev") 2>&1 1>/dev/null )" || rc=$?
  return $rc
}

# passing fixture
D="$(mk_fixture)"; TMP_DIRS+=("$D")
if run_hook "$D"; then pass "complete external-canon fixture PASSES"; else fail "complete fixture blocked: $HOOK_ERR"; fi

# local mode no-op even with everything missing
D="$(mktemp -d -t canon-check-local.XXXXXX)"; TMP_DIRS+=("$D")
mkdir -p "$D/src/alpha"
if run_hook "$D"; then pass "markerless repo -> no-op (exit 0) with no docs at all"; else fail "local-mode repo was blocked"; fi
mkdir -p "$D/.claude"; echo "local" > "$D/.claude/canon-mode"
if run_hook "$D"; then pass "'local' marker -> no-op"; else fail "'local' marker was blocked"; fi

break_check() { # break_check LABEL MUTATION_FN GREP
  local label="$1" mut="$2" want="$3" d rc=0
  d="$(mk_fixture)"; TMP_DIRS+=("$d")
  "$mut" "$d"
  if run_hook "$d"; then
    fail "$label: hook passed, expected BLOCK"
  else
    rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$HOOK_ERR" | grep -q "$want"; then
      pass "$label blocks with named reason"
    else
      fail "$label: rc=$rc, stderr: $(printf '%s' "$HOOK_ERR" | head -3)"
    fi
  fi
}

m_no_sync()        { rm "$1/docs/CANON_SYNC.md"; }
m_placeholder()    { sed -i '' 's|abc1234|<canon-repo commit hash>|' "$1/docs/CANON_SYNC.md"; }
m_missing_meta()   { sed -i '' '/Canon commit/d' "$1/docs/CANON_SYNC.md"; }
m_missing_current(){ sed -i '' '/Current implementation repo commit/d' "$1/docs/CANON_SYNC.md"; }
m_empty_value()    { sed -i '' 's|\(- \*\*Canon commit:\*\*\).*|\1|' "$1/docs/CANON_SYNC.md"; }
m_missing_reviewed(){ sed -i '' '/Last implementation-behavior commit/d' "$1/docs/CANON_SYNC.md"; }
m_no_pack()        { rm -rf "$1/docs/modules/alpha"; }
m_missing_file()   { rm "$1/docs/modules/alpha/CANON_MAP.md"; }
m_dead_codepath()  { printf '| `src/alpha/ghost.ts` | gone |\n' >> "$1/docs/modules/alpha/CODE_MAP.md"; }
m_dead_testpath()  { printf '| `tests/ghost.test.ts` | gone |\n' >> "$1/docs/modules/alpha/TEST_MAP.md"; }
m_bare_inv()       { printf -- '- INV-alpha-003: uncovered claim\n' >> "$1/docs/modules/alpha/INVARIANTS.md"; }
m_dead_inv_test()  { printf -- '- INV-alpha-004: fake proof | tests: `tests/ghost.test.ts`\n' >> "$1/docs/modules/alpha/INVARIANTS.md"; }
m_unquoted_inv()   { printf -- '- INV-alpha-005: unquoted | tests: tests/alpha.test.ts\n' >> "$1/docs/modules/alpha/INVARIANTS.md"; }
m_dangling_gapref(){ printf -- '- INV-alpha-006: phantom | gap: GAP-alpha-999\n' >> "$1/docs/modules/alpha/INVARIANTS.md"; }
m_unquoted_map()   { printf '# CODE_MAP\nsrc/alpha/main.ts unquoted\n' > "$1/docs/modules/alpha/CODE_MAP.md"; }
m_unrouted_gap()   { printf -- '- GAP-alpha-002 (conflict): not in ledger [adr-required]\n' >> "$1/docs/modules/alpha/OPEN_GAPS.md"; }
m_no_ledger()      { rm "$1/docs/GAP_LEDGER.md"; }

break_check "missing CANON_SYNC.md"                 m_no_sync       "CANON_SYNC.md missing"
break_check "placeholder sync metadata"             m_placeholder   "template placeholder"
break_check "missing sync metadata line"            m_missing_meta  "lacks 'Canon commit:'"
break_check "missing behavior-reviewed commit field" m_missing_reviewed "lacks 'Last implementation-behavior commit reviewed against canon:'"
break_check "missing current-repo-commit field"     m_missing_current "lacks 'Current implementation repo commit at sync-doc update:'"
break_check "field label with empty value"          m_empty_value   "'Canon commit:' has an empty value"
break_check "src module without doc pack"           m_no_pack       "no doc pack"
break_check "pack missing a required file"          m_missing_file  "CANON_MAP.md missing"
break_check "CODE_MAP references missing path"      m_dead_codepath "missing path: src/alpha/ghost.ts"
break_check "TEST_MAP references missing path"      m_dead_testpath "missing path: tests/ghost.test.ts"
break_check "INVARIANTS entry without tests:/gap:"  m_bare_inv      "lacks 'tests:' or 'gap:'"
break_check "INVARIANTS tests: cites missing path"  m_dead_inv_test "'tests:' path missing: tests/ghost.test.ts"
break_check "INVARIANTS tests: path not backticked" m_unquoted_inv  "cites no backtick-quoted path"
break_check "INVARIANTS gap: id not in OPEN_GAPS"   m_dangling_gapref "not recorded in docs/modules/alpha/OPEN_GAPS.md"
break_check "map with no backtick-quoted paths"     m_unquoted_map  "cites no backtick-quoted src/tests path"
break_check "[adr-required] gap absent from ledger" m_unrouted_gap  "absent from docs/GAP_LEDGER.md"
break_check "missing root GAP_LEDGER.md"            m_no_ledger     "docs/GAP_LEDGER.md missing"

# runtime-control opt-out still works
D="$(mk_fixture)"; TMP_DIRS+=("$D")
rm "$D/docs/CANON_SYNC.md"
RC=0
(cd "$D" && CLAUDE_PROJECT_DIR="$D" QOFI_HOOK_PROFILE=minimal bash "$HOOK" </dev/null) >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && pass "QOFI_HOOK_PROFILE=minimal disables the gate" || fail "runtime control did not disable (rc=$RC)"

# ===========================================================================
echo ""
echo "==> PART 4: swarm-canon-enable.sh seeding"

CANON="$(mktemp -d -t canon-repo.XXXXXX)"; TMP_DIRS+=("$CANON")
git -C "$CANON" init -q; git -C "$CANON" config user.email t@e.c; git -C "$CANON" config user.name T
mkdir -p "$CANON/products/widget"; echo hi > "$CANON/products/widget/vision.md"
git -C "$CANON" add -A; git -C "$CANON" commit -qm init
CANON_HEAD="$(git -C "$CANON" rev-parse HEAD)"

IMPL="$(mktemp -d -t canon-impl.XXXXXX)"; TMP_DIRS+=("$IMPL")
git -C "$IMPL" init -q; git -C "$IMPL" config user.email t@e.c; git -C "$IMPL" config user.name T
mkdir -p "$IMPL/src/alpha" "$IMPL/src/beta"; touch "$IMPL/src/alpha/a.ts" "$IMPL/src/beta/b.ts"
git -C "$IMPL" add -A; git -C "$IMPL" commit -qm init

"$ROOT/bin/swarm-canon-enable.sh" "$IMPL" --canon "$CANON/products/widget" >/tmp/canon-enable.out 2>&1 \
  && pass "enable script ran clean" \
  || { fail "enable script rc!=0"; sed 's/^/    /' /tmp/canon-enable.out; }

[ "$(head -n1 "$IMPL/.claude/canon-mode" 2>/dev/null)" = "external" ] \
  && pass "marker written: canon-mode=external" || fail "canon-mode marker wrong"
grep -q "$CANON" "$IMPL/.claude/canon-binding.md" 2>/dev/null \
  && pass "binding names the canon repo root" || fail "binding missing canon repo"
grep -q "products/widget" "$IMPL/.claude/canon-binding.md" 2>/dev/null \
  && pass "binding names the product path (derived from nested canon path)" || fail "binding missing product path"
grep -q "$CANON_HEAD" "$IMPL/docs/CANON_SYNC.md" 2>/dev/null \
  && pass "CANON_SYNC carries the real canon commit" || fail "CANON_SYNC canon commit not filled"
if grep -q '<[a-zA-Z].*>' "$IMPL/docs/CANON_SYNC.md"; then
  fail "CANON_SYNC still has template placeholders"
else
  pass "CANON_SYNC placeholders all filled"
fi
for f in docs/MODULE_INDEX.md docs/TRACEABILITY_LEDGER.md docs/GAP_LEDGER.md; do
  [ -s "$IMPL/$f" ] && pass "seeded $f" || fail "missing $f"
done
for m in alpha beta; do
  for f in README CANON_MAP INTERFACES INVARIANTS OPEN_GAPS TEST_MAP CODE_MAP; do
    [ -s "$IMPL/docs/modules/$m/$f.md" ] || fail "missing pack file docs/modules/$m/$f.md"
  done
  grep -q "\`$m\`" "$IMPL/docs/modules/$m/README.md" && pass "pack $m: <module> substituted" \
    || fail "pack $m: <module> placeholder not substituted"
  [ ! -e "$IMPL/docs/modules/$m/LIFECYCLE.md" ] || fail "LIFECYCLE auto-seeded (should be optional/manual)"
done

# idempotency: re-run never clobbers
echo "CUSTOM" >> "$IMPL/docs/CANON_SYNC.md"
"$ROOT/bin/swarm-canon-enable.sh" "$IMPL" --canon "$CANON/products/widget" >/dev/null 2>&1
grep -q "CUSTOM" "$IMPL/docs/CANON_SYNC.md" \
  && pass "re-run is write-if-absent (kept edited CANON_SYNC)" \
  || fail "re-run clobbered an existing seeded doc"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL ($FAIL failure(s))"
  exit 1
fi
echo "OK"
