#!/usr/bin/env bash
# test-swarm-limit-near-notice.sh — regression tests for the PANE-NOTICE tier
# and the SIGNATURE LATCH in bin/swarm-limit-detect.sh --or-poll (the fallback
# trigger the operator asked for: catch the yellow "You've used N% of your
# <session|weekly> limit · resets X" warning straight off the panes).
#
# WHAT THIS PINS:
#   - A pane notice at >= threshold -> NEAR (exit 10), ahead of the delegated
#     poll; below threshold -> delegate. The no-percent "Approaching <limit>"
#     form always qualifies.
#   - THE LATCH (anti-loop): firing writes the PENDING signature (percentless —
#     the climbing 95->98 must NOT re-fire); a signature equal to LATCHED is
#     suppressed (delegates); a fresh LATCHED mtime suppresses the whole pane
#     tier for the cooldown, even for a NEW signature; an old LATCHED with a
#     new signature fires. swarm-reauth.sh promotes pending->latched ONLY on a
#     successful re-auth (pinned in test-swarm-reauth.sh).
#   - The cap tier (pane_state rc=2 -> AT) goes through the SAME latch.
#   - The benign Fable allowance notice and plain prose never fire.
#   - The notice tier is DISABLED when pane-state is injected without a notice
#     cmd (pre-tier tests/observers stay hermetic).
#
# All observation is injected (SWARM_PANE_STATE_CMD + SWARM_PANE_NOTICE_CMD);
# the delegated poll is a stub. No real tmux, fleet, or network. bash 3.2-safe.

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
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/limit-near-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/templates"
cat > "$FAKE_HOME/swarm.conf" <<'CONF'
alpha | ~/repos/alpha | ALPHA_TOK | 111 | 999
beta  | ~/repos/beta  | BETA_TOK  | 222 | 999
CONF

PROXY="$TMP/proxy.sh"
cat > "$PROXY" <<'EOF'
#!/usr/bin/env bash
echo "stub-proxy verdict"
exit "${PROXY_RC:-0}"
EOF
chmod +x "$PROXY"

STATE="$TMP/latch-state"
PENDING="$STATE/swarm-pane-signal.pending"
LATCHED="$STATE/swarm-pane-signal.latched"

# Notice fixtures use the real templates (binary v2.1.206), one file per
# session; the injected notice stub prints $TMP/notices/<session>.txt if present.
set_notice() {  # SESSION LINES...
  local s="$1"; shift
  printf '%s\n' "$@" > "$TMP/notices/$s.txt"
}
clear_notices() { rm -rf "$TMP/notices"; mkdir -p "$TMP/notices"; }

NOTICE_STUB='[ -f "'"$TMP"'/notices/$1.txt" ] && { cat "'"$TMP"'/notices/$1.txt"; exit 0; }; exit 1'

# run [--keep-state] PANE_STUB [flags...] -> OUT, rc
KEEP=0
run() {
  if [ "$1" = "--keep-state" ]; then KEEP=1; shift; else KEEP=0; fi
  local stub="$1"; shift
  [ "$KEEP" -eq 0 ] && rm -rf "$STATE"
  OUT="$(SWARM_HOME="$FAKE_HOME" \
         SWARM_PANE_STATE_CMD="$stub" \
         SWARM_PANE_NOTICE_CMD="$NOTICE_STUB" \
         SWARM_STATE_DIR="$STATE" \
         SWARM_ROTATE_THRESHOLD_PCT="${T_THRESH:-95}" \
         SWARM_PANE_LATCH_COOLDOWN="${T_COOLDOWN:-900}" \
         SWARM_PANE_REPROMPT_COOLDOWN="${T_REPROMPT:-0}" \
         SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" "$@" 2>&1)"; rc=$?
}
IDLE_STUB='exit 1'   # every pane at-prompt (readable, no cap)

# promote — simulate swarm-reauth.sh's SUCCESS promotion: append the pending
# signature to latched, epoch-stamped (the file is a SET), consume pending.
promote() {
  local now; now="$(date +%s)"
  awk -v now="$now" 'NF { print now "\t" $0 }' "$PENDING" >> "$LATCHED"
  rm -f "$PENDING"
}
# age_latched — push every latched entry's epoch AND the file mtime into the
# past (cooldown out of play; TTL still satisfied).
age_latched() {
  awk -F'\t' -v old="$(( $(date +%s) - 86400 ))" 'NF>=2 { print old "\t" substr($0, index($0,"\t")+1) }' "$LATCHED" > "$LATCHED.tmp" && mv "$LATCHED.tmp" "$LATCHED"
  touch -t 202601010000 "$LATCHED"
}

