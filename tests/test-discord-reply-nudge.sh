#!/usr/bin/env bash
# test-discord-reply-nudge.sh — the Stop nudge that reminds an engineering-cto
# lead when a substantive response went to the terminal without a Discord post.
#
# Pins the SOFT, non-blocking contract: the hook NEVER blocks (always exit 0); it
# emits an additionalContext nudge ONLY when (substantive lead text >= floor) AND
# (no discord reply this turn). Silent when a reply happened (lead OR teammate-
# sidechain), when the lead text is short/absent, or on a tool-only turn; and it
# windows the CURRENT turn (a prior turn's reply doesn't suppress a new nudge).
#
# Run from $SWARM_HOME:  bash tests/test-discord-reply-nudge.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/templates/engineering-cto/hooks/discord-reply-nudge.sh"

PASS=0; FAIL=0; FAILURES=""
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nudge.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT INT TERM

# run_hook TRANSCRIPT -> echoes hook stdout; asserts the hook NEVER blocks (exit 0)
run_hook(){
  local t="$1" out rc
  out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"%s"}' "$t" | bash "$HOOK" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || fail "hook exited non-zero ($rc) — it must NEVER block"
  printf '%s' "$out"
}

# --- transcript line builders ---
user_str(){ python3 -c 'import json,sys;print(json.dumps({"type":"user","message":{"content":sys.argv[1]}}))' "$1"; }
asst_text(){ # text [sidechain=true|false]
  python3 -c 'import json,sys
print(json.dumps({"type":"assistant","isSidechain":(sys.argv[2]=="true"),
  "message":{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":sys.argv[1]}]}}))' "$1" "${2:-false}"
}
asst_reply(){ # [sidechain=true|false]
  python3 -c 'import json,sys
print(json.dumps({"type":"assistant","isSidechain":(sys.argv[1]=="true"),
  "message":{"content":[{"type":"tool_use","name":"mcp__plugin_discord-b2b_discord__reply","input":{"text":"posted"}}]}}))' "${1:-false}"
}
asst_tooluse(){ # a non-reply tool_use only, no text
  printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}'
}
LONG="This is a substantial operator-facing status update that comfortably exceeds the 150-character floor, so the nudge should treat it as a real response that ought to be delivered to Discord."

echo "=== 1) substantive lead text, NO reply -> NUDGE ==="
F="$TMP/t1.jsonl"; { user_str "do the thing"; asst_text "$LONG"; } > "$F"
out="$(run_hook "$F")"
printf '%s' "$out" | grep -q 'additionalContext'    && pass "text-without-reply -> nudge emitted" || fail "expected a nudge"
printf '%s' "$out" | grep -q 'discord reply tool'   && pass "nudge names the discord reply tool"  || fail "nudge should name the tool"
printf '%s' "$out" | grep -q '"decision"'           && fail "nudge must NOT carry a block decision" || pass "nudge is non-blocking (no decision:block)"

echo "=== 2) lead posted a reply -> SILENT ==="
F="$TMP/t2.jsonl"; { user_str "do the thing"; asst_reply false; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "lead reply present -> silent" || fail "should be silent when the lead replied"

echo "=== 3) teammate (sidechain) reply -> SILENT (reply-anywhere, Q3) ==="
F="$TMP/t3.jsonl"; { user_str "do the thing"; asst_reply true; asst_text "$LONG"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "teammate-delivered reply -> silent" || fail "should be silent when a teammate posted"

echo "=== 4) short lead text (< floor) -> SILENT ==="
F="$TMP/t4.jsonl"; { user_str "do the thing"; asst_text "on it"; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "short text -> silent (below floor)" || fail "short text should not nudge"

echo "=== 5) tool-only final (no operator-facing text) -> SILENT ==="
F="$TMP/t5.jsonl"; { user_str "do the thing"; asst_tooluse; } > "$F"
[ -z "$(run_hook "$F")" ] && pass "tool-only turn -> silent" || fail "tool-only should not nudge"

echo "=== 6) prior turn delivered; CURRENT turn has substantive text + no reply -> NUDGE ==="
F="$TMP/t6.jsonl"; { user_str "first"; asst_reply false; user_str "second"; asst_text "$LONG"; } > "$F"
printf '%s' "$(run_hook "$F")" | grep -q 'additionalContext' && pass "windows the current turn (prior reply doesn't count)" || fail "should nudge on the new turn"

echo "=== 7) fail-open: unreadable transcript -> silent, exit 0 ==="
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"/no/such/file.jsonl"}' | bash "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && pass "missing transcript -> fail-open silent exit 0" || fail "fail-open expected"

echo "=== 8) stop_hook_active=true -> silent (no re-entry) ==="
F="$TMP/t8.jsonl"; { user_str "do the thing"; asst_text "$LONG"; } > "$F"
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":true,"transcript_path":"%s"}' "$F" | bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && pass "stop_hook_active -> silent" || fail "should be silent under stop_hook_active"

echo; printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; }
exit 0
