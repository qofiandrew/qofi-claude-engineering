#!/usr/bin/env bash
# test-swarm-reauth.sh — regression tests for bin/swarm-reauth.sh, the no-restart
# rotation actuator that slots into the tick's SWARM_ROTATE_CMD seam.
#
# WHAT THIS PINS:
#   - The tick's actuator contract: --next prints NOTHING (exit 0) so the tick
#     writes no account-state; --dry-run runs nothing; --force is accepted/inert.
#   - THE EXIT-CODE REMAP (the reason this wrapper exists): the relay's exit 7
#     (authed-but-capped) -> reauth 6 (the tick's ring-exhaustion code), while the
#     relay's OWN exit 6 (Discord-post-failed) must NOT become 6 -> it collapses
#     to 5. Every other non-zero relay code -> 5. Relay 0 -> 0.
#   - The post-swap probe recycle runs ONLY on success, is skippable, and never
#     runs on a failed re-auth.
#
# The re-auth command is stubbed via SWARM_REAUTH_LOGIN_CMD; the probe recycle
# via SWARM_REAUTH_POSTSWAP_CMD. No real tmux, claude, or network.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-reauth.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_empty() { if [ -z "$1" ]; then ok "$2"; else bad "$2 (got [$1])"; fi; }
assert_nonempty() { if [ -n "$1" ]; then ok "$2"; else bad "$2 (was empty)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-reauth-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-reauth.sh" "$FAKE_SH/bin/swarm-reauth.sh"
chmod +x "$FAKE_SH/bin/swarm-reauth.sh"
REAUTH="$FAKE_SH/bin/swarm-reauth.sh"
cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo-prodtest | BOT_TEST | 12345 | |
EOF

RECYCLE_MARK="$TMP/recycled"

# run REAUTH-ARGS -- LOGIN_EXIT [POSTSWAP_ON] : sets $OUT/$rc, records recycle.
# SWARM_STATE_DIR is pinned to a throwaway: without it a success path would
# promote/consume the REAL machine's pane-signal latch (~/.config/swarm) —
# running the suite would mutate live rotation state.
run_reauth() {
  local login_exit="$1"; shift
  rm -f "$RECYCLE_MARK"; rm -rf "$TMP/reauth-state"
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_STATE_DIR="$TMP/reauth-state"
    export SWARM_REAUTH_LOGIN_CMD="exit $login_exit"
    export SWARM_REAUTH_POSTSWAP_CMD="sh -c 'echo yes > $RECYCLE_MARK'"
    bash "$REAUTH" "$@" 2>&1
  )"; rc=$?
}

echo "=== actuator contract: --next prints nothing, exit 0 (no ring under this model) ==="
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_REAUTH_LOGIN_CMD='exit 0' bash "$REAUTH" --next 2>&1)"; rc=$?
assert_eq 0 "$rc" "--next exits 0"
assert_empty "$OUT" "--next prints nothing (tick then writes no account-state)"

echo "=== --dry-run runs nothing (login stub must NOT fire) ==="
run_reauth 99 --dry-run   # login stub would exit 99 if it ran
assert_eq 0 "$rc" "--dry-run exits 0 regardless of the (unused) login stub"
assert_has "$OUT" "DRY-RUN" "reports dry-run"
assert_empty "$(cat "$RECYCLE_MARK" 2>/dev/null)" "--dry-run does not recycle the probe"

echo "=== SUCCESS: relay 0 -> reauth 0, and the probe is recycled ==="
run_reauth 0
assert_eq 0 "$rc" "relay 0 -> reauth 0"
assert_eq "yes" "$(cat "$RECYCLE_MARK" 2>/dev/null)" "probe recycled AFTER a successful re-auth"
assert_has "$OUT" "No lead was restarted" "states no restart happened"

echo "=== THE REMAP: relay 7 (capped) -> reauth 6 (ring exhausted) ==="
run_reauth 7
assert_eq 6 "$rc" "relay 7 -> reauth 6 (tick escalates ring exhaustion)"
assert_empty "$(cat "$RECYCLE_MARK" 2>/dev/null)" "no probe recycle on a capped re-auth"

echo "=== THE REMAP: relay 6 (Discord-post-failed) must NOT be read as ring exhaustion ==="
run_reauth 6
assert_eq 5 "$rc" "relay 6 -> reauth 5, NOT 6 (the collision this wrapper exists to prevent)"

echo "=== other non-zero relay codes -> reauth 5, no recycle ==="
for c in 2 3 4 5 8 42; do
  run_reauth "$c"
  assert_eq 5 "$rc" "relay $c -> reauth 5"
  assert_empty "$(cat "$RECYCLE_MARK" 2>/dev/null)" "relay $c: no probe recycle on failure"
