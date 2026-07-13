#!/usr/bin/env bash
# Supported operator view for a Codex-engine swarm. A healthy manager-owned,
# per-swarm filtering facade opens the native Codex TUI through a navigation-
# enabled tmux client. The facade remains the read-only authority boundary.
# Every incomplete or ambiguous contract falls back to the
# bounded/redacted persisted event/status window.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-view: SWARM_HOME unset or wrong" >&2
  exit 1
fi

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: swarm-view.sh <name>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"
CONF="$SWARM_HOME/swarm.conf"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"

FOUND=0
ENGINE=""
REPO=""
CHANNEL=""
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$NAME" ]; then
    FOUND=1
    ENGINE="$SWARM_CONF_F_ENGINE"
    REPO="$SWARM_CONF_F_REPO"
    CHANNEL="$SWARM_CONF_F_CHANNEL"
    break
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

[ "$FOUND" -eq 1 ] || { echo "swarm-view: no configured swarm '$NAME'" >&2; exit 1; }
if [ "$ENGINE" != "codex" ]; then
  echo "swarm-view: '$NAME' uses engine=$ENGINE; use bin/swarm-attach.sh $NAME for the native Claude TUI" >&2
  exit 2
fi
command -v "$TMUX_BIN" >/dev/null 2>&1 || { echo "swarm-view: tmux not found" >&2; exit 1; }
VIEW_PLAN="$(/usr/bin/env -i HOME="${HOME:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
  /usr/bin/python3 -I -B "$SWARM_HOME/bin/codex-host-preflight.py" --viewer-check "$REPO" "$SWARM_HOME" 2>&1)" || {
  echo "swarm-view: trusted offline viewer preflight failed: $VIEW_PLAN" >&2
  exit 1
}
IFS='|' read -r \
  VIEW_BUN VIEW_NODE VIEW_CODEX_SCRIPT VIEW_CODEX_VERSION \
  VIEW_HOME VIEW_CODEX_HOME VIEW_PATH <<EOF
$VIEW_PLAN
EOF
[ -n "$VIEW_BUN" ] && [ -n "$VIEW_HOME" ] && [ -n "$VIEW_PATH" ] || {
  echo "swarm-view: offline viewer preflight returned an incomplete contract" >&2
  exit 1
}
NATIVE_TOOLS_OK=0
if [ -n "$VIEW_NODE" ] && [ -n "$VIEW_CODEX_SCRIPT" ] && \
   [ -n "$VIEW_CODEX_VERSION" ] && [ -n "$VIEW_CODEX_HOME" ]; then
  NATIVE_TOOLS_OK=1
fi
# Viewer windows live in a separate, non-`swarm-*` tmux session. A viewer must
# never keep the daemon's primary session alive after its daemon pane exits,
# because swarm-up/watch use that session's disappearance as a relaunch signal.
VIEW_SESS="codex-view-${NAME}"

STATE_DIR="$(swarm_codex_state_dir "$NAME")"
RUNTIME_OK=0
swarm_codex_runtime_read "$NAME" && RUNTIME_OK=1

attach_target() {  # target read_only(0|1)
  local target="$1" ro="$2"
  if [ -n "${TMUX:-}" ]; then
    if [ "$ro" -eq 1 ]; then exec "$TMUX_BIN" switch-client -r -t "$target"
    else exec "$TMUX_BIN" switch-client -t "$target"; fi
  else
    if [ "$ro" -eq 1 ]; then exec "$TMUX_BIN" attach-session -r -t "$target"
    else exec "$TMUX_BIN" attach-session -t "$target"; fi
  fi
}

