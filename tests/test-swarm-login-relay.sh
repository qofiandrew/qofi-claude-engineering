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
#      -> FRESH URL scraped -> private request + generic channel control
#      -> success frame -> resume Enter AFTER the success capture
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
#      warns loud on timeout (still exit 0 — the re-auth is real); malformed
#      config is held fail-closed before launch or after auth.
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
OWNER_ID="1507069153335443608"
BOT_ID="888777666555444333"
CONTROL_MESSAGE_ID="777666555444333222"
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

ACCESS_DIR="$TMP/access"; mkdir -m 700 "$ACCESS_DIR"
ACCESS_FILE="$ACCESS_DIR/access.json"
printf '{"allowFrom":["%s"],"groups":{"%s":{"requireMention":false,"allowFrom":["%s"]}},"pending":{},"dmPolicy":"allowlist"}\n' \
  "$OWNER_ID" "$TEST_CHANNEL" "$OWNER_ID" > "$ACCESS_FILE"
chmod 600 "$ACCESS_FILE"
LOGIN_CONTROL_DIR="$ACCESS_DIR/login-control"

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
  load-buffer) cat > "${MOCK_TMUX_STDIN:?}"; exit 0 ;;
  paste-buffer|delete-buffer) exit 0 ;;
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
case "$*" in
  *'/users/@me'*) printf '{"id":"%s"}' "${MOCK_BOT_ID:?}"; exit 0 ;;
esac
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
case "$*" in
  *' -X DELETE '*) printf '204'; exit 0 ;;
esac
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; break; fi
  prev="$arg"
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  printf '{"id":"%s","channel_id":"%s","author":{"id":"%s"}}' \
    "${MOCK_CONTROL_MESSAGE_ID:?}" "${MOCK_CHANNEL_ID:?}" "${MOCK_BOT_ID:?}" > "$out"
  if [ -n "${MOCK_PASTEBACK_CODE:-}" ]; then
    nonce="$(printf '%s' "$*" | sed -n 's/.*qofi-login:open:v1:\([a-f0-9]\{32\}\).*/\1/p')"
    if [ -n "$nonce" ]; then
      printf '{"schema":"qofi-login-control-response/v1","protocol":1,"nonce":"%s","owner_id":"%s","channel_id":"%s","message_id":"%s","bot_user_id":"%s","created_at":%s,"expires_at":%s,"code":"%s"}\n' \
        "$nonce" "${MOCK_OWNER_ID:?}" "${MOCK_CHANNEL_ID:?}" "${MOCK_CONTROL_MESSAGE_ID:?}" "${MOCK_BOT_ID:?}" \
        "$(date +%s)" "$(( $(date +%s) + 60 ))" "$MOCK_PASTEBACK_CODE" \
        > "${MOCK_LOGIN_CONTROL_DIR:?}/response-$nonce.json"
      chmod 600 "${MOCK_LOGIN_CONTROL_DIR:?}/response-$nonce.json"
    fi
  fi
