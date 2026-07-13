#!/usr/bin/env bash
# swarm-remove.sh — unregister a swarm (stop session, remove from swarm.conf,
# optionally clean up access.json group and heartbeat state).
#
# Usage: swarm-remove.sh <name>
#
# Does NOT remove tokens.env entries (a token may be reused) -- prints which
# BOT_<NAME> var is now orphaned so the operator can remove it by hand.
# Does NOT touch the repo's files or git.

set -euo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-remove: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_RUNTIME_BIN="${SWARM_CODEX_RUNTIME_BIN:-$SCRIPT_DIR/swarm-codex-runtime.sh}"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

cleanup_swarm_remove() {
  while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
}
trap cleanup_swarm_remove EXIT

CONF="$SWARM_HOME/swarm.conf"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
# ACCESS (which account's access.json holds this channel's group) is resolved
# from the removed swarm's account — swarm.conf field 6, parsed below from the
# matched row — never a hand-built $HOME/.claude path. An empty account (every
# row today) resolves byte-for-byte to today's path.
PREFIX="swarm"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
[ -n "$TMUX_BIN" ] && command -v "$TMUX_BIN" >/dev/null 2>&1 || {
  echo "swarm-remove: REFUSED — tmux is unavailable; session quiescence cannot be proven: $TMUX_BIN" >&2
  exit 1
}

usage() { echo "usage: swarm-remove.sh <name>" >&2; exit 1; }
NAME="${1:-}"
[ -z "$NAME" ] && usage
case "$NAME" in *[!A-Za-z0-9_-]*|'') echo "swarm-remove: invalid swarm name '$NAME'" >&2; exit 1 ;; esac
[ -f "$CONF" ] || { echo "swarm-remove: $CONF not found" >&2; exit 1; }

# Own the registration lifecycle before reading the target row or touching a
# tmux session. A contended remove must be side-effect free: killing a live
# Claude/Codex session and only later discovering a config writer leaves a
# stopped but still-registered swarm. swarm-up and swarm-add use this same
# boundary, so no launch/adoption can cross removal either.
if ! swarm_conf_lock_acquire "$CONF"; then
  echo "swarm-remove: REFUSED — swarm.conf lifecycle mutation is in progress; no session was stopped and the row remains registered." >&2
  exit 1
fi

# Resolve the row through the canonical full-arity parser.
REPO=""; TOK_VAR=""; CHANNEL=""; ACCOUNT=""; ENGINE=""; ROW_RAW=""; FOUND=0
while IFS= read -r _line || [ -n "$_line" ]; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$NAME" ]; then
    FOUND=$((FOUND + 1))
    if [ "$FOUND" -eq 1 ]; then
      REPO="$SWARM_CONF_F_REPO"
      TOK_VAR="$SWARM_CONF_F_TOKVAR"
      CHANNEL="$SWARM_CONF_F_CHANNEL"
      ACCOUNT="$SWARM_CONF_F_ACCOUNT"
      ENGINE="$SWARM_CONF_F_ENGINE"
      ROW_RAW="$_line"
    fi
  fi
done < "$CONF"
[ "$FOUND" -gt 0 ] || { echo "swarm-remove: no swarm named '$NAME' in $CONF" >&2; exit 1; }
[ "$FOUND" -eq 1 ] || {
  echo "swarm-remove: REFUSED — swarm.conf has $FOUND rows named '$NAME'; no session was stopped." >&2
  exit 1
}

CODEX_RUNTIME_REPO=""
if [ "$ENGINE" = "codex" ]; then
  if [ -d "$REPO" ]; then
    CODEX_RUNTIME_REPO="$(cd "$REPO" && pwd -P)" || {
      echo "swarm-remove: could not canonicalize Codex repo: $REPO" >&2; exit 1; }
    if [ "$CODEX_RUNTIME_REPO" != "$REPO" ]; then
      echo "swarm-remove: REFUSED — Codex repo rows must contain their canonical physical path before authority can be released: $REPO -> $CODEX_RUNTIME_REPO" >&2
      echo "swarm-remove: repair the row to the originally prepared canonical path, then retry; an alias may have been retargeted." >&2
      exit 1
    fi
  elif [ -L "$REPO" ]; then
    echo "swarm-remove: REFUSED — unsafe unresolved Codex repo symlink: $REPO" >&2
    exit 1
  else
    CODEX_RUNTIME_REPO="$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os,sys
