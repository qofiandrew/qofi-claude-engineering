#!/usr/bin/env bash
# test-swarm-login-relay.sh — regression tests for bin/swarm-login-relay.sh,
# the user-assisted /login re-auth actuator that drops into swarm-rotate's
# SWARM_CREDSWAP_CMD seam. SYNTHETIC-FIXTURE discipline (mirrors
# test-swarm-credswap.sh / test-swarm-rotate.sh):
#   - MOCK tmux: a script that RECORDS every invocation (send-keys included)
#     and serves SCRIPTED capture-pane frames (frame-1.txt, frame-2.txt, …;
#     each capture advances; sticks on the last frame).
#   - MOCK Discord: a PATH-stubbed `curl` that records the full argv (payload
#     included) and emits a scripted HTTP code. NEVER a real call to Discord.
#   - STUB auth probe via SWARM_LOGIN_AUTHCHECK_CMD.
#   - The bot token is a SYNTHETIC marker; the no-leak assertions prove even
#     that throwaway value never reaches stdout/stderr.
#
# FRAME ACCOUNTING: the relay captures the pane once inside the clean-boundary
# guard (pane_working) and once for the BASELINE, so every scripted sequence is
# [guard-frame, baseline-frame, poll-frames…].
#
# WHAT THIS PROTECTS (the directive's nine cases + adversarial-review closes):
#   1. Happy path: /login sent (exact keystrokes C-u "/login" Enter, one call)
#      -> FRESH URL scraped -> posted (payload contains the URL, exactly, and
#      the channel) -> success frame -> resume Enter AFTER the success capture
#      -> probe 0 -> exit 0. Curl argv shape (-o /dev/null, --max-time) and
#      capture argv shape (-J) asserted, not just outcomes.
#   2. Method-picker frame -> exactly ONE extra Enter -> then URL frame; and
#      stale conversation text can neither trigger a stray Enter nor burn the
#      once-flag before the real picker renders.
#   3. URL timeout -> Escape sent, non-zero, NO Discord message.
#   4. Discord post failure -> Escape sent, loud non-zero exit (6).
#   5. Auth-wait timeout -> timeout notice posted, Escape, non-zero (8).
#   6. Probe 75 after login -> exit 7 (ring-exhaustion mapping); probe fail -> 4.
#   7. Working pane without --force -> refuse BEFORE touching the pane;
#      --force proceeds. Unverifiable pane also refuses (fail closed).
#   8. Seam contract: invoked exactly the way swarm-rotate invokes
#      SWARM_CREDSWAP_CMD (SWARM_ROTATE_TO_ACCOUNT=x sh -c "$CMD" _ x) ->
#      behaves identically.
#   9. No-leak: the synthetic bot-token value never appears on stdout/stderr.
#  10. STALENESS (adversarial-review closes): a pre-/login URL in the pane is
#      never posted (bottom-most FRESH URL wins, TUI chrome not swallowed); a
#      stale "Login successful" line cannot end the operator window early.
#  11. Single-instance mkdir lock: live-owner contention refuses loud; a stale
#      lock is broken; the lock is released on exit.
#  12. Step-6 boundary re-check: a WORKING fleet delays the exit-0 handoff and
#      warns loud on timeout (still exit 0 — the re-auth is real).
#
# Run from $SWARM_HOME:  bash tests/test-swarm-login-relay.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; SKIP=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-login-relay-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── Fixture SWARM_HOME: templates/ + swarm.conf satisfy the relay's guard ────
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-login-relay.sh" "$FAKE_SH/bin/swarm-login-relay.sh"
chmod +x "$FAKE_SH/bin/swarm-login-relay.sh"
RELAY="$FAKE_SH/bin/swarm-login-relay.sh"

TEST_CHANNEL="999000111222333"
cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo-prodtest | BOT_TEST | $TEST_CHANNEL | |
other    | $TMP/repo-other    | BOT_OTHER | 444555666 | |
EOF
mkdir -p "$TMP/repo-prodtest" "$TMP/repo-other"
EMPTY_PROJ="$TMP/proj-empty"; mkdir -p "$EMPTY_PROJ"

