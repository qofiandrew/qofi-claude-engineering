#!/usr/bin/env bash
# Compatibility test for the engineering Claude Stop adapter. Delivery/retry
# policy is covered in swarm-harness/stop-delivery.test.ts; this pins the native
# hook wiring, fail-closed launcher behavior, and durable queue boundary.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/templates/engineering-cto/hooks/discord-reply-nudge.sh"
CHANNEL=1508921858165047390
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stop-adapter.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

echo '=== missing harness blocks Stop ==='
out="$(printf '{}' | SWARM_HOME= bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && pass 'missing operator-controlled harness exits 2' || fail "missing harness rc=$rc"
printf '%s' "$out" | grep -q '"decision":"block"' \
  && pass 'missing harness emits a native block decision' || fail 'missing block decision'

echo '=== failed Discord delivery becomes a verified private dead-letter ==='
TRANSCRIPT="$TMP/transcript.jsonl"
printf '%s\n' \
  '{"type":"user","uuid":"u1","message":{"content":"task"}}' \
  '{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Implemented the requested boundary and ran focused tests."}]}}' \
  > "$TRANSCRIPT"
STATE="$TMP/state"
payload="$(printf '{"session_id":"session-1","task_id":"task-1","transcript_path":"%s"}' "$TRANSCRIPT")"
printf '%s' "$payload" | env -u DISCORD_BOT_TOKEN \
  SWARM_HOME="$ROOT" SWARM_NAME=press-backend DISCORD_BOUND_CHANNEL="$CHANNEL" \
  SWARM_HARNESS_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>"$TMP/stderr"; rc=$?
