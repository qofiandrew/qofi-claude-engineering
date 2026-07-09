#!/usr/bin/env bash
# test-swarm-failover-target.sh — bin/swarm-failover-target.sh, the failover
# SELECTOR (ADR-0018). Read-only; never swaps/restarts anything.
#
# WHAT THIS PROTECTS:
#   1. Universe = distinct NON-EMPTY accounts in swarm.conf; never targets the
#      default account; an all-default fleet has no target (ring exhausted).
#   2. Skip-capped + exclude: a capped or excluded account is never chosen.
#   3. Ring exhaustion: every account capped/excluded -> exit 6.
#   4. Least-recently-capped ordering: a never-capped account beats a
#      recently-capped one; among capped-before, the OLDEST marker wins; ties
#      break by swarm.conf order.
#   5. THE CARVE-OUT: hysteresis gates PROACTIVE moves (and only with a headroom
#      signal wired), but NEVER blocks an EVACUATION — a capped swarm always gets
#      a target if one is eligible, regardless of any headroom margin.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-failover-target.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEL="$ROOT/bin/swarm-failover-target.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/failover-target.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture: three labeled accounts (maxa, maxb, maxc) + one default-account swarm.
FAKE_SH="$TMP/sh"; mkdir -p "$FAKE_SH"
cat > "$FAKE_SH/swarm.conf" <<'CONF'
# name | repo | tok | channel | guild | account
s-a | ~/r/a | TA | 11 | 99 | maxa
s-b | ~/r/b | TB | 22 | 99 | maxb
s-c | ~/r/c | TC | 33 | 99 | maxc
s-d | ~/r/d | TD | 44 | 99 |
CONF
CAPS="$TMP/caps"; mkdir -p "$CAPS"

run_sel() {  # ARGS... -> OUT, rc  (CAPS dir fresh-pointed; override per test as needed)
  OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" bash "$SEL" "$@" 2>&1)"; rc=$?
}

# ---------------------------------------------------------------------------
echo "=== 1) basic select: skip the capped account, pick an eligible one ==="
rm -rf "$CAPS"; mkdir -p "$CAPS"
run_sel --capped "maxa"
assert_eq 0 "$rc" "a target exists -> exit 0"
assert_eq "maxb" "$OUT" "capped maxa -> first eligible (maxb, conf order, none capped before)"

run_sel --capped "maxa maxb"
assert_eq "maxc" "$OUT" "capped maxa+maxb -> only maxc remains"

echo "=== 2) exclude is honored ==="
run_sel --capped "maxa" --exclude "maxb"
assert_eq "maxc" "$OUT" "exclude maxb -> maxc chosen even though maxb was eligible"

echo "=== 3) ring exhaustion -> exit 6 ==="
run_sel --capped "maxa maxb maxc"
assert_eq 6 "$rc" "all accounts capped -> RING EXHAUSTED (exit 6)"
assert_has "$OUT" "RING EXHAUSTED" "announces ring exhaustion"
assert_eq "" "$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" bash "$SEL" --capped 'maxa maxb maxc' 2>/dev/null)" "no target printed to stdout on exhaustion"

echo "=== 3b) comma-separated lists are accepted too ==="
run_sel --capped "maxa,maxb"
assert_eq "maxc" "$OUT" "comma-separated capped list parses"

# ---------------------------------------------------------------------------
echo "=== 4) least-recently-capped ordering ==="
# 4a) never-capped beats capped-before: maxb has a (recent) marker, maxc has NONE.
rm -rf "$CAPS"; mkdir -p "$CAPS"
touch -t 202606010000 "$CAPS/maxb"     # maxb capped at some point
run_sel --capped "maxa"                # eligible: maxb (capped-before), maxc (never)
assert_eq "maxc" "$OUT" "never-capped maxc beats recently-capped maxb"

# 4b) among capped-before, the OLDEST marker (least-recently-capped) wins.
rm -rf "$CAPS"; mkdir -p "$CAPS"
touch -t 202601010000 "$CAPS/maxb"     # maxb capped long ago
touch -t 202606010000 "$CAPS/maxc"     # maxc capped recently
run_sel --capped "maxa"
assert_eq "maxb" "$OUT" "older marker (maxb) chosen over recently-capped maxc"

# 4c) reverse the marker ages -> the choice flips.
rm -rf "$CAPS"; mkdir -p "$CAPS"
touch -t 202606010000 "$CAPS/maxb"     # maxb recent
touch -t 202601010000 "$CAPS/maxc"     # maxc long ago
run_sel --capped "maxa"
assert_eq "maxc" "$OUT" "choice flips to the older marker (maxc)"