echo "=== 1) notice >= threshold -> NEAR (exit 10), pending signature written ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
run "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "95% notice at threshold 95 -> NEAR (exit 10)"
assert_has "$OUT" "PANE notice" "reports the pane-notice source"
assert_has "$OUT" "95% of your session limit" "carries the matched line"
assert_has "$OUT" " alpha" "names the swarm"
[ -f "$PENDING" ] && ok "pending signature written" || bad "pending signature written"
assert_has "$(cat "$PENDING" 2>/dev/null)" "% of your session limit · resets 8:39am" "signature keeps the resets identity"
assert_lacks "$(cat "$PENDING" 2>/dev/null)" "95" "signature is PERCENTLESS (a climb must not re-fire)"

echo ""
echo "=== 2) below threshold -> delegate to the poll ==="
clear_notices
set_notice swarm-alpha "You've used 80% of your session limit · resets 8:39am"
PROXY_RC=0 run "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "80% with threshold 95 -> delegate (poll OK)"
assert_has "$OUT" "delegating" "reports delegation"
[ -f "$PENDING" ] && bad "no pending written below threshold" || ok "no pending written below threshold"

echo ""
echo "=== 3) 'Approaching <limit>' (no percentage) always qualifies ==="
clear_notices
set_notice swarm-beta "Approaching weekly limit · resets Jul 13"
run "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "Approaching form -> NEAR"

echo ""
echo "=== 4) benign allowance notice and prose never fire ==="
clear_notices
set_notice swarm-alpha "▎ Through July 12, you can use up to 50% of your weekly usage limit on Fable 5."
PROXY_RC=0 run "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "Fable allowance notice -> not a trigger (delegates)"
clear_notices
set_notice swarm-alpha "we should watch the session limit and warn at 90% of your budget"
PROXY_RC=0 run "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "prose without the exact notice phrasing -> delegates"

echo ""
echo "=== 5) THE LATCH: promoted signature -> suppressed (delegates) ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
run "$IDLE_STUB" --or-poll                       # fires; writes pending
promote                                           # swarm-reauth success promotion
touch -t 202601010000 "$LATCHED"                  # old mtime: cooldown NOT in play
set_notice swarm-alpha "You've used 98% of your session limit · resets 8:39am"  # pct climbed
PROXY_RC=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "same window (98% now, same resets) -> suppressed, delegates"
assert_has "$OUT" "suppressed" "reports the suppression"
[ -f "$PENDING" ] && bad "suppressed run must not re-arm pending" || ok "suppressed run must not re-arm pending"

echo ""
echo "=== 6) new window signature + OLD latch -> fires again ==="
set_notice swarm-alpha "You've used 95% of your session limit · resets 1:39pm"  # window rolled
run --keep-state "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "new resets identity -> NEAR fires again"
rm -f "$PENDING"

echo ""
echo "=== 7) cooldown: FRESH latch suppresses even a NEW signature ==="
touch "$LATCHED"                                  # fresh success moments ago
set_notice swarm-alpha "You've used 96% of your weekly limit · resets Jul 13"
PROXY_RC=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "fresh latch (cooldown) -> pane tier suppressed, delegates"
T_COOLDOWN=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "cooldown=0 disables the time gate (signature differs -> fires)"

echo ""
echo "=== 7b) SUBSET semantics: a shrinking multi-pane union stays suppressed ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
set_notice swarm-beta  "You've used 96% of your weekly limit · resets Jul 13"
run "$IDLE_STUB" --or-poll                        # union fires
assert_eq 10 "$rc" "two-pane union fires once"
promote; age_latched                              # answered; cooldown out of play
clear_notices
set_notice swarm-alpha "You've used 97% of your session limit · resets 8:39am"  # beta's cleared
PROXY_RC=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "one pane's notice clearing (subset of the answered union) does NOT re-fire"

echo ""
echo "=== 7c) RE-PROMPT cooldown: unanswered prompt does not spam every tick ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
T_REPROMPT=3600 run "$IDLE_STUB" --or-poll        # fires; pending stamped now
assert_eq 10 "$rc" "first fire goes out"
PROXY_RC=0 T_REPROMPT=3600 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "next tick, unanswered -> suppressed by the re-prompt cooldown"
touch -t 202601010000 "$PENDING"                  # an hour+ passed
T_REPROMPT=3600 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "after the re-prompt cooldown, the unanswered signal fires again"

echo ""
echo "=== 7d) unwritable STATE_DIR -> fail toward the poll (no unlatched spam) ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
rm -rf "$STATE"; touch "$STATE"                   # a FILE where the dir should be
PROXY_RC=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "cannot persist the latch -> does NOT fire; delegates"
assert_has "$OUT" "cannot persist" "warns loud about the unwritable latch"
rm -f "$STATE"

# bash gotcha: VAR=x func-call assignments LEAK past the call — reset explicitly
# so 7c's re-prompt cooldown doesn't bleed into the later cases.
T_REPROMPT=0