# Synthetic bot token — NOT a real credential. The no-leak assertions prove
# even this throwaway marker never reaches the relay's stdout/stderr.
SYNTH_TOKEN="SYNTH-BOT-TOKEN-do-not-leak-$$"
printf 'export BOT_TEST="%s"\n' "$SYNTH_TOKEN" > "$FAKE_SH/tokens.env"
chmod 600 "$FAKE_SH/tokens.env"
# A tokens file WITHOUT the swarm's var, for the missing-token refusal.
printf 'export BOT_OTHER="unrelated"\n' > "$FAKE_SH/tokens-missing.env"

# ── MOCK tmux: records every invocation; serves scripted capture frames ─────
MOCK_TMUX="$TMP/stubbin/tmux"
MOCK_TMUX_LOG="$TMP/tmux.log"
MOCK_FRAMES_DIR="$TMP/frames"
mkdir -p "$TMP/stubbin" "$MOCK_FRAMES_DIR"
cat > "$MOCK_TMUX" <<'EOF'
#!/usr/bin/env bash
# Mock tmux — faithful to the calls the relay makes:
#   has-session   exit code from $MOCK_HAS_SESSION_RC (default 0 = exists)
#   send-keys     recorded, exit 0
#   capture-pane  prints frame-N.txt from $MOCK_FRAMES_DIR and advances the
#                 counter; when past the last frame, STICKS on the last one
#                 (a real pane keeps showing its final state).
set -u
log="${MOCK_TMUX_LOG:?}"
frames="${MOCK_FRAMES_DIR:?}"
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  has-session) exit "${MOCK_HAS_SESSION_RC:-0}" ;;
  send-keys)   exit 0 ;;
  capture-pane)
    n="$(cat "$frames/.counter" 2>/dev/null || echo 1)"
    f="$frames/frame-$n.txt"
    if [ -f "$f" ]; then
      echo $((n+1)) > "$frames/.counter"
    else
      last=0
      for ff in "$frames"/frame-*.txt; do
        [ -f "$ff" ] || continue
        num="${ff##*frame-}"; num="${num%.txt}"
        case "$num" in *[!0-9]*) continue ;; esac
        [ "$num" -gt "$last" ] && last="$num"
      done
      [ "$last" -eq 0 ] && exit 1
      f="$frames/frame-$last.txt"
    fi
    cat "$f"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_TMUX"

# ── MOCK curl (Discord): records argv incl. payload; scripted HTTP code ─────
MOCK_CURL_LOG="$TMP/curl.log"
cat > "$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
# Mock curl — records the full argv (the -d payload rides in it) and emits a
# scripted HTTP status code, exactly what the relay's `-w %{http_code}` reads.
# NEVER touches the network.
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
printf '%s' "${MOCK_CURL_CODE:-200}"
exit 0
EOF
chmod +x "$TMP/stubbin/curl"

# ── Scripted pane frames ─────────────────────────────────────────────────────
SYNTH_URL='https://claude.ai/oauth/authorize?code=true&client_id=SYNTH123&state=SYNTHSTATE'
STALE_URL='https://claude.ai/oauth/authorize?code=true&client_id=OLD999&state=OLDSTALE'
# The relay's default URL charset (kept in sync for exact-extraction asserts).
RELAY_URL_RE='https://[A-Za-z0-9./?=&_%:~#+-]*oauth[A-Za-z0-9./?=&_%:~#+-]*'
FRAME_IDLE='>
? for shortcuts · ← for agents'
FRAME_WORKING='✻ Baking… (esc to interrupt)'
FRAME_PICKER='Select login method:
 ❯ 1. Claude account with subscription
   2. Anthropic Console account'
