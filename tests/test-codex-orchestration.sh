#!/usr/bin/env bash
# Engine-aware restart/rotation/watch/typing/view integration regressions.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-orchestration.XXXXXX")"
SHORT_HOME="$(/usr/bin/python3 -c 'import os; print(os.path.realpath("/tmp"))')/codexorch.$$"
trap 'rm -rf "$TMP" "$SHORT_HOME"' EXIT

HOME="$SHORT_HOME"; export HOME
SWARM="$TMP/swarm"
REPO_CODEX="$TMP/repo-codex"
REPO_CLAUDE="$TMP/repo-claude"
STUB="$TMP/stubbin"
mkdir -p "$HOME" "$SWARM/templates" "$REPO_CODEX" "$REPO_CLAUDE" "$STUB"
chmod 700 "$HOME"
printf 'export BOT_CODEX="tok-codex"\nexport BOT_CLAUDE="tok-claude"\n' > "$SWARM/tokens.env"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=$1 got=$2)"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

codex_conf(){
  printf 'codex | %s | BOT_CODEX | 111 | 999 | | codex\n' "$REPO_CODEX" > "$SWARM/swarm.conf"
}
mixed_conf(){
  {
    printf 'codex | %s | BOT_CODEX | 111 | 999 | | codex\n' "$REPO_CODEX"
    printf 'claude | %s | BOT_CLAUDE | 222 | 999\n' "$REPO_CLAUDE"
  } > "$SWARM/swarm.conf"
}
write_runtime(){ # name active queue [endpoint]
  local name="$1" active="$2" queue="$3" endpoint="${4:-}"
  local dir="$HOME/.codex/channels/discord-$name"
  mkdir -p "$dir"
  chmod 700 "$HOME/.codex" "$HOME/.codex/channels" "$dir"
  /usr/bin/python3 - "$dir/runtime.json" "$$" "$active" "$queue" "$endpoint" <<'PY'
import datetime, json, os, sys
p,pid,active,queue,endpoint=sys.argv[1:]
now=datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
active=active=='1'
json.dump({
  'schema':'codex-bridge-runtime/v1','pid':int(pid),'started_at':now,'updated_at':now,
  'ready':True,'active':active,'queue_depth':int(queue),
  'child_pid':int(pid) if active else None,
  'turn_started_at':now if active else None,'last_completed_at':now,
  'last_error':None,'backend':'app-server' if endpoint else 'exec',
  'app_server_endpoint':endpoint or None,
},open(p,'w'))
os.chmod(p,0o600)
PY
}
make_socket(){ # name
  local socket_path="$HOME/.codex/channels/discord-$1/app-server.sock"
  rm -f "$socket_path"
  /usr/bin/python3 - "$socket_path" <<'PY'
import os, socket, sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close(); os.chmod(sys.argv[1], 0o600)
PY
  printf '%s' "$socket_path"
}
write_sessions(){ # name thread...
  local name="$1"; shift
  local file="$HOME/.codex/channels/discord-$name/sessions.json"
  /usr/bin/python3 - "$file" "$@" <<'PY'
import json, os, sys
path,*threads=sys.argv[1:]
json.dump({'schema':'codex-bridge-sessions/v1','entries':[
  {'chat_id':'111' if index == 1 else f'chat-{index}', 'thread_id':thread}
  for index,thread in enumerate(threads,1)
]},open(path,'w'))
os.chmod(path,0o600)
PY
}

TMUX_LOG="$TMP/tmux.log"; UP_LOG="$TMP/up.log"; CURL_LOG="$TMP/curl.log"; ROTATE_LOG="$TMP/rotate.log"
export TMUX_LOG UP_LOG CURL_LOG ROTATE_LOG
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in
  has-session)
    case "$*" in *'codex-view-'*) exit "${TMUX_VIEW_EXISTS_RC:-1}" ;; esac
    exit "${TMUX_HAS_SESSION_RC:-0}" ;;
  list-windows) [ -n "${TMUX_WINDOWS:-}" ] && printf '%s\n' "$TMUX_WINDOWS"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$STUB/swarm-up" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UP_LOG"
[ "${1:-}" = down ] && [ "${2:-}" = "${SWARM_UP_FAIL_DOWN_NAME:-}" ] && exit 8
[ "${1:-}" = up ] && [ "${SWARM_UP_FAIL_UP:-0}" = 1 ] && exit 7
exit 0
EOF
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/pins/'*) printf '204' ;;
  *'/messages'*)
    case "$*" in *'-o /dev/null'*) printf '201' ;; *) printf '{"id":"message-1"}' ;; esac ;;