echo ""
echo "=== 8) the CAP tier goes through the same latch ==="
clear_notices
CAP_STUB='case "$1" in *alpha*) printf "Claude usage limit reached · resets 3pm\n"; exit 2;; *) exit 1;; esac'
run "$CAP_STUB" --or-poll
assert_eq 20 "$rc" "unlatched cap -> AT (exit 20)"
assert_has "$(cat "$PENDING" 2>/dev/null)" "usage limit reached · resets 3pm" "cap signature pending"
promote; age_latched
PROXY_RC=0 run --keep-state "$CAP_STUB" --or-poll
assert_eq 0 "$rc" "latched cap signature -> suppressed, delegates"
assert_has "$OUT" "manual nudge" "suppressed-cap message points at the stuck-pane path"

echo ""
echo "=== 8b) notice THEN cap for the same window: the cap still fires (set, not slot) ==="
clear_notices
set_notice swarm-alpha "You've used 95% of your session limit · resets 8:39am"
run "$IDLE_STUB" --or-poll; promote; age_latched  # notice answered
clear_notices
run --keep-state "$CAP_STUB" --or-poll            # now the cap banner appears
assert_eq 20 "$rc" "a cap line not in the answered set still fires AT"
promote; age_latched                              # cap answered too
set_notice swarm-alpha "You've used 99% of your session limit · resets 8:39am"
PROXY_RC=0 run --keep-state "$IDLE_STUB" --or-poll
assert_eq 0 "$rc" "the earlier notice signature was NOT evicted by the cap promotion (append, not overwrite)"

echo ""
echo "=== 9) poll passthrough intact when nothing fires ==="
clear_notices
PROXY_RC=10 run "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "no pane signal -> the poll's NEAR passes through"
PROXY_RC=3 run "$IDLE_STUB" --or-poll
assert_eq 3 "$rc" "no pane signal -> the poll's UNKNOWN passes through"

echo ""
echo "=== 9b) account switch near threshold: fresh pane latch never suppresses the percentage poll ==="
# A successful re-auth touches LATCHED and therefore suppresses the PANE tier for
# its short anti-loop cooldown. The newly selected account may already be near a
# limit, so the independent /usage percentage tier must remain live throughout:
# 90% is OK, then exactly 95% is NEAR on the very next tick. Use the REAL poller
# here (not the exit-code stub) and keep the fresh latch across both readings.
rm -rf "$STATE"; mkdir -p "$STATE"
: > "$LATCHED"
clear_notices
set_notice swarm-alpha "You've used 99% of your session limit · resets old-account-window"
SWITCH_PAYLOAD="$TMP/switched-account-usage.json"
printf '%s\n' '{"five_hour":{"used_pct":4},"weekly":{"used_pct":90},"account":"browser-selected-next"}' > "$SWITCH_PAYLOAD"
OUT="$(SWARM_HOME="$FAKE_HOME" \
       SWARM_PANE_STATE_CMD="$IDLE_STUB" SWARM_PANE_NOTICE_CMD="$NOTICE_STUB" \
       SWARM_STATE_DIR="$STATE" SWARM_ROTATE_THRESHOLD_PCT=95 \
       SWARM_PANE_LATCH_COOLDOWN=900 SWARM_PANE_REPROMPT_COOLDOWN=0 \
       SWARM_USAGE_PROBE="cat '$SWITCH_PAYLOAD'" \
       SWARM_POLL_CMD_INNER="$ROOT/bin/swarm-usage-poll.sh" \
       bash "$DETECT" --or-poll 2>&1)"; rc=$?
assert_eq 0 "$rc" "new account at 90% during fresh pane cooldown -> poll remains live and reports OK"
assert_has "$OUT" "weekly=90%" "delegated poll reports the new account's 90% reading"
printf '%s\n' '{"five_hour":{"used_pct":5},"weekly":{"used_pct":95},"account":"browser-selected-next"}' > "$SWITCH_PAYLOAD"
OUT="$(SWARM_HOME="$FAKE_HOME" \
       SWARM_PANE_STATE_CMD="$IDLE_STUB" SWARM_PANE_NOTICE_CMD="$NOTICE_STUB" \
       SWARM_STATE_DIR="$STATE" SWARM_ROTATE_THRESHOLD_PCT=95 \
       SWARM_PANE_LATCH_COOLDOWN=900 SWARM_PANE_REPROMPT_COOLDOWN=0 \
       SWARM_USAGE_PROBE="cat '$SWITCH_PAYLOAD'" \
       SWARM_POLL_CMD_INNER="$ROOT/bin/swarm-usage-poll.sh" \
       bash "$DETECT" --or-poll 2>&1)"; rc=$?
assert_eq 10 "$rc" "new account reaching exactly 95% on the next tick -> NEAR despite fresh pane cooldown"
assert_has "$OUT" "weekly=95%" "inclusive 95% evidence comes from the new account's delegated poll"

