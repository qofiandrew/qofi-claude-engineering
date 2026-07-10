#!/usr/bin/env bash
# test-swarm-limit-transcript.sh — regression tests for the TRANSCRIPT tier in
# bin/swarm-limit-detect.sh --or-poll: Claude Code writes
# `"error":"rate_limit","isApiErrorMessage":true` events (TOP-LEVEL keys, ISO
# timestamp) into the lead's session jsonl the moment the API throttles it —
# durable per-lead ground truth, unlike the pane's transient status strip
# (which cost a missed real deployment-core limit on 2026-07-10).
#
# WHAT THIS PINS:
#   - a recent top-level rate_limit event -> AT (exit 20), naming the swarm;
#   - an event OLDER than the window -> no fire (delegates);
#   - a NESTED mention (a lead writing about rate limits inside message
#     content) -> never fires (top-level-key parsing, not substring);
#   - an authentication_failed event -> not this tier's signal;
#   - the hour-bucket latch: same bucket answered -> suppressed; and the
#     re-prompt cooldown bounds an unanswered prompt;
#   - hermeticity: an injected pane stub DISABLES the tier unless
#     SWARM_XSCRIPT_TIER=1; window=0 disables it outright;
#   - the tail knob: an event deeper than SWARM_XSCRIPT_TAIL_BYTES is missed
#     (pinning WHY the default is generous) and found when the tail covers it.
#
# Fixtures are synthetic jsonl files under a fake CLAUDE_PROJECTS_DIR (the
# default-account projects dir swarm_account_resolve hands the scanner).
# bash 3.2-safe. Run from $SWARM_HOME: bash tests/test-swarm-limit-transcript.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECT="$ROOT/bin/swarm-limit-detect.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/limit-xscript-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/templates"
REPO="$TMP/repos/alpha"; mkdir -p "$REPO"
cat > "$FAKE_HOME/swarm.conf" <<CONF
alpha | $REPO | ALPHA_TOK | 111 | 999
CONF

PROXY="$TMP/proxy.sh"
printf '#!/usr/bin/env bash\necho "stub-proxy"\nexit "${PROXY_RC:-0}"\n' > "$PROXY"
chmod +x "$PROXY"

PROJ="$TMP/projects"
# the scanner derives the transcript dir name the same way repo_activity does:
LEAD_ENC="$(printf '%s' "$REPO" | sed 's/[/.]/-/g')"
TDIR="$PROJ/$LEAD_ENC"
STATE="$TMP/state"
PENDING="$STATE/swarm-pane-signal.pending"
LATCHED="$STATE/swarm-pane-signal.latched"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || python3 -c "import datetime,sys;print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }

# write_event FILE EPOCH KIND — append one top-level api-error event line.
write_event() {
  local f="$1" ep="$2" kind="${3:-rate_limit}"
  printf '{"timestamp":"%s","error":"%s","isApiErrorMessage":true,"apiErrorStatus":429,"session_id":"synthetic"}\n' "$(iso "$ep")" "$kind" >> "$f"
}
# write_noise FILE — a normal assistant event (bulk filler / non-error line).
write_noise() {
  printf '{"timestamp":"%s","type":"assistant","message":{"content":"working"}}\n' "$(iso "$(date +%s)")" >> "$1"
}

reset_fix() { rm -rf "$PROJ" "$STATE"; mkdir -p "$TDIR"; }

run_x() {  # [env overrides via T_*] -> OUT, rc
  OUT="$(SWARM_HOME="$FAKE_HOME" \
         CLAUDE_PROJECTS_DIR="$PROJ" \
         SWARM_STATE_DIR="$STATE" \
         SWARM_PANE_STATE_CMD='exit 1' \
         SWARM_XSCRIPT_TIER=1 \
         SWARM_XSCRIPT_LIMIT_WINDOW="${T_WINDOW:-900}" \
         SWARM_XSCRIPT_TAIL_BYTES="${T_TAIL:-4194304}" \
         SWARM_PANE_REPROMPT_COOLDOWN="${T_REPROMPT:-0}" \
         SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" --or-poll 2>&1)"; rc=$?
}