path=sys.argv[1]
if not os.path.isabs(path) or any(ord(ch)<32 or ord(ch)==127 for ch in path): raise SystemExit(2)
print(os.path.normpath(path))
PY
)" || { echo "swarm-remove: unsafe Codex repo path in configured row" >&2; exit 1; }
  fi
fi

swarm_codex_repo_ref_count() {  # repo [excluded-name]
  local _repo="$1" _exclude="${2:-}" _line _trimmed _configured_repo _configured_repo_canon
  SWARM_CODEX_REPO_REF_COUNT=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_line"; then return 2; fi
    if [ "$SWARM_CONF_F_ENGINE" != "codex" ] || [ "$SWARM_CONF_F_NAME" = "$_exclude" ]; then
      continue
    fi
    _configured_repo="$SWARM_CONF_F_REPO"
    if [ -d "$_configured_repo" ]; then
      _configured_repo_canon="$(cd "$_configured_repo" && pwd -P)" || return 2
      [ "$_configured_repo_canon" = "$_configured_repo" ] || return 2
      _configured_repo="$_configured_repo_canon"
    elif [ -L "$_configured_repo" ]; then
      return 2
    else
      _configured_repo="$(/usr/bin/python3 -I -B - "$_configured_repo" <<'PY'
import os,sys
path=sys.argv[1]
if not os.path.isabs(path) or any(ord(ch)<32 or ord(ch)==127 for ch in path): raise SystemExit(2)
print(os.path.normpath(path))
PY
)" || return 2
    fi
    if [ "$_configured_repo" = "$_repo" ]; then
      SWARM_CODEX_REPO_REF_COUNT=$((SWARM_CODEX_REPO_REF_COUNT + 1))
    fi
  done < "$CONF"
  return 0
}

# Resolve the removed swarm's account → its access.json. The resolver is the
# SOLE constructor of the path: empty account → today's $HOME/.claude/... ,
# a label → that account's isolated dir.
ACCESS_ACCOUNT="$ACCOUNT"
[ "$ENGINE" = "codex" ] && ACCESS_ACCOUNT=""
swarm_account_resolve "$ACCESS_ACCOUNT" || {
  echo "swarm-remove: invalid account '$ACCOUNT' in swarm.conf row for '$NAME'" >&2
  exit 1
}
ACCESS="$SWARM_ACCT_ACCESS_FILE"

_conf_digest="$(/usr/bin/python3 -I -B - "$CONF" <<'PY'
import hashlib, os, stat, sys
path=sys.argv[1]
st=os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise SystemExit(2)
with open(path,'rb') as f: print(hashlib.sha256(f.read()).hexdigest())
PY
)" || {
  echo "swarm-remove: REFUSED — could not safely fingerprint swarm.conf; no session was stopped and the row remains registered." >&2
  exit 1
}

cat <<EOF
About to remove swarm '$NAME':
  repo:    $REPO
  channel: $CHANNEL
  engine:  $ENGINE
  bot var: \$$TOK_VAR  (will be left in tokens.env)
EOF

# 1) Kill ONLY this swarm's tmux session.
#    (swarm-up.sh down kills ALL swarm sessions -- too broad for a single remove.)
SESS="${PREFIX}-${NAME}"
if "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
  "$TMUX_BIN" kill-session -t "$SESS"
  echo "swarm-remove: killed tmux session $SESS"
else
  echo "swarm-remove: tmux session $SESS not running"
