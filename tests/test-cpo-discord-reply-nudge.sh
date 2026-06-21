#!/usr/bin/env bash
# test-cpo-discord-reply-nudge.sh — the CPO Stop nudge: like the engineering-cto
# nudge, but it fires ONLY on an OPERATOR-origin turn, never on a bus/CTO turn.
#
# Pins the SOFT, non-blocking contract AND the CPO-specific origin gate: the hook
# NEVER blocks (always exit 0); it emits an additionalContext nudge ONLY when
# (the turn was started by a prompt from the operator channel) AND (substantive
# CPO text >= floor) AND (no discord reply this turn). It is SILENT on a
# bus-origin turn (silence-by-default toward CTOs is correct, not a missed post),
# when a reply happened (CPO OR teammate-sidechain), when the text is
# short/absent, on a tool-only turn, and when the operator channel is unknown.
#
# Run from $SWARM_HOME:  bash tests/test-cpo-discord-reply-nudge.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/templates/cpo/hooks/discord-reply-nudge.sh"

OP=1508921858165047390          # #qofi-product (operator channel)
BUS=1510301812434141194         # #cpo-cto-bus

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cponudge.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT INT TERM

# run_hook TRANSCRIPT [OPERATOR_CHANNEL] -> echoes hook stdout; asserts exit 0.
run_hook(){
  local t="$1" opch="${2:-$OP}" out rc
  out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"%s"}' "$t" \
        | DISCORD_OPERATOR_CHANNEL="$opch" bash "$HOOK" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || fail "hook exited non-zero ($rc) — it must NEVER block"
  printf '%s' "$out"
}

# --- transcript line builders ---
# A Discord-framed prompt as the bridge delivers it (isMeta=True, carries chat_id).
prompt(){ # chat_id
  python3 -c 'import json,sys
print(json.dumps({"type":"user","isMeta":True,"message":{"content":
  "<channel source=\"plugin:discord-b2b:discord\" chat_id=\""+sys.argv[1]+"\" message_id=\"1\" user=\"op\">\nhello\n</channel>"}}))' "$1"; }
asst_text(){ # text [sidechain=true|false]
  python3 -c 'import json,sys
print(json.dumps({"type":"assistant","isSidechain":(sys.argv[2]=="true"),
  "message":{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":sys.argv[1]}]}}))' "$1" "${2:-false}"; }
asst_reply(){ # [sidechain=true|false]
  python3 -c 'import json,sys
print(json.dumps({"type":"assistant","isSidechain":(sys.argv[1]=="true"),
  "message":{"content":[{"type":"tool_use","name":"mcp__plugin_discord-b2b_discord__reply","input":{"text":"posted"}}]}}))' "${1:-false}"; }
asst_tooluse(){ printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}'; }
LONG="This is a substantial operator-facing status update that comfortably exceeds the 150-character floor, so the nudge should treat it as a real response that ought to be delivered to Discord."

echo "=== 1) OPERATOR-origin, substantive text, NO reply -> NUDGE ==="
F="$TMP/t1.jsonl"; { prompt "$OP"; asst_text "$LONG"; } > "$F"
out="$(run_hook "$F")"
printf '%s' "$out" | grep -q 'additionalContext'  && pass "operator turn, text-without-reply -> nudge" || fail "expected a nudge"
printf '%s' "$out" | grep -q 'discord reply tool'  && pass "nudge names the discord reply tool"        || fail "nudge should name the tool"
printf '%s' "$out" | grep -q '"decision"'          && fail "nudge must NOT carry a block decision"      || pass "nudge is non-blocking (no decision:block)"

echo "=== 2) BUS-origin, substantive text, NO reply -> SILENT (the CPO-specific gate) ==="
F="$TMP/t2.jsonl"; { prompt "$BUS"; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "bus turn -> silent (silence-by-default toward CTOs preserved)" || fail "bus-origin must never nudge"

echo "=== 3) OPERATOR-origin, CPO posted a reply -> SILENT ==="
F="$TMP/t3.jsonl"; { prompt "$OP"; asst_reply false; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "reply present -> silent" || fail "should be silent when the CPO replied"

echo "=== 4) OPERATOR-origin, teammate (sidechain) reply -> SILENT ==="
F="$TMP/t4.jsonl"; { prompt "$OP"; asst_reply true; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "teammate-delivered reply -> silent" || fail "should be silent when a teammate posted"

echo "=== 5) OPERATOR-origin, short text (< floor) -> SILENT ==="
F="$TMP/t5.jsonl"; { prompt "$OP"; asst_text "on it"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "short text -> silent (below floor)" || fail "short text should not nudge"

echo "=== 6) OPERATOR-origin, tool-only final -> SILENT ==="
F="$TMP/t6.jsonl"; { prompt "$OP"; asst_tooluse; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "tool-only turn -> silent" || fail "tool-only should not nudge"

echo "=== 7) windows the CURRENT turn: prior BUS turn delivered, new OPERATOR turn text+no reply -> NUDGE ==="
F="$TMP/t7.jsonl"; { prompt "$BUS"; asst_reply false; prompt "$OP"; asst_text "$LONG"; } > "$F"
printf '%s' "$(run_hook "$F")" | grep -q 'additionalContext' && pass "anchors on the latest prompt (new operator turn)" || fail "should nudge on the new operator turn"

echo "=== 8) windows the CURRENT turn: prior OPERATOR turn (no reply), new BUS turn -> SILENT ==="
F="$TMP/t8.jsonl"; { prompt "$OP"; asst_text "$LONG"; prompt "$BUS"; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "latest turn is bus -> silent (prior operator turn doesn't leak)" || fail "should anchor on the latest (bus) prompt"

echo "=== 9) DISCORD_OPERATOR_CHANNEL unset -> SILENT (indeterminate origin, fail-open) ==="
F="$TMP/t9.jsonl"; { prompt "$OP"; asst_text "$LONG"; } > "$F"
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"%s"}' "$F" | DISCORD_OPERATOR_CHANNEL="" bash "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && pass "no operator channel -> fail-open silent" || fail "unset operator channel must fail-open silent"

echo "=== 10) no Discord-framed prompt at all -> SILENT (no anchor) ==="
F="$TMP/t10.jsonl"; { asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "no anchor prompt -> silent" || fail "missing anchor must be silent"

echo "=== 11) fail-open: unreadable transcript -> silent, exit 0 ==="
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"/no/such/file.jsonl"}' | DISCORD_OPERATOR_CHANNEL="$OP" bash "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && pass "missing transcript -> fail-open silent exit 0" || fail "fail-open expected"

echo "=== 12) stop_hook_active=true -> silent (no re-entry) ==="
F="$TMP/t12.jsonl"; { prompt "$OP"; asst_text "$LONG"; } > "$F"
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":true,"transcript_path":"%s"}' "$F" | DISCORD_OPERATOR_CHANNEL="$OP" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && pass "stop_hook_active -> silent" || fail "should be silent under stop_hook_active"

echo; printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; }
exit 0
