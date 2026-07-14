#!/usr/bin/env bash
# test-swarm-login-relay-dedicated.sh — regression tests for the --dedicated
# mode of bin/swarm-login-relay.sh (the no-restart re-auth model).
#
# WHAT --dedicated CHANGES (and what this pins):
#   - The /login target is an ISOLATED probe session (swarm-login-probe), NEVER
#     a CTO pane. THE ISOLATION INVARIANT: every send-keys targets the probe
#     session; no key ever reaches swarm-<swarm>. This is the whole safety claim.
#   - The step-1 CTO-pane clean-boundary guard is SKIPPED (nothing to interrupt).
#   - The step-6 fleet-idle re-check is SKIPPED (no relaunch follows).
#   - A generic secure-control button posts to the SWARM ROW's channel while the
#     OAuth URL remains private/ephemeral.
#   - A missing/unhealthy probe session is CREATED (new-session + launch keys).
#
# Synthetic-fixture discipline mirrors test-swarm-login-relay.sh: a mock tmux
# that records every invocation and serves scripted capture frames, a PATH-stub
# curl that records argv, a stub auth probe. No real tmux, network, or claude.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-login-relay-dedicated.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/relay-dedicated-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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
EOF
mkdir -p "$TMP/repo-prodtest"
EMPTY_PROJ="$TMP/proj-empty"; mkdir -p "$EMPTY_PROJ"

SYNTH_TOKEN="SYNTH-BOT-TOKEN-do-not-leak-$$"
printf 'export BOT_TEST="%s"\n' "$SYNTH_TOKEN" > "$FAKE_SH/tokens.env"
chmod 600 "$FAKE_SH/tokens.env"

OWNER_ID="1507069153335443608"
BOT_ID="888777666555444333"
CONTROL_MESSAGE_ID="777666555444333222"
ACCESS_DIR="$TMP/access"; mkdir -m 700 "$ACCESS_DIR"
ACCESS_FILE="$ACCESS_DIR/access.json"
printf '{"allowFrom":["%s"],"groups":{"%s":{"requireMention":false,"allowFrom":["%s"]}},"pending":{},"dmPolicy":"allowlist"}\n' \
  "$OWNER_ID" "$TEST_CHANNEL" "$OWNER_ID" > "$ACCESS_FILE"
chmod 600 "$ACCESS_FILE"
LOGIN_CONTROL_DIR="$ACCESS_DIR/login-control"

MOCK_TMUX="$TMP/stubbin/tmux"
MOCK_TMUX_LOG="$TMP/tmux.log"
MOCK_FRAMES_DIR="$TMP/frames"
mkdir -p "$TMP/stubbin" "$MOCK_FRAMES_DIR"
cat > "$MOCK_TMUX" <<'EOF'
#!/usr/bin/env bash
set -u
log="${MOCK_TMUX_LOG:?}"
frames="${MOCK_FRAMES_DIR:?}"
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  has-session) exit "${MOCK_HAS_SESSION_RC:-0}" ;;
  show-options) printf '%s\n' "${MOCK_BROWSER_POLICY:-discord-only-v1}"; exit 0 ;;
  set-option) exit 0 ;;
  send-keys)   exit 0 ;;
  new-session) exit 0 ;;
  kill-session) exit 0 ;;
  capture-pane)
    n="$(cat "$frames/.counter" 2>/dev/null || echo 1)"
    f="$frames/frame-$n.txt"
    if [ -f "$f" ]; then echo $((n+1)) > "$frames/.counter"
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
    cat "$f"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_TMUX"

MOCK_CURL_LOG="$TMP/curl.log"
cat > "$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/users/@me'*) printf '{"id":"%s"}' "${MOCK_BOT_ID:?}"; exit 0 ;;
esac
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
case "$*" in
  *' -X DELETE '*) printf '204'; exit 0 ;;
esac
out=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; break; fi
  prev="$arg"
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  printf '{"id":"%s","channel_id":"%s","author":{"id":"%s"}}' \
    "${MOCK_CONTROL_MESSAGE_ID:?}" "${MOCK_CHANNEL_ID:?}" "${MOCK_BOT_ID:?}" > "$out"
fi
printf '%s' "${MOCK_CURL_CODE:-200}"
exit 0
EOF
chmod +x "$TMP/stubbin/curl"

SYNTH_URL='https://claude.ai/oauth/authorize?code=true&client_id=SYNTH123&state=SYNTHSTATE'
FRAME_READY='>
? for shortcuts · ← for agents'
FRAME_URL="Browser did not open? Use the url below to sign in:
$SYNTH_URL"
FRAME_SUCCESS='Login successful. Press Enter to continue…'