fi
if [ "$ENGINE" = "codex" ]; then
  VIEW_SESS="codex-view-${NAME}"
  if "$TMUX_BIN" has-session -t "$VIEW_SESS" 2>/dev/null; then
    "$TMUX_BIN" kill-session -t "$VIEW_SESS"
    echo "swarm-remove: killed Codex viewer session $VIEW_SESS"
  fi

  # Do not unregister while a daemon/child recorded in runtime or daemon.lock
  # remains alive. Killing the tmux session is asynchronous; wait briefly, then
  # refuse with the conf row intact if shutdown did not complete.
  CODEX_STATE="$(swarm_codex_state_dir "$NAME")"
  if swarm_codex_state_validate "$NAME" read; then
    CODEX_STATE="$SWARM_CODEX_STATE_DIR"
  else
    _state_rc=$?
    if [ "$_state_rc" -ne 1 ]; then
      echo "swarm-remove: REFUSED — Codex state boundary is unsafe; swarm.conf remains unchanged." >&2
      exit 1
    fi
  fi
  _waited=0; _timeout="${SWARM_REMOVE_CODEX_TIMEOUT:-15}"
  case "$_timeout" in ''|*[!0-9]*) _timeout=15 ;; esac
  while :; do
    _boundary="$(/usr/bin/python3 -I -B - "$CODEX_STATE/runtime.json" "$CODEX_STATE/daemon.lock" <<'PY'
import datetime as dt, json, os, sys
runtime, lock = sys.argv[1:3]
issues=[]; pids=[]

def timestamp(value):
    if not isinstance(value,str) or not value: return False
    try: dt.datetime.fromisoformat(value.replace('Z','+00:00')); return True
    except Exception: return False

if os.path.exists(runtime):
    try:
        d=json.load(open(runtime))
        if not isinstance(d,dict) or d.get('schema') != 'codex-bridge-runtime/v1': raise ValueError()
        if type(d.get('pid')) is not int or d['pid'] <= 0: raise ValueError()
        if not timestamp(d.get('started_at')) or not timestamp(d.get('updated_at')): raise ValueError()
        if type(d.get('ready')) is not bool or type(d.get('active')) is not bool: raise ValueError()
        if type(d.get('queue_depth')) is not int or d['queue_depth'] < 0: raise ValueError()
        child=d.get('child_pid')
        if child is not None and (type(child) is not int or child <= 0): raise ValueError()
        if d.get('backend') not in ('exec','app-server'): raise ValueError()
        pids.extend([d['pid']] + ([child] if child is not None else []))
    except Exception: issues.append('runtime-unreadable')

if os.path.exists(lock):
    owner=os.path.join(lock,'owner.json')
    try:
        d=json.load(open(owner)); pid=d.get('pid') if isinstance(d,dict) else None
        if d.get('schema') != 'codex-bridge-lock/v1' or type(pid) is not int or pid <= 0: raise ValueError()
        pids.append(pid)
    except Exception: issues.append('lock-owner-unreadable')

live=[]
for pid in dict.fromkeys(pids):
    try: os.kill(pid,0)
    except PermissionError: live.append(pid)
    except OSError: pass
    else: live.append(pid)
if issues: print('unsafe|' + ','.join(issues))
elif live: print('live|' + ','.join(map(str,live)))
else: print('ok|')
PY
)"
    case "$_boundary" in
      unsafe\|*)
        echo "swarm-remove: REFUSED — Codex process boundary is ${_boundary#unsafe|}; swarm.conf remains unchanged." >&2
        echo "swarm-remove: repair or remove the malformed state only after independently proving the daemon is stopped." >&2
        exit 1
        ;;
      live\|*) _live="${_boundary#live|}" ;;
      ok\|) _live="" ;;
      *)
        echo "swarm-remove: REFUSED — Codex process boundary could not be classified; swarm.conf remains unchanged." >&2
        exit 1
        ;;
    esac
    [ -z "$_live" ] && break
    if [ "$_waited" -ge "$_timeout" ]; then
      echo "swarm-remove: REFUSED — Codex daemon/child still alive after ${_timeout}s: $_live" >&2
      echo "swarm-remove: swarm.conf is unchanged; stop those PIDs and retry." >&2
      exit 1
    fi
    sleep 1
    _waited=$((_waited + 1))
  done