fi
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
FRAME_PASTE='Paste code here if prompted > '
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
  : > "$MOCK_TMUX_LOG"; : > "$MOCK_CURL_LOG"; : > "$TMP/tmux-stdin"
  rm -rf "$TMP/state"
  rm -rf "$LOGIN_CONTROL_DIR"; mkdir -m 700 "$LOGIN_CONTROL_DIR"
  printf '{"schema":"qofi-login-control-ready/v1","protocol":1,"instance":"0123456789abcdef0123456789abcdef","pid":%s,"bot_user_id":"%s","channel_id":"%s","updated_at":%s}\n' \
    "$$" "$BOT_ID" "$TEST_CHANNEL" "$(date +%s)" > "$LOGIN_CONTROL_DIR/ready-$TEST_CHANNEL-$BOT_ID.json"
  chmod 600 "$LOGIN_CONTROL_DIR/ready-$TEST_CHANNEL-$BOT_ID.json"
  T_HAS_SESSION_RC=0; T_CURL_CODE=200; T_AUTHCHECK='exit 0'
  T_URL_TIMEOUT=5; T_AUTH_TIMEOUT=5; T_IDLE_TIMEOUT=5; T_POLL=0
  T_VERIFY_ATTEMPTS=5; T_VERIFY_INTERVAL=0
  T_TOKENS="$FAKE_SH/tokens.env"; T_PROJ="$EMPTY_PROJ"
  T_PASTEBACK_CODE=""
  T_OWNER_OVERRIDE="$OWNER_ID"; T_EXPECTED_OWNER_ID="$OWNER_ID"
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
    export MOCK_TMUX_STDIN="$TMP/tmux-stdin"
    export MOCK_BOT_ID="$BOT_ID" MOCK_CHANNEL_ID="$TEST_CHANNEL" MOCK_CONTROL_MESSAGE_ID="$CONTROL_MESSAGE_ID"
    export MOCK_OWNER_ID="$T_EXPECTED_OWNER_ID" MOCK_LOGIN_CONTROL_DIR="$LOGIN_CONTROL_DIR"
    export MOCK_PASTEBACK_CODE="$T_PASTEBACK_CODE"
    export MOCK_HAS_SESSION_RC="$T_HAS_SESSION_RC"
    export MOCK_CURL_CODE="$T_CURL_CODE"
    export SWARM_LOGIN_AUTHCHECK_CMD="$T_AUTHCHECK"
    export SWARM_LOGIN_URL_TIMEOUT="$T_URL_TIMEOUT"
    export SWARM_LOGIN_AUTH_TIMEOUT="$T_AUTH_TIMEOUT"
    export SWARM_LOGIN_IDLE_TIMEOUT="$T_IDLE_TIMEOUT"
    export SWARM_LOGIN_POLL_INTERVAL="$T_POLL"
    export SWARM_LOGIN_VERIFY_ATTEMPTS="$T_VERIFY_ATTEMPTS"
    export SWARM_LOGIN_VERIFY_INTERVAL="$T_VERIFY_INTERVAL"
    export SWARM_OWNER_DISCORD_ID="$T_OWNER_OVERRIDE"
    export SWARM_LOGIN_ACCESS_FILE="$ACCESS_FILE"
    PATH="$TMP/stubbin:$PATH" bash "$RELAY" "$@" 2>&1
  )"; rc=$?
}

send_keys_log() { grep '^send-keys' "$MOCK_TMUX_LOG" 2>/dev/null || true; }
curl_log()      { cat "$MOCK_CURL_LOG" 2>/dev/null || true; }
curl_line()     { sed -n "${1}p" "$MOCK_CURL_LOG" 2>/dev/null || true; }
# An OAuth URL must never appear in a public Discord request.
posted_url()    { curl_line 1 | grep -oE "$RELAY_URL_RE" | head -n 1; }

echo "=== 1) HAPPY PATH: /login -> private URL handoff -> success -> Enter -> probe 0 -> exit 0 ==="
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "happy path exits 0"
assert_eq "send-keys -t swarm-prodtest C-u /login Enter" "$(send_keys_log | head -n 1)" "exact /login keystrokes: ONE call, C-u then /login then Enter"
assert_eq "" "$(posted_url)" "OAuth URL is absent from the public Discord payload"
assert_has "$(curl_line 1)" "qofi-login:open:v1:" "public post contains only the nonce-bound secure-control button"
assert_has "$(curl_line 1)" "/channels/$TEST_CHANNEL/messages" "posted to the swarm's own channel"
assert_lacks "$(curl_line 1)" "$SYNTH_URL" "public login-control post never contains the OAuth URL"
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

echo "--- legacy owner-held 0755 Discord state remains reauth-compatible ---"
chmod 755 "$ACCESS_DIR"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "owner-held non-writable 0755 state accepts secure reauth"
assert_eq "700" "$(stat -f %Lp "$LOGIN_CONTROL_DIR" 2>/dev/null || stat -c %a "$LOGIN_CONTROL_DIR")" "login-control leaf stays exact 0700 under a 0755 state parent"
chmod 700 "$ACCESS_DIR"

