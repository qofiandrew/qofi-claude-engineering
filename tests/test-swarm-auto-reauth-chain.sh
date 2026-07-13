#!/usr/bin/env bash
# test-swarm-auto-reauth-chain.sh — one hermetic proof of the production
# automatic re-auth call graph:
#
#   swarm-rotate-tick.sh (NEAR) -> swarm-reauth.sh ->
#   swarm-login-relay.sh --dedicated -> isolated swarm-login-probe
#
# The three production scripts are copied into a synthetic SWARM_HOME and run
# unchanged. Only external effects are stubbed: usage poll, account state, tmux,
# Discord control/status posts, deletion, and the final auth probe. There is no
# network, live tmux, credential, account-state mutation, or real Discord state.
#
# This complements the scripts' focused suites. In particular, it proves the
# tick's `--next` probe does not accidentally enter /login, the reauth wrapper's
# DEFAULT command really selects `--dedicated`, and the automatic localhost
# callback remains a no-paste success path all the way back to tick exit 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-auto-reauth-chain.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FAKE_SH="$TMP/swarmhome"
FAKE_BIN="$FAKE_SH/bin"
STUB="$TMP/stubbin"
STATE_DIR="$TMP/state"
FRAMES="$TMP/frames"
mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$STUB" "$STATE_DIR" "$FRAMES" "$TMP/repo" "$TMP/projects"
chmod 700 "$FAKE_HOME" "$STATE_DIR"
ln -s "$ROOT/templates" "$FAKE_SH/templates"