replace_view_session() {  # window command
  local window="$1" command="$2"
  local bootstrap="qofi-bootstrap"
  # Never reuse a pane merely because its name matches. A stale/dead/preseeded
  # window could otherwise be presented as the supported redacted reader.
  # The `codex-view-*` namespace is owned by this command; replace the whole
  # one-window observer generation and refuse if either operation races.
  if "$TMUX_BIN" has-session -t "$VIEW_SESS" 2>/dev/null; then
    "$TMUX_BIN" kill-session -t "$VIEW_SESS" 2>/dev/null || return 1
  fi
  # Create the real pane only after the session-scoped history limit is set;
  # tmux fixes history capacity at pane creation time. Inline Codex output can
  # then be browsed with mouse wheel or normal tmux copy mode.
  "$TMUX_BIN" new-session -d -s "$VIEW_SESS" -n "$bootstrap" -c "$REPO" "/bin/sleep 60" || return 1
  if ! "$TMUX_BIN" set-option -t "$VIEW_SESS" history-limit 100000 || \
     ! "$TMUX_BIN" set-option -t "$VIEW_SESS" mouse on || \
     ! "$TMUX_BIN" set-option -t "$VIEW_SESS" status off || \
     ! "$TMUX_BIN" new-window -d -t "$VIEW_SESS:" -n "$window" -c "$REPO" "$command" || \
     ! "$TMUX_BIN" set-window-option -t "$VIEW_SESS:$window" window-size latest || \
     ! "$TMUX_BIN" set-window-option -t "$VIEW_SESS:$window" aggressive-resize on || \
     ! "$TMUX_BIN" select-window -t "$VIEW_SESS:$window" || \
     ! "$TMUX_BIN" kill-window -t "$VIEW_SESS:$bootstrap"; then
    "$TMUX_BIN" kill-session -t "$VIEW_SESS" 2>/dev/null || true
    return 1
  fi
}

viewer_session_thread() {  # sessions.json configured-channel rotation-state.json
  /usr/bin/python3 -I -B - "$1" "$2" "$3" <<'PY'
import json, os, re, stat, sys

path,expected_chat,rotation_path=sys.argv[1:]
limit=128*1024
identifier=re.compile(r'^[A-Za-z0-9_-]{1,128}$')
thread_id=re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
)

def identity(value):
    return (value.st_dev,value.st_ino,value.st_uid,value.st_gid,
            stat.S_IMODE(value.st_mode),value.st_nlink,value.st_size,
            value.st_mtime_ns,value.st_ctime_ns)

try:
    if not identifier.fullmatch(expected_chat): raise ValueError('unsafe configured chat')
    active_profile='default'
    if os.path.exists(rotation_path):
        rotation_info=os.lstat(rotation_path)
        if (not stat.S_ISREG(rotation_info.st_mode) or stat.S_ISLNK(rotation_info.st_mode)
                or rotation_info.st_uid != os.getuid()
                or stat.S_IMODE(rotation_info.st_mode) != 0o600
                or rotation_info.st_nlink != 1 or rotation_info.st_size > 1024*1024):
            raise ValueError('unsafe rotation state')
        rotation=json.loads(open(rotation_path,encoding='utf-8').read())
        if (not isinstance(rotation,dict)
                or rotation.get('schema') != 'qofi-codex-profile-rotation/v1'
                or not isinstance(rotation.get('active_profile'),str)
                or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',rotation['active_profile'])):
            raise ValueError('invalid active profile')
        active_profile=rotation['active_profile']
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1 or not 2 <= before.st_size <= limit):
        raise ValueError('unsafe sessions file')
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        opened=os.fstat(fd)
        if identity(opened) != identity(before): raise ValueError('sessions file changed')
        chunks=[]; total=0
        while True:
            chunk=os.read(fd,8192)
            if not chunk: break
            total += len(chunk)
            if total > limit: raise ValueError('sessions file too large')
            chunks.append(chunk)
        after=os.fstat(fd)
        if identity(after) != identity(opened): raise ValueError('sessions file changed')
    finally:
        os.close(fd)
    if identity(os.lstat(path)) != identity(after): raise ValueError('sessions file replaced')
    value=json.loads(b''.join(chunks).decode('utf-8','strict'))
    if not isinstance(value,dict): raise ValueError('invalid sessions shape')
    schema=value.get('schema')
    if schema == 'codex-bridge-sessions/v2':
        entries=value.get('entries')
        if not isinstance(entries,list): raise ValueError('invalid sessions entries')
    elif schema == 'codex-bridge-sessions/v1':
        entries=value.get('entries')
        if not isinstance(entries,list): raise ValueError('invalid sessions entries')
        entries=[dict(entry,profile_id='default') if isinstance(entry,dict) else entry for entry in entries]
    elif 'schema' not in value:
        entries=[{'chat_id':key,'profile_id':'default','thread_id':item} for key,item in value.items()]
    else:
        raise ValueError('unsupported sessions schema')
    if not 1 <= len(entries) <= 256: raise ValueError('ambiguous sessions')
    chats=set(); selected=[]
    for entry in entries:
        if not isinstance(entry,dict): raise ValueError('invalid session entry')
        chat=entry.get('chat_id'); profile=entry.get('profile_id'); thread=entry.get('thread_id')
        if (not isinstance(chat,str) or not identifier.fullmatch(chat)
                or not isinstance(profile,str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',profile)
                or not isinstance(thread,str) or not thread_id.fullmatch(thread)
                or (chat,profile) in chats):
            raise ValueError('unsafe session identity')
        chats.add((chat,profile))
        if chat == expected_chat and profile == active_profile: selected.append(thread)
    if len(selected) != 1: raise ValueError('configured channel has no unique session thread')
    print(selected[0])
except Exception:
    raise SystemExit(1)
PY
}