echo "--- private ACL owner pin is portable when no runtime owner env is set ---"
ALT_OWNER_ID="999111222333444555"
cp "$ACCESS_FILE" "$TMP/access.before-portable-owner.json"
printf '{"loginControlOwnerId":"%s","allowFrom":["%s"],"groups":{"%s":{"requireMention":false,"allowFrom":["%s"]}},"pending":{},"dmPolicy":"allowlist"}\n' \
  "$ALT_OWNER_ID" "$ALT_OWNER_ID" "$TEST_CHANNEL" "$ALT_OWNER_ID" > "$ACCESS_FILE"
chmod 600 "$ACCESS_FILE"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_OWNER_OVERRIDE=""; T_EXPECTED_OWNER_ID="$ALT_OWNER_ID"
run_relay prodtest
assert_eq 0 "$rc" "ACL-pinned non-author deployment owner completes reauth without an env override"
assert_lacks "$OUT" "$OWNER_ID" "portable owner path never falls back to the repository author's Discord id"
mv "$TMP/access.before-portable-owner.json" "$ACCESS_FILE"
chmod 600 "$ACCESS_FILE"

echo "--- group-writable Discord state fails closed before /login ---"
chmod 775 "$ACCESS_DIR"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 2 "$rc" "group-writable state refuses reauth"
assert_eq "" "$(send_keys_log)" "unsafe state is rejected before pane input"
chmod 700 "$ACCESS_DIR"

echo "--- symlinked account/config ancestor fails closed before /login ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
ORIG_ACCESS_FILE="$ACCESS_FILE"; ORIG_LOGIN_CONTROL_DIR="$LOGIN_CONTROL_DIR"
REAL_ACCOUNT="$TMP/real-claude-account"
LINKED_ACCOUNT="$TMP/linked-claude-account"
mkdir -p "$REAL_ACCOUNT/channels/discord"
chmod 700 "$REAL_ACCOUNT" "$REAL_ACCOUNT/channels" "$REAL_ACCOUNT/channels/discord"
cp "$ORIG_ACCESS_FILE" "$REAL_ACCOUNT/channels/discord/access.json"
chmod 600 "$REAL_ACCOUNT/channels/discord/access.json"
ln -s "$REAL_ACCOUNT" "$LINKED_ACCOUNT"
ACCESS_FILE="$LINKED_ACCOUNT/channels/discord/access.json"
LOGIN_CONTROL_DIR="$LINKED_ACCOUNT/channels/discord/login-control"
run_relay prodtest
assert_eq 2 "$rc" "symlinked account ancestor refuses reauth"
assert_eq "" "$(send_keys_log)" "ancestor redirection is rejected before pane input"
ACCESS_FILE="$ORIG_ACCESS_FILE"; LOGIN_CONTROL_DIR="$ORIG_LOGIN_CONTROL_DIR"

echo ""
echo "=== 1b) PRIVATE MODAL PASTE-BACK: fresh prompt gates stdin-only injection ==="
PASTE_CODE="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_PASTE" "$FRAME_SUCCESS"
T_PASTEBACK_CODE="$PASTE_CODE"
run_relay prodtest
assert_eq 0 "$rc" "manual paste-back path exits 0"
assert_eq "$PASTE_CODE" "$(cat "$TMP/tmux-stdin")" "exact code reaches only tmux load-buffer stdin"
assert_has "$(cat "$MOCK_TMUX_LOG")" "load-buffer -b qofi-login-" "uses a nonce-named tmux buffer"
assert_has "$(cat "$MOCK_TMUX_LOG")" "paste-buffer -b qofi-login-" "paste-buffer consumes and deletes the private buffer"
assert_lacks "$(cat "$MOCK_TMUX_LOG")" "$PASTE_CODE" "code absent from every tmux argv"
assert_lacks "$(curl_log)" "$PASTE_CODE" "code absent from every public Discord request"
assert_lacks "$OUT" "$PASTE_CODE" "code absent from stdout/stderr (launchd log surrogate)"
if find "$LOGIN_CONTROL_DIR" -name 'request-*' -o -name 'response-*' | grep -q .; then bad "request/response residue remains after paste-back"; else ok "private request/response removed after paste-back"; fi