# Real chain under a synthetic SWARM_HOME. The tiny wrapper records the relay's
# actual argv and immediately execs the copied production relay.
cp "$ROOT/bin/swarm-rotate-tick.sh" "$FAKE_BIN/swarm-rotate-tick.sh"
cp "$ROOT/bin/swarm-reauth.sh" "$FAKE_BIN/swarm-reauth.sh"
cp "$ROOT/bin/swarm-login-relay.sh" "$FAKE_BIN/swarm-login-relay.real.sh"
cp "$ROOT/bin/swarm-lib.sh" "$FAKE_BIN/swarm-lib.sh"
chmod +x "$FAKE_BIN"/*.sh

RELAY_INVOKE_LOG="$TMP/relay-invocations.log"
: > "$RELAY_INVOKE_LOG"
cat > "$FAKE_BIN/swarm-login-relay.sh" <<'EOF'
#!/usr/bin/env bash
printf 'argc=%s' "$#" >> "${RELAY_INVOKE_LOG:?}"
for arg in "$@"; do printf ' arg=[%s]' "$arg" >> "$RELAY_INVOKE_LOG"; done
printf '\n' >> "$RELAY_INVOKE_LOG"
exec "$(cd "$(dirname "$0")" && pwd)/swarm-login-relay.real.sh" "$@"
EOF
chmod +x "$FAKE_BIN/swarm-login-relay.sh"

OWNER_ID="1507069153335443608"
CHANNEL_ID="999000111222333"
BOT_ID="888777666555444"
MESSAGE_ID="777666555444333"
SYNTH_URL='https://claude.ai/oauth/authorize?code=true&client_id=SYNTH123&state=SYNTHSTATE'
SYNTH_CODE='SYNTHAUTHORIZATION#SYNTHSTATECODE'

cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo | BOT_TEST | $CHANNEL_ID | |
EOF

# Canonical ACL + adjacent login-control readiness. The ready PID is this test
# shell, so the relay's kill(pid, 0) liveness check is real but harmless.
ACCESS_DIR="$TMP/identity/channels/discord"
ACCESS_FILE="$ACCESS_DIR/access.json"
CONTROL_DIR="$ACCESS_DIR/login-control"
mkdir -p "$ACCESS_DIR" "$CONTROL_DIR"
chmod 700 "$TMP/identity" "$TMP/identity/channels" "$ACCESS_DIR" "$CONTROL_DIR"
cat > "$ACCESS_FILE" <<EOF
{"dmPolicy":"allowlist","allowFrom":["$OWNER_ID"],"groups":{"$CHANNEL_ID":{"requireMention":false,"allowFrom":["$OWNER_ID"]}},"pending":{}}
EOF
chmod 600 "$ACCESS_FILE"
NOW="$(date +%s)"
cat > "$CONTROL_DIR/ready-$CHANNEL_ID-$BOT_ID.json" <<EOF
{"schema":"qofi-login-control-ready/v1","protocol":1,"instance":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pid":$$,"bot_user_id":"$BOT_ID","channel_id":"$CHANNEL_ID","updated_at":$NOW}
EOF
chmod 600 "$CONTROL_DIR/ready-$CHANNEL_ID-$BOT_ID.json"

# Poll and account-state seams. The state stub records every operation; under
# the browser-selected model reauth --next prints nothing, so no SET may occur.
POLL_LOG="$TMP/poll.log"
cat > "$STUB/poll" <<'EOF'
#!/usr/bin/env bash
printf 'poll argc=%s args=[%s]\n' "$#" "$*" >> "${POLL_LOG:?}"
echo 'synthetic usage verdict: NEAR'
exit 10
EOF
STATE_LOG="$TMP/account-state.log"
cat > "$STUB/account-state" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STATE_LOG:?}"
case "${1:-}" in
  get) printf 'max-CUR\n'; exit 0 ;;
  set) exit 0 ;;
  *) exit 2 ;;
esac
EOF

# Discord seams. The control post returns the exact message|bot|channel binding
# expected by the relay. Logs contain only public arguments, making them useful
# leakage witnesses. No URL or paste-back code should ever appear here.
CONTROL_POST_LOG="$TMP/control-post.log"
cat > "$STUB/control-post" <<'EOF'
#!/usr/bin/env bash
printf 'channel=[%s] content=[%s] custom=[%s]\n' "${1:-}" "${2:-}" "${3:-}" >> "${CONTROL_POST_LOG:?}"
printf '%s|%s|%s\n' "${MESSAGE_ID:?}" "${BOT_ID:?}" "${CHANNEL_ID:?}"
EOF
CONTROL_DELETE_LOG="$TMP/control-delete.log"
cat > "$STUB/control-delete" <<'EOF'
#!/usr/bin/env bash
printf 'channel=[%s] message=[%s]\n' "${1:-}" "${2:-}" >> "${CONTROL_DELETE_LOG:?}"
EOF
STATUS_POST_LOG="$TMP/status-post.log"
cat > "$STUB/status-post" <<'EOF'
#!/usr/bin/env bash
printf 'channel=[%s] content=[%s]\n' "${1:-}" "${2:-}" >> "${STATUS_POST_LOG:?}"
EOF
AUTH_LOG="$TMP/auth-probe.log"
cat > "$STUB/auth-probe" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "${AUTH_LOG:?}"
exit 0
EOF

# Scripted tmux: healthy isolated probe, clean baseline, fresh OAuth URL, then
# automatic login success. Capture sticks on the final frame like a real pane.
FRAME_READY='>
? for shortcuts · ← for agents'
FRAME_URL="Browser did not open? Use the url below to sign in:
$SYNTH_URL"
FRAME_SUCCESS='Login successful. Press Enter to continue…'
printf '%s\n' "$FRAME_READY"   > "$FRAMES/frame-1.txt"
printf '%s\n' "$FRAME_READY"   > "$FRAMES/frame-2.txt"
printf '%s\n' "$FRAME_URL"     > "$FRAMES/frame-3.txt"
printf '%s\n' "$FRAME_SUCCESS" > "$FRAMES/frame-4.txt"

TMUX_LOG="$TMP/tmux.log"
TMUX_STDIN="$TMP/tmux-buffer-stdin"
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${TMUX_LOG:?}"
case "${1:-}" in
  has-session) exit 0 ;;
  capture-pane)
    n="$(cat "${FRAMES:?}/.counter" 2>/dev/null || echo 1)"
    f="$FRAMES/frame-$n.txt"
    if [ -f "$f" ]; then
      echo $((n+1)) > "$FRAMES/.counter"
    else
      f="$FRAMES/frame-4.txt"
    fi
    cat "$f"
    exit 0
    ;;
  load-buffer)
    cat > "${TMUX_STDIN:?}"
    exit 0
    ;;
  send-keys|paste-buffer|delete-buffer|kill-session|new-session) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB"/*

TICK="$FAKE_BIN/swarm-rotate-tick.sh"
OUT="$({
  export HOME="$FAKE_HOME"
  export SWARM_HOME="$FAKE_SH"
  export SWARM_POLL_CMD="$STUB/poll"
  export SWARM_ROTATE_CMD="$FAKE_BIN/swarm-reauth.sh"
  export SWARM_ACCOUNT_STATE_CMD="$STUB/account-state"
  export SWARM_REAUTH_POSTSWAP_CMD=true
  export SWARM_LOGIN_RELAY_SWARM=prodtest
  export SWARM_TMUX_BIN="$STUB/tmux"
  export SWARM_STATE_DIR="$STATE_DIR"
  export SWARM_ACCESS_FILE="$ACCESS_FILE"
  export CLAUDE_PROJECTS_DIR="$TMP/projects"
  export SWARM_OWNER_DISCORD_ID="$OWNER_ID"
  export SWARM_LOGIN_CONTROL_BOT_ID="$BOT_ID"
  export SWARM_LOGIN_CONTROL_POST_CMD="$STUB/control-post \"\$1\" \"\$2\" \"\$3\""
  export SWARM_LOGIN_CONTROL_DELETE_CMD="$STUB/control-delete \"\$1\" \"\$2\""
  export SWARM_LOGIN_POST_CMD="$STUB/status-post \"\$1\" \"\$2\""
  export SWARM_LOGIN_AUTHCHECK_CMD="$STUB/auth-probe"
  export SWARM_LOGIN_URL_TIMEOUT=5
  export SWARM_LOGIN_AUTH_TIMEOUT=5
  export SWARM_LOGIN_IDLE_TIMEOUT=0
  export SWARM_LOGIN_POLL_INTERVAL=0
  export SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT=5
  export RELAY_INVOKE_LOG POLL_LOG STATE_LOG CONTROL_POST_LOG CONTROL_DELETE_LOG STATUS_POST_LOG AUTH_LOG
  export MESSAGE_ID BOT_ID CHANNEL_ID TMUX_LOG TMUX_STDIN FRAMES
  bash "$TICK" 2>&1
})"; rc=$?

echo "=== automatic NEAR -> reauth -> dedicated secure relay chain ==="
assert_eq 0 "$rc" "full automatic chain returns tick exit 0"
assert_has "$OUT" "verdict NEAR-LIMIT" "NEAR verdict reached the rotation actuator"
assert_has "$OUT" "DEDICATED mode: isolated login session 'swarm-login-probe'" "real relay selected dedicated isolation"
assert_has "$OUT" "login success detected" "automatic callback completed without paste-back"

INVOCATIONS="$(cat "$RELAY_INVOKE_LOG")"
assert_eq 1 "$(wc -l < "$RELAY_INVOKE_LOG" | tr -d ' ')" "relay is invoked exactly once across tick --next + live actuator calls"
assert_eq "argc=1 arg=[--dedicated]" "$INVOCATIONS" "reauth default invokes the real relay with exactly --dedicated"
assert_eq 1 "$(grep -c 'send-keys -t swarm-login-probe C-u /login Enter' "$TMUX_LOG" | tr -d ' ')" "--next causes no login; the live actuator sends exactly one /login"

KEYS="$(grep '^send-keys ' "$TMUX_LOG" 2>/dev/null || true)"
BAD_KEY_TARGETS="$(printf '%s\n' "$KEYS" | grep -v '^send-keys -t swarm-login-probe ' || true)"
assert_eq "" "$BAD_KEY_TARGETS" "every pane key targets only swarm-login-probe"
assert_lacks "$KEYS" "swarm-prodtest" "no key targets the product CTO pane"
assert_eq "send-keys -t swarm-login-probe Enter" "$(printf '%s\n' "$KEYS" | tail -n 1)" "automatic success only needs the final resume Enter"
assert_lacks "$(cat "$TMUX_LOG")" "load-buffer" "automatic callback never loads a paste-back buffer"
assert_lacks "$(cat "$TMUX_LOG")" "paste-buffer" "automatic callback never pastes a code"

STATE_CALLS="$(cat "$STATE_LOG")"
assert_eq "get" "$STATE_CALLS" "tick reads account state but never writes it under browser-selected reauth"
assert_eq 1 "$(wc -l < "$AUTH_LOG" | tr -d ' ')" "fresh credential is verified exactly once"
assert_has "$(cat "$CONTROL_DELETE_LOG")" "message=[$MESSAGE_ID]" "generic control message is cleaned up"
if find "$CONTROL_DIR" -maxdepth 1 \( -name 'request-*.json' -o -name 'response-*.json' \) -print | grep -q .; then
  bad "private login request/response records are cleaned up"
else
  ok "private login request/response records are cleaned up"
fi

PUBLIC_LOGS="$(cat "$CONTROL_POST_LOG" "$STATUS_POST_LOG" "$CONTROL_DELETE_LOG" "$TMUX_LOG" "$RELAY_INVOKE_LOG" "$STATE_LOG")"
assert_lacks "$OUT" "$SYNTH_URL" "OAuth URL is absent from tick/actuator output"
assert_lacks "$OUT" "$SYNTH_CODE" "paste-back canary is absent from tick/actuator output"
assert_lacks "$PUBLIC_LOGS" "$SYNTH_URL" "OAuth URL is absent from public posts and subprocess argv logs"
assert_lacks "$PUBLIC_LOGS" "$SYNTH_CODE" "paste-back canary is absent from public posts and subprocess argv logs"
assert_has "$(cat "$CONTROL_POST_LOG")" "Secure re-auth ready" "public Discord surface receives only the generic secure-control notice"

echo ""
echo "=== labeled ACCOUNT fails closed through the automatic actuator chain ==="
# Auto-reauth changes only the shared default ~/.claude keychain. A labeled
# swarm row denotes an isolated ~/.claude-accounts/<label> lane, so the real
# relay must refuse before touching even the dedicated probe or control plane.
cat > "$FAKE_SH/swarm.conf" <<EOF
prodtest | $TMP/repo | BOT_TEST | $CHANNEL_ID | | max-a | claude
EOF
_before_relay="$(wc -l < "$RELAY_INVOKE_LOG" | tr -d ' ')"
_before_pane="$(grep -Ec '^(send-keys|new-session|load-buffer|paste-buffer|delete-buffer) ' "$TMUX_LOG" 2>/dev/null || true)"
_before_control="$(wc -l < "$CONTROL_POST_LOG" | tr -d ' ')"
_before_delete="$(wc -l < "$CONTROL_DELETE_LOG" | tr -d ' ')"
_before_status="$(wc -l < "$STATUS_POST_LOG" | tr -d ' ')"
_before_auth="$(wc -l < "$AUTH_LOG" | tr -d ' ')"

OUT_LABELED="$({
  export HOME="$FAKE_HOME"
  export SWARM_HOME="$FAKE_SH"
  export SWARM_POLL_CMD="$STUB/poll"
  export SWARM_ROTATE_CMD="$FAKE_BIN/swarm-reauth.sh"
  export SWARM_ACCOUNT_STATE_CMD="$STUB/account-state"
  export SWARM_REAUTH_POSTSWAP_CMD=true
  export SWARM_LOGIN_RELAY_SWARM=prodtest
  export SWARM_TMUX_BIN="$STUB/tmux"
  export SWARM_STATE_DIR="$STATE_DIR"
  export SWARM_ACCESS_FILE="$ACCESS_FILE"
  export CLAUDE_PROJECTS_DIR="$TMP/projects"
  export SWARM_OWNER_DISCORD_ID="$OWNER_ID"
  export SWARM_LOGIN_CONTROL_BOT_ID="$BOT_ID"
  export SWARM_LOGIN_CONTROL_POST_CMD="$STUB/control-post \"\$1\" \"\$2\" \"\$3\""
  export SWARM_LOGIN_CONTROL_DELETE_CMD="$STUB/control-delete \"\$1\" \"\$2\""
  export SWARM_LOGIN_POST_CMD="$STUB/status-post \"\$1\" \"\$2\""
  export SWARM_LOGIN_AUTHCHECK_CMD="$STUB/auth-probe"
  export SWARM_LOGIN_URL_TIMEOUT=5
  export SWARM_LOGIN_AUTH_TIMEOUT=5
  export SWARM_LOGIN_IDLE_TIMEOUT=0
  export SWARM_LOGIN_POLL_INTERVAL=0
  export SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT=5
  export RELAY_INVOKE_LOG POLL_LOG STATE_LOG CONTROL_POST_LOG CONTROL_DELETE_LOG STATUS_POST_LOG AUTH_LOG
  export MESSAGE_ID BOT_ID CHANNEL_ID TMUX_LOG TMUX_STDIN FRAMES
  bash "$TICK" 2>&1
})"; labeled_rc=$?

assert_eq 4 "$labeled_rc" "tick reports an actuator failure when its target swarm has a labeled ACCOUNT"
assert_has "$OUT_LABELED" "ACCOUNT='max-a'" "automatic-chain refusal identifies the account boundary"
assert_has "$OUT_LABELED" "shared default Claude keychain" "automatic-chain refusal explains why the labeled lane is unsupported"
assert_eq "$((_before_relay + 1))" "$(wc -l < "$RELAY_INVOKE_LOG" | tr -d ' ')" "automatic tick reaches the real relay once, which refuses"
assert_eq "$_before_pane" "$(grep -Ec '^(send-keys|new-session|load-buffer|paste-buffer|delete-buffer) ' "$TMUX_LOG" 2>/dev/null || true)" "labeled auto-reauth adds no probe/pane side effect"
assert_eq "$_before_control" "$(wc -l < "$CONTROL_POST_LOG" | tr -d ' ')" "labeled auto-reauth publishes no login control"
assert_eq "$_before_delete" "$(wc -l < "$CONTROL_DELETE_LOG" | tr -d ' ')" "labeled auto-reauth has no control message to delete"
assert_eq "$_before_status" "$(wc -l < "$STATUS_POST_LOG" | tr -d ' ')" "labeled auto-reauth posts no status message"
assert_eq "$_before_auth" "$(wc -l < "$AUTH_LOG" | tr -d ' ')" "labeled auto-reauth never probes a credential it did not change"
if find "$CONTROL_DIR" -maxdepth 1 \( -name 'request-*.json' -o -name 'response-*.json' \) -print | grep -q .; then
  bad "labeled automatic refusal created private login request/response state"
else
  ok "labeled automatic refusal creates no private login request/response state"
fi

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