reset_frames() {
  rm -rf "$MOCK_FRAMES_DIR"; mkdir -p "$MOCK_FRAMES_DIR"
  local i=1
  for _f in "$@"; do printf '%s\n' "$_f" > "$MOCK_FRAMES_DIR/frame-$i.txt"; i=$((i+1)); done
  : > "$MOCK_TMUX_LOG"; : > "$MOCK_CURL_LOG"
  rm -rf "$TMP/state"
  rm -rf "$LOGIN_CONTROL_DIR"; mkdir -m 700 "$LOGIN_CONTROL_DIR"
  printf '{"schema":"qofi-login-control-ready/v1","protocol":1,"instance":"0123456789abcdef0123456789abcdef","pid":%s,"bot_user_id":"%s","channel_id":"%s","updated_at":%s}\n' \
    "$$" "$BOT_ID" "$TEST_CHANNEL" "$(date +%s)" > "$LOGIN_CONTROL_DIR/ready-$TEST_CHANNEL-$BOT_ID.json"
  chmod 600 "$LOGIN_CONTROL_DIR/ready-$TEST_CHANNEL-$BOT_ID.json"
  T_HAS_SESSION_RC=0
  T_BROWSER_POLICY=discord-only-v1
}

run_dedicated() {
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_TMUX_BIN="$MOCK_TMUX"
    export SWARM_TOKENS_ENV="$FAKE_SH/tokens.env"
    export SWARM_STATE_DIR="$TMP/state"
    export CLAUDE_PROJECTS_DIR="$EMPTY_PROJ"
    export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG
    export MOCK_BOT_ID="$BOT_ID" MOCK_CHANNEL_ID="$TEST_CHANNEL" MOCK_CONTROL_MESSAGE_ID="$CONTROL_MESSAGE_ID"
    export MOCK_HAS_SESSION_RC="$T_HAS_SESSION_RC"
    export MOCK_BROWSER_POLICY="$T_BROWSER_POLICY"
    export MOCK_CURL_CODE=200
    export SWARM_LOGIN_AUTHCHECK_CMD='exit 0'
    export SWARM_LOGIN_URL_TIMEOUT=5 SWARM_LOGIN_AUTH_TIMEOUT=5 SWARM_LOGIN_POLL_INTERVAL=0
    export SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT=5
    export SWARM_OWNER_DISCORD_ID="$OWNER_ID" SWARM_LOGIN_ACCESS_FILE="$ACCESS_FILE"
    PATH="$TMP/stubbin:$PATH" bash "$RELAY" "$@" 2>&1
  )"; rc=$?
}
send_keys_log() { grep '^send-keys' "$MOCK_TMUX_LOG" 2>/dev/null || true; }

echo "=== 0) LABELED ACCOUNT is outside the shared-keychain actuator ==="
cp "$FAKE_SH/swarm.conf" "$TMP/swarm.conf.default-lane"
cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo-prodtest | BOT_TEST | $TEST_CHANNEL | | max-a | claude
EOF
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
run_dedicated --dedicated prodtest
assert_eq 2 "$rc" "dedicated mode refuses a nonempty ACCOUNT"
assert_has "$OUT" "ACCOUNT='max-a'" "dedicated refusal names the labeled account boundary"
assert_has "$OUT" "shared default Claude keychain" "dedicated refusal explains which credential it can change"
assert_eq "" "$(cat "$MOCK_TMUX_LOG" 2>/dev/null || true)" "dedicated refusal happens before probe lookup/creation or pane input"
assert_eq "" "$(cat "$MOCK_CURL_LOG" 2>/dev/null || true)" "dedicated refusal happens before Discord control publication"
if find "$LOGIN_CONTROL_DIR" -maxdepth 1 \( -name 'request-*.json' -o -name 'response-*.json' \) -print | grep -q .; then
  bad "dedicated labeled-row refusal created private login-control request/response state"
else
  ok "dedicated labeled-row refusal creates no private login-control request/response state"
fi
if [ -e "$TMP/state" ]; then
  bad "dedicated labeled-row refusal created relay lock/state"
else
  ok "dedicated labeled-row refusal occurs before relay lock/state creation"
fi
cp "$TMP/swarm.conf.default-lane" "$FAKE_SH/swarm.conf"

