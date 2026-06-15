#!/usr/bin/env bash
# test-swarm-failover-tick.sh — swarm-rotate-tick.sh --failover, the PER-ACCOUNT
# failover ROUTER (ADR-0018). Integration test: the REAL selector
# (swarm-failover-target.sh) is wired in; only the detector, the per-swarm swap
# actuator, and the attention hook are stubbed (so no real probe/checkpoint/
# restart/credential ever runs).
#
#   SWARM_LIMIT_DETECT_CMD  -> stub: emits canned `account=.. verdict=..` lines + rc
#   SWARM_FAILOVER_TARGET_CMD -> the REAL selector over a fixture swarm.conf
#   SWARM_ACCOUNT_CMD       -> stub: records "swap:<name>:<target>:<flags>", exits a knob
#   SWARM_ATTENTION_CMD     -> stub: records "attention:<reason>"
#
# WHAT THIS PROTECTS:
#   1. No capped accounts -> no swaps, exit 0.
#   2. One capped account, one swarm -> that swarm moves to a non-capped target.
#   3. SPREAD: a capped account's TWO swarms move to DIFFERENT targets (round-robin).
#   4. RING EXHAUSTION: every account capped -> exit 6, attention escalated, no swaps.
#   5. --dry-run: logs the plan, fires NO swap, writes NO LRC marker.
#   6. --force is passed through to the swap actuator.
#   7. Working swarm (swap exit 6) -> skipped, tick still exit 0.
#   8. Target capped race (swap exit 7) -> re-selects, excludes the raced target.
#   9. Detector config error (exit 2) -> tick exit 2, no swaps.
#  10. LRC marker is written for a capped account (live run only).
#
# Run from $SWARM_HOME:  bash tests/test-swarm-failover-tick.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TICK="$ROOT/bin/swarm-rotate-tick.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/failover-tick.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_SH="$TMP/sh"; mkdir -p "$FAKE_SH"
cat > "$FAKE_SH/swarm.conf" <<'CONF'
# name | repo | tok | channel | guild | account
s-a1 | ~/r/a1 | T | 11 | 99 | maxa
s-a2 | ~/r/a2 | T | 22 | 99 | maxa
s-b  | ~/r/b  | T | 33 | 99 | maxb
s-c  | ~/r/c  | T | 44 | 99 | maxc
s-d  | ~/r/d  | T | 55 | 99 |
CONF
CAPS="$TMP/caps"
WITNESS="$TMP/witness.log"

mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/detect.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/detect.out" 2>/dev/null
exit "\$(cat "$TMP/detect.rc" 2>/dev/null || echo 0)"
EOF
# swap stub: records the call; per-target rc override ($TMP/swaprc.<target>) else default.
cat > "$TMP/stubs/swap.sh" <<EOF
#!/usr/bin/env bash
printf 'swap:%s:%s:%s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> "$WITNESS"
if [ -f "$TMP/swaprc.\${2:-}" ]; then exit "\$(cat "$TMP/swaprc.\${2:-}")"; fi
exit "\$(cat "$TMP/swap.rc" 2>/dev/null || echo 0)"
EOF
cat > "$TMP/stubs/attention.sh" <<EOF
#!/usr/bin/env bash
printf 'attention:%s\n' "\${1:-}" >> "$WITNESS"
EOF
chmod +x "$TMP"/stubs/*.sh

# set_detect "<lines>" RC — write the detector's canned output + exit code.
set_detect() { printf '%s\n' "$1" > "$TMP/detect.out"; echo "$2" > "$TMP/detect.rc"; }

reset_state() {
  rm -rf "$CAPS"; : > "$WITNESS"
  echo 0 > "$TMP/swap.rc"; rm -f "$TMP"/swaprc.*
}

run_tick() {
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_LIMIT_DETECT_CMD="$TMP/stubs/detect.sh"
    export SWARM_FAILOVER_TARGET_CMD="$ROOT/bin/swarm-failover-target.sh"
    export SWARM_ACCOUNT_CMD="$TMP/stubs/swap.sh"
    export SWARM_ACCOUNT_CAPS_DIR="$CAPS"
    export SWARM_ATTENTION_CMD="$TMP/stubs/attention.sh \"\$1\""
    bash "$TICK" --failover "$@" 2>&1
  )"; rc=$?
  W="$(cat "$WITNESS")"
}

ALL_OK='account=maxa verdict=OK
account=maxb verdict=OK
account=maxc verdict=OK
account=_default_ verdict=OK'

# ---------------------------------------------------------------------------
echo "=== 1) no capped accounts -> exit 0, no swaps ==="
reset_state; set_detect "$ALL_OK" 0
run_tick
assert_eq 0 "$rc" "all accounts OK -> exit 0"
assert_has "$OUT" "no capped labeled accounts" "reports nothing to do"
assert_eq "" "$W" "no swap fired"

# ---------------------------------------------------------------------------
echo "=== 2) one capped account, one swarm -> moves to a non-capped target ==="
# Put a single swarm on maxa by capping maxa; only s-a1/s-a2 are on maxa.
reset_state
set_detect 'account=maxa verdict=AT swarm=s-a1
account=maxb verdict=OK
account=maxc verdict=OK' 20
run_tick
assert_eq 0 "$rc" "capped maxa -> tick exit 0"
assert_has "$W" "swap:s-a1:maxb:" "s-a1 swapped off maxa onto maxb"
assert_has "$W" "swap:s-a2:" "s-a2 (also on maxa) was evacuated too"

# ---------------------------------------------------------------------------
echo "=== 3) SPREAD: maxa's two swarms go to DIFFERENT targets ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
run_tick
assert_has "$W" "swap:s-a1:maxb:" "first swarm -> maxb"
assert_has "$W" "swap:s-a2:maxc:" "second swarm -> maxc (spread, not piled on maxb)"
assert_has "$OUT" "moved=2" "summary reports two moves"

# ---------------------------------------------------------------------------
echo "=== 4) RING EXHAUSTION: every account capped -> exit 6, escalate, no swaps ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=AT
account=maxc verdict=AT' 20
run_tick
assert_eq 6 "$rc" "all accounts capped -> exit 6 (terminal)"
assert_has "$OUT" "RING EXHAUSTED" "announces ring exhaustion"
assert_has "$W" "attention:" "raised the attention escalation hook"
assert_has "$W" "RING EXHAUSTED" "attention reason names ring exhaustion"
assert_lacks "$W" "swap:" "no swap fired when there is nowhere to go"

# ---------------------------------------------------------------------------
echo "=== 5) --dry-run: logs the plan, fires NO swap, writes NO marker ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
run_tick --dry-run
assert_eq 0 "$rc" "--dry-run exit 0"
assert_has "$OUT" "WOULD move" "logs the plan"
assert_lacks "$W" "swap:" "no swap fired in dry-run"
[ -e "$CAPS/maxa" ] && bad "dry-run wrote an LRC marker (should not)" || ok "dry-run wrote NO LRC marker"

# ---------------------------------------------------------------------------
echo "=== 6) --force is passed through to the swap actuator ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
run_tick --force
assert_has "$W" "swap:s-a1:maxb:--force" "--force threaded to the swap actuator"

# ---------------------------------------------------------------------------
echo "=== 7) working swarm (swap exit 6) -> skipped, tick still exit 0 ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
echo 6 > "$TMP/swap.rc"
run_tick
assert_eq 0 "$rc" "a working swarm refusal does not fail the tick (exit 0)"
assert_has "$OUT" "WORKING" "reports the swarm was skipped as working"
assert_has "$OUT" "skipped=" "summary counts the skip"

# ---------------------------------------------------------------------------
echo "=== 8) target capped race (swap exit 7) -> re-select, exclude the raced target ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
echo 7 > "$TMP/swaprc.maxb"     # maxb caps the moment we swap onto it
run_tick
assert_has "$W" "swap:s-a1:maxb:" "first tries maxb"
assert_has "$W" "swap:s-a1:maxc:" "after maxb races to capped, re-selects maxc for the SAME swarm"
assert_has "$OUT" "race" "logs the capped-target race"

# ---------------------------------------------------------------------------
echo "=== 9) detector config error (exit 2) -> tick exit 2, no swaps ==="
reset_state
set_detect "" 2
run_tick
assert_eq 2 "$rc" "detector config error -> tick exit 2"
assert_eq "" "$W" "no swap fired on a detector config error"

# ---------------------------------------------------------------------------
echo "=== 10) LRC marker written for a capped account (live run) ==="
reset_state
set_detect 'account=maxa verdict=AT
account=maxb verdict=OK
account=maxc verdict=OK' 20
run_tick
[ -e "$CAPS/maxa" ] && ok "live run wrote the LRC marker for capped maxa" || bad "no LRC marker written for maxa"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
