#!/usr/bin/env bash
# test-swarm-profile-dispatch.sh — the frontend|backend PROFILE axis (ADR-0013).
#
# Profile is an ORTHOGONAL axis layered on top of the engineering-cto archetype:
# a per-repo .claude/swarm-profile marker that appends a stack-specific overlay
# to the COMPOSED CLAUDE.md only. Three states, by design:
#   - absent marker  -> no overlay; byte-identical to a pre-profile swarm
#   - 'backend'      -> LABEL-ONLY (no overlay fragment); also byte-identical
#   - 'frontend'     -> overlay fragment appended as the final compose source
#
# PART 1 — swarm-init.sh CLI contract (isolated SWARM_HOME, minimal manifest):
#   (a) --profile frontend stamps .claude/swarm-profile AND --type stamps type
#   (b) no --profile writes NO profile marker (back-compat)
#   (c) unknown --profile is refused, names the bad value, leaves NO partial state
#   (d) --profile against a non-engineering-cto --type is refused (eng-cto only)
#   (e) the --profile=<val> equals form works
#   (f) --profile against a repo with a DIFFERENT profile marker is refused
#       (profile-switching unsupported, like archetype)
#   (g) --profile backend is a VALID (label-only) profile and stamps the marker
#   + swarm_profile_of() defaults to EMPTY for a markerless repo, reads the marker
#
# PART 2 — the REAL compose injection (real SWARM_HOME = repo, calls
#   manifest_apply_compose directly, asserts byte-identity to the frozen
#   fixtures). This exercises the live pipeline, not a re-implemented cat — the
#   gap test-doctrine-compose.sh's compose_check cannot cover.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
note() { printf '  %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }
pass() { printf '  ok   %s\n' "$*"; }

FAKE_HOME=""
REPO=""
TMP_DIRS=()
cleanup() {
  [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
  [ -n "$REPO" ]      && rm -rf "$REPO"
  for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT INT TERM

mk_repo() {
  local d
  d="$(mktemp -d -t swarm-test-profile.XXXXXX)"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name  "Test"
  git -C "$d" commit --allow-empty -q -m "init"
  printf '%s' "$d"
}

# ===========================================================================
# PART 1 — swarm-init.sh CLI contract, isolated SWARM_HOME.
# ===========================================================================
FAKE_HOME="$(mktemp -d -t swarm-test-profile-home.XXXXXX)" || { echo "mktemp FAKE_HOME failed"; exit 1; }
touch "$FAKE_HOME/swarm.conf"
# Minimal manifests: just a gitignore line so manifest_apply has something to
# walk. Profile stamping/validation in swarm-init happens BEFORE the walk and
# does not need the real CLAUDE.md compose — Part 2 covers the compose.
mkdir -p "$FAKE_HOME/templates/engineering-cto" "$FAKE_HOME/templates/cpo"
printf 'gitignore | .claude/worktrees/ | .gitignore\n' > "$FAKE_HOME/templates/engineering-cto/manifest.tsv"
printf 'gitignore | .claude/worktrees/ | .gitignore\n' > "$FAKE_HOME/templates/cpo/manifest.tsv"
export SWARM_HOME="$FAKE_HOME"

# ---------------------------------------------------------------------------
echo "==> (a) --type engineering-cto --profile frontend stamps both markers"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type engineering-cto --profile frontend >/tmp/swarm-profile-a.out 2>&1
RC=$?
[ "$RC" -eq 0 ] && pass "swarm-init --profile frontend succeeded" || { fail "rc=$RC"; sed 's/^/    /' /tmp/swarm-profile-a.out; }
if [ "$(cat "$REPO/.claude/swarm-profile" 2>/dev/null)" = "frontend" ]; then
  pass ".claude/swarm-profile == frontend"
else
  fail ".claude/swarm-profile is '$(cat "$REPO/.claude/swarm-profile" 2>/dev/null)', want frontend"
fi
if [ "$(cat "$REPO/.claude/swarm-type" 2>/dev/null)" = "engineering-cto" ]; then
  pass ".claude/swarm-type == engineering-cto (profile coexists with type)"
else
  fail ".claude/swarm-type is '$(cat "$REPO/.claude/swarm-type" 2>/dev/null)', want engineering-cto"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (b) without --profile, NO profile marker is written (back-compat)"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type engineering-cto >/tmp/swarm-profile-b.out 2>&1
if [ ! -f "$REPO/.claude/swarm-profile" ]; then
  pass "no .claude/swarm-profile marker when --profile absent"
else
  fail "profile marker written without --profile: $(cat "$REPO/.claude/swarm-profile")"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (c) unknown --profile is refused; NO partial state"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type engineering-cto --profile fullstack >/tmp/swarm-profile-c.out 2>&1
RC=$?
[ "$RC" -ne 0 ] && pass "unknown --profile fullstack refused (rc=$RC)" || fail "unknown --profile was accepted"
grep -qF "unknown --profile 'fullstack'" /tmp/swarm-profile-c.out \
  && pass "error names the bad profile" \
  || { fail "error didn't name the bad profile"; sed 's/^/    /' /tmp/swarm-profile-c.out; }
# Refusal is BEFORE any marker write (validation precedes type+profile stamping).
if [ ! -f "$REPO/.claude/swarm-profile" ] && [ ! -f "$REPO/.claude/swarm-type" ] && [ ! -f "$REPO/.gitignore" ]; then
  pass "no partial state — refusal happened before any write"
else
  fail "refusal left partial state:"
  ls -la "$REPO/.claude/" "$REPO/.gitignore" 2>&1 | sed 's/^/    /'
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (d) --profile against a non-engineering-cto --type is refused"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type cpo --profile frontend >/tmp/swarm-profile-d.out 2>&1
RC=$?
[ "$RC" -ne 0 ] && pass "--type cpo --profile frontend refused (rc=$RC)" || fail "cpo+profile was accepted"
grep -qF "only valid for engineering-cto" /tmp/swarm-profile-d.out \
  && pass "error explains the engineering-cto-only rule" \
  || { fail "error didn't explain the rule"; sed 's/^/    /' /tmp/swarm-profile-d.out; }
[ ! -f "$REPO/.claude/swarm-profile" ] \
  && pass "no profile marker written on refusal" \
  || fail "profile marker written despite refusal"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (e) --profile=<val> equals form works"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type=engineering-cto --profile=frontend >/tmp/swarm-profile-e.out 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$REPO/.claude/swarm-profile" 2>/dev/null)" = "frontend" ]; then
  pass "--profile=frontend (equals form) stamps the marker"
else
  fail "--profile=frontend did not work (rc=$RC)"; sed 's/^/    /' /tmp/swarm-profile-e.out
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (f) --profile against a repo with a DIFFERENT profile is refused"
REPO="$(mk_repo)"
mkdir -p "$REPO/.claude"
echo "backend" > "$REPO/.claude/swarm-profile"
"$ROOT/bin/swarm-init.sh" "$REPO" --profile frontend >/tmp/swarm-profile-f.out 2>&1
RC=$?
[ "$RC" -ne 0 ] && pass "profile-switch (backend -> frontend) refused (rc=$RC)" || fail "profile-switch was accepted"
grep -qF "is already 'backend'" /tmp/swarm-profile-f.out \
  && pass "error mentions the existing profile" \
  || { fail "error didn't mention existing profile"; sed 's/^/    /' /tmp/swarm-profile-f.out; }
[ "$(cat "$REPO/.claude/swarm-profile")" = "backend" ] \
  && pass "existing profile marker preserved on refusal" \
  || fail "existing profile marker was clobbered"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==> (g) --profile backend is a VALID (label-only) profile"
REPO="$(mk_repo)"
"$ROOT/bin/swarm-init.sh" "$REPO" --type engineering-cto --profile backend >/tmp/swarm-profile-g.out 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$REPO/.claude/swarm-profile" 2>/dev/null)" = "backend" ]; then
  pass "--profile backend stamps the marker (label-only, but valid)"
else
  fail "--profile backend did not work (rc=$RC)"; sed 's/^/    /' /tmp/swarm-profile-g.out
fi
rm -rf "$REPO"
REPO=""

# ---------------------------------------------------------------------------
echo ""
echo "==> swarm_profile_of() defaults to EMPTY for a markerless repo"
PROBE="$(mktemp -d -t swarm-test-profile-of.XXXXXX)"; TMP_DIRS+=("$PROBE")
PROF_EMPTY="$(SWARM_HOME="$ROOT" bash -c 'set +u; source "$1/bin/swarm-lib.sh"; printf "[%s]" "$(swarm_profile_of "$2")"' _ "$ROOT" "$PROBE")"
[ "$PROF_EMPTY" = "[]" ] \
  && pass "swarm_profile_of markerless == empty (no-op default, ADR-0013)" \
  || fail "swarm_profile_of markerless == '$PROF_EMPTY', want '[]'"
mkdir -p "$PROBE/.claude"; echo "frontend" > "$PROBE/.claude/swarm-profile"
PROF_SET="$(SWARM_HOME="$ROOT" bash -c 'set +u; source "$1/bin/swarm-lib.sh"; printf "[%s]" "$(swarm_profile_of "$2")"' _ "$ROOT" "$PROBE")"
[ "$PROF_SET" = "[frontend]" ] \
  && pass "swarm_profile_of reads the marker == frontend" \
  || fail "swarm_profile_of marked == '$PROF_SET', want '[frontend]'"

# ===========================================================================
# PART 2 — the REAL compose injection (manifest_apply_compose, real templates).
# Proves the live pipeline produces the frozen fixtures — closes the gap that
# test-doctrine-compose.sh's compose_check (a re-implemented cat) cannot.
# ===========================================================================
echo ""
echo "==> PART 2: real manifest_apply_compose injection (SWARM_HOME = repo)"

CLAUDE_SRC_LIST="engineering-cto/CLAUDE.preamble.md+_base/CLAUDE.md+_base/SWARM_BEHAVIOR.md+engineering-cto/CLAUDE.md"
FIX_BASE="$ROOT/tests/fixtures/CLAUDE.engineering-cto.expected.md"
FIX_FRONT="$ROOT/tests/fixtures/CLAUDE.engineering-cto.frontend.expected.md"

# Run the real manifest_apply_compose for CLAUDE.md with a given type+profile,
# returning the path to the composed file. Uses bash -c (set +u, like the
# type-dispatch test) so sourcing the lib under the test's set -u is safe.
real_compose() {
  local prof="$1" typ="$2" d
  d="$(mktemp -d -t swarm-test-profile-compose.XXXXXX)"; TMP_DIRS+=("$d")
  SWARM_HOME="$ROOT" SWARM_APPLY_REPO="$d" SWARM_APPLY_MODE="init" \
  SWARM_APPLY_TYPE="$typ" SWARM_APPLY_PROFILE="$prof" SWARM_QUIET_UNCHANGED=1 \
  bash -c '
    set +u
    source "$SWARM_HOME/bin/swarm-lib.sh"
    manifest_apply_compose "$1" "CLAUDE.md"
  ' _ "$CLAUDE_SRC_LIST" >/dev/null 2>&1
  printf '%s' "$d/CLAUDE.md"
}

cmp_fixture() {
  local label="$1" got="$2" want="$3"
  if cmp -s "$got" "$want"; then
    pass "$label composed == $(basename "$want")"
  else
    fail "$label composed != $(basename "$want")"
    diff "$got" "$want" 2>/dev/null | head -15 | sed 's/^/    /'
  fi
}

cmp_fixture "frontend profile" "$(real_compose frontend engineering-cto)" "$FIX_FRONT"
cmp_fixture "backend profile (label-only -> base)" "$(real_compose backend engineering-cto)" "$FIX_BASE"
cmp_fixture "absent profile (no-op -> base)" "$(real_compose '' engineering-cto)" "$FIX_BASE"
# Type guard: a frontend profile on a NON-engineering-cto compose must NOT
# inject the overlay (defends a stray marker on a cpo repo).
cmp_fixture "frontend profile + type=cpo (guard -> base)" "$(real_compose frontend cpo)" "$FIX_BASE"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL ($FAIL failure(s))"
  exit 1
fi
echo "OK"
