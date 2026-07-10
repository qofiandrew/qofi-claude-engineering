#!/usr/bin/env bash
# test-swarm-reauth-verify.sh — regression tests for bin/swarm-reauth-verify.sh,
# the standing STUCK-PANE alerter for no-restart rotation.
#
# WHAT THIS PINS:
#   - Detection: a CTO pane PARKED on a cap banner (pane_state rc=2) is found and
#     named; an idle/working pane is not.
#   - THE HEADROOM GATE: alert only when the account is NOT genuinely capped —
#     verdict AT or UNKNOWN SUPPRESSES the alert (those parks are expected); OK
#     and NEAR alert (the park is anomalous = a stuck lead).
#   - DEDUP: one alert per distinct parked SET; an unchanged set does not re-post;
#     a changed set re-posts; a recovered (empty) set clears the marker so a later
#     re-park alerts again.
#   - THE NON-INTERFERENCE INVARIANT: the alerter only READS panes — it NEVER
#     sends keys, kills, restarts, or creates any session. Proven from the mock
#     tmux log.
#
# Mock tmux serves a per-session capture frame; the Discord post is stubbed via
# SWARM_REAUTH_VERIFY_POST_CMD (records channel + payload). No real tmux/network.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-reauth-verify.sh
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
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/reauth-verify-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-reauth-verify.sh" "$FAKE_SH/bin/swarm-reauth-verify.sh"
chmod +x "$FAKE_SH/bin/swarm-reauth-verify.sh"
VERIFY="$FAKE_SH/bin/swarm-reauth-verify.sh"

cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo-prodtest | BOT_TEST | 555 | |
alpha    | $TMP/repo-alpha    | BOT_A    | 111 | |
beta     | $TMP/repo-beta     | BOT_B    | 222 | |
EOF

MOCK_TMUX="$TMP/stubbin/tmux"
MOCK_TMUX_LOG="$TMP/tmux.log"
MOCK_PANE_DIR="$TMP/panes"
mkdir -p "$TMP/stubbin" "$MOCK_PANE_DIR"
cat > "$MOCK_TMUX" <<'EOF'
#!/usr/bin/env bash
# Mock tmux: has-session/capture-pane keyed on the -t <session> argument.
#   live sessions = $MOCK_LIVE (space list); a pane's frame = $MOCK_PANE_DIR/<sess>.txt
set -u
printf '%s\n' "$*" >> "${MOCK_TMUX_LOG:?}"
cmd="${1:-}"; shift || true
sess=""; want=0
for a in "$@"; do
  if [ "$want" = 1 ]; then sess="$a"; want=0; fi
  [ "$a" = "-t" ] && want=1
done
case "$cmd" in
  has-session) case " ${MOCK_LIVE:-} " in *" $sess "*) exit 0 ;; *) exit 1 ;; esac ;;
  capture-pane) f="${MOCK_PANE_DIR:?}/$sess.txt"; [ -f "$f" ] && cat "$f"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_TMUX"

CAP_FRAME='Claude usage limit reached · resets 3pm
❯'
IDLE_FRAME='❯
  ⏵⏵ auto mode on · ← for agents'

POST_LOG="$TMP/post.log"
STATE_DIR="$TMP/state"