echo "--- automatic success wins a simultaneous modal-response race ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_PASTEBACK_CODE="$PASTE_CODE"
run_relay prodtest
assert_eq 0 "$rc" "automatic callback still succeeds when an unused response exists"
assert_eq "" "$(cat "$TMP/tmux-stdin")" "automatic success discards response with zero code injection"

echo "--- a paste prompt already present in the baseline is stale and cannot authorize injection ---"
FRAME_URL_STALEPASTE="$FRAME_PASTE
$FRAME_URL"
reset_frames "$FRAME_IDLE" "$FRAME_PASTE" "$FRAME_URL_STALEPASTE"
T_PASTEBACK_CODE="$PASTE_CODE"; T_AUTH_TIMEOUT=1
run_relay prodtest
assert_eq 8 "$rc" "stale baseline paste prompt times out instead of injecting"
assert_eq "" "$(cat "$TMP/tmux-stdin")" "stale prompt leaves code out of tmux"

echo ""
echo "=== 2) METHOD-PICKER: exactly ONE extra Enter, freshness-gated ==="
echo "--- 2a) picker persists two captures -> still ONE Enter -> then the URL ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_PICKER" "$FRAME_PICKER" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "picker path exits 0"
assert_eq 3 "$(send_keys_log | wc -l | tr -d ' ')" "exactly 3 send-keys: /login, ONE picker Enter, resume Enter"
assert_eq "send-keys -t swarm-prodtest Enter" "$(send_keys_log | sed -n '2p')" "the picker Enter is a single bare Enter"
assert_has "$OUT" "method-picker" "announces the picker handling"
assert_eq "" "$(posted_url)" "picker path also keeps the URL out of channel history"
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
assert_eq 1 "$(wc -l < "$MOCK_CURL_LOG" | tr -d ' ')" "exactly one POST attempt (the failed generic control post)"
assert_has "$OUT" "could not post" "loud about the failed post"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the post-failure path"

echo ""
echo "=== 5) AUTH-WAIT TIMEOUT -> timeout notice posted, Escape, non-zero ==="
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL"   # URL renders, success never does
T_AUTH_TIMEOUT=1
run_relay prodtest
assert_eq 8 "$rc" "auth-wait timeout exits 8"
assert_eq 3 "$(wc -l < "$MOCK_CURL_LOG" | tr -d ' ')" "generic control + timeout notice + best-effort control deletion"
assert_has "$(curl_line 2)" "timed out" "the second post is the timeout notice"
assert_eq "send-keys -t swarm-prodtest Escape" "$(send_keys_log | tail -n 1)" "backed out (Escape) after the timeout"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the timeout path"

echo ""
echo "=== 6) PROBE VERDICT MAPPING (credswap exit-code contract) ==="
AUTH_ATTEMPT_FILE="$TMP/auth-attempts"
FLAKY_AUTH="$TMP/flaky-auth"
cat > "$FLAKY_AUTH" <<'EOF'
#!/bin/sh
n=0
[ ! -f "$MOCK_AUTH_ATTEMPT_FILE" ] || n="$(cat "$MOCK_AUTH_ATTEMPT_FILE")"
n=$((n + 1))
printf '%s\n' "$n" > "$MOCK_AUTH_ATTEMPT_FILE"
[ "$n" -ge "${MOCK_AUTH_SUCCEED_ON:-3}" ]
EOF
chmod +x "$FLAKY_AUTH"
export MOCK_AUTH_ATTEMPT_FILE="$AUTH_ATTEMPT_FILE"