[ "$rc" -eq 0 ] && pass 'durably queued stop may complete' || fail "queued stop rc=$rc"
[ "$(find "$STATE/dead-letter" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  && pass 'one dead-letter record written' || fail 'dead-letter record missing'
[ "$(find "$STATE/audit" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  && pass 'one audit record written' || fail 'audit record missing'
python3 - "$STATE" <<'PY'
import glob,json,os,stat,sys
root=sys.argv[1]
dead=json.load(open(glob.glob(root+'/dead-letter/*.json')[0]))
audit=json.load(open(glob.glob(root+'/audit/*.json')[0]))
assert dead['event']['runtime']=='claude'
assert dead['event']['channelId']=='1508921858165047390'
assert audit['outcome']['disposition']=='queued'
for p in glob.glob(root+'/*/*.json'):
    assert stat.S_IMODE(os.stat(p).st_mode)==0o600
PY
[ "$?" -eq 0 ] && pass 'queued event and private modes verify' || fail 'queued event verification failed'

echo '=== Stop re-entry is idempotent ==='
printf '%s' "$payload" | env -u DISCORD_BOT_TOKEN \
  SWARM_HOME="$ROOT" SWARM_NAME=press-backend DISCORD_BOUND_CHANNEL="$CHANNEL" \
  SWARM_HARNESS_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass 'replayed queued event completes' || fail "replay rc=$rc"
[ "$(find "$STATE/dead-letter" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  && pass 'replay does not duplicate dead-letter' || fail 'replay duplicated dead-letter'

echo '=== lead and SubagentStop boundaries are distinct and durable ==='
MULTI_STATE="$TMP/multi-state"
for who in lead agent-a agent-b; do
  transcript="$TMP/$who.jsonl"
  printf '%s\n' \
    "{\"type\":\"user\",\"uuid\":\"u-$who\",\"message\":{\"content\":\"task\"}}" \
    "{\"type\":\"assistant\",\"uuid\":\"a-$who\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$who boundary\"}]}}" \
    > "$transcript"
  if [ "$who" = lead ]; then
    multi_payload="$(printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"shared-session\",\"task_id\":\"shared-task\",\"stop_event_id\":\"same-native-id\",\"transcript_path\":\"%s\"}' "$transcript")"
  else
    multi_payload="$(printf '{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"shared-session\",\"task_id\":\"shared-task\",\"stop_event_id\":\"same-native-id\",\"agent_id\":\"%s\",\"agent_transcript_path\":\"%s\"}' "$who" "$transcript")"
  fi
  printf '%s' "$multi_payload" | env -u DISCORD_BOT_TOKEN \
    SWARM_HOME="$ROOT" SWARM_NAME=press-backend DISCORD_BOUND_CHANNEL="$CHANNEL" \
    SWARM_HARNESS_STATE_DIR="$MULTI_STATE" bash "$HOOK" >/dev/null 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] || fail "$who delivered-or-queued boundary rc=$rc"
done
[ "$(find "$MULTI_STATE/dead-letter" -type f -name '*.json' | wc -l | tr -d ' ')" = 3 ] \
  && pass 'lead plus two subagents produce three distinct durable outcomes' \
  || fail 'lead/subagent outcomes collided'
[ "$(find "$MULTI_STATE/audit" -type f -name '*.json' | wc -l | tr -d ' ')" = 3 ] \
  && pass 'every lead/subagent stop is audited' || fail 'subagent audit is incomplete'

echo '=== both Claude templates register the same SubagentStop adapter ==='
python3 - "$ROOT" <<'PY'
import json,sys
root=sys.argv[1]
expected='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/discord-reply-nudge.sh"'
for kind in ('engineering-cto','cpo'):
    value=json.load(open(f'{root}/templates/{kind}/settings.example.json'))
    hooks=value['hooks']['SubagentStop']
    commands=[entry['command'] for group in hooks for entry in group['hooks']]
    assert commands == [expected], (kind,commands)
PY
[ "$?" -eq 0 ] && pass 'SubagentStop registration is symmetric' || fail 'SubagentStop registration drifted'

echo '=== atomic parity receipt enables the Claude completion gate ==='
ADOPT_STATE="$TMP/adopt-state"
AUTHORITY="$TMP/adoption-authority"
mkdir -m 700 "$ADOPT_STATE" "$AUTHORITY"
ADOPT_STATE="$(cd "$ADOPT_STATE" && pwd -P)"
AUTHORITY="$(cd "$AUTHORITY" && pwd -P)"
ROOT_CANON="$(cd "$ROOT" && pwd -P)"
POLICY_SHA="$(cd "$ROOT" && bun -e '
  import { readFileSync } from "node:fs";
  import { completionReviewPolicySha256, parseCompletionReviewPolicy } from "./swarm-harness/completion-review-policy.ts";
  console.log(completionReviewPolicySha256(parseCompletionReviewPolicy(JSON.parse(readFileSync("./swarm-harness/completion-review-policy.json", "utf8")))));
')"
RECEIPT="$AUTHORITY/parity.json"
python3 - "$RECEIPT" "$ADOPT_STATE" "$ROOT_CANON" "$POLICY_SHA" <<'PY'
import json,os,sys
path,state,repo,policy=sys.argv[1:]
value={
  'schema':'qofi-harness-parity-adoption/v1', 'contract':'claude-codex-v1',
  'swarm':'press-backend', 'runtimes':['claude','codex'],
  'state_root':state, 'roadmap_repo_root':repo,
  'dr_refs':['ADR-0022','ADR-0023'], 'completion_policy_sha256':policy,
}
with open(path,'x') as f:
    f.write(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n')
os.chmod(path,0o600)
PY

missing_payload='{"hook_event_name":"Stop","session_id":"adopted","task_id":"missing-review","stop_event_id":"native-missing","last_assistant_message":"must block"}'
missing_out="$(printf '%s' "$missing_payload" | env -u DISCORD_BOT_TOKEN \
  SWARM_HOME="$ROOT" SWARM_NAME=press-backend CLAUDE_PROJECT_DIR="$ROOT_CANON" \
  DISCORD_BOUND_CHANNEL="$CHANNEL" SWARM_HARNESS_PARITY_RECEIPT="$RECEIPT" \
  bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && pass 'adopted missing completion evidence blocks Stop' \
  || fail "adopted missing evidence rc=$rc"
printf '%s' "$missing_out" | grep -q '"decision":"block"' \
  && pass 'adopted refusal emits native block decision' || fail 'adopted refusal lacks block decision'
[ ! -d "$ADOPT_STATE/stops/dead-letter" ] || \
  [ "$(find "$ADOPT_STATE/stops/dead-letter" -type f | wc -l | tr -d ' ')" = 0 ] \
  && pass 'gate refusal performs no Discord/dead-letter delivery attempt' \
  || fail 'gate refusal attempted delivery'

valid_payload='{"hook_event_name":"Stop","session_id":"adopted","task_id":"reviewed-task","stop_event_id":"native-valid","last_assistant_message":"reviewed boundary","occurred_at_ms":4000}'
EVENT_ID="$(cd "$ROOT" && PAYLOAD="$valid_payload" SWARM_NAME=press-backend CLAUDE_PROJECT_DIR="$ROOT_CANON" DISCORD_BOUND_CHANNEL="$CHANNEL" bun -e '
  import { ClaudeStopAdapter } from "./swarm-harness/runtime-adapters.ts";
  console.log(new ClaudeStopAdapter({env:process.env}).normalizeStop(JSON.parse(process.env.PAYLOAD)).eventId);
')"
RECEIPT_SHA="$(shasum -a 256 "$RECEIPT" | awk '{print $1}')"
ENVELOPE_DIR="$ADOPT_STATE/completion-authority/claude/press-backend"
mkdir -p -m 700 "$ENVELOPE_DIR"
chmod 700 "$ADOPT_STATE/completion-authority" "$ADOPT_STATE/completion-authority/claude" "$ENVELOPE_DIR"
python3 - "$ENVELOPE_DIR/reviewed-task.json" "$RECEIPT_SHA" "$EVENT_ID" <<'PY'
import json,os,sys
path,receipt,event=sys.argv[1:]
diff='d'*64
value={
  'schema':'qofi-claude-completion-envelope/v1',
  'adoption_receipt_sha256':receipt, 'runtime':'claude', 'swarm':'press-backend',
  'task_id':'reviewed-task', 'stop_event_id':event, 'final_diff_sha256':diff,
  'reviewed_paths':[],
  'artifact':{
    'schema':'qofi-harness-review-evidence/v1', 'artifact_id':'review-result',
    'task_id':'reviewed-task', 'phase':'completion',
    'reviewed_diff_sha256':diff, 'verdict':'approve',
  },
}
with open(path,'x') as f:
    f.write(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n')
os.chmod(path,0o600)
PY
printf '%s' "$valid_payload" | env -u DISCORD_BOT_TOKEN \
  SWARM_HOME="$ROOT" SWARM_NAME=press-backend CLAUDE_PROJECT_DIR="$ROOT_CANON" \
  DISCORD_BOUND_CHANNEL="$CHANNEL" SWARM_HARNESS_PARITY_RECEIPT="$RECEIPT" \
  bash "$HOOK" >/dev/null 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass 'exact receipt-bound completion artifact may stop' \
  || fail "valid adopted artifact rc=$rc"
[ "$(find "$ADOPT_STATE/stops/dead-letter" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  && pass 'valid gate proceeds into legacy-compatible delivered-or-queued transport' \
  || fail 'valid gate did not reach transport'

printf '\n  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