done

echo "=== --force is accepted but inert (no guard to override) ==="
run_reauth 0 --force
assert_eq 0 "$rc" "--force + relay 0 -> reauth 0"
assert_has "$OUT" "inert" "notes --force is inert in the no-guard model"

echo "=== post-swap recycle is skippable (SWARM_REAUTH_POSTSWAP_CMD=true) ==="
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_REAUTH_LOGIN_CMD='exit 0' SWARM_REAUTH_POSTSWAP_CMD='true' bash "$REAUTH" 2>&1)"; rc=$?
assert_eq 0 "$rc" "skipped recycle still exits 0"

echo "=== config: bad SWARM_HOME -> exit 2 ==="
OUT="$(SWARM_HOME="$TMP/nope" bash "$REAUTH" 2>&1)"; rc=$?
assert_eq 2 "$rc" "bad SWARM_HOME -> config error 2"

echo "=== pane-signal latch promotion (the detector's anti-loop contract) ==="
LSTATE="$TMP/latch-state"
run_latch() {  # LOGIN_EXIT — run with a pending signature present
  rm -rf "$LSTATE"; mkdir -p "$LSTATE"
  printf '%s\n' "% of your session limit · resets 8:39am" > "$LSTATE/swarm-pane-signal.pending"
  OUT="$(SWARM_HOME="$FAKE_SH" SWARM_STATE_DIR="$LSTATE" \
         SWARM_REAUTH_LOGIN_CMD="exit $1" SWARM_REAUTH_POSTSWAP_CMD='true' \
         bash "$REAUTH" 2>&1)"; rc=$?
}
run_latch 0
assert_eq 0 "$rc" "success with pending -> exit 0"
[ -f "$LSTATE/swarm-pane-signal.pending" ] && bad "success consumes the pending file" || ok "success consumes the pending file"
_lat="$(cat "$LSTATE/swarm-pane-signal.latched" 2>/dev/null)"
assert_has "$_lat" "% of your session limit · resets 8:39am" "success promotes pending -> latched (signature present)"
printf '%s' "$_lat" | grep -qE '^[0-9]+	' && ok "latched entry is epoch-stamped (TTL substrate)" || bad "latched entry is epoch-stamped (TTL substrate) (got [$_lat])"
_now=$(date +%s); _mt=$(stat -f %m "$LSTATE/swarm-pane-signal.latched" 2>/dev/null || stat -c %Y "$LSTATE/swarm-pane-signal.latched")
[ $((_now - _mt)) -le 5 ] && ok "latched mtime is NOW (arms the cooldown)" || bad "latched mtime is NOW (arms the cooldown) (age=$((_now-_mt))s)"
assert_has "$OUT" "latched the triggering pane signature" "reports the promotion"

echo "--- promotion APPENDS (a second window's signature never evicts the first) ---"
printf '%s\n' "usage limit reached · resets 3pm" > "$LSTATE/swarm-pane-signal.pending"
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_STATE_DIR="$LSTATE" \
       SWARM_REAUTH_LOGIN_CMD='exit 0' SWARM_REAUTH_POSTSWAP_CMD='true' \
       bash "$REAUTH" 2>&1)"; rc=$?
_lat="$(cat "$LSTATE/swarm-pane-signal.latched" 2>/dev/null)"
assert_has "$_lat" "% of your session limit · resets 8:39am" "first signature still latched after a second promotion"
assert_has "$_lat" "usage limit reached · resets 3pm" "second signature latched too (set, not slot)"

run_latch 5
assert_eq 5 "$rc" "failed re-auth -> exit 5"
[ -f "$LSTATE/swarm-pane-signal.pending" ] && ok "failure leaves pending (next tick retries)" || bad "failure leaves pending (next tick retries)"
[ -f "$LSTATE/swarm-pane-signal.latched" ] && bad "failure must NOT latch" || ok "failure must NOT latch"

rm -rf "$LSTATE"; mkdir -p "$LSTATE"
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_STATE_DIR="$LSTATE" \
       SWARM_REAUTH_LOGIN_CMD='exit 0' SWARM_REAUTH_POSTSWAP_CMD='true' \
       bash "$REAUTH" 2>&1)"; rc=$?
assert_eq 0 "$rc" "success with NO pending -> exit 0 (poll-triggered re-auth)"
[ -f "$LSTATE/swarm-pane-signal.latched" ] && ok "poll-triggered success still touches latched (arms the cooldown for pane signals)" || bad "poll-triggered success still touches latched (arms the cooldown)"
[ -s "$LSTATE/swarm-pane-signal.latched" ] && bad "no pending -> latched stays EMPTY (only the mtime arms)" || ok "no pending -> latched stays EMPTY (only the mtime arms)"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