FRAME_URL="Browser did not open? Use the url below to sign in:
$SYNTH_URL"
FRAME_SUCCESS='Login successful. Press Enter to continue…'
# Staleness fixtures: pre-/login pane content carrying a URL, a success line,
# and picker-ish prose. The URL-with-chrome frame renders the FRESH URL below
# the stale one, boxed in TUI border chars with NO space before the border.
FRAME_IDLE_STALEURL="earlier turn: the OAuth doc is at $STALE_URL
>
? for shortcuts · ← for agents"
FRAME_URL_SHADOWED="earlier turn: the OAuth doc is at $STALE_URL
Browser did not open? Use the url below to sign in:
│ ${SYNTH_URL}│"
FRAME_IDLE_OLDOK='Login successful. Press Enter to continue…
>
? for shortcuts · ← for agents'
FRAME_URL_OLDOK="Login successful. Press Enter to continue…
Browser did not open? Use the url below to sign in:
$SYNTH_URL"
FRAME_URL_OLDOK_FRESHOK="Login successful. Press Enter to continue…
Browser did not open? Use the url below to sign in:
$SYNTH_URL
Login successful. Press Enter to continue…"
FRAME_IDLE_SUBTEXT='we tier the subscription pricing model by seat, per the Console account docs
>
? for shortcuts · ← for agents'
# TWO fresh URLs (neither in the baseline): the login UI renders at the pane
# BOTTOM, so the bottom-most fresh match must win over a fresh-but-incidental
# URL above it.
FRAME_URL_TWOFRESH="See the oauth overview at https://docs.example.com/oauth/guide first
Browser did not open? Use the url below to sign in:
│ ${SYNTH_URL}│"

# reset_frames FRAME... — lay down the scripted capture sequence and clear the
# per-test logs/knobs. Frame 1 feeds the clean-boundary guard's pane_working
# capture, frame 2 the BASELINE; the URL/success polls consume the rest.
reset_frames() {
  rm -rf "$MOCK_FRAMES_DIR"; mkdir -p "$MOCK_FRAMES_DIR"
  local i=1
  for _f in "$@"; do
    printf '%s\n' "$_f" > "$MOCK_FRAMES_DIR/frame-$i.txt"
    i=$((i+1))
  done
  : > "$MOCK_TMUX_LOG"; : > "$MOCK_CURL_LOG"
  rm -rf "$TMP/state"
  T_HAS_SESSION_RC=0; T_CURL_CODE=200; T_AUTHCHECK='exit 0'
  T_URL_TIMEOUT=5; T_AUTH_TIMEOUT=5; T_IDLE_TIMEOUT=5; T_POLL=0
  T_TOKENS="$FAKE_SH/tokens.env"; T_PROJ="$EMPTY_PROJ"
}

# run_relay [args...] — invoke the relay against the mocks. Captures $OUT + $rc.
# Fast polls (interval 0); timeouts overridable per test via T_*. Hermetic:
# CLAUDE_PROJECTS_DIR points the step-6 boundary probe at a fixture dir, and
# the lock lives under a per-run SWARM_STATE_DIR.
run_relay() {
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_TMUX_BIN="$MOCK_TMUX"
    export SWARM_TOKENS_ENV="$T_TOKENS"
    export SWARM_STATE_DIR="$TMP/state"
    export CLAUDE_PROJECTS_DIR="$T_PROJ"
    export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG
    export MOCK_HAS_SESSION_RC="$T_HAS_SESSION_RC"
    export MOCK_CURL_CODE="$T_CURL_CODE"
    export SWARM_LOGIN_AUTHCHECK_CMD="$T_AUTHCHECK"
    export SWARM_LOGIN_URL_TIMEOUT="$T_URL_TIMEOUT"
    export SWARM_LOGIN_AUTH_TIMEOUT="$T_AUTH_TIMEOUT"
    export SWARM_LOGIN_IDLE_TIMEOUT="$T_IDLE_TIMEOUT"
    export SWARM_LOGIN_POLL_INTERVAL="$T_POLL"
    PATH="$TMP/stubbin:$PATH" bash "$RELAY" "$@" 2>&1
  )"; rc=$?
}

send_keys_log() { grep '^send-keys' "$MOCK_TMUX_LOG" 2>/dev/null || true; }
curl_log()      { cat "$MOCK_CURL_LOG" 2>/dev/null || true; }
curl_line()     { sed -n "${1}p" "$MOCK_CURL_LOG" 2>/dev/null || true; }
# The URL actually posted (first POST's payload), extracted with the relay's
# own default charset — EXACT comparison, not substring, so trailing chrome or
# a wrong (stale) URL fails the test.
posted_url()    { curl_line 1 | grep -oE "$RELAY_URL_RE" | head -n 1; }