echo "--- 6a) transient exit 1 is retried, then verifies within the bounded budget ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
rm -f "$AUTH_ATTEMPT_FILE"
T_AUTHCHECK="$FLAKY_AUTH"
T_VERIFY_ATTEMPTS=5
run_relay prodtest
assert_eq 0 "$rc" "transient post-login verify failure succeeds on retry"
assert_eq 3 "$(cat "$AUTH_ATTEMPT_FILE")" "auth probe stopped immediately after the third-attempt success"
assert_has "$OUT" "verified on probe attempt 3/5" "retry recovery is explicit in relay output"

echo "--- 6b) persistent exit 1 fails closed after exactly the configured budget ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
rm -f "$AUTH_ATTEMPT_FILE"
MOCK_AUTH_SUCCEED_ON=99; export MOCK_AUTH_SUCCEED_ON
T_AUTHCHECK="$FLAKY_AUTH"
T_VERIFY_ATTEMPTS=3
run_relay prodtest
assert_eq 4 "$rc" "persistent auth failure still maps to verify-failed exit 4"
assert_eq 3 "$(cat "$AUTH_ATTEMPT_FILE")" "persistent failure performs no more than the configured three attempts"
unset MOCK_AUTH_SUCCEED_ON

echo "--- 6c) probe 75 (authed-but-capped) -> exit 7 (ring-exhaustion signal) ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_AUTHCHECK='exit 75'
run_relay prodtest
assert_eq 7 "$rc" "probe 75 maps to exit 7 (ring exhaustion, matches credswap)"
assert_has "$(curl_line 2)" "CAPPED" "capped notice posted to the channel"
echo "--- 6d) probe hard-fail -> exit 4 (verify failed), loud ---"
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
  export MOCK_TMUX_STDIN="$TMP/tmux-stdin"
  export MOCK_BOT_ID="$BOT_ID" MOCK_CHANNEL_ID="$TEST_CHANNEL" MOCK_CONTROL_MESSAGE_ID="$CONTROL_MESSAGE_ID"
  export MOCK_HAS_SESSION_RC=0 MOCK_CURL_CODE=200
  export SWARM_LOGIN_AUTHCHECK_CMD='exit 0'
  export SWARM_LOGIN_URL_TIMEOUT=5 SWARM_LOGIN_AUTH_TIMEOUT=5 SWARM_LOGIN_IDLE_TIMEOUT=5 SWARM_LOGIN_POLL_INTERVAL=0
  export SWARM_LOGIN_RELAY_SWARM="prodtest"
  export SWARM_OWNER_DISCORD_ID="$OWNER_ID" SWARM_LOGIN_ACCESS_FILE="$ACCESS_FILE"
  export PATH="$TMP/stubbin:$PATH"
  SWARM_ROTATE_TO_ACCOUNT="max-b" sh -c "$RELAY" _ "max-b" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "rotate-style invocation exits 0 (drop-in credswap)"
assert_has "$OUT" "max-b" "the rotate handle is received and logged"
assert_has "$OUT" "operator's browser" "documents that the account choice happens in the browser"
assert_eq "" "$(posted_url)" "rotate-style run keeps the URL private"
assert_has "$OUT" "max-b" "rotate-style output names the nominal target without putting it in the secret handoff"
assert_lacks "$OUT" "$SYNTH_TOKEN" "no-leak: token absent from output on the rotate-style path"

echo ""
echo "=== 10) STALENESS: pre-/login pane content never drives the flow ==="
echo "--- 10a) stale oauth URL in the pane is NOT posted; the fresh bottom URL is, without TUI chrome ---"
reset_frames "$FRAME_IDLE_STALEURL" "$FRAME_IDLE_STALEURL" "$FRAME_URL_SHADOWED" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "shadowed-URL path exits 0"
assert_eq "" "$(posted_url)" "the fresh URL is consumed privately, never posted"
assert_lacks "$(curl_line 1)" "OLD999" "the stale pre-/login URL is never relayed to the operator"
echo "--- 10a2) two FRESH URLs -> the BOTTOM-most wins (the login UI renders at the pane bottom) ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL_TWOFRESH" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 0 "$rc" "two-fresh-URLs path exits 0"
assert_eq "" "$(posted_url)" "bottom-most fresh selection still leaves no URL in channel history"
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

