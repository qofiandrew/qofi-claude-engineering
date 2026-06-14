#!/usr/bin/env bash
# test-swarm-doctor-gap-detection.sh — pins bin/swarm-doctor.sh's BLOCK-on-any-
# gap contract (ADR-0015): for an engineering-cto swarm with a swarm.conf row,
# swarm-doctor asserts the full operational set and exits non-zero on ANY gap.
# No partial state passes silently.
#
# THE OPERATIONAL SET swarm-doctor gates (all four must hold):
#   1. doctrine stamped  — required doctrine files present AND
#                          enabledPlugins["discord-b2b@qofi-swarm"] === true.
#   2. bot token PRESENT — the swarm's token var line exists in tokens.env
#                          (PRESENCE ONLY — the value is never read/printed).
#   3. config.json wired — ctoChannels[<name>] entry (the routing AUTHORITY,
#                          ADR-0014) with matching channelId + non-empty botUserId.
#   4. allowFrom wired   — the cto-watcher bot id is in this channel's access.json
#                          allowFrom.
#
# Each test builds a fixture SWARM_HOME (templates symlinked, synthetic
# swarm.conf / tokens.env) plus synthetic config.json + access.json in a temp
# dir. NOTHING touches the live config, the live access.json under $HOME, or any
# running watcher. The complete fixture passes; each single-gap mutation BLOCKS.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-doctor-gap-detection.sh
# Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR="$ROOT/bin/swarm-doctor.sh"

PASS=0
FAIL=0
FAILURES=""

