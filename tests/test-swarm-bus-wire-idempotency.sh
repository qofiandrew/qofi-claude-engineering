#!/usr/bin/env bash
# test-swarm-bus-wire-idempotency.sh — pins the IDEMPOTENCY contract of
# bin/swarm-bus-wire.sh (ADR-0015): the bus wiring extracted from swarm-add
# phase 4e must re-run as a safe no-op.
#
# THE CONTRACT. swarm-bus-wire wires both halves of the #cpo-cto-bus for one
# CTO:
#   Half 1 — ctoChannels[<name>] = {channelId, botUserId} in the watcher's
#            config.json (the routing AUTHORITY, ADR-0014).
#   Half 2 — the cto-watcher bot id appended (once) to this channel's access.json
#            allowFrom.
# Re-running on an already-wired swarm must NOT duplicate the allowFrom id, NOT
# churn the ctoChannels entry, and must report "already current" — so swarm-add
# re-runs (and standalone re-invocations) are self-healing, not double-applying.
#
# These tests construct synthetic config.json + access.json fixtures in a temp
# dir and never touch the live watcher config or any access.json under $HOME.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-bus-wire-idempotency.sh
# Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WIRE="$ROOT/bin/swarm-bus-wire.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bus-wire.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CFG="$TMP/config.json"
ACC="$TMP/access.json"
NAME="acme"
CHANNEL="555111222333444555"
BOT="777888999000111222"
WATCHER="999000111222333444"

# Fixtures: empty ctoChannels; an access.json group for the channel WITHOUT
# the watcher id (so the first run must add it).
echo '{"ctoChannels":{}}' > "$CFG"
cat > "$ACC" <<EOF
{
  "dmPolicy": "pairing",
  "allowFrom": ["1"],
  "groups": { "$CHANNEL": { "requireMention": false, "allowFrom": ["1"] } },
  "pending": {}
}
EOF

run_wire() {  # invoke the script with the test env overrides
  SWARM_HOME="$ROOT" \
  CTO_WATCHER_CONFIG="$CFG" \
  SWARM_ACCESS_FILE="$ACC" \
  CTO_BUS_WATCHER_BOT_ID="$WATCHER" \
    "$WIRE" "$NAME" "$CHANNEL" "$BOT"
}

# Helpers that read the fixture files (never the live config).
cfg_channel() { python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("ctoChannels") or {}).get(sys.argv[2],{}).get("channelId",""))' "$CFG" "$NAME"; }
cfg_bot()     { python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("ctoChannels") or {}).get(sys.argv[2],{}).get("botUserId",""))'  "$CFG" "$NAME"; }
cfg_count()   { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("ctoChannels") or {}))' "$CFG"; }
acl_count()   { python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("groups") or {}).get(sys.argv[2],{}).get("allowFrom",[]).count(sys.argv[3]))' "$ACC" "$CHANNEL" "$WATCHER"; }
acl_len()     { python3 -c 'import json,sys;print(len((json.load(open(sys.argv[1])).get("groups") or {}).get(sys.argv[2],{}).get("allowFrom",[])))' "$ACC" "$CHANNEL"; }

# ---------------------------------------------------------------------------
# 1) FIRST run — both halves applied.
# ---------------------------------------------------------------------------
echo "=== first run wires both halves ==="
run_wire >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc"                       "first run exits 0"
assert_eq "$CHANNEL" "$(cfg_channel)"   "ctoChannels[$NAME].channelId set"
assert_eq "$BOT"     "$(cfg_bot)"       "ctoChannels[$NAME].botUserId set"
assert_eq 1 "$(cfg_count)"              "exactly one ctoChannels entry"
assert_eq 1 "$(acl_count)"              "watcher id appended once to allowFrom"

# ---------------------------------------------------------------------------
# 2) SECOND run — idempotent no-op. No dup in allowFrom; entry unchanged.
# ---------------------------------------------------------------------------
echo "=== second run is an idempotent no-op ==="
len_before="$(acl_len)"
run_wire >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc"                       "second run exits 0"
assert_eq 1 "$(acl_count)"              "watcher id still present exactly once (no duplicate)"
assert_eq "$len_before" "$(acl_len)"    "allowFrom length unchanged on re-run"
assert_eq "$CHANNEL" "$(cfg_channel)"   "channelId unchanged on re-run"
assert_eq "$BOT"     "$(cfg_bot)"       "botUserId unchanged on re-run"
assert_eq 1 "$(cfg_count)"              "still exactly one ctoChannels entry"

# Confirm the "already current" path is reported (proves no-op detection, not
# a silent re-write that happens to land the same bytes).
echo "=== second run reports already-current ==="
out2="$(run_wire 2>&1)"
case "$out2" in
  *"already current"*) assert_eq 1 1 "Half 1 reports 'already current'" ;;
  *) assert_eq 1 0 "Half 1 reports 'already current' (got: $out2)" ;;
esac
case "$out2" in
  *"already in allowFrom"*) assert_eq 1 1 "Half 2 reports 'already in allowFrom'" ;;
  *) assert_eq 1 0 "Half 2 reports 'already in allowFrom' (got: $out2)" ;;
esac

# ---------------------------------------------------------------------------
# 3) EMPTY bot id (re-run with no id on hand) — Half 1 SKIPPED, Half 2 still
#    runs and stays a no-op. Mirrors swarm-add's original phase-4e re-run path.
# ---------------------------------------------------------------------------
echo "=== empty bot-user-id skips Half 1, Half 2 stays no-op ==="
out3="$(SWARM_HOME="$ROOT" CTO_WATCHER_CONFIG="$CFG" SWARM_ACCESS_FILE="$ACC" \
        CTO_BUS_WATCHER_BOT_ID="$WATCHER" "$WIRE" "$NAME" "$CHANNEL" "" 2>&1)"; rc=$?
assert_eq 0 "$rc"                       "empty-bot-id run exits 0"
case "$out3" in
  *"SKIP ctoChannels write"*) assert_eq 1 1 "empty bot id SKIPs Half 1" ;;
  *) assert_eq 1 0 "empty bot id SKIPs Half 1 (got: $out3)" ;;
esac
assert_eq "$BOT" "$(cfg_bot)"           "ctoChannels botUserId untouched by empty-id run"
assert_eq 1 "$(acl_count)"              "allowFrom still has watcher id exactly once"

# ---------------------------------------------------------------------------
# 4) Argument validation — bad inputs are refused (fail-fast at the boundary).
# ---------------------------------------------------------------------------
echo "=== argument validation ==="
SWARM_HOME="$ROOT" CTO_WATCHER_CONFIG="$CFG" SWARM_ACCESS_FILE="$ACC" CTO_BUS_WATCHER_BOT_ID="$WATCHER" \
  "$WIRE" "$NAME" "not-numeric" "$BOT" >/dev/null 2>&1
assert_eq 1 "$?"                        "non-numeric channel refused"
SWARM_HOME="$ROOT" CTO_WATCHER_CONFIG="$CFG" SWARM_ACCESS_FILE="$ACC" CTO_BUS_WATCHER_BOT_ID="$WATCHER" \
  "$WIRE" "$NAME" "$CHANNEL" "not-numeric" >/dev/null 2>&1
assert_eq 1 "$?"                        "non-numeric (non-empty) bot id refused"
SWARM_HOME="$ROOT" CTO_WATCHER_CONFIG="$CFG" SWARM_ACCESS_FILE="$ACC" CTO_BUS_WATCHER_BOT_ID="$WATCHER" \
  "$WIRE" "$NAME" "$CHANNEL" >/dev/null 2>&1
assert_eq 1 "$?"                        "wrong arg count refused"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