echo "=== 1) HAPPY PATH: /login -> fresh URL -> posted -> success -> Enter -> probe 0 -> exit 0 ==="
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "happy path exits 0"
assert_eq "send-keys -t swarm-prodtest C-u /login Enter" "$(send_keys_log | head -n 1)" "exact /login keystrokes: ONE call, C-u then /login then Enter"
assert_eq "$SYNTH_URL" "$(posted_url)" "posted URL is EXACTLY the scraped login URL"
assert_has "$(curl_line 1)" "/channels/$TEST_CHANNEL/messages" "posted to the swarm's own channel"
assert_has "$(curl_line 1)" "-o /dev/null" "curl argv keeps -o /dev/null (http_code capture stays parseable)"
assert_has "$(curl_line 1)" "--max-time 10" "curl argv keeps --max-time (a stuck Discord call can't wedge the relay)"
assert_has "$(grep '^capture-pane' "$MOCK_TMUX_LOG" | tail -n 1)" " -J " "capture-pane uses -J (soft-wrapped URLs join to one line)"
assert_eq "send-keys -t swarm-prodtest Enter" "$(send_keys_log | tail -n 1)" "final key is the resume Enter"
last_sk_line="$(grep -n '^send-keys' "$MOCK_TMUX_LOG" | tail -n 1 | cut -d: -f1)"
last_cp_line="$(grep -n '^capture-pane' "$MOCK_TMUX_LOG" | tail -n 1 | cut -d: -f1)"
if [ -n "$last_sk_line" ] && [ -n "$last_cp_line" ] && [ "$last_sk_line" -gt "$last_cp_line" ]; then
  ok "resume Enter was sent AFTER the capture that served the success frame (ordering proven from the interleaved log)"
else
  bad "resume Enter ordering wrong (last send-keys line=$last_sk_line, last capture line=$last_cp_line)"
fi
assert_has "$(curl_line 2)" "Re-auth complete" "posted the success confirmation"
assert_has "$OUT" "DONE" "reports DONE"
assert_lacks "$(send_keys_log)" "Escape" "no Escape on the happy path (nothing to back out of)"
echo "--- 9) NO-LEAK: the synthetic bot token never appears on stdout/stderr ---"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from relay output (happy path)"
assert_has "$(curl_line 1)" "Authorization: Bot $SYNTH_TOKEN" "the built-in curl path used the swarm's own token (mock argv, never printed by the relay)"

echo ""
echo "=== 2) METHOD-PICKER: exactly ONE extra Enter, freshness-gated ==="
echo "--- 2a) picker persists two captures -> still ONE Enter -> then the URL ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_PICKER" "$FRAME_PICKER" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "picker path exits 0"
assert_eq 3 "$(send_keys_log | wc -l | tr -d ' ')" "exactly 3 send-keys: /login, ONE picker Enter, resume Enter"
assert_eq "send-keys -t swarm-prodtest Enter" "$(send_keys_log | sed -n '2p')" "the picker Enter is a single bare Enter"
assert_has "$OUT" "method-picker" "announces the picker handling"
assert_eq "$SYNTH_URL" "$(posted_url)" "URL still scraped and posted after the picker"
echo "--- 2b) stale conversation text (old broad patterns' false-positive) neither fires a stray Enter nor burns the once-flag ---"
reset_frames "$FRAME_IDLE_SUBTEXT" "$FRAME_IDLE_SUBTEXT" "$FRAME_IDLE_SUBTEXT" "$FRAME_PICKER" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "subscription-prose path exits 0"
assert_eq 3 "$(send_keys_log | wc -l | tr -d ' ')" "no stray Enter on 'subscription' prose; the real picker still gets its ONE Enter"
assert_eq "send-keys -t swarm-prodtest Enter" "$(send_keys_log | sed -n '2p')" "picker Enter fired for the REAL picker frame, after the prose frames"

echo ""
echo "=== 3) URL TIMEOUT -> Escape sent, non-zero, NO Discord message ==="
reset_frames "$FRAME_IDLE"        # idle sticks; no URL ever renders
T_URL_TIMEOUT=1
run_relay prodtest
assert_eq 5 "$rc" "URL timeout exits 5"
assert_eq "send-keys -t swarm-prodtest Escape" "$(send_keys_log | tail -n 1)" "backed out of the login UI (Escape)"
assert_eq "" "$(curl_log)" "NO Discord message posted (operator never pinged about a dead link)"
assert_has "$OUT" "no fresh login URL" "loud about the missing URL"