esac
exit 0
EOF
cat > "$STUB/checkpoint" <<'EOF'
#!/usr/bin/env bash
printf 'checkpoint:%s\n' "$1" >> "$ROTATE_LOG"
EOF
cat > "$STUB/credswap" <<'EOF'
#!/usr/bin/env bash
printf 'credswap:%s\n' "$1" >> "$ROTATE_LOG"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/bun"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/node"
chmod +x "$STUB"/*
VIEWER_CODEX_HOME="$HOME/.qofi-codex-viewers/test"
mkdir -p "$VIEWER_CODEX_HOME"
chmod 700 "$HOME/.qofi-codex-viewers" "$VIEWER_CODEX_HOME"
mkdir -p "$SWARM/bin"
cat > "$SWARM/bin/codex-host-preflight.py" <<PY
import sys
if '--viewer-check' in sys.argv:
    if __import__('os').path.exists('$SWARM/no-native-viewer'):
        print('$STUB/bun||||$HOME||$STUB:/usr/bin:/bin')
    else:
        print('$STUB/bun|$STUB/node|$STUB/codex|0.144.1|$HOME|$VIEWER_CODEX_HOME|$STUB:/usr/bin:/bin')
else:
    canary = '' if __import__('os').path.exists('$SWARM/missing-canary') else 'fixture_operator_canary-1234567890'
    print('$STUB/codex|$STUB/bun|$HOME|$HOME/.codex|0.144.1|$STUB/codex|$STUB:/usr/bin:/bin|65001|_qofi_test|$HOME/runtime|$HOME/runtime/.codex|65002|_qofi_shared|/usr/local/libexec/qofi-codex-runner|qofi-codex-runtime/v2|' + canary)
PY

echo '=== shared host-preflight parser carries only a fresh dedicated witness ==='
. "$ROOT/bin/swarm-lib.sh"
SWARM_HOME="$SWARM"
if swarm_codex_host_preflight "$REPO_CODEX" >"$TMP/preflight.out" 2>&1; then rc=0; else rc=$?; fi
eq 0 "$rc" 'v2 preflight accepts the final attested canary field'
eq 'fixture_operator_canary-1234567890' "$SWARM_CODEX_OPERATOR_CANARY_VALUE" 'v2 preflight parses the final canary field'
eq 'fixture_operator_canary-1234567890' "$(/usr/bin/printenv SWARM_CODEX_OPERATOR_CANARY_VALUE)" 'v2 preflight exports the canary witness'
: > "$SWARM/missing-canary"
SWARM_CODEX_OPERATOR_CANARY_VALUE='stale_operator_canary-1234567890'
export SWARM_CODEX_OPERATOR_CANARY_VALUE
if swarm_codex_host_preflight "$REPO_CODEX" >"$TMP/preflight.out" 2>&1; then rc=0; else rc=$?; fi
eq 1 "$rc" 'v2 preflight refuses an omitted canary field'
eq '' "$SWARM_CODEX_OPERATOR_CANARY_VALUE" 'failed preflight clears a stale inherited witness'
rm -f "$SWARM/missing-canary"

echo '=== restart uses fresh Codex runtime and fails safe ==='
codex_conf
write_runtime codex 1 0
: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" codex 2>&1)"; rc=$?
eq 2 "$rc" 'active Codex restart is refused'
eq '' "$(cat "$UP_LOG")" 'active refusal never cycles the session'
has "$OUT" 'Codex swarm' 'restart reports engine-native activity'

write_runtime codex 0 0
: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'healthy idle Codex restart succeeds'
eq $'down codex\nup codex' "$(cat "$UP_LOG")" 'idle Codex restart cycles only its row'
has "$OUT" 'swarm-view.sh' 'Codex restart points to the supported operator view'
lacks "$OUT" 'dev-channels prompt' 'Codex restart omits Claude-only prompt guidance'

: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" SWARM_UP_FAIL_UP=1 PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" codex 2>&1)"; rc=$?
eq 7 "$rc" 'failed Codex relaunch status propagates from swarm-up'
has "$OUT" 'relaunch failed' 'failed Codex relaunch is reported honestly'
lacks "$OUT" 'Codex lead relaunched' 'failed relaunch prints no success handoff'

rm -f "$HOME/.codex/channels/discord-codex/runtime.json"
: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" codex 2>&1)"; rc=$?
eq 2 "$rc" 'missing live Codex runtime state refuses restart'
eq '' "$(cat "$UP_LOG")" 'missing runtime cannot authorize teardown'

: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" TMUX_HAS_SESSION_RC=1 SWARM_UP_BIN="$STUB/swarm-up" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'down Codex restart degenerates to up only'
eq 'up codex' "$(cat "$UP_LOG")" 'down session skips the failing/no-match down command'

echo '=== restart validates the target row before teardown ==='
printf 'badengine | %s | BOT_CLAUDE | 222 | 999 | | future\n' "$REPO_CLAUDE" > "$SWARM/swarm.conf"
: > "$UP_LOG"; : > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" badengine --force 2>&1)"; rc=$?
eq 2 "$rc" 'restart refuses an unknown engine before teardown even with --force'
eq '' "$(cat "$UP_LOG")" 'malformed restart target never reaches down or up'
eq '' "$(cat "$TMUX_LOG")" 'malformed restart target is rejected before session inspection'
has "$OUT" 'malformed' 'restart explains the malformed target refusal'

mixed_conf
: > "$UP_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-restart.sh" claude 2>&1)"; rc=$?
eq 0 "$rc" 'legacy five-field Claude restart remains supported'
eq $'down claude\nup claude' "$(cat "$UP_LOG")" 'legacy Claude restart retains its targeted cycle'
has "$OUT" 'dev-channels prompt' 'legacy Claude restart retains Claude operator guidance'
lacks "$OUT" 'Codex lead relaunched' 'legacy Claude restart never enters the Codex handoff'

echo '=== Claude account rotation leaves Codex rows untouched ==='
{
  printf 'claude | %s | BOT_CLAUDE | 222 | 999\n' "$REPO_CLAUDE"
  printf 'badengine | %s | BOT_CODEX | 111 | 999 | | future\n' "$REPO_CODEX"
} > "$SWARM/swarm.conf"
: > "$UP_LOG"; : > "$ROTATE_LOG"; : > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" \
  SWARM_ACCOUNTS='max-a max-b' SWARM_ACTIVE_ACCOUNT=max-a \
  SWARM_CHECKPOINT_CMD="$STUB/checkpoint \"\$1\"" \
  SWARM_CREDSWAP_CMD="$STUB/credswap \"\$1\"" \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-rotate.sh" 2>&1)"; rc=$?
eq 2 "$rc" 'rotation refuses an unknown engine before changing fleet state'
eq '' "$(cat "$UP_LOG")" 'malformed rotation config never tears down or relaunches a session'
eq '' "$(cat "$ROTATE_LOG")" 'malformed rotation config never checkpoints or swaps credentials'
eq '' "$(cat "$TMUX_LOG")" 'malformed rotation config is rejected before session inspection'
has "$OUT" 'malformed swarm.conf row' 'rotation explains the fail-closed config refusal'

mixed_conf
write_runtime codex 1 3
: > "$UP_LOG"; : > "$ROTATE_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" \
  SWARM_ACCOUNTS='max-a max-b' SWARM_ACTIVE_ACCOUNT=max-a \
  SWARM_CHECKPOINT_CMD="$STUB/checkpoint \"\$1\"" \
  SWARM_CREDSWAP_CMD="$STUB/credswap \"\$1\"" \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-rotate.sh" 2>&1)"; rc=$?
eq 0 "$rc" 'rotation succeeds while a Codex row is active'
eq $'down claude\nup claude' "$(cat "$UP_LOG")" 'default relaunch cycles Claude rows only'
has "$(cat "$ROTATE_LOG")" "checkpoint:$REPO_CLAUDE" 'checkpoint covers the Claude repo'
lacks "$(cat "$ROTATE_LOG")" "$REPO_CODEX" 'checkpoint excludes the Codex repo'
has "$OUT" "leaving Codex swarm 'codex' untouched" 'rotation says the Codex runtime is untouched'

: > "$UP_LOG"; : > "$ROTATE_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_UP_BIN="$STUB/swarm-up" \
  SWARM_UP_FAIL_DOWN_NAME=claude SWARM_ACCOUNTS='max-a max-b' SWARM_ACTIVE_ACCOUNT=max-a \
  SWARM_CHECKPOINT_CMD="$STUB/checkpoint \"\$1\"" SWARM_CREDSWAP_CMD="$STUB/credswap \"\$1\"" \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-rotate.sh" 2>&1)"; rc=$?
eq 1 "$rc" 'rotation fails when any Claude shutdown fails'
eq 'down claude' "$(cat "$UP_LOG")" 'failed Claude shutdown aborts the entire up pass'
has "$OUT" 'old auth may still be live' 'shutdown failure explains why relaunch is unsafe'

echo '=== watch and typing consume runtime.json instead of Claude signals ==='
codex_conf
write_runtime codex 1 2
WATCH_STATE="$TMP/watch-state"
: > "$CURL_LOG"
HOME="$HOME" SWARM_HOME="$SWARM" SWARM_STATE_DIR="$WATCH_STATE" SWARM_TMUX_BIN="$STUB/tmux" \
  SWARM_ENABLE_TYPING=1 PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-watch.sh" >/dev/null 2>&1
watch_state="$(python3 - "$WATCH_STATE/status.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['swarms'][0]['state'])
PY
)"
eq working "$watch_state" 'watcher emits working from active Codex runtime'
has "$(cat "$CURL_LOG")" '/channels/111/typing' 'watcher typing follows Codex active state'

: > "$CURL_LOG"
HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_TYPING_ONCE=1 \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-typing.sh" >/dev/null 2>&1
has "$(cat "$CURL_LOG")" '/channels/111/typing' 'typing daemon fires for active Codex runtime'

write_runtime codex 0 0
: > "$CURL_LOG"
HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_TYPING_ONCE=1 \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-typing.sh" >/dev/null 2>&1
lacks "$(cat "$CURL_LOG")" '/typing' 'typing daemon stays silent for idle Codex runtime'

echo '=== swarm-view uses the native filtered remote only for one safe thread ==='
SOCKET="$(make_socket codex)"
write_runtime codex 0 0 "unix://$SOCKET"
THREAD='019f54ac-6079-7312-95a6-35fe8912a3f1'
OTHER_THREAD='019f54ac-6079-7312-a5a6-35fe8912a3f2'
write_sessions codex "$THREAD"
: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" CODEX_BIN="$TMP/ambient-codex" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'healthy local filtering facade opens the native viewer'
has "$OUT" 'NATIVE CODEX TUI v0.144.1' 'native view is identified with the attested version'
has "$OUT" 'read-only facade; scrollable responsive tmux client' 'native view explains its navigation and authority boundary'
has "$(cat "$TMUX_LOG")" 'new-session -d -s codex-view-codex -n qofi-bootstrap' 'native viewer uses a session separate from the daemon'
has "$(cat "$TMUX_LOG")" 'set-option -t codex-view-codex history-limit 100000' 'native viewer preserves deep inline scrollback'
has "$(cat "$TMUX_LOG")" 'set-window-option -t codex-view-codex:codex-native window-size latest' 'native viewer follows the latest client dimensions'
has "$(cat "$TMUX_LOG")" 'set-window-option -t codex-view-codex:codex-native aggressive-resize on' 'native viewer resizes with its active client'
has "$(cat "$TMUX_LOG")" "'$STUB/node' '$STUB/codex' resume --remote" 'native viewer uses the preflight-pinned Node and Codex script'
has "$(cat "$TMUX_LOG")" '--no-alt-screen' 'native Codex runs inline so tmux can retain its transcript'
has "$(cat "$TMUX_LOG")" "-C '$REPO_CODEX' '$THREAD'" 'native resume is bound to the configured repo and sole thread'
has "$(cat "$TMUX_LOG")" "CODEX_HOME='$VIEWER_CODEX_HOME'" 'native TUI uses its isolated auth-free CODEX_HOME'
has "$(cat "$TMUX_LOG")" 'attach-session -t codex-view-codex:codex-native' 'native tmux client permits navigation and copy mode'
lacks "$(cat "$TMUX_LOG")" 'attach-session -r -t codex-view-codex:codex-native' 'native navigation is not blocked by tmux read-only mode'
lacks "$(cat "$TMUX_LOG")" "$TMP/ambient-codex" 'ambient CODEX_BIN cannot select the native executable'
lacks "$(cat "$TMUX_LOG")" 'view.ts' 'eligible native view does not start the fallback reader'

: > "$SWARM/no-native-viewer"
: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'missing native attestation retains the Bun event viewer'
has "$OUT" 'FALLBACK EVENT/STATUS VIEW' 'Bun-only viewer contract is truthfully labeled as fallback'
lacks "$(cat "$TMUX_LOG")" '--remote' 'Bun-only contract never attempts a native remote'
has "$(cat "$TMUX_LOG")" 'view.ts' 'Bun-only contract launches the persisted event reader'
rm -f "$SWARM/no-native-viewer"

write_sessions codex "$THREAD" "$OTHER_THREAD"
: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'multiple channel threads select the configured operator channel'
has "$OUT" 'NATIVE CODEX TUI v0.144.1' 'extra bus/channel sessions do not hide the configured native view'
has "$(cat "$TMUX_LOG")" "-C '$REPO_CODEX' '$THREAD'" 'configured channel selects its exact persisted thread'
lacks "$(cat "$TMUX_LOG")" "'$OTHER_THREAD'" 'another channel thread is never selected accidentally'

# Without one exact mapping for the configured channel, multiple valid threads
# remain ambiguous and must not reach the native remote.
/usr/bin/python3 - "$HOME/.codex/channels/discord-codex/sessions.json" <<PY
import json,os,sys
json.dump({'schema':'codex-bridge-sessions/v1','entries':[
  {'chat_id':'chat-a','thread_id':'$THREAD'},
  {'chat_id':'chat-b','thread_id':'$OTHER_THREAD'},
]},open(sys.argv[1],'w'))
os.chmod(sys.argv[1],0o600)
PY
: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'missing configured-channel mapping degrades safely to persisted view'
has "$OUT" 'FALLBACK EVENT/STATUS VIEW' 'ambiguous configured-channel state is truthfully labeled as fallback'
has "$OUT" 'configured Discord channel has no persisted Codex thread' 'fallback explains how to unlock the native view'
lacks "$(cat "$TMUX_LOG")" '--remote' 'ambiguous sessions never reach codex remote'
has "$(cat "$TMUX_LOG")" 'attach-session -r -t codex-view-codex:codex-events' 'ambiguous-session fallback attaches read-only'

write_sessions codex "$THREAD"

: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" TMUX_VIEW_EXISTS_RC=0 \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'preseeded viewer namespace is replaced, not trusted'
has "$(cat "$TMUX_LOG")" 'kill-session -t codex-view-codex' 'preseeded/wrong viewer generation is destroyed'
has "$(cat "$TMUX_LOG")" 'new-window -d -t codex-view-codex: -n codex-native' 'viewer is recreated from the exact pinned native command'
has "$(cat "$TMUX_LOG")" 'kill-window -t codex-view-codex:qofi-bootstrap' 'temporary bootstrap window is removed after exact viewer creation'

: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" TMUX=/tmp/test-client \
  PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'in-tmux viewer switch succeeds'
has "$(cat "$TMUX_LOG")" 'switch-client -t codex-view-codex:codex-native' 'in-tmux native viewer keeps navigation and responsive resize enabled'
lacks "$(cat "$TMUX_LOG")" 'switch-client -r -t codex-view-codex:codex-native' 'in-tmux native viewer does not re-enable tmux read-only mode'

# A remote endpoint is malformed at the shared runtime boundary and can never
# reach `codex --remote`; view degrades to the bounded event/status surface.
python3 - "$HOME/.codex/channels/discord-codex/runtime.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['app_server_endpoint']='ws://example.com:4567'; json.dump(d,open(p,'w'))
PY
: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" CODEX_BIN="$STUB/codex" PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'nonlocal endpoint degrades safely to fallback'
has "$OUT" 'FALLBACK EVENT/STATUS VIEW' 'fallback view is labeled as non-native'
lacks "$(cat "$TMUX_LOG")" '--remote' 'nonlocal endpoint is never forwarded to codex --remote'
has "$(cat "$TMUX_LOG")" 'view.ts' 'fallback runs the bounded bridge viewer'
has "$(cat "$TMUX_LOG")" 'attach-session -r' 'fallback tmux client is read-only'
lacks "$(cat "$TMUX_LOG")" 'new-window -d -t swarm-codex:' 'viewer never adds a window that can keep the daemon session alive'

: > "$TMUX_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" TMUX_HAS_SESSION_RC=1 PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-view.sh" codex 2>&1)"; rc=$?
eq 0 "$rc" 'persisted fallback remains available while the primary daemon session is down'
has "$OUT" 'FALLBACK EVENT/STATUS VIEW' 'offline diagnostics remain truthfully labeled'
has "$(cat "$TMUX_LOG")" 'view.ts' 'offline diagnostics still launch the bounded event reader'

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
