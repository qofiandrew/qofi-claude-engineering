#!/usr/bin/env bash
# discord-reply-nudge.sh — Stop hook (cpo LEAD only).
#
# The CPO counterpart to engineering-cto's nudge of the same name, with ONE
# extra gate that makes it safe for an agent that is silent-by-default toward
# CTOs: it fires ONLY on an OPERATOR-origin turn. If the cycle the operator
# started (a prompt in #qofi-product) produced a substantive text response but
# never posted it to Discord, remind the CPO (via additionalContext) that the
# terminal is unmonitored. It NEVER blocks (always exit 0) — a soft behavioral
# expectation with legitimate exceptions gets a NUDGE, not a gate.
#
# WHY an operator-origin gate (the CPO-specific part). The CPO is silent by
# default toward CTOs (CLAUDE.md §"Discord is the only surface", §"The CTO
# loop"): on a BUS-origin turn, producing no post is usually CORRECT, not a lost
# response — so nudging there would nag exactly the legitimate silence the
# doctrine protects. The reported failure is narrower: an OPERATOR question
# answered in the pane and stopped, indistinguishable from silence. This hook
# closes precisely that case and nothing else — it changes WHERE the CPO's
# operator-facing output goes, never WHEN it speaks to a CTO. The base nudge
# exempted the CPO wholesale; this is the CPO-shaped re-introduction.
#
# Wired in settings.json under hooks.Stop. Fires for the LEAD; teammates fire
# SubagentStop (untouched).
#
# Fail-OPEN: any parse/read issue, or an indeterminate origin → exit 0, no
# nudge, never disrupt. We would rather miss a nudge than nag a correct silence.
#
# Detection (the confirmed heuristic):
#   1. Window the current turn: anchor on the LAST Discord-framed prompt — a user
#      record whose string content carries `chat_id="<id>"` (how the bridge
#      delivers, server.ts: `<channel source="…discord" chat_id="…" …>`). No such
#      record → fail-open silent.
#   2. ORIGIN GATE: the anchor's chat_id must equal DISCORD_OPERATOR_CHANNEL (the
#      env the CPO launch sets, swarm_bound_exports). Bus/other/unset → silent.
#   3. DELIVERED if any mcp__plugin_discord-b2b_discord__reply tool_use appears in
#      the turn — the CPO's OR a teammate's (isSidechain), inline or .md-attach. →
#      silent. (The reply routes by the answered prompt's channel_id; we don't
#      re-check the target — a reply this cycle means the CPO spoke.)
#   4. Else take the CPO's FINAL assistant message text (drop thinking/tool_use),
#      trim; < FLOOR chars → silent (trivial/internal); else → nudge.

set -uo pipefail
FLOOR=150
REPLY_TOOL='mcp__plugin_discord-b2b_discord__reply'
OPERATOR_CHANNEL="${DISCORD_OPERATOR_CHANNEL:-}"

EVENT="$(cat 2>/dev/null || true)"

# Stop-hook loop guard (belt-and-suspenders — we never block, so this won't be set).
if printf '%s' "$EVENT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# Indeterminate operator channel → can't prove operator-origin → fail-open silent.
if [ -z "$OPERATOR_CHANNEL" ]; then exit 0; fi

TRANSCRIPT="$(printf '%s' "$EVENT" | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("transcript_path") or "")
except Exception: print("")
' 2>/dev/null)"
if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then exit 0; fi

# One python pass over the transcript JSONL → "1" (nudge) or "0" (silent).
# The heredoc is kept OUT of $(...) — bash 3.2's command-substitution scanner
# mishandles a heredoc body carrying regex parens/quotes; write to a temp, read back.
PYOUT="$(mktemp "${TMPDIR:-/tmp}/cponudge.XXXXXX")" || exit 0
python3 - "$TRANSCRIPT" "$FLOOR" "$REPLY_TOOL" "$OPERATOR_CHANNEL" > "$PYOUT" 2>/dev/null <<'PY'
import json, re, sys
path, floor, reply_tool, operator = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
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

def content(r):
    return (r.get("message") or {}).get("content")

# 1) Anchor = last user record whose STRING content carries a chat_id (the
#    Discord-framed prompt that began the cycle). These arrive isMeta=True.
CHAT_ID = re.compile(r'chat_id="(\d+)"')
start, origin = None, None
for i in range(len(recs) - 1, -1, -1):
    r = recs[i]
    if r.get("type") != "user":
        continue
    c = content(r)
    if not isinstance(c, str):
        continue
    m = CHAT_ID.search(c)
    if m:
        start, origin = i, m.group(1)
        break
if start is None:
    print("0"); sys.exit(0)

# 2) Origin gate: only an operator-origin cycle is eligible. Bus/other → silent.
if origin != operator:
    print("0"); sys.exit(0)

turn = recs[start:]

def blocks(r):
    return content(r) or []

# 3) Delivered? any reply tool_use in the turn (CPO OR teammate-sidechain).
for r in turn:
    if r.get("type") != "assistant":
        continue
    for b in blocks(r):
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == reply_tool:
            print("0"); sys.exit(0)

# 4) CPO's FINAL assistant message text (isSidechain != true), text blocks only.
final_text = ""
for r in turn:
    if r.get("type") != "assistant" or r.get("isSidechain") is True:
        continue
    txt = "".join(
        b.get("text", "") for b in blocks(r)
        if isinstance(b, dict) and b.get("type") == "text"
    )
    if txt.strip():
        final_text = txt  # keep the LAST CPO text message
print("1" if len(final_text.strip()) >= floor else "0")
PY
NUDGE="$(cat "$PYOUT" 2>/dev/null)"
rm -f "$PYOUT"

[ "$NUDGE" = "1" ] || exit 0

# Non-blocking nudge: surface loudly into the next turn's context. NEVER exit 2.
python3 - <<'PY' 2>/dev/null || true
import json
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": (
      "Your last response to the operator went to the terminal, which they "
      "CANNOT see. Deliver it through the discord reply tool "
      "(mcp__plugin_discord-b2b_discord__reply) to #qofi-product — ≤2000 chars, "
      "or attach as a .md file per §Message length. This is the operator "
      "register; terminal output is unmonitored and reaches no one. (Silence "
      "toward CTOs on the bus is unaffected — this fires only on operator turns.)"
    )
  }
}))
PY
exit 0
