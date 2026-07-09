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
#   1. Window the current turn: anchor on the LAST OPERATOR-channel prompt — a
#      user record whose string content carries `chat_id="<operator>"` (how the
#      bridge delivers, server.ts: `<channel source="…discord" chat_id="…" …>`,
#      where chat_id == operator equals DISCORD_OPERATOR_CHANNEL, the env the CPO
#      launch sets via swarm_bound_exports). We anchor on the operator prompt
#      SPECIFICALLY, not the last chat_id record: an operator turn is routinely
#      interleaved with bus traffic (CTO replies, watcher pings) that also carry a
#      chat_id, and anchoring on the last of those lands the window on a BUS record
#      and misses the operator's question. No operator inbound → fail-open silent.
#   2. DELIVERED only if a mcp__plugin_discord-b2b_discord__reply tool_use whose
#      input.chat_id == operator appears in the turn — the CPO's OR a teammate's
#      (isSidechain), inline or .md-attach. → silent. The TARGET check is the crux:
#      the CPO legitimately posts to the BUS on an operator turn (driving CTOs,
#      STATE markers); a bus reply is NOT an operator reply, so it does NOT count
#      as delivered. Only an operator-targeted reply proves the operator was answered.
#   3. Else take the CPO's FINAL assistant message text (drop thinking/tool_use),
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

# 1) Anchor = last OPERATOR-channel inbound (chat_id == operator). We anchor on
#    the operator prompt SPECIFICALLY, not merely the last chat_id record: an
#    operator-origin turn is routinely interleaved with bus traffic (CTO replies,
#    watcher pings) that ALSO carry a chat_id, and anchoring on the last of those
#    would land the window on a BUS record and miss the operator's question
#    entirely. Bus records simply don't match `operator`, so this skips them. No
#    operator inbound at all → fail-open silent (a pure-bus cycle is not in scope).
CHAT_ID = re.compile(r'chat_id="(\d+)"')
start = None
for i in range(len(recs) - 1, -1, -1):
    r = recs[i]
    if r.get("type") != "user":
        continue
    c = content(r)
    if not isinstance(c, str):
        continue
    m = CHAT_ID.search(c)
    if m and m.group(1) == operator:
        start = i
        break
if start is None:
    print("0"); sys.exit(0)

turn = recs[start:]

def blocks(r):
    return content(r) or []

# 2) Delivered? a reply tool_use TARGETING THE OPERATOR CHANNEL anywhere in the
#    window (CPO OR teammate-sidechain). The target check is the whole point: on
#    an operator-origin turn the CPO legitimately posts to the BUS (driving CTOs,
#    STATE markers) — those are NOT operator replies. Only a reply whose
#    input.chat_id == operator proves the operator was actually answered. A turn
#    that posts only to the bus has NOT delivered to the operator.
for r in turn:
    if r.get("type") != "assistant":
        continue
    for b in blocks(r):
        if (isinstance(b, dict) and b.get("type") == "tool_use"
                and b.get("name") == reply_tool
                and str((b.get("input") or {}).get("chat_id", "")) == operator):
            print("0"); sys.exit(0)

# 3) The CPO's most substantive operator-owed text in the window (isSidechain
#    != true), text blocks only — the LONGEST, not merely the last. On an
#    interleaved operator+bus window the operator's actual answer is often an
#    EARLY text block (the real reply, written but not posted), while the LAST
#    text is short bus-narration ("retrying the state declaration"). Taking the
#    last would let that trailing narration fall below the floor and mask an
#    unposted operator answer — the documented failure. The longest substantive
#    text block is the response the operator was owed; floor-test that.
best_len = 0
for r in turn:
    if r.get("type") != "assistant" or r.get("isSidechain") is True:
        continue
    txt = "".join(
        b.get("text", "") for b in blocks(r)
        if isinstance(b, dict) and b.get("type") == "text"
    )
    n = len(txt.strip())
    if n > best_len:
        best_len = n  # keep the CPO's LONGEST text message (the owed answer)
print("1" if best_len >= floor else "0")
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
