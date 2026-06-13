#!/usr/bin/env bash
# discord-reply-nudge.sh — Stop hook (engineering-cto LEAD only).
#
# A SOFT, non-blocking nudge: if the lead's response cycle produced a substantive
# operator-facing TEXT response but never posted it to Discord, remind it (via
# additionalContext) that terminal output is unmonitored. It NEVER blocks (always
# exit 0) — a soft behavioral expectation with legitimate exceptions gets a NUDGE,
# not a gate. A blocking Stop-gate satisfiable by reflexive "ack, working" filler
# would be worse than no gate (it trains go-through-the-motions posting); hard
# blocks are reserved for binary objective floors (red tests → test-gate;
# missing [DoD-*] → dod-affirm). Models the PostToolUse quality-check philosophy:
# deterministic detect, surface loudly, never fight the agent.
#
# Wired in settings.json under hooks.Stop. Fires for the LEAD; teammates fire
# SubagentStop (untouched). The CPO is exempt — it is deliberately silent by
# default, so this hook is engineering-cto only (not stamped into cpo swarms).
#
# Fail-OPEN: any parse/read issue → exit 0, no nudge, never disrupt.
#
# Detection (the confirmed heuristic):
#   1. Window the current turn: back to the last string-content, non-meta user
#      record (the relayed prompt that began the turn).
#   2. DELIVERED if any mcp__plugin_discord-b2b_discord__reply tool_use appears in
#      the turn — the lead's OR a teammate's (isSidechain) — inline or .md-attach
#      (the reply tool's `files` param). → silent.
#   3. Else take the LEAD's FINAL assistant message text (drop thinking/tool_use),
#      trim; < FLOOR chars → silent (trivial/internal); else → nudge.

set -uo pipefail
FLOOR=150
REPLY_TOOL='mcp__plugin_discord-b2b_discord__reply'

EVENT="$(cat 2>/dev/null || true)"

# Stop-hook loop guard (belt-and-suspenders — we never block, so this won't be set).
if printf '%s' "$EVENT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

TRANSCRIPT="$(printf '%s' "$EVENT" | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("transcript_path") or "")
except Exception: print("")
' 2>/dev/null)"
if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then exit 0; fi

# One python pass over the transcript JSONL → "1" (nudge) or "0" (silent).
NUDGE="$(python3 - "$TRANSCRIPT" "$FLOOR" "$REPLY_TOOL" <<'PY' 2>/dev/null
import json, sys
path, floor, reply_tool = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    raw = open(path, encoding="utf-8").read().splitlines()
except Exception:
    print("0"); sys.exit(0)

recs = []
for ln in raw:
    ln = ln.strip()
    if not ln:
        continue
    try:
        recs.append(json.loads(ln))
    except Exception:
        continue

# 1) Turn start = last user record with STRING content, not isMeta.
start = 0
for i in range(len(recs) - 1, -1, -1):
    r = recs[i]
    if r.get("type") != "user" or r.get("isMeta"):
        continue
    if isinstance((r.get("message") or {}).get("content"), str):
        start = i
        break
turn = recs[start:]

def blocks(r):
    return ((r.get("message") or {}).get("content")) or []

# 2) Delivered? any reply tool_use in the turn (lead OR teammate-sidechain).
for r in turn:
    if r.get("type") != "assistant":
        continue
    for b in blocks(r):
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == reply_tool:
            print("0"); sys.exit(0)

# 3) Lead's FINAL assistant message text (isSidechain != true), text blocks only.
final_text = ""
for r in turn:
    if r.get("type") != "assistant" or r.get("isSidechain") is True:
        continue
    txt = "".join(
        b.get("text", "") for b in blocks(r)
        if isinstance(b, dict) and b.get("type") == "text"
    )
    if txt.strip():
        final_text = txt  # keep the LAST lead text message
print("1" if len(final_text.strip()) >= floor else "0")
PY
)"

[ "$NUDGE" = "1" ] || exit 0

# Non-blocking nudge: surface loudly into the next turn's context. NEVER exit 2.
python3 - <<'PY' 2>/dev/null || true
import json
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": (
      "Your last response went to the terminal, which the operator CANNOT see. "
      "Deliver it through the discord reply tool (mcp__plugin_discord-b2b_discord__reply) "
      "— ≤2000 chars, or attach as a .md file per §Message length. Terminal "
      "output is unmonitored; nothing reaches the operator until you post."
    )
  }
}))
PY
exit 0