echo "=== 1) DEDICATED reuse: healthy probe -> /login there -> secure control to product channel -> exit 0 ==="
# Frames: [session_ready, baseline, URL, success].
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
run_dedicated --dedicated prodtest
assert_eq 0 "$rc" "dedicated happy path exits 0"
assert_has "$OUT" "DEDICATED mode: isolated login session 'swarm-login-probe'" "targets the isolated probe session"
assert_eq "send-keys -t swarm-login-probe C-u /login Enter" "$(send_keys_log | grep -F 'C-u /login' | head -n1)" "/login sent to the PROBE session, not a CTO pane"

echo "--- THE ISOLATION INVARIANT: no key ever targets a CTO pane ---"
assert_lacks "$(send_keys_log)" "swarm-prodtest" "no send-keys ever targets the CTO pane swarm-prodtest"
assert_has "$(send_keys_log)" "swarm-login-probe" "every /login key targets the isolated probe session"
assert_lacks "$(grep '^new-session' "$MOCK_TMUX_LOG" 2>/dev/null || true)" "swarm-login-probe" "a current Discord-only probe is safely reused"

echo "--- channel resolution is from the SWARM ROW, not the session ---"
assert_has "$(sed -n '1p' "$MOCK_CURL_LOG")" "/channels/$TEST_CHANNEL/messages" "secure control posted to the product row's channel"
assert_has "$(sed -n '1p' "$MOCK_CURL_LOG")" "qofi-login:open:v1:" "public payload carries only a nonce-bound button"
assert_lacks "$(cat "$MOCK_CURL_LOG")" "$SYNTH_URL" "OAuth URL never enters public Discord history"

echo "--- the two CTO-pane guards are SKIPPED in dedicated mode ---"
assert_lacks "$OUT" "clean boundary" "step-6 fleet clean-boundary re-check is skipped"
assert_has "$OUT" "no fleet re-check" "reports the fleet re-check is skipped (no relaunch follows)"
assert_has "$OUT" "isolated session; no fleet restart" "DONE line states no restart"

echo "--- no-leak: the synthetic token never reaches stdout/stderr ---"
assert_lacks "$OUT" "$SYNTH_TOKEN" "token absent from output"

echo ""
echo "=== 2) DEDICATED create: no healthy probe session -> new-session + launch, then /login ==="
# has-session returns 1 => session_ready fails => create_probe_session runs.
# Frames: [create-loop ready, baseline, URL, success].
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
T_HAS_SESSION_RC=1
run_dedicated --dedicated prodtest
assert_eq 0 "$rc" "dedicated create path exits 0"
assert_has "$(grep '^new-session' "$MOCK_TMUX_LOG" | head -n1)" "swarm-login-probe" "created the probe session (new-session)"
assert_has "$(grep '^new-session' "$MOCK_TMUX_LOG" | head -n1)" "-x 800" "probe created 800 cols wide — the OAuth URL must render UNWRAPPED (a 200-col pane hard-clipped it to a broken link, live 2026-07-10)"
assert_has "$(send_keys_log)" "export BROWSER=/usr/bin/false NO_BROWSER=1 && exec claude" "probe refuses local browser launching before Claude starts"
assert_has "$(grep '^set-option' "$MOCK_TMUX_LOG" | head -n1)" "@qofi_login_browser_policy discord-only-v1" "probe session records the Discord-only browser policy"
assert_lacks "$(send_keys_log)" "swarm-prodtest" "create path also never touches a CTO pane"

echo ""
echo "=== 2a) DEDICATED migration: a legacy probe without browser policy is recreated ==="
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
T_BROWSER_POLICY=legacy
run_dedicated --dedicated prodtest
assert_eq 0 "$rc" "legacy probe migration exits 0"
assert_has "$(grep '^kill-session' "$MOCK_TMUX_LOG" | head -n1)" "swarm-login-probe" "legacy browser-capable probe is discarded"
assert_has "$(grep '^new-session' "$MOCK_TMUX_LOG" | head -n1)" "swarm-login-probe" "legacy probe is recreated under the new policy"
assert_has "$(send_keys_log)" "export BROWSER=/usr/bin/false NO_BROWSER=1 && exec claude" "migrated probe blocks local browser launching"