echo ""
echo "=== 4) DISCORD POST FAILURE -> Escape sent, loud non-zero exit ==="
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_CURL_CODE=500
run_relay prodtest
assert_eq 6 "$rc" "post failure exits 6"
assert_eq "send-keys -t swarm-prodtest Escape" "$(send_keys_log | tail -n 1)" "backed out (Escape) — never leave a login modal nobody knows about"
assert_eq 1 "$(wc -l < "$MOCK_CURL_LOG" | tr -d ' ')" "exactly one POST attempt (the failed URL post)"
assert_has "$OUT" "could not post" "loud about the failed post"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the post-failure path"

echo ""
echo "=== 5) AUTH-WAIT TIMEOUT -> timeout notice posted, Escape, non-zero ==="
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL"   # URL renders, success never does
T_AUTH_TIMEOUT=1
run_relay prodtest
assert_eq 8 "$rc" "auth-wait timeout exits 8"
assert_eq 2 "$(wc -l < "$MOCK_CURL_LOG" | tr -d ' ')" "two posts: the URL, then the timeout notice"
assert_has "$(curl_line 2)" "timed out" "the second post is the timeout notice"
assert_eq "send-keys -t swarm-prodtest Escape" "$(send_keys_log | tail -n 1)" "backed out (Escape) after the timeout"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the timeout path"

echo ""
echo "=== 6) PROBE VERDICT MAPPING (credswap exit-code contract) ==="
echo "--- 6a) probe 75 (authed-but-capped) -> exit 7 (ring-exhaustion signal) ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_AUTHCHECK='exit 75'
run_relay prodtest
assert_eq 7 "$rc" "probe 75 maps to exit 7 (ring exhaustion, matches credswap)"
assert_has "$(curl_line 2)" "CAPPED" "capped notice posted to the channel"
echo "--- 6b) probe hard-fail -> exit 4 (verify failed), loud ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_AUTHCHECK='exit 1'
run_relay prodtest
assert_eq 4 "$rc" "probe auth-fail maps to exit 4 (verify failed)"
assert_has "$OUT" "VERIFY FAILED" "loud about the failed verify"

echo ""
echo "=== 7) CLEAN-BOUNDARY GUARD ==="
echo "--- 7a) WORKING pane without --force -> refuse BEFORE touching the pane ---"
reset_frames "$FRAME_WORKING"
run_relay prodtest
assert_eq 3 "$rc" "working pane refuses with exit 3"
assert_eq "" "$(send_keys_log)" "NO keys were sent to the pane (refused before touching it)"
assert_eq "" "$(curl_log)" "no Discord post on refusal"
echo "--- 7b) WORKING pane WITH --force -> proceeds ---"
reset_frames "$FRAME_WORKING" "$FRAME_WORKING" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay --force prodtest
assert_eq 0 "$rc" "--force proceeds past a working pane"
assert_has "$OUT" "WARNING" "warns that it is interrupting a mid-turn pane"
echo "--- 7c) UNVERIFIABLE pane (empty capture) -> fail closed, refuse ---"
reset_frames ""
run_relay prodtest
assert_eq 3 "$rc" "unverifiable pane refuses with exit 3 (fail closed)"
assert_eq "" "$(send_keys_log)" "no keys sent to an unreadable pane"

echo ""
echo "=== 8) SEAM CONTRACT: invoked exactly as swarm-rotate invokes SWARM_CREDSWAP_CMD ==="
# swarm-rotate runs: SWARM_ROTATE_TO_ACCOUNT=<next> sh -c "$CMD" _ <next>
# with CMD wired WITHOUT "$1" — so the relay gets NO positional arg and the
# handle arrives via the env. Target swarm comes from SWARM_LOGIN_RELAY_SWARM.
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
OUT="$(
  export SWARM_HOME="$FAKE_SH"
  export SWARM_TMUX_BIN="$MOCK_TMUX"
  export SWARM_TOKENS_ENV="$FAKE_SH/tokens.env"
  export SWARM_STATE_DIR="$TMP/state"
  export CLAUDE_PROJECTS_DIR="$EMPTY_PROJ"
  export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG
  export MOCK_HAS_SESSION_RC=0 MOCK_CURL_CODE=200
  export SWARM_LOGIN_AUTHCHECK_CMD='exit 0'
  export SWARM_LOGIN_URL_TIMEOUT=5 SWARM_LOGIN_AUTH_TIMEOUT=5 SWARM_LOGIN_IDLE_TIMEOUT=5 SWARM_LOGIN_POLL_INTERVAL=0
  export SWARM_LOGIN_RELAY_SWARM="prodtest"
  export PATH="$TMP/stubbin:$PATH"
  SWARM_ROTATE_TO_ACCOUNT="max-b" sh -c "$RELAY" _ "max-b" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "rotate-style invocation exits 0 (drop-in credswap)"