fi

# A dead daemon PID is not proof that its physical-repository transaction
# completed.  Refuse to release workspace authority or remove the owning row
# while the exact inode lease (or an interrupted exact-release tombstone) is
# still present.  This preserves a config-independent route through
# swarm-recover.sh instead of manufacturing an orphaned coordination signal.
if [ "$ENGINE" = "codex" ]; then
  if _repo_lease_guard="$(/usr/bin/python3 -I -B - "$HOME" "$CODEX_RUNTIME_REPO" <<'PY'
import json,os,re,stat,sys
home,repo=sys.argv[1:3]
root=os.path.join(home,".codex","channels","repo-locks")
if not os.path.lexists(root): raise SystemExit(0)
info=os.lstat(root)
if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
        or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700):
    print("unsafe shared repo-lease root")
    raise SystemExit(3)
target=None
try:
    current=os.lstat(repo)
    if stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode):
        target=(current.st_dev,current.st_ino)
except FileNotFoundError:
    pass
base=f"{target[0]}-{target[1]}.lock" if target else None
canonical=re.compile(r"[0-9]+-[0-9]+\.lock\Z")
release=re.compile(r"\.([0-9]+-[0-9]+\.lock)\.release\.[0-9a-f]{24}\Z")
released=re.compile(r"\.([0-9]+-[0-9]+\.lock)\.released\.[0-9a-f]{24}\Z")

def owner_repo(path):
    try:
        lock=os.lstat(path)
        owner_path=os.path.join(path,"owner.json")
        owner=os.lstat(owner_path)
        if (not stat.S_ISDIR(lock.st_mode) or stat.S_ISLNK(lock.st_mode)
                or lock.st_uid!=os.getuid() or stat.S_IMODE(lock.st_mode)!=0o700
                or not stat.S_ISREG(owner.st_mode) or stat.S_ISLNK(owner.st_mode)
                or owner.st_uid!=os.getuid() or stat.S_IMODE(owner.st_mode)!=0o600
                or owner.st_size>65536):
            return None
        with open(owner_path,"rb") as stream: raw=stream.read(65537)
        if len(raw)>65536: return None
        value=json.loads(raw.decode("utf-8","strict"))
        if not isinstance(value,dict) or value.get("schema")!="qofi-codex-repo-lease/v1":
            return None
        return value.get("repo_path")
    except (OSError,UnicodeDecodeError,ValueError):
        return None

for name in sorted(os.listdir(root)):
    if released.fullmatch(name):
        # Finalized release evidence is explicitly inert.
        continue
    match=release.fullmatch(name)
    logical=match.group(1) if match else (name if canonical.fullmatch(name) else None)
    if logical is None:
        continue
    path=os.path.join(root,name)
    if base is not None and logical==base:
        print(f"retained physical repo lease/tombstone: {path}")
        raise SystemExit(4)
    if owner_repo(path)==repo:
        print(f"retained physical repo lease/tombstone: {path}")
        raise SystemExit(4)
raise SystemExit(0)
PY
)"; then
    _repo_lease_guard_rc=0
  else
    _repo_lease_guard_rc=$?
  fi
  if [ "$_repo_lease_guard_rc" -ne 0 ]; then
    swarm_conf_lock_release
    echo "swarm-remove: REFUSED — ${_repo_lease_guard:-physical repository lease evidence is unsafe}; recover the exact repo lease before unregistering '$NAME'." >&2
    exit 1
  fi
fi

# 2) Remove the line from swarm.conf (atomic rewrite, comments preserved).
_released_workspace=0