echo ""
echo "=== 2b) COMPLETENESS gate: a width-truncated URL (no state=) is NEVER posted ==="
# The real failure: the TUI hard-wraps a ~450-char URL at pane width; the
# captured fragment ends mid-parameter. The relay must treat it as not-yet-
# rendered and time out LOUD — not post a broken link.
TRUNC_URL='https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3A'
reset_frames "$FRAME_READY" "$FRAME_READY" "Browser did not open? Use the url below to sign in:
$TRUNC_URL"
T_HAS_SESSION_RC=0
run_dedicated --dedicated prodtest
assert_eq 5 "$rc" "truncated URL -> URL-timeout exit 5 (fails loud)"
assert_has "$OUT" "WIDTH-TRUNCATED" "warns the URL looks width-truncated and names the fix"
# (grep -c prints "0" AND exits 1 on no match — no || fallback, it would
# append a second 0)
_posts="$(grep -c . "$MOCK_CURL_LOG" 2>/dev/null || true)"
assert_eq "0" "${_posts:-0}" "NO Discord post carried the broken link"
assert_has "$(send_keys_log)" "Escape" "backed out of the login UI"

echo ""
echo "=== 3) DEDICATED honored via env (SWARM_LOGIN_RELAY_DEDICATED=1), no flag ==="
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
OUT="$(
  export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX" SWARM_TOKENS_ENV="$FAKE_SH/tokens.env"
  export SWARM_STATE_DIR="$TMP/state" CLAUDE_PROJECTS_DIR="$EMPTY_PROJ"
  export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG MOCK_HAS_SESSION_RC=0 MOCK_CURL_CODE=200
  export MOCK_BOT_ID="$BOT_ID" MOCK_CHANNEL_ID="$TEST_CHANNEL" MOCK_CONTROL_MESSAGE_ID="$CONTROL_MESSAGE_ID"
  export SWARM_OWNER_DISCORD_ID="$OWNER_ID" SWARM_LOGIN_ACCESS_FILE="$ACCESS_FILE"
  export SWARM_LOGIN_AUTHCHECK_CMD='exit 0' SWARM_LOGIN_RELAY_DEDICATED=1
  export SWARM_LOGIN_URL_TIMEOUT=5 SWARM_LOGIN_AUTH_TIMEOUT=5 SWARM_LOGIN_POLL_INTERVAL=0 SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT=5
  PATH="$TMP/stubbin:$PATH" bash "$RELAY" prodtest 2>&1
)"; rc=$?
assert_eq 0 "$rc" "env-driven dedicated exits 0"
assert_has "$OUT" "isolated login session" "env SWARM_LOGIN_RELAY_DEDICATED=1 selects dedicated mode"

echo "--- OFF spellings must NOT enable dedicated (the =false footgun) ---"
for v in false no off 0 FALSE; do
  reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
  OUT="$(
    export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX" SWARM_TOKENS_ENV="$FAKE_SH/tokens.env"
    export SWARM_STATE_DIR="$TMP/state" CLAUDE_PROJECTS_DIR="$EMPTY_PROJ"
    export MOCK_TMUX_LOG MOCK_FRAMES_DIR MOCK_CURL_LOG MOCK_HAS_SESSION_RC=0 MOCK_CURL_CODE=200
    export MOCK_BOT_ID="$BOT_ID" MOCK_CHANNEL_ID="$TEST_CHANNEL" MOCK_CONTROL_MESSAGE_ID="$CONTROL_MESSAGE_ID"
    export SWARM_OWNER_DISCORD_ID="$OWNER_ID" SWARM_LOGIN_ACCESS_FILE="$ACCESS_FILE"
    export SWARM_LOGIN_AUTHCHECK_CMD='exit 0' SWARM_LOGIN_RELAY_DEDICATED="$v"
    export SWARM_LOGIN_URL_TIMEOUT=5 SWARM_LOGIN_AUTH_TIMEOUT=5 SWARM_LOGIN_POLL_INTERVAL=0 SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT=5
    PATH="$TMP/stubbin:$PATH" bash "$RELAY" prodtest 2>&1
  )"; rc=$?
  assert_lacks "$OUT" "isolated login session" "SWARM_LOGIN_RELAY_DEDICATED=$v stays in DEFAULT (CTO-pane) mode"
done

echo ""
echo "=== 4) DEFAULT mode still targets the CTO pane (regression: flag absent) ==="
# frame-1 idle (guard passes), frame-2 baseline, frame-3 URL, frame-4 success.
reset_frames "$FRAME_READY" "$FRAME_READY" "$FRAME_URL" "$FRAME_SUCCESS"
run_dedicated prodtest
assert_eq 0 "$rc" "default mode exits 0"
assert_has "$(send_keys_log | grep -F 'C-u /login' | head -n1)" "swarm-prodtest" "default mode /login targets the CTO pane swarm-prodtest"
assert_lacks "$(send_keys_log)" "swarm-login-probe" "default mode never uses the probe session"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