assert_has "$OUT" "max-b" "the rotate handle is received and logged"
assert_has "$OUT" "operator's browser" "documents that the account choice happens in the browser"
assert_eq "$SYNTH_URL" "$(posted_url)" "rotate-style run still relays the exact URL"
assert_has "$(curl_line 1)" "max-b" "URL post names the rotation target handle for the operator"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the rotate-style path"

echo ""
echo "=== 10) STALENESS: pre-/login pane content never drives the flow ==="
echo "--- 10a) stale oauth URL in the pane is NOT posted; the fresh bottom URL is, without TUI chrome ---"
reset_frames "$FRAME_IDLE_STALEURL" "$FRAME_IDLE_STALEURL" "$FRAME_URL_SHADOWED" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "shadowed-URL path exits 0"
assert_eq "$SYNTH_URL" "$(posted_url)" "the FRESH bottom URL is posted — exact, no stale URL, no box-drawing chrome swallowed"
assert_lacks "$(curl_line 1)" "OLD999" "the stale pre-/login URL is never relayed to the operator"
echo "--- 10a2) two FRESH URLs -> the BOTTOM-most wins (the login UI renders at the pane bottom) ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL_TWOFRESH" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "two-fresh-URLs path exits 0"
assert_eq "$SYNTH_URL" "$(posted_url)" "the BOTTOM-most fresh URL is posted, not the incidental one above it"
assert_lacks "$(curl_line 1)" "docs.example.com" "the incidental fresh URL is never relayed"
echo "--- 10b) a URL already visible pre-/login never satisfies the scrape (fresh-only) ---"
reset_frames "$FRAME_IDLE_STALEURL" "$FRAME_IDLE_STALEURL"   # stale URL sticks; nothing fresh ever renders
T_URL_TIMEOUT=1
run_relay prodtest
assert_eq 5 "$rc" "stale-URL-only pane times out (exit 5) instead of posting the stale link"
assert_eq "" "$(curl_log)" "nothing was posted"
echo "--- 10c) stale 'Login successful' line cannot end the operator window early ---"
reset_frames "$FRAME_IDLE_OLDOK" "$FRAME_IDLE_OLDOK" "$FRAME_URL_OLDOK"   # old success line persists; no fresh success
T_AUTH_TIMEOUT=1
run_relay prodtest
assert_eq 8 "$rc" "stale success line -> still waits for the operator -> honest timeout (exit 8)"
assert_has "$(curl_line 2)" "timed out" "timeout notice posted (not a false success confirmation)"
echo "--- 10d) a FRESH success line (beyond the stale one) still completes the flow ---"
reset_frames "$FRAME_IDLE_OLDOK" "$FRAME_IDLE_OLDOK" "$FRAME_URL_OLDOK" "$FRAME_URL_OLDOK_FRESHOK"
run_relay prodtest
assert_eq 0 "$rc" "fresh success on top of a stale line exits 0"
assert_has "$(curl_line 2)" "Re-auth complete" "success confirmation posted"

echo ""
echo "=== 11) SINGLE-INSTANCE LOCK (mkdir + PID, the swarm-watch idiom) ==="
echo "--- 11a) live-owner contention -> refuse loud, pane untouched ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
mkdir -p "$TMP/state/swarm-login-relay.lock"
echo $$ > "$TMP/state/swarm-login-relay.lock/pid"   # this test shell is alive
run_relay prodtest
assert_eq 2 "$rc" "live lock owner -> REFUSED (exit 2)"
assert_has "$OUT" "already running" "explains the contention"
assert_eq "" "$(send_keys_log)" "no keys sent while another relay owns the pane"
echo "--- 11b) stale lock (dead owner) -> broken, run proceeds, lock released on exit ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
mkdir -p "$TMP/state/swarm-login-relay.lock"
echo 999999 > "$TMP/state/swarm-login-relay.lock/pid"   # no such PID on macOS (pid_max 99998)
run_relay prodtest
assert_eq 0 "$rc" "stale lock is broken and the relay proceeds"
if [ -d "$TMP/state/swarm-login-relay.lock" ]; then
  bad "lock dir released on exit (still present)"