# ---------------------------------------------------------------------------
echo "=== 5) all-default fleet: no labeled accounts -> exit 6 ==="
DEF_SH="$TMP/defsh"; mkdir -p "$DEF_SH"
cat > "$DEF_SH/swarm.conf" <<'CONF'
only | ~/r/only | TO | 11 | 99 |
CONF
OUT="$(SWARM_HOME="$DEF_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" bash "$SEL" --capped "" 2>&1)"; rc=$?
assert_eq 6 "$rc" "no labeled accounts -> exit 6"
assert_has "$OUT" "no labeled accounts" "explains there is nowhere to fail over to"

# ---------------------------------------------------------------------------
echo "=== 6) THE CARVE-OUT: hysteresis blocks PROACTIVE but never EVACUATION ==="
rm -rf "$CAPS"; mkdir -p "$CAPS"
# A headroom stub where the source (maxa) has tiny headroom and targets only a
# little more — margin BELOW the 15% hysteresis.
STINGY="$TMP/stingy.sh"
cat > "$STINGY" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in maxa) echo 2 ;; *) echo 6 ;; esac   # margin 6-2=4% < 15%
EOF
chmod +x "$STINGY"

# 6a) PROACTIVE with a sub-hysteresis margin -> declined (exit 5), stays put.
# The headroom cmd is invoked `sh -c "$cmd" _ <acct>`, so the account lands in $1
# of the stub (which reads ${1:-}).
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$STINGY" \
       bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 5 "$rc" "proactive move with margin < hysteresis -> declined (exit 5)"
assert_has "$OUT" "declined" "explains the proactive decline"

# 6b) EVACUATION (default mode) with the SAME stingy headroom -> still moves.
#     The capped swarm gets a target regardless of the margin (the carve-out).
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$STINGY" \
       bash "$SEL" --capped "maxa" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 0 "$rc" "EVACUATION ignores hysteresis -> a target is returned (exit 0)"
assert_eq "maxb" "$OUT" "the capped swarm evacuates to an eligible target despite a tiny margin"

# 6c) PROACTIVE with NO headroom signal wired -> declined (won't churn on guesses).
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" \
       bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 5 "$rc" "proactive with no headroom seam -> declined (exit 5)"
assert_has "$OUT" "headroom signal" "names the missing Phase-4 telemetry seam"

# 6d) PROACTIVE with a HEALTHY margin -> moves (exit 0).
GEN="$TMP/generous.sh"
cat > "$GEN" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in maxa) echo 10 ;; *) echo 40 ;; esac   # margin 30% >= 15%
EOF
chmod +x "$GEN"
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$GEN" \
       bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 0 "$rc" "proactive with margin >= hysteresis -> moves (exit 0)"
assert_eq "maxb" "$OUT" "healthy-margin proactive move picks the eligible target"

# 6e) LEADING-ZERO headroom (R1-1): a zero-padded telemetry value (e.g. "08","09")
#     must NOT trip a bash-3.2 octal arith error that falls through past the decline
#     gate. Source 09, target 08 (target strictly WORSE) -> must DECLINE (exit 5),
#     never a spurious move.
LZERO="$TMP/lzero.sh"
cat > "$LZERO" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in maxa) echo 09 ;; *) echo 08 ;; esac   # leading-zero, target worse
EOF
chmod +x "$LZERO"
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$LZERO" \
       bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 5 "$rc" "leading-zero headroom, target worse -> still DECLINES (exit 5), no octal fall-through"
assert_eq "" "$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$LZERO" bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>/dev/null)" "no target printed to stdout on the leading-zero decline"

# 6f) LEADING-ZERO with a genuinely healthy margin -> base-10 coercion still moves.
LZGEN="$TMP/lzgen.sh"
cat > "$LZGEN" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in maxa) echo 08 ;; *) echo 040 ;; esac   # 10#040=40 vs 10#08=8 -> 32% >= 15%
EOF
chmod +x "$LZGEN"
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_ACCOUNT_CAPS_DIR="$CAPS" SWARM_ACCOUNT_HEADROOM_CMD="$LZGEN" \
       bash "$SEL" --proactive --source maxa --capped "" --for-swarm s-a 2>&1)"; rc=$?
assert_eq 0 "$rc" "leading-zero headroom with a real margin -> moves (base-10 coercion)"
assert_eq "maxb" "$OUT" "base-10 coercion picks the eligible target"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