# Release only the final Codex reference to this repo. Hold the global config
# lock across release + row CAS, and verify the pre-release file digest so a
# non-cooperating writer cannot create a hidden new reference in the gap.
if [ "$ENGINE" = "codex" ]; then
  if ! swarm_codex_repo_ref_count "$CODEX_RUNTIME_REPO" "$NAME"; then
    swarm_conf_lock_release
    echo "swarm-remove: REFUSED — malformed swarm.conf prevents safe Codex reference accounting." >&2
    exit 1
  fi
  if [ "$SWARM_CODEX_REPO_REF_COUNT" -eq 0 ]; then
    if [ ! -x "$CODEX_RUNTIME_BIN" ] \
       || ! "$CODEX_RUNTIME_BIN" release-workspace --repo "$CODEX_RUNTIME_REPO"; then
      swarm_conf_lock_release
      echo "swarm-remove: REFUSED — could not release Codex workspace authority; row remains registered." >&2
      exit 1
    fi
    _released_workspace=1
  fi
fi

if /usr/bin/python3 -I -B - "$CONF" "$NAME" "$ROW_RAW" "$_conf_digest" <<'PY'
import hashlib,os,stat,sys,tempfile
path,name,expected,expected_digest=sys.argv[1:5]
st=os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise SystemExit(2)
if hashlib.sha256(open(path,'rb').read()).hexdigest() != expected_digest:
    raise SystemExit(4)
with open(path,'r',newline='') as f: original=f.read()
lines=original.splitlines(keepends=True); matches=[]
for i,raw in enumerate(lines):
    body=raw[:-2] if raw.endswith('\r\n') else (raw[:-1] if raw.endswith('\n') else raw)
    if body.lstrip().startswith('#') or not body.strip(): continue
    if body.split('|',1)[0].strip()==name: matches.append((i,body))
if len(matches)!=1 or matches[0][1]!=expected: raise SystemExit(3)
del lines[matches[0][0]]
fd,tmp=tempfile.mkstemp(prefix='.swarm.conf.remove.',dir=os.path.dirname(path) or '.')
try:
    with os.fdopen(fd,'w',newline='') as f:
        f.writelines(lines); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(st.st_mode)); os.replace(tmp,path)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
then
  _remove_rc=0
else
  _remove_rc=$?
fi
if [ "$_remove_rc" -ne 0 ]; then
  if [ "$_released_workspace" -eq 1 ]; then
    if ! swarm_codex_repo_ref_count "$CODEX_RUNTIME_REPO"; then
      swarm_conf_lock_release
      echo "swarm-remove: CRITICAL — concurrent malformed config prevents safe Codex authority reconciliation; workspace access remains revoked." >&2
      exit 1
    fi
    if [ "$SWARM_CODEX_REPO_REF_COUNT" -gt 0 ] \
       && { [ ! -x "$CODEX_RUNTIME_BIN" ] \
            || ! "$CODEX_RUNTIME_BIN" prepare-workspace --repo "$CODEX_RUNTIME_REPO" \
            || ! "$CODEX_RUNTIME_BIN" verify --repo "$CODEX_RUNTIME_REPO"; }; then
        swarm_conf_lock_release
        echo "swarm-remove: CRITICAL — a Codex row still references the repo but workspace authority rollback failed; repair the dedicated runtime before launch." >&2
        exit 1
    fi
  fi
  swarm_conf_lock_release
  echo "swarm-remove: REFUSED — the configured row changed during removal; swarm.conf remains registered." >&2
  exit 1
fi
_post_remove_digest="$(/usr/bin/python3 -I -B - "$CONF" <<'PY'
import hashlib, os, stat, sys
path=sys.argv[1]; st=os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise SystemExit(2)
with open(path,'rb') as f: print(hashlib.sha256(f.read()).hexdigest())
PY
)" || {
  echo "swarm-remove: CRITICAL — row was removed but the resulting config generation could not be fingerprinted; optional cleanup is disabled." >&2
  _post_remove_digest=""
}
swarm_conf_lock_release
echo "swarm-remove: removed '$NAME' from swarm.conf"

# 3) Collect optional cleanup choices without holding the global lifecycle
# lock. No deletion happens from these answers yet: after the prompts we
# reacquire the lock and require the exact post-removal config generation plus
# no same-name/channel reference. This prevents an old remove process from
# deleting a newly registered swarm's ACL/operator/runtime state.
REMOVE_HEARTBEAT=0
REMOVE_ATTENTION=0
REMOVE_ACCESS_GROUP=0
PURGE_CODEX_STATE=0