VIEW_THREAD=""
NATIVE_REASON=""
if [ "$NATIVE_TOOLS_OK" -ne 1 ]; then
  NATIVE_REASON="pinned native Codex client is unavailable"
elif [ "$RUNTIME_OK" -ne 1 ] || [ "$SWARM_CODEX_RUNTIME_STATUS" != "healthy" ]; then
  NATIVE_REASON="Codex daemon runtime is not healthy"
elif [ "$SWARM_CODEX_RUNTIME_READY" != "1" ]; then
  NATIVE_REASON="Codex daemon is not ready"
elif [ -z "$SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT" ] || \
     ! swarm_codex_endpoint_is_safe "$NAME" "$SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT"; then
  NATIVE_REASON="per-swarm read-only App Server facade is unavailable"
else
  VIEW_THREAD="$(viewer_session_thread "$STATE_DIR/sessions.json" "$CHANNEL" "$STATE_DIR/rotation-state.json" 2>/dev/null)" || VIEW_THREAD=""
  [ -n "$VIEW_THREAD" ] || \
    NATIVE_REASON="configured Discord channel has no persisted Codex thread; complete one turn, then reopen the view"
fi

if [ -n "$VIEW_THREAD" ] && \
   swarm_codex_endpoint_is_safe "$NAME" "$SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT"; then
  q_node="$(shell_quote "$VIEW_NODE")"
  q_codex="$(shell_quote "$VIEW_CODEX_SCRIPT")"
  q_home="$(shell_quote "$VIEW_HOME")"
  q_codex_home="$(shell_quote "$VIEW_CODEX_HOME")"
  q_path="$(shell_quote "$VIEW_PATH")"
  q_endpoint="$(shell_quote "$SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT")"
  q_repo="$(shell_quote "$REPO")"
  q_thread="$(shell_quote "$VIEW_THREAD")"
  native_command="exec /usr/bin/env -i HOME=$q_home CODEX_HOME=$q_codex_home PATH=$q_path TERM=xterm-256color COLORTERM=truecolor LANG=C LC_ALL=C $q_node $q_codex resume --remote $q_endpoint --no-alt-screen -C $q_repo $q_thread"
  if replace_view_session "codex-native" "$native_command"; then
    echo "swarm-view: NATIVE CODEX TUI v$VIEW_CODEX_VERSION — read-only facade; scrollable responsive tmux client" >&2
    attach_target "$VIEW_SESS:codex-native" 0
  fi
  echo "swarm-view: native viewer launch failed; using persisted fallback" >&2
  NATIVE_REASON="native viewer process failed to launch"
fi

WIN="codex-events"
q_viewer="$(shell_quote "$SWARM_HOME/codex-bridge/view.ts")"
q_state="$(shell_quote "$STATE_DIR")"
q_bun="$(shell_quote "$VIEW_BUN")"
q_home="$(shell_quote "$VIEW_HOME")"
q_path="$(shell_quote "$VIEW_PATH")"
q_cwd="$(shell_quote "$SWARM_HOME/codex-bridge")"
replace_view_session "$WIN" "exec /usr/bin/env -i HOME=$q_home PATH=$q_path LANG=C LC_ALL=C $q_bun --no-env-file --config=/dev/null --no-install --no-addons --no-macros --cwd=$q_cwd $q_viewer $q_state" || exit 1
echo "swarm-view: FALLBACK EVENT/STATUS VIEW — not a native Codex TUI" >&2
[ -z "$NATIVE_REASON" ] || echo "swarm-view: native_unavailable=$NATIVE_REASON" >&2
echo "swarm-view: runtime=$SWARM_CODEX_RUNTIME_STATUS ready=$SWARM_CODEX_RUNTIME_READY active=$SWARM_CODEX_RUNTIME_ACTIVE queued=$SWARM_CODEX_RUNTIME_QUEUE_DEPTH child=${SWARM_CODEX_RUNTIME_CHILD_PID:-none}" >&2
[ -n "$SWARM_CODEX_RUNTIME_LAST_ERROR" ] && echo "swarm-view: last_error=$SWARM_CODEX_RUNTIME_LAST_ERROR" >&2
attach_target "$VIEW_SESS:$WIN" 1