echo ""
echo "=== 10) tier disabled when pane-state injected WITHOUT a notice cmd ==="
clear_notices
set_notice swarm-alpha "You've used 99% of your session limit · resets 8:39am"
OUT="$(SWARM_HOME="$FAKE_HOME" SWARM_PANE_STATE_CMD="$IDLE_STUB" \
       SWARM_STATE_DIR="$STATE" SWARM_ROTATE_THRESHOLD_PCT=95 \
       SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" --or-poll 2>&1)"; rc=$?
assert_eq 0 "$rc" "no notice seam + injected pane-state -> tier inert (delegates)"

echo ""
echo "=== 11) multi-pane: max percentage across panes decides ==="
clear_notices
set_notice swarm-alpha "You've used 60% of your session limit · resets 8:39am"
set_notice swarm-beta  "You've used 97% of your weekly limit · resets Jul 13"
run "$IDLE_STUB" --or-poll
assert_eq 10 "$rc" "one pane at 97 fires even though another is at 60"
assert_has "$OUT" "97% of your weekly limit" "evidence line is the QUALIFYING (max-pct) line, not just the first"

echo ""
echo "=== 12) the REAL grep path (no notice seam): patterns + exclusions do the work ==="
# A fake tmux binary exercises probe_notice's DEFAULT implementation — the ERE
# match and the exclusion filter that the injected seam bypasses everywhere
# else. Frames per session live in $TMP/frames-real/<session>.txt.
mkdir -p "$TMP/frames-real" "$TMP/fakebin"
cat > "$TMP/fakebin/tmux" <<EOF
#!/usr/bin/env bash
cmd="\$1"; shift
sess=""; want=0
for a in "\$@"; do [ "\$want" = 1 ] && { sess="\$a"; want=0; }; [ "\$a" = "-t" ] && want=1; done
case "\$cmd" in
  has-session) [ -f "$TMP/frames-real/\$sess.txt" ] ;;
  capture-pane) cat "$TMP/frames-real/\$sess.txt" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/fakebin/tmux"
run_real() {  # writes OUT/rc using the fake tmux (no injected seams at all)
  rm -rf "$STATE"
  # CLAUDE_PROJECTS_DIR pinned to an empty fixture: without a pane stub the
  # TRANSCRIPT tier is enabled and would otherwise scan the REAL machine's
  # transcripts — a live rate_limit event would break these cases.
  mkdir -p "$TMP/empty-projects"
  OUT="$(SWARM_HOME="$FAKE_HOME" SWARM_TMUX_BIN="$TMP/fakebin/tmux" \
         SWARM_STATE_DIR="$STATE" SWARM_ROTATE_THRESHOLD_PCT=95 \
         SWARM_PANE_REPROMPT_COOLDOWN=0 CLAUDE_PROJECTS_DIR="$TMP/empty-projects" \
         SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" --or-poll 2>&1)"; rc=$?
}
IDLE_FOOT='❯
  ⏵⏵ auto mode on · ← for agents'
# (a) a model-scoped notice — the variant the fixed-substring set MISSED —
# matched by the ERE against a real capture:
printf '%s\n%s\n' "You've used 96% of your Fable 5 limit · resets Jul 13" "$IDLE_FOOT" > "$TMP/frames-real/swarm-alpha.txt"
printf '%s\n' "$IDLE_FOOT" > "$TMP/frames-real/swarm-beta.txt"
run_real
assert_eq 10 "$rc" "REAL grep path: model-scoped 'Fable 5 limit' notice -> NEAR"
# (b) the Fable allowance notice is EXCLUDED on the real path:
printf '%s\n%s\n' "▎ Through July 12, you can use up to 50% of your weekly usage limit on Fable 5." "$IDLE_FOOT" > "$TMP/frames-real/swarm-alpha.txt"
PROXY_RC=0 run_real
assert_eq 0 "$rc" "REAL grep path: allowance notice excluded -> delegates"
# (c) quoted/percentless pattern text (source code in a pane) does not fire:
printf '%s\n%s\n' 'NEAR_PATTERNS="% of your session limit|approaching usage limit"' "$IDLE_FOOT" > "$TMP/frames-real/swarm-alpha.txt"
PROXY_RC=0 run_real
assert_eq 0 "$rc" "REAL grep path: percentless quoted pattern text -> no fire (digits+% required)"
# (d) prose 'Approaching' without the '· resets' tail does not fire:
printf '%s\n%s\n' "we are Approaching usage limit territory here" "$IDLE_FOOT" > "$TMP/frames-real/swarm-alpha.txt"
PROXY_RC=0 run_real
assert_eq 0 "$rc" "REAL grep path: 'Approaching' prose without '· resets' -> no fire"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