# 3a) Optional: remove heartbeat state files (prompt; default no).
for ID_FILE in "$STATE_DIR/heartbeat-$CHANNEL.id" "$STATE_DIR/attention-$CHANNEL.flag"; do
if [ -f "$ID_FILE" ]; then
  printf "Remove operator state %s ? [y/N] " "$ID_FILE"
  read -r ans || ans=""
  case "$ans" in
    y|Y)
      case "$ID_FILE" in
        */heartbeat-*.id) REMOVE_HEARTBEAT=1 ;;
        */attention-*.flag) REMOVE_ATTENTION=1 ;;
      esac
      ;;
    *)   echo "swarm-remove: left $ID_FILE in place" ;;
  esac
fi
done

# 3b) Optional: remove access.json group (prompt; default no per spec).
if [ -f "$ACCESS" ] && \
   /usr/bin/python3 -I -B -c "import json,sys; cfg=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in (cfg.get('groups') or {}) else 1)" \
     "$ACCESS" "$CHANNEL" 2>/dev/null; then
  printf "Remove channel %s group from %s ? [y/N] " "$CHANNEL" "$ACCESS"
  read -r ans || ans=""
  case "$ans" in
    y|Y) REMOVE_ACCESS_GROUP=1 ;;
    *) echo "swarm-remove: left access.json untouched" ;;
  esac
fi

# Codex state may contain a bot-token .env, session continuity, and bounded
# audit evidence. Preserve by default; purge only with an explicit confirmation
# after quiescence was proven above.
if [ "$ENGINE" = "codex" ] && [ -e "$CODEX_STATE" ]; then
  printf "Purge Codex state %s (may contain token/session/audit evidence)? [y/N] " "$CODEX_STATE"
  read -r ans || ans=""
  case "$ans" in
    y|Y) PURGE_CODEX_STATE=1 ;;
    *) echo "swarm-remove: preserved Codex state $CODEX_STATE" ;;
  esac
fi

if [ "$REMOVE_HEARTBEAT" -eq 1 ] || [ "$REMOVE_ATTENTION" -eq 1 ] \
   || [ "$REMOVE_ACCESS_GROUP" -eq 1 ] || [ "$PURGE_CODEX_STATE" -eq 1 ]; then
  _cleanup_allowed=1
  _channel_refs=0
  if [ -z "$_post_remove_digest" ] || ! swarm_conf_lock_acquire "$CONF"; then
    _cleanup_allowed=0
  else
    _cleanup_digest="$(/usr/bin/python3 -I -B - "$CONF" <<'PY'
import hashlib, os, stat, sys
path=sys.argv[1]; st=os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise SystemExit(2)
with open(path,'rb') as f: print(hashlib.sha256(f.read()).hexdigest())
PY
)" || _cleanup_allowed=0
    [ "$_cleanup_digest" = "$_post_remove_digest" ] || _cleanup_allowed=0
    if [ "$_cleanup_allowed" -eq 1 ]; then
      while IFS= read -r _cleanup_line || [ -n "$_cleanup_line" ]; do
        _cleanup_trim="$(_swarm_trim "$_cleanup_line")"
        case "$_cleanup_trim" in ''|'#'*) continue ;; esac
        if ! swarm_conf_parse_line "$_cleanup_line"; then
          _cleanup_allowed=0
          break
        fi
        if [ "$SWARM_CONF_F_NAME" = "$NAME" ]; then
          _cleanup_allowed=0
          break
        fi
        if [ "$SWARM_CONF_F_CHANNEL" = "$CHANNEL" ]; then
          _channel_refs=$((_channel_refs + 1))
        fi
      done < "$CONF"
    fi
  fi

  if [ "$_cleanup_allowed" -ne 1 ]; then
    echo "swarm-remove: optional cleanup skipped — swarm.conf changed or could not be locked after confirmation; retained all selected state." >&2
  else
    if [ "$_channel_refs" -gt 0 ] && { [ "$REMOVE_HEARTBEAT" -eq 1 ] \
         || [ "$REMOVE_ATTENTION" -eq 1 ] || [ "$REMOVE_ACCESS_GROUP" -eq 1 ]; }; then
      echo "swarm-remove: channel $CHANNEL is still referenced by $_channel_refs row(s); shared operator/ACL state was retained." >&2
      REMOVE_HEARTBEAT=0
      REMOVE_ATTENTION=0
      REMOVE_ACCESS_GROUP=0
    fi
    if [ "$REMOVE_HEARTBEAT" -eq 1 ]; then
      rm -f "$STATE_DIR/heartbeat-$CHANNEL.id"
      echo "swarm-remove: removed $STATE_DIR/heartbeat-$CHANNEL.id"
    fi
    if [ "$REMOVE_ATTENTION" -eq 1 ]; then
      rm -f "$STATE_DIR/attention-$CHANNEL.flag"
      echo "swarm-remove: removed $STATE_DIR/attention-$CHANNEL.flag"
    fi
    if [ "$REMOVE_ACCESS_GROUP" -eq 1 ]; then
      /usr/bin/python3 -I -B - "$ACCESS" "$CHANNEL" "$ENGINE" <<'PY'