# set_pane SESSION FRAME
set_pane() { printf '%s\n' "$2" > "$MOCK_PANE_DIR/$1.txt"; }
clear_panes() { rm -f "$MOCK_PANE_DIR"/*.txt 2>/dev/null || true; }

# run_verify VERDICT : sets $OUT/$rc, records posts to $POST_LOG.
run_verify() {
  local verdict="$1"
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_TMUX_BIN="$MOCK_TMUX"
    export SWARM_STATE_DIR="$STATE_DIR"
    export SWARM_REAUTH_VERIFY_SWARM="prodtest"
    export SWARM_TICK_POLL_VERDICT="$verdict"
    # The post seam is run as `sh -c "$POST_CMD" _ <channel> <content>`, so $1 is
    # the channel and $2 the content. Record both; no nested sh -c (that would
    # start a fresh shell with no positional args).
    export SWARM_REAUTH_VERIFY_POST_CMD='printf "chan=%s :: %s\n" "$1" "$2" >> '"$POST_LOG"
    export MOCK_TMUX_LOG MOCK_PANE_DIR
    export MOCK_LIVE="swarm-prodtest swarm-alpha swarm-beta"
    bash "$VERIFY" 2>&1
  )"; rc=$?
}
posts() { cat "$POST_LOG" 2>/dev/null || true; }
# grep -c prints "0" AND exits 1 on no match; swallow the exit so we don't append
# a second "0" via a fallback. Always yields exactly one integer.
post_count() { local n; n="$(grep -c '^chan=' "$POST_LOG" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

reset_all() { clear_panes; : > "$POST_LOG"; rm -rf "$STATE_DIR"; : > "$MOCK_TMUX_LOG"; }

echo "=== 1) one pane PARKED, verdict OK -> alert names it, to the product channel ==="
reset_all
set_pane swarm-alpha "$CAP_FRAME"
set_pane swarm-prodtest "$IDLE_FRAME"
set_pane swarm-beta "$IDLE_FRAME"
run_verify OK
assert_eq 0 "$rc" "exit 0"
assert_eq 1 "$(post_count)" "exactly one alert posted"
assert_has "$(posts)" "chan=555" "alert went to the product row's channel (555)"
assert_has "$(posts)" "alpha" "alert names the parked swarm 'alpha'"
assert_lacks "$(posts)" "beta" "alert does not name the idle swarm 'beta'"

echo "--- THE NON-INTERFERENCE INVARIANT: only reads, never acts ---"
assert_lacks "$(cat "$MOCK_TMUX_LOG")" "send-keys" "never sends keys to any pane"
assert_lacks "$(cat "$MOCK_TMUX_LOG")" "kill-session" "never kills a session"
assert_lacks "$(cat "$MOCK_TMUX_LOG")" "new-session" "never creates a session"

echo "=== 2) DEDUP: same parked set, next tick -> NO re-post ==="
# marker persists from test 1 (do not reset state)
: > "$POST_LOG"; : > "$MOCK_TMUX_LOG"
run_verify OK
assert_eq 0 "$rc" "exit 0"
assert_eq 0 "$(post_count)" "unchanged parked set does not re-alert"
assert_has "$OUT" "already alerted" "reports it already alerted this set"

echo "=== 3) CHANGED set (beta parks too) -> re-post ==="
: > "$POST_LOG"
set_pane swarm-beta "$CAP_FRAME"
run_verify OK
assert_eq 1 "$(post_count)" "a changed parked set re-alerts"
assert_has "$(posts)" "alpha" "alert lists alpha"
assert_has "$(posts)" "beta" "alert lists beta (newly parked)"

echo "=== 4) RECOVERED: no parked panes -> no post, marker cleared ==="
: > "$POST_LOG"
clear_panes
set_pane swarm-alpha "$IDLE_FRAME"; set_pane swarm-beta "$IDLE_FRAME"; set_pane swarm-prodtest "$IDLE_FRAME"
run_verify OK
assert_eq 0 "$(post_count)" "no alert when nothing is parked"
assert_has "$OUT" "no CTO pane is parked" "reports the all-clear"
[ -f "$STATE_DIR/swarm-reauth-verify.last" ] && bad "marker should be cleared when nothing is parked" || ok "dedup marker cleared on recovery"

echo "=== 5) re-park AFTER recovery alerts again (marker was cleared) ==="
: > "$POST_LOG"
set_pane swarm-alpha "$CAP_FRAME"
run_verify OK
assert_eq 1 "$(post_count)" "a re-park after recovery alerts again"

echo "=== 6) HEADROOM GATE: parked pane but verdict AT -> SUPPRESSED ==="
reset_all
set_pane swarm-alpha "$CAP_FRAME"; set_pane swarm-prodtest "$IDLE_FRAME"; set_pane swarm-beta "$IDLE_FRAME"
run_verify AT
assert_eq 0 "$rc" "exit 0"
assert_eq 0 "$(post_count)" "verdict AT suppresses the alert (genuine cap, not a stuck lead)"
assert_has "$OUT" "suppressed" "reports suppression"
[ -f "$STATE_DIR/swarm-reauth-verify.last" ] && bad "suppressed tick must NOT write the marker" || ok "suppressed tick leaves the marker untouched"

echo "=== 7) SUPPRESS then OK -> the still-stuck pane DOES alert (marker untouched by suppression) ==="
: > "$POST_LOG"
run_verify OK
assert_eq 1 "$(post_count)" "after suppression lifts, the stuck pane alerts"

echo "=== 8) verdict UNKNOWN also suppresses ==="
reset_all
set_pane swarm-alpha "$CAP_FRAME"; set_pane swarm-prodtest "$IDLE_FRAME"; set_pane swarm-beta "$IDLE_FRAME"
run_verify UNKNOWN
assert_eq 0 "$(post_count)" "verdict UNKNOWN suppresses (ambiguous)"

echo "=== 9) NEAR still alerts (account has headroom, park is anomalous) ==="
reset_all
set_pane swarm-alpha "$CAP_FRAME"; set_pane swarm-prodtest "$IDLE_FRAME"; set_pane swarm-beta "$IDLE_FRAME"
run_verify NEAR
assert_eq 1 "$(post_count)" "verdict NEAR alerts (still has headroom)"

echo "=== 10) config: unknown alert swarm -> exit 2 ==="
OUT="$(SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX" SWARM_STATE_DIR="$STATE_DIR" \
  SWARM_REAUTH_VERIFY_SWARM="does-not-exist" SWARM_REAUTH_VERIFY_POST_CMD='true' \
  MOCK_LIVE="" MOCK_PANE_DIR="$MOCK_PANE_DIR" bash "$VERIFY" 2>&1)"; rc=$?
assert_eq 2 "$rc" "unknown alert swarm -> config error 2"

echo "=== 11) config: bad SWARM_HOME -> exit 2 ==="
OUT="$(SWARM_HOME="$TMP/nope" bash "$VERIFY" 2>&1)"; rc=$?
assert_eq 2 "$rc" "bad SWARM_HOME -> config error 2"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