else
  ok "lock dir released on exit"
fi

echo ""
echo "=== 12) STEP-6 BOUNDARY RE-CHECK before handing back to rotate ==="
# A fresh transcript for repo-prodtest makes repo_activity report WORKING
# (same fixture idiom as test-swarm-rotate.sh: encoded path prefix + fresh
# .jsonl). With a 1s idle timeout the relay must warn loud and still exit 0.
PROJ_LIVE="$TMP/proj-live"
enc_prod="$(printf '%s' "$TMP/repo-prodtest" | sed -e 's/[/.]/-/g')"
mkdir -p "$PROJ_LIVE/$enc_prod"
: > "$PROJ_LIVE/$enc_prod/live.jsonl"   # mtime = now => age 0 => WORKING
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_PROJ="$PROJ_LIVE"; T_IDLE_TIMEOUT=1
run_relay prodtest
assert_eq 0 "$rc" "working fleet at step 6 still exits 0 (the re-auth is real; rotate owns the relaunch)"
assert_has "$OUT" "still WORKING" "warns LOUD that the relaunch may interrupt mid-turn swarms"
assert_has "$OUT" "prodtest" "names the working swarm"
assert_has "$(curl_line 2)" "Re-auth complete" "confirmation still posted after the warning"

echo ""
echo "=== REFUSAL EDGES (fail loud, pane untouched) ==="
echo "--- unknown swarm -> exit 2 ---"
reset_frames "$FRAME_IDLE"
run_relay no-such-swarm
assert_eq 2 "$rc" "unknown swarm refuses with exit 2"
assert_has "$OUT" "no swarm named" "explains the unknown swarm"
echo "--- wired-with-\$1 misconfiguration -> exit 2 + precise diagnosis ---"
# If an operator wires SWARM_CREDSWAP_CMD='…/swarm-login-relay.sh "$1"', the
# ACCOUNT handle lands in the swarm positional. The relay must fail loud AND
# say exactly what is miswired.
reset_frames "$FRAME_IDLE"
OUT="$(
  export SWARM_HOME="$FAKE_SH"
  export SWARM_TMUX_BIN="$MOCK_TMUX"
  export SWARM_TOKENS_ENV="$FAKE_SH/tokens.env"
  export SWARM_STATE_DIR="$TMP/state"
  export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG
  export PATH="$TMP/stubbin:$PATH"
  SWARM_ROTATE_TO_ACCOUNT="max-b" sh -c "$RELAY \"\$1\"" _ "max-b" 2>&1
)"; rc=$?
assert_eq 2 "$rc" "account-handle-as-swarm refuses with exit 2"
assert_has "$OUT" "WITHOUT" 'diagnosis tells the operator to wire WITHOUT "$1"'
echo "--- session absent -> exit 2, nothing sent ---"
reset_frames "$FRAME_IDLE"
T_HAS_SESSION_RC=1
run_relay prodtest
assert_eq 2 "$rc" "missing tmux session refuses with exit 2"
assert_has "$OUT" "does not exist" "explains the missing session"
assert_eq "" "$(send_keys_log)" "no keys sent when the session is absent"
echo "--- missing bot token -> refuse BEFORE touching the pane ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_TOKENS="$FAKE_SH/tokens-missing.env"
run_relay prodtest
assert_eq 2 "$rc" "missing token refuses with exit 2"
assert_eq "" "$(send_keys_log)" "pane untouched when the URL could never be relayed"
assert_has "$OUT" "Not touching the pane" "explains the pre-flight refusal"
echo "--- bad timeout value -> config error 2 ---"
reset_frames "$FRAME_IDLE"
T_URL_TIMEOUT="soon"
run_relay prodtest
assert_eq 2 "$rc" "non-integer timeout refuses with exit 2"
echo "--- bad poll interval -> config error 2 (a hot loop must never reach the pane) ---"
reset_frames "$FRAME_IDLE"
T_POLL="fast"
run_relay prodtest
assert_eq 2 "$rc" "non-numeric poll interval refuses with exit 2"
assert_has "$OUT" "POLL_INTERVAL" "names the bad knob"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