assert_eq() {  # expected got label
  if [ "$1" = "$2" ]; then
    printf '  PASS  %s\n' "$3"; PASS=$((PASS + 1))
  else
    printf '  FAIL  expected=[%s] got=[%s]  %s\n' "$1" "$2" "$3" >&2
    FAIL=$((FAIL + 1)); FAILURES="${FAILURES}
  - $3 (expected=[$1] got=[$2])"
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-doctor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

NAME="acme"
CHANNEL="555111222333444555"
BOT="777888999000111222"
WATCHER="999000111222333444"
TOKVAR="BOT_ACME"

# Fixture SWARM_HOME — templates symlinked (swarm-lib needs them for the
# SWARM_HOME guard), plus the lib and the doctor script. swarm.conf + tokens.env
# live here too.
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$DOCTOR" "$FAKE_SH/bin/swarm-doctor.sh"
chmod +x "$FAKE_SH/bin/swarm-doctor.sh"
DOCTOR_F="$FAKE_SH/bin/swarm-doctor.sh"

# The product repo (engineering-cto by default — no swarm-type marker needed).
REPO="$TMP/repo"
mkdir -p "$REPO/.claude"

CFG="$TMP/config.json"
ACC="$TMP/access.json"
TOKENS="$FAKE_SH/tokens.env"

# Build a COMPLETE fixture, then mutate one thing per gap test and restore.
build_complete() {
  cat > "$FAKE_SH/swarm.conf" <<EOF
# session_name | repo | TOKEN_VAR | CHANNEL_ID | GUILD_ID
$NAME | $REPO | $TOKVAR | $CHANNEL |
EOF
  printf 'export %s="fake-not-real-token-value"\n' "$TOKVAR" > "$TOKENS"
  : > "$REPO/CLAUDE.md"; : > "$REPO/ESCALATION.md"; : > "$REPO/TEAM_LEAD.md"
  printf '%s\n' '{"enabledPlugins":{"discord-b2b@qofi-swarm":true}}' > "$REPO/.claude/settings.json"
  cat > "$CFG" <<EOF
{ "ctoChannels": { "$NAME": { "channelId": "$CHANNEL", "botUserId": "$BOT" } } }
EOF
  cat > "$ACC" <<EOF
{ "groups": { "$CHANNEL": { "requireMention": false, "allowFrom": ["1", "$WATCHER"] } } }
EOF
}

run_doctor() {  # -> exit code; output discarded unless caller captures
  SWARM_HOME="$FAKE_SH" \
  CTO_WATCHER_CONFIG="$CFG" \
  SWARM_ACCESS_FILE="$ACC" \
  CTO_BUS_WATCHER_BOT_ID="$WATCHER" \
  SWARM_TOKENS_FILE="$TOKENS" \
    "$DOCTOR_F" "$NAME"
}

# ---------------------------------------------------------------------------
# 1) COMPLETE fixture passes (exit 0). The baseline — a real "all wired" state.
# ---------------------------------------------------------------------------
echo "=== complete fixture passes ==="
build_complete
run_doctor >/dev/null 2>&1
assert_eq 0 "$?" "complete operational set -> exit 0 (PASS)"

# ---------------------------------------------------------------------------
# 2) GAP: doctrine file missing -> BLOCK.
# ---------------------------------------------------------------------------
echo "=== gap: missing doctrine file ==="
build_complete
rm -f "$REPO/TEAM_LEAD.md"
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "missing TEAM_LEAD.md -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 3) GAP: enabledPlugins not true -> BLOCK (the bridge MCP would not spawn).
# ---------------------------------------------------------------------------
echo "=== gap: enabledPlugins not true ==="
build_complete
printf '%s\n' '{"enabledPlugins":{"discord-b2b@qofi-swarm":false}}' > "$REPO/.claude/settings.json"
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "enabledPlugins false -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 4) GAP: bot token absent from tokens.env -> BLOCK (presence-only check).
# ---------------------------------------------------------------------------
echo "=== gap: token absent ==="
build_complete
: > "$TOKENS"   # empty tokens.env — no export line for $TOKVAR
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "missing token var -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 5) GAP: config.json has no ctoChannels entry -> BLOCK.
# ---------------------------------------------------------------------------
echo "=== gap: config.json ctoChannels entry missing ==="
build_complete
echo '{"ctoChannels":{}}' > "$CFG"
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "no ctoChannels[$NAME] -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 6) GAP: config.json ctoChannels channelId mismatch -> BLOCK.
# ---------------------------------------------------------------------------
echo "=== gap: ctoChannels channelId mismatch ==="
build_complete
cat > "$CFG" <<EOF
{ "ctoChannels": { "$NAME": { "channelId": "111000111000111000", "botUserId": "$BOT" } } }
EOF
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "channelId mismatch vs swarm.conf -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 7) GAP: watcher id NOT in this channel's allowFrom -> BLOCK.
# ---------------------------------------------------------------------------
echo "=== gap: watcher id absent from allowFrom ==="
build_complete
cat > "$ACC" <<EOF
{ "groups": { "$CHANNEL": { "requireMention": false, "allowFrom": ["1"] } } }
EOF
run_doctor >/dev/null 2>&1
assert_eq 1 "$?" "watcher id absent from allowFrom -> BLOCK (exit 1)"

# ---------------------------------------------------------------------------
# 8) The token VALUE is NEVER emitted (secrets discipline). Plant a sentinel
#    value and assert it never appears in stdout/stderr — presence check only.
# ---------------------------------------------------------------------------
echo "=== token value is never printed ==="
build_complete
SENTINEL="SENTINEL_TOKEN_abc123_DO_NOT_LEAK"
printf 'export %s="%s"\n' "$TOKVAR" "$SENTINEL" > "$TOKENS"
out="$(run_doctor 2>&1)"
case "$out" in
  *"$SENTINEL"*) assert_eq 1 0 "token VALUE leaked into output" ;;
  *) assert_eq 1 1 "token value never appears in output (presence only)" ;;
esac

# ---------------------------------------------------------------------------
# 9) The standing operator-manual restart flag is always emitted.
# ---------------------------------------------------------------------------
echo "=== standing restart flag emitted ==="
build_complete
out="$(run_doctor 2>&1)"
case "$out" in
  *"OPERATOR-MANUAL"*) assert_eq 1 1 "watcher-restart-is-operator-manual flag emitted" ;;
  *) assert_eq 1 0 "watcher-restart flag emitted (not found)" ;;
esac

# ---------------------------------------------------------------------------
# 10) Unknown name (no swarm.conf row) is a usage error (exit 2), not a "gap".
# ---------------------------------------------------------------------------
echo "=== unknown swarm name -> usage error (exit 2) ==="
build_complete
SWARM_HOME="$FAKE_SH" CTO_WATCHER_CONFIG="$CFG" SWARM_ACCESS_FILE="$ACC" \
  CTO_BUS_WATCHER_BOT_ID="$WATCHER" SWARM_TOKENS_FILE="$TOKENS" \
  "$DOCTOR_F" no-such-swarm >/dev/null 2>&1
assert_eq 2 "$?" "no swarm.conf row -> exit 2 (usage, not a gap)"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