echo "=== 1) recent top-level rate_limit event -> AT, names the swarm ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
run_x
assert_eq 20 "$rc" "recent rate_limit -> AT (exit 20)"
assert_has "$OUT" "TRANSCRIPT record" "reports the transcript source"
assert_has "$OUT" "alpha" "names the swarm"
assert_has "$(cat "$PENDING" 2>/dev/null)" "transcript rate_limit alpha" "pending carries the hour-bucket signature"

echo ""
echo "=== 2) event older than the window -> delegates ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 3600 ))"
PROXY_RC=0 run_x
assert_eq 0 "$rc" "hour-old event with a 900s window -> no fire"

echo ""
echo "=== 3) NESTED mention (lead writing about rate limits) never fires ==="
reset_fix
printf '{"timestamp":"%s","type":"assistant","message":{"content":"we handle \\"error\\":\\"rate_limit\\",\\"isApiErrorMessage\\":true in the retry loop"}}\n' "$(iso "$(date +%s)")" >> "$TDIR/sess.jsonl"
PROXY_RC=0 run_x
assert_eq 0 "$rc" "nested marker text inside content -> not a top-level event, no fire"

echo ""
echo "=== 4) authentication_failed is not this tier's signal ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))" "authentication_failed"
PROXY_RC=0 run_x
assert_eq 0 "$rc" "auth-failure event -> no fire (only rate_limit)"

echo ""
echo "=== 5) hour-bucket latch: answered bucket -> suppressed; new hour re-fires ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
run_x                                              # fires; pending armed
# promote as swarm-reauth does (epoch-stamped append), age past the cooldown
mkdir -p "$STATE"
awk -v now="$(( $(date +%s) - 86400 ))" 'NF { print now "\t" $0 }' "$PENDING" >> "$LATCHED"
rm -f "$PENDING"; touch -t 202601010000 "$LATCHED"
PROXY_RC=0 run_x
assert_eq 0 "$rc" "same swarm-hour bucket after a successful re-auth -> suppressed"
assert_has "$OUT" "suppressed" "reports the suppression"

echo ""
echo "=== 6) re-prompt cooldown bounds an unanswered transcript prompt ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
T_REPROMPT=3600 run_x
assert_eq 20 "$rc" "first fire"
PROXY_RC=0 T_REPROMPT=3600 run_x
assert_eq 0 "$rc" "unanswered -> next tick suppressed by the re-prompt cooldown"
T_REPROMPT=0

echo ""
echo "=== 7) hermeticity: pane stub without SWARM_XSCRIPT_TIER disables the tier ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
OUT="$(SWARM_HOME="$FAKE_HOME" CLAUDE_PROJECTS_DIR="$PROJ" SWARM_STATE_DIR="$STATE" \
       SWARM_PANE_STATE_CMD='exit 1' \
       SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" --or-poll 2>&1)"; rc=$?
assert_eq 0 "$rc" "injected pane stub, no force flag -> tier inert (delegates)"

echo ""
echo "=== 8) window=0 disables the tier outright ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
T_WINDOW=0 PROXY_RC=0 run_x
assert_eq 0 "$rc" "SWARM_XSCRIPT_LIMIT_WINDOW=0 -> no scan, delegates"

echo ""
echo "=== 9) the tail knob: an event buried past the tail is missed; a covering tail finds it ==="
reset_fix
write_event "$TDIR/sess.jsonl" "$(( $(date +%s) - 60 ))"
for i in $(seq 1 2000); do write_noise "$TDIR/sess.jsonl"; done   # ~170KB after the event
T_TAIL=65536 PROXY_RC=0 run_x
assert_eq 0 "$rc" "64KB tail cannot reach the buried event (pins why the default is 4MB)"
T_TAIL=4194304 run_x
assert_eq 20 "$rc" "4MB tail finds the same event"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