echo "--- malformed config is refused before touching the pane ---"
cp "$FAKE_SH/swarm.conf" "$TMP/swarm.conf.good"
printf 'broken | %s | BOT_BAD | 123 | | | typo\n' "$TMP/repo-bad" >> "$FAKE_SH/swarm.conf"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 2 "$rc" "unknown engine anywhere in shared config refuses re-auth"
assert_has "$OUT" "malformed swarm.conf" "pre-auth refusal names unsafe config"
assert_eq "" "$(send_keys_log)" "malformed config is rejected before pane input"
cp "$TMP/swarm.conf.good" "$FAKE_SH/swarm.conf"

echo "--- config drift after successful auth holds the relaunch ---"
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
T_AUTHCHECK="printf '%s\\n' 'broken | $TMP/repo-bad | BOT_BAD | 123 | | | typo' >> '$FAKE_SH/swarm.conf'; exit 0"
run_relay prodtest
assert_eq 9 "$rc" "post-auth malformed config returns the explicit hold status"
assert_has "$OUT" "POST-AUTH HOLD" "post-auth drift reports credential changed but relaunch held"
assert_has "$(curl_line 2)" "relaunch HELD" "operator receives the post-auth hold notice"
cp "$TMP/swarm.conf.good" "$FAKE_SH/swarm.conf"

echo ""
echo "=== REFUSAL EDGES (fail loud, pane untouched) ==="
echo "--- unknown swarm -> exit 2 ---"
reset_frames "$FRAME_IDLE"
run_relay no-such-swarm
assert_eq 2 "$rc" "unknown swarm refuses with exit 2"
assert_has "$OUT" "no swarm named" "explains the unknown swarm"
echo "--- labeled ACCOUNT -> refuse before every pane/control side effect ---"
cp "$FAKE_SH/swarm.conf" "$TMP/swarm.conf.default-lane"
cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo-prodtest | BOT_TEST | $TEST_CHANNEL | | max-a | claude
other    | $TMP/repo-other    | BOT_OTHER | 444555666 | |
EOF
reset_frames "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_URL" "$FRAME_SUCCESS"
run_relay prodtest
assert_eq 2 "$rc" "nonempty ACCOUNT refuses with exit 2"
assert_has "$OUT" "ACCOUNT='max-a'" "refusal identifies the labeled account boundary"
assert_has "$OUT" "shared default Claude keychain" "refusal explains the shared-default-keychain contract"
assert_eq "" "$(cat "$MOCK_TMUX_LOG" 2>/dev/null || true)" "labeled row is rejected before any tmux lookup, capture, or pane key"
assert_eq "" "$(curl_log)" "labeled row is rejected before any Discord control/status request"
if find "$LOGIN_CONTROL_DIR" -maxdepth 1 \( -name 'request-*.json' -o -name 'response-*.json' \) -print | grep -q .; then
  bad "labeled-row refusal created private login-control request/response state"
else
  ok "labeled-row refusal creates no private login-control request/response state"
fi
if [ -e "$TMP/state" ]; then
  bad "labeled-row refusal created relay lock/state"
else
  ok "labeled-row refusal occurs before relay lock/state creation"
fi
cp "$TMP/swarm.conf.default-lane" "$FAKE_SH/swarm.conf"
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
echo "--- bad verify retry budget/interval -> config error 2 before pane input ---"
reset_frames "$FRAME_IDLE"
T_VERIFY_ATTEMPTS=0
run_relay prodtest
assert_eq 2 "$rc" "zero verify-attempt budget refuses with exit 2"
assert_eq "" "$(send_keys_log)" "bad verify-attempt budget is rejected before pane input"
reset_frames "$FRAME_IDLE"
T_VERIFY_INTERVAL="fast"
run_relay prodtest
assert_eq 2 "$rc" "non-numeric verify interval refuses with exit 2"
assert_has "$OUT" "VERIFY_INTERVAL" "names the bad verify-interval knob"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