import ctypes, errno, json, os, stat, sys, tempfile
path, channel, engine = sys.argv[1], sys.argv[2], sys.argv[3]
st=os.lstat(path)
if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != os.getuid()):
    raise SystemExit('unsafe access.json owner/type')
if engine == 'codex' and sys.platform == 'darwin':
    libc=ctypes.CDLL(None,use_errno=True)
    get_acl=libc.acl_get_fd_np
    get_acl.argtypes=[ctypes.c_int,ctypes.c_int]
    get_acl.restype=ctypes.c_void_p
    free_acl=libc.acl_free
    free_acl.argtypes=[ctypes.c_void_p]
    for checked,is_dir in ((path,False),(os.path.dirname(path),True)):
      flags=os.O_RDONLY | getattr(os,'O_NOFOLLOW',0)
      if is_dir: flags |= getattr(os,'O_DIRECTORY',0)
      fd=os.open(checked,flags)
      try:
        ctypes.set_errno(0)
        acl=get_acl(fd,0x00000100)
        if acl:
            free_acl(acl)
            raise SystemExit(f'access boundary must not have an extended ACL: {checked}; run chmod -N')
        if ctypes.get_errno() not in (0,errno.ENOENT):
            raise SystemExit(f'could not inspect access ACL: {checked}')
      finally:
        os.close(fd)
with open(path) as f: cfg = json.load(f)
cfg.get("groups", {}).pop(channel, None)
fd,tmp=tempfile.mkstemp(prefix='.access.json.',dir=os.path.dirname(path) or '.')
try:
    with os.fdopen(fd,"w") as f:
        json.dump(cfg,f,indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
      echo "swarm-remove: removed group $CHANNEL from access.json"
    fi
    if [ "$PURGE_CODEX_STATE" -eq 1 ]; then
      if swarm_codex_state_validate "$NAME" read; then
        CODEX_STATE="$SWARM_CODEX_STATE_DIR"
        rm -rf "$CODEX_STATE"
        echo "swarm-remove: purged $CODEX_STATE"
      else
        _state_cleanup_rc=$?
        if [ "$_state_cleanup_rc" -eq 1 ]; then
          echo "swarm-remove: Codex state already absent"
        else
          echo "swarm-remove: optional Codex purge refused — state boundary changed after confirmation." >&2
        fi
      fi
    fi
  fi
  while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
fi

# 4) Tell the operator about the orphaned token-env var.
cat <<EOF

----------------------------------------------------------------------
Swarm '$NAME' removed from active config.

Token-env var \$$TOK_VAR is NOT removed automatically (it may be reused).
If you no longer need it, remove the matching 'export $TOK_VAR=' line from:
    $SWARM_HOME/tokens.env
and rotate the Discord bot token if the bot will no longer be used.

Repo at $REPO is UNTOUCHED.
----------------------------------------------------------------------
EOF
