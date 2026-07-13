#!/usr/bin/env bash
# CPO adapter parity: a multi-bound Stop uses the transcript's actual source
# channel and the operator register as fallback. The harness, not the CPO's
# choice to call a tool, owns delivery.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/templates/cpo/hooks/discord-reply-nudge.sh"
OP=1508921858165047390
BUS=1510301812434141194
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpo-stop-adapter.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

TRANSCRIPT="$TMP/transcript.jsonl"
python3 - "$TRANSCRIPT" "$BUS" <<'PY'
import json,sys
path,bus=sys.argv[1:]
records=[
 {"type":"user","uuid":"u1","isMeta":True,"message":{"content":f'<channel source="discord" chat_id="{bus}">ping</channel>'}},
 {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Resolved the named loop to its next harness state."}]}}
]
with open(path,'w') as f:
 for record in records: f.write(json.dumps(record)+'\n')
PY

STATE="$TMP/state"
printf '{"session_id":"cpo-session","task_id":"cpo-loop","transcript_path":"%s"}' "$TRANSCRIPT" \
  | env -u DISCORD_BOT_TOKEN SWARM_HOME="$ROOT" SWARM_NAME=qofi-product \
      DISCORD_BOUND_CHANNEL="$OP,$BUS" DISCORD_OPERATOR_CHANNEL="$OP" \
      SWARM_HARNESS_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass 'CPO Stop is delivered-or-queued by the shared harness' || fail "CPO hook rc=$rc"

python3 - "$STATE" "$BUS" "$OP" <<'PY'
import glob,json,sys
root,bus,op=sys.argv[1:]
record=json.load(open(glob.glob(root+'/dead-letter/*.json')[0]))
event=record['event']
assert event['runtime']=='claude'
assert event['channelId']==bus
assert event['fallbackChannelId']==op
assert event['summary']=='Resolved the named loop to its next harness state.'
PY
[ "$?" -eq 0 ] && pass 'meta transcript source and operator fallback are normalized' || fail 'CPO channel normalization failed'

cmp -s "$HOOK" "$ROOT/templates/engineering-cto/hooks/discord-reply-nudge.sh" \
  && fail 'adapters should carry only archetype comments, not identical copied policy' \
  || pass 'both thin adapters delegate to one harness policy'

printf '\n  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
