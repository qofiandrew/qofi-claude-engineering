#!/usr/bin/env bash
# swarm-lib.sh — shared helpers, sourced by the swarm-* scripts.
#
# Sourced, not executed. Bash 3.2-safe (macOS default). Does NOT call `set` —
# the caller owns shell options. python3 is the only non-shell dependency
# (already required across the swarm scripts; see swarm-add, dod-affirm,
# permission-gate).
#
# Four concerns live here:
#
#   0. swarm_conf_parse_line()     — parse ONE swarm.conf row into the
#                                    canonical fields. The single place the
#                                    column schema/arity is defined, so every
#                                    reader shares it and a future column can
#                                    never silently corrupt an existing one.
#   1. repo_activity()             — shared "is this swarm producing work?"
#                                    signal for swarm-watch + swarm-typing.
#   2. manifest_walk / apply       — the single-source-of-truth deployer
#                                    consumed by swarm-init, swarm-sync, and
#                                    swarm-onboard. ALL three commands share
#                                    these helpers; per-mode policy is in
#                                    flags passed via env, not duplicated
#                                    logic. See templates/<type>/manifest.tsv
#                                    (per-archetype dispatch via swarm_type_of).
#   3. settings_merge_swarm()      — structured merge of swarm hook
#                                    registrations into an existing
#                                    settings.json. Additive, dedup-by-
#                                    command, atomic write. Never clobbers
#                                    foreign hook entries.

# ---------------------------------------------------------------------------
# 0) swarm.conf row parsing — ONE definition of the column schema.
# ---------------------------------------------------------------------------
#
# swarm.conf rows are positional, pipe-delimited:
#
#     name | repo | tokvar | channel | guild_id | account | engine | codex_auth_pool
#
# The historical bug this section exists to kill: readers did their own
# `IFS='|' read -r name repo tokvar channel` with a FIXED arity SHORTER than
# the file's column count. Bash's last `read` variable absorbs every trailing
# field INCLUDING the delimiter — so once the 5th (guild_id) column landed, a
# 4-variable reader's `channel` silently became "<channel> | <guild_id>".
# That broke swarm-attention (channel failed all-digits validation) and
# swarm-typing (typing URL carried " | <guild>"). Each future column would
# break the next reader the same way.
#
# The fix: parse a row HERE, once, splitting into the full known arity PLUS a
# trailing catch-all (`_rest`). The last *named* field can therefore never
# swallow an unknown future column — it lands in `_rest` and is ignored until
# we name it. To add a column later: add it to the read below and expose a new
# SWARM_CONF_F_* global. Readers that don't use it need no change and cannot
# be corrupted by it.
#
# Results are returned in globals (bash 3.2 has no namerefs / assoc-array
# return); a reader copies out only the fields it uses:
#
#   SWARM_CONF_F_NAME  SWARM_CONF_F_REPO  SWARM_CONF_F_TOKVAR
#   SWARM_CONF_F_CHANNEL  SWARM_CONF_F_GUILD  SWARM_CONF_F_ACCOUNT
#   SWARM_CONF_F_ENGINE  SWARM_CONF_F_CODEX_AUTH_POOL
#
# swarm_conf_parse_line returns non-zero for a comment/blank or invalid row so
# callers can `swarm_conf_parse_line "$line" || continue` fail-closed.

SWARM_CONF_F_NAME=""
SWARM_CONF_F_REPO=""
SWARM_CONF_F_TOKVAR=""
SWARM_CONF_F_CHANNEL=""
SWARM_CONF_F_GUILD=""
SWARM_CONF_F_ACCOUNT=""
SWARM_CONF_F_ENGINE=""
SWARM_CONF_F_CODEX_AUTH_POOL=""

# _swarm_trim STRING — strip leading/trailing whitespace (pure bash, no
# subprocess; safe in the per-row hot loops swarm-typing/swarm-watch run).
_swarm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# swarm_conf_parse_line RAW_LINE
#   Populate SWARM_CONF_F_* from one raw swarm.conf line. Returns 1 (caller
#   should `continue`) for blank or comment ('#') lines, 0 otherwise.
swarm_conf_parse_line() {
  local _line="$1" _trimmed
  _trimmed="$(_swarm_trim "$_line")"
  case "$_trimmed" in
    ''|'#'*) return 1 ;;
  esac
  local _name _repo _tokvar _channel _guild _account _engine _codex_auth_pool _rest
  # Full known arity + `_rest` catch-all so a row with MORE columns than the
  # current schema cannot corrupt the last named field (see header). ACCOUNT
  # (field 6) is the multi-account partition label; absent in legacy 4/5-col
  # rows → empty → the default account (today's behavior). Resolve it via
  # swarm_account_resolve — never construct an account path by hand.
  # ENGINE (field 7) selects the lead runtime: empty or 'claude' → the Claude
  # Code lead (today's behavior, byte-identical launch); 'codex' → a Codex
  # lead driven through codex-bridge/. Anything else is refused — a typo must
  # not silently boot the wrong runtime.
  # CODEX_AUTH_POOL (field 8) selects a named, ordered Codex profile pool.
  # Blank resolves to the explicit `default` pool. It is independent from
  # ACCOUNT (field 6), which remains the Claude account partition label.
  IFS='|' read -r _name _repo _tokvar _channel _guild _account _engine _codex_auth_pool _rest <<EOF
$_line
EOF
  SWARM_CONF_F_NAME="$(_swarm_trim "$_name")"
  SWARM_CONF_F_REPO="$(_swarm_trim "$_repo")"
  SWARM_CONF_F_TOKVAR="$(_swarm_trim "$_tokvar")"
  # Field 3 (TOKEN_VAR_NAME) is later deref'd by NAME via ${!tokvar} (swarm-up /
  # swarm-typing / swarm-watch) and spliced into the pane env line. A value that
  # is not a legal shell IDENTIFIER is an injection sink: the array-subscript form
  # NAME[$(...)] fires command substitution inside the launcher (which could
  # re-source and exfiltrate the whole vault), and a quote-break escapes the pane
  # env string — either defeats F1 token isolation (ADR-0018). A `case` match does
  # NOT evaluate the value, so checking it is itself safe. Reject a malformed
  # non-empty token-var by BLANKING it; the consumers' empty-token guards then skip
  # the swarm (fail-safe) rather than deref a hostile name. (The OAUTH token-var is
  # built by swarm_account_resolve from a charset-validated label, already safe.)
  case "$SWARM_CONF_F_TOKVAR" in
    '') : ;;                                   # empty is fine — guards skip the swarm
    [0-9]* | *[!A-Za-z0-9_]*)                  # not ^[A-Za-z_][A-Za-z0-9_]*$ → reject
      echo "swarm_conf_parse_line: refusing non-identifier TOKEN_VAR_NAME '$SWARM_CONF_F_TOKVAR' for swarm '$SWARM_CONF_F_NAME' (must match [A-Za-z_][A-Za-z0-9_]*); blanking it." >&2
      SWARM_CONF_F_TOKVAR="" ;;
  esac
  SWARM_CONF_F_CHANNEL="$(_swarm_trim "$_channel")"
  SWARM_CONF_F_GUILD="$(_swarm_trim "$_guild")"
  SWARM_CONF_F_ACCOUNT="$(_swarm_trim "$_account")"
  SWARM_CONF_F_ENGINE="$(_swarm_trim "$_engine")"
  case "$SWARM_CONF_F_ENGINE" in
    ''|claude) SWARM_CONF_F_ENGINE="claude" ;;
    codex)     : ;;
    *)
      echo "swarm_conf_parse_line: refusing unknown ENGINE '$SWARM_CONF_F_ENGINE' for swarm '$SWARM_CONF_F_NAME' (must be claude or codex); row skipped." >&2
      SWARM_CONF_F_ENGINE=""
      return 1 ;;
  esac
  SWARM_CONF_F_CODEX_AUTH_POOL="$(_swarm_trim "$_codex_auth_pool")"
  [ -n "$SWARM_CONF_F_CODEX_AUTH_POOL" ] || SWARM_CONF_F_CODEX_AUTH_POOL="default"
  case "$SWARM_CONF_F_CODEX_AUTH_POOL" in
    [!a-z]*|*[!a-z0-9_-]*)
      echo "swarm_conf_parse_line: refusing invalid CODEX_AUTH_POOL '$SWARM_CONF_F_CODEX_AUTH_POOL' for swarm '$SWARM_CONF_F_NAME' (must match [a-z][a-z0-9_-]{0,31}); row skipped." >&2
      SWARM_CONF_F_CODEX_AUTH_POOL=""
      return 1 ;;
  esac
  if [ "${#SWARM_CONF_F_CODEX_AUTH_POOL}" -gt 32 ]; then
    echo "swarm_conf_parse_line: refusing overlong CODEX_AUTH_POOL '$SWARM_CONF_F_CODEX_AUTH_POOL' for swarm '$SWARM_CONF_F_NAME' (max 32 characters); row skipped." >&2
    SWARM_CONF_F_CODEX_AUTH_POOL=""
    return 1
  fi
  return 0
}

# shell_quote VALUE — emit VALUE as one POSIX-shell word. Used only when an
# integration must generate a small launcher file / tmux shell-command string;
# normal process launches should continue to pass argv directly. The classic
# single-quote splice (`'` -> `'\''`) preserves every byte except NUL (which a
# shell variable cannot contain) and makes ordinary valid paths containing an
# apostrophe safe.
shell_quote() {
  local _sq
  _sq="$(printf '%s' "$1" | /usr/bin/sed "s/'/'\\\\''/g")"
  printf "'%s'" "$_sq"
}

# ---------------------------------------------------------------------------
# Codex bridge runtime state — one parser/health contract for every consumer.
# ---------------------------------------------------------------------------
#
# codex-bridge writes this file atomically (temp + rename, mode 0600):
#
#   $HOME/.codex/channels/discord-<swarm>/runtime.json
#
# Schema: codex-bridge-runtime/v1. updated_at heartbeats every 5s; consumers
# trust a snapshot for 20s by default AND require its daemon pid to be alive.
# `active` covers the dequeued Discord job; `queue_depth` is waiting jobs only;
# `child_pid` is the direct Codex CLI child when one exists. Missing/malformed/
# stale/dead state is deliberately non-zero so destructive callers fail safe.
#
# swarm_codex_runtime_read NAME [MAX_AGE_SECONDS]
#   return 0 healthy; 1 missing; 2 malformed/wrong schema; 3 stale/dead
#   sets SWARM_CODEX_RUNTIME_* globals on every path.
SWARM_CODEX_RUNTIME_STATUS="unread"
SWARM_CODEX_RUNTIME_FILE=""
SWARM_CODEX_RUNTIME_PID=""
SWARM_CODEX_RUNTIME_READY=0
SWARM_CODEX_RUNTIME_ACTIVE=0
SWARM_CODEX_RUNTIME_QUEUE_DEPTH=0
SWARM_CODEX_RUNTIME_CHILD_PID=""
SWARM_CODEX_RUNTIME_AGE=""
SWARM_CODEX_RUNTIME_LAST_COMPLETED_AGE=""
SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT=""
SWARM_CODEX_RUNTIME_LAST_ERROR=""
SWARM_CODEX_STATE_DIR=""
SWARM_CODEX_STATE_STATUS="unread"

swarm_codex_state_dir() {  # name
  local _codex_home="${SWARM_CODEX_HOME_EFFECTIVE:-$HOME/.codex}"
  printf '%s/channels/discord-%s' "$_codex_home" "$1"
}

# Validate the complete per-swarm state path before any consumer reads or
# writes it. Existing path components from CODEX_HOME downward must be real,
# owner-held 0700 directories; every nested regular state file is 0600 (the
# generated launch.sh is the sole 0700 executable exception), sockets are 0600,
# and symlinks/special files are refused. `prepare` creates missing directories
# with 0700; `read` returns 1 for an absent path and 2 for unsafe state.
swarm_codex_state_validate() {  # name [read|prepare]
  local _name="$1" _mode="${2:-read}" _home _codex_home _out _rc
  SWARM_CODEX_STATE_DIR=""
  SWARM_CODEX_STATE_STATUS="unread"
  case "$_name" in
    [A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9_-]*) ;;
    *) SWARM_CODEX_STATE_STATUS="unsafe"; return 2 ;;
  esac
  case "$_mode" in read|prepare) ;; *) SWARM_CODEX_STATE_STATUS="unsafe"; return 2 ;; esac
  _home="${HOME:-}"
  _codex_home="${SWARM_CODEX_HOME_EFFECTIVE:-${HOME:-}/.codex}"
  _out="$(/usr/bin/python3 -I -B - "$_home" "$_codex_home" "$_name" "$_mode" <<'PY'
import ctypes, errno, os, stat, subprocess, sys
home, codex_home, name, mode = sys.argv[1:]
uid=os.getuid()

def fail(message, code=2):
    sys.stderr.write('unsafe Codex state: ' + message + '\n')
    raise SystemExit(code)

def inside(root, candidate):
    try: return os.path.commonpath([root, candidate]) == root
    except ValueError: return False

def has_extended_acl(path):
    """Inspect the fd ACL without following a final symlink (macOS only)."""
    if sys.platform != 'darwin':
        return False
    before=os.lstat(path)
    if stat.S_ISSOCK(before.st_mode):
        # macOS refuses open(2) and listxattr(2) on a Unix socket with ENOTSUP,
        # even though the socket can carry an extended ACL. Bind the fixed
        # system ls inspection between exact identity checks instead.
        identity=lambda value: (
            value.st_dev,value.st_ino,value.st_uid,value.st_gid,value.st_mode,
            value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns,
        )
        try:
            result=subprocess.run(
                ['/bin/ls','-lde',path], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'}, timeout=2,
                check=False,
            )
            after=os.lstat(path)
        except Exception as exc:
            fail(f'could not inspect ACL on {path}: {exc}')
        if identity(after) != identity(before):
            fail(f'socket changed while inspecting ACL: {path}')
        if result.returncode != 0 or len(result.stdout) > 8192 or len(result.stderr) > 8192:
            fail(f'could not inspect ACL on {path}')
        try: lines=result.stdout.decode('utf-8','strict').splitlines()
        except UnicodeDecodeError: fail(f'malformed ACL listing on {path}')
        if not lines:
            fail(f'empty ACL listing on {path}')
        permissions=lines[0].split(None,1)[0]
        if not permissions.startswith('s'):
            fail(f'malformed socket ACL listing on {path}')
        return '+' in permissions
    flags=os.O_RDONLY | getattr(os,'O_NONBLOCK',0) | getattr(os,'O_NOFOLLOW',0)
    if stat.S_ISDIR(os.lstat(path).st_mode):
        flags |= getattr(os,'O_DIRECTORY',0)
    fd=os.open(path,flags)
    try:
        libc=ctypes.CDLL(None,use_errno=True)
        get_acl=libc.acl_get_fd_np
        get_acl.argtypes=[ctypes.c_int,ctypes.c_int]
        get_acl.restype=ctypes.c_void_p
        free_acl=libc.acl_free
        free_acl.argtypes=[ctypes.c_void_p]
        free_acl.restype=ctypes.c_int
        ctypes.set_errno(0)
        acl=get_acl(fd,0x00000100)  # ACL_TYPE_EXTENDED
        if not acl:
            error=ctypes.get_errno()
            if error in (0,errno.ENOENT): return False
            fail(f'could not inspect ACL on {path}: errno {error}')
        try: return True
        finally: free_acl(acl)
    finally:
        os.close(fd)

if not home or not os.path.isabs(home) or os.path.normpath(home) != home:
    fail('HOME must be an absolute normalized path')
if not os.path.isabs(codex_home) or os.path.normpath(codex_home) != codex_home:
    fail('CODEX_HOME must be an absolute normalized path')
home_real=os.path.realpath(home)
if home_real != home:
    fail('HOME must not contain symlink indirection')
try: hs=os.lstat(home)
except OSError: fail('HOME does not exist')
if (not stat.S_ISDIR(hs.st_mode) or stat.S_ISLNK(hs.st_mode)
        or hs.st_uid != uid or hs.st_mode & 0o022):
    fail('HOME must be an owner-controlled non-writable real directory')
if not inside(home, codex_home) or codex_home == home:
    fail('CODEX_HOME must be a dedicated path beneath HOME')

state=os.path.join(codex_home, 'channels', 'discord-' + name)
parts=[]
cursor=codex_home
while cursor != home:
    parts.append(cursor)
    parent=os.path.dirname(cursor)
    if parent == cursor or not inside(home, parent):
        fail('CODEX_HOME escapes HOME')
    cursor=parent
parts.reverse()
parts.extend([os.path.join(codex_home, 'channels'), state])

for path in parts:
    try: st=os.lstat(path)
    except FileNotFoundError:
        if mode != 'prepare':
            print('missing|' + state)
            raise SystemExit(1)
        try: os.mkdir(path, 0o700)
        except FileExistsError: pass
        st=os.lstat(path)
    except OSError as exc:
        fail(f'{path}: {exc}')
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != uid or stat.S_IMODE(st.st_mode) != 0o700):
        fail(f'{path} must be a real owner-held 0700 directory; run: chmod 700 {path}')

opaque_dirs={'tool-tmp','git-broker','inbox'}
private_dirs={'approved','tool-tmp','tool-shims','git-broker','inbox','daemon.lock','native-view',
              'review-artifacts','fable-review-tmp'}

def validate_private_dir(path):
    st=os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != uid or stat.S_IMODE(st.st_mode) != 0o700):
        fail(f'{path} must be a real owner-held 0700 directory')

def validate_controlled_tree(root, file_mode=0o600, allow_runtime_acls=False):
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        validate_private_dir(current)
        if not allow_runtime_acls and has_extended_acl(current):
            fail(f'{current} must not have an extended ACL')
        for entry in dirs:
            path=os.path.join(current, entry)
            if stat.S_ISLNK(os.lstat(path).st_mode): fail(f'{path} must not be a symlink')
        for entry in files:
            path=os.path.join(current, entry); st=os.lstat(path)
            if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
                    or st.st_uid != uid or stat.S_IMODE(st.st_mode) != file_mode):
                fail(f'{path} file mode must be {file_mode:04o}')
            if not allow_runtime_acls and has_extended_acl(path):
                fail(f'{path} must not have an extended ACL')

def validate_native_view(root):
    validate_private_dir(root)
    if has_extended_acl(root): fail(f'{root} must not have an extended ACL')
    entries=list(os.scandir(root))
    if len(entries) > 1: fail(f'{root} contains unknown native-view entries')
    for item in entries:
        st=os.lstat(item.path)
        if (item.name != 'app-server.sock' or not stat.S_ISSOCK(st.st_mode)
                or stat.S_ISLNK(st.st_mode) or st.st_uid != uid
                or stat.S_IMODE(st.st_mode) != 0o600):
            fail(f'{item.path} is not the private native-view socket')
        if has_extended_acl(item.path): fail(f'{item.path} must not have an extended ACL')

for entry in os.scandir(state):
    path=entry.path; st=os.lstat(path); perms=stat.S_IMODE(st.st_mode)
    if stat.S_ISLNK(st.st_mode): fail(f'{path} must not be a symlink')
    if st.st_uid != uid: fail(f'{path} has the wrong owner')
    if stat.S_ISDIR(st.st_mode):
        if entry.name not in private_dirs: fail(f'{path} is an unknown state directory')
        validate_private_dir(path)
        if entry.name in opaque_dirs:
            continue
        if entry.name == 'native-view':
            validate_native_view(path)
        elif entry.name == 'tool-shims':
            # The dedicated runtime receives exact execute/read ACEs here;
            # runtime-acl.ts validates their allowlist transactionally.
            validate_controlled_tree(path, 0o500, True)
        else:
            validate_controlled_tree(path, 0o600)
    elif stat.S_ISREG(st.st_mode):
        expected=0o700 if entry.name == 'launch.sh' else 0o600
        if perms != expected: fail(f'{path} file mode must be {expected:04o}')
        # Root state files contain the bot token, authorization ceiling,
        # session continuity, and redacted audit state. No service/everyone
        # ACE is ever legitimate on these files.
        if has_extended_acl(path): fail(f'{path} must not have an extended ACL')
    elif stat.S_ISSOCK(st.st_mode):
        if perms != 0o600: fail(f'{path} socket mode must be 0600')
        if has_extended_acl(path): fail(f'{path} must not have an extended ACL')
    else:
        fail(f'{path} has an unsupported special-file type')

print('ok|' + state)
PY
)"; _rc=$?
  case "$_rc:$_out" in
    0:ok\|*)
      SWARM_CODEX_STATE_DIR="${_out#ok|}"
      SWARM_CODEX_HOME_EFFECTIVE="${SWARM_CODEX_STATE_DIR%/channels/discord-*}"
      SWARM_CODEX_STATE_STATUS="safe"
      export SWARM_CODEX_HOME_EFFECTIVE
      return 0
      ;;
    1:missing\|*)
      SWARM_CODEX_STATE_DIR="${_out#missing|}"
      SWARM_CODEX_STATE_STATUS="missing"
      return 1
      ;;
    *)
      SWARM_CODEX_STATE_STATUS="unsafe"
      return 2
      ;;
  esac
}

SWARM_CODEX_TRUSTED_BIN_REAL=""
SWARM_CODEX_ARGV_PREFIX=""
SWARM_CODEX_TOOL_PATH=""
SWARM_CODEX_TRUSTED_BUN_REAL=""
SWARM_CODEX_CANONICAL_HOME=""
SWARM_CODEX_CANONICAL_CODEX_HOME=""
SWARM_CODEX_CLI_VERSION=""
SWARM_CODEX_RUNTIME_UID=""
SWARM_CODEX_RUNTIME_USER=""
SWARM_CODEX_RUNTIME_HOME=""
SWARM_CODEX_RUNTIME_CODEX_HOME=""
SWARM_CODEX_RUNTIME_GID=""
SWARM_CODEX_RUNTIME_GROUP=""
SWARM_CODEX_RUNNER=""
SWARM_CODEX_RUNTIME_SCHEMA=""
SWARM_CODEX_OPERATOR_CANARY_VALUE=""
SWARM_CODEX_MANAGER_STATE_DIR=""
SWARM_CODEX_MANAGER_SOCKET=""
SWARM_CODEX_MANAGER_SESSION="qofi-codex-app-server-manager"

# The App Server manager is a single operator-local broker shared by every
# Codex swarm.  Its upstream root runner holds a host-wide exclusion lock, so
# root lifecycle/preflight commands must explicitly drain it before touching
# that authority.  Only the root-installed, zero-argument launcher may start
# the manager; workspace TypeScript is never a production launch target.
swarm_codex_manager_paths() {
  local _home="${HOME:-}"
  [ -n "$_home" ] || {
    echo "Codex manager: HOME is unset" >&2
    return 1
  }
  SWARM_CODEX_MANAGER_STATE_DIR="${_home%/}/.codex/app-server-manager"
  SWARM_CODEX_MANAGER_SOCKET="$SWARM_CODEX_MANAGER_STATE_DIR/control.sock"
  export SWARM_CODEX_MANAGER_STATE_DIR SWARM_CODEX_MANAGER_SOCKET
  return 0
}

# Validate (and, only for prepare, create) the exact global state directory.
# The fixed launcher independently repeats this proof before it drops to the
# operator; this caller-side check prevents tmux/sudo from being aimed through
# a symlink or a directory writable by another principal in the first place.
swarm_codex_manager_state_validate() {  # read|prepare
  local _mode="${1:-read}" _out _rc
  case "$_mode" in read|prepare) ;; *) return 2 ;; esac
  swarm_codex_manager_paths || return 2
  if _out="$(/usr/bin/python3 -I -B - "$HOME" "$SWARM_CODEX_MANAGER_STATE_DIR" "$_mode" <<'PY'
import os, stat, subprocess, sys
home, state, mode = sys.argv[1:]
uid = os.getuid()

def fail(message, code=2):
    print('Codex manager: ' + message, file=sys.stderr)
    raise SystemExit(code)

if not os.path.isabs(home) or os.path.normpath(home) != home or os.path.realpath(home) != home:
    fail('HOME must be an absolute canonical path')
expected = os.path.join(home, '.codex', 'app-server-manager')
if state != expected or len(os.fsencode(os.path.join(state, 'control.sock'))) > 100:
    fail('manager state path is not the fixed portable HOME path')

def check_dir(path, exact_mode, label):
    try:
        value = os.lstat(path)
    except FileNotFoundError:
        return False
    if (not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode)
            or value.st_uid != uid or stat.S_IMODE(value.st_mode) != exact_mode):
        fail(f'{label} must be a real owner-held mode-{exact_mode:04o} directory')
    return True

home_info = os.lstat(home)
if (not stat.S_ISDIR(home_info.st_mode) or stat.S_ISLNK(home_info.st_mode)
        or home_info.st_uid != uid or home_info.st_mode & 0o022):
    fail('HOME must be a real owner-controlled non-writable directory')

codex_home = os.path.join(home, '.codex')
if not check_dir(codex_home, 0o700, 'CODEX_HOME'):
    if mode != 'prepare':
        raise SystemExit(1)
    try:
        os.mkdir(codex_home, 0o700)
    except FileExistsError:
        pass
    check_dir(codex_home, 0o700, 'CODEX_HOME')

if not check_dir(state, 0o700, 'manager state'):
    if mode != 'prepare':
        raise SystemExit(1)
    try:
        os.mkdir(state, 0o700)
    except FileExistsError:
        pass
    check_dir(state, 0o700, 'manager state')

# macOS prints a trailing '+' in the mode word for an extended ACL.  Linux
# test hosts accept the same ls form and simply omit it.
probe = subprocess.run(['/bin/ls', '-lde', state], text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if probe.returncode != 0 or not probe.stdout.split():
    fail('could not attest manager state ACLs')
if '+' in probe.stdout.split()[0]:
    fail('manager state must not have an extended ACL')
print(state)
PY
)"; then
    _rc=0
  else
    _rc=$?
  fi
  [ "$_rc" -eq 0 ] || {
    [ "$_rc" -eq 1 ] || printf '%s\n' "$_out" >&2
    return "$_rc"
  }
  [ "$_out" = "$SWARM_CODEX_MANAGER_STATE_DIR" ] || return 2
  return 0
}

swarm_codex_manager_socket_present() {
  swarm_codex_manager_paths || return 1
  [ -e "$SWARM_CODEX_MANAGER_SOCKET" ] || [ -L "$SWARM_CODEX_MANAGER_SOCKET" ]
}

swarm_codex_manager_session_exists() {
  local _tmux="${SWARM_TMUX_BIN:-tmux}"
  if [ "$_tmux" = tmux ]; then command -v tmux >/dev/null 2>&1; else [ -x "$_tmux" ]; fi && \
    "$_tmux" has-session -t "$SWARM_CODEX_MANAGER_SESSION" 2>/dev/null
}

swarm_codex_manager_control() {  # health|ready|drain|resume|shutdown|review
  local _command="$1" _control
  swarm_codex_manager_paths || return 1
  _control="$SWARM_HOME/bin/codex-manager-control.py"
  if [ ! -f "$_control" ] || [ -L "$_control" ]; then
    echo "Codex manager control helper missing or unsafe: $_control" >&2
    return 1
  fi
  /usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
    /usr/bin/python3 -I -B "$_control" --socket "$SWARM_CODEX_MANAGER_SOCKET" "$_command"
}

# Run the existing full root-runner/toolchain/auth preflight without racing the
# manager's upstream generation.  A pre-existing manager is always resumed,
# even when preflight fails, so an unrelated attempted launch cannot strand the
# already-running fleet in a drained state.
swarm_codex_manager_host_preflight() {  # repo
  local _repo="$1" _preflight_rc=0 _resume_rc=0
  if ! swarm_codex_manager_socket_present; then
    if ! swarm_codex_manager_session_exists; then
      swarm_codex_host_preflight "$_repo"
      return $?
    fi
    # A concurrent first launch has published the persistence session but not
    # its endpoint yet. Wait for the strict ready contract before deciding
    # whether the root runner is available; never race raw host preflight into
    # that manager's startup lock acquisition.
    swarm_codex_manager_ensure || return 1
  fi
  if ! swarm_codex_manager_control health >/dev/null 2>&1; then
    # A killed manager can leave the identity-bound socket inode behind.  The
    # fixed launcher/manager owns stale-socket reclamation; shell never unlinks
    # it. Recovery is allowed only when no managed tmux generation is alive.
    if ! swarm_codex_manager_ensure; then
      echo "Codex manager: an endpoint exists but failed health/recovery" >&2
      return 1
    fi
  fi
  if ! swarm_codex_manager_control drain >/dev/null; then
    echo "Codex manager: could not drain the shared App Server before host preflight" >&2
    return 1
  fi
  swarm_codex_host_preflight "$_repo" || _preflight_rc=$?
  swarm_codex_manager_control resume >/dev/null || _resume_rc=$?
  if [ "$_resume_rc" -ne 0 ]; then
    echo "Codex manager: failed to resume after host preflight; Codex remains fail-closed" >&2
    return 1
  fi
  [ "$_preflight_rc" -eq 0 ] || return "$_preflight_rc"
  swarm_codex_manager_control ready >/dev/null
}

# Start or attest the one manager generation.  tmux is only a persistence
# wrapper: the pane command is the exact no-argument fixed launcher through its
# narrowly-scoped sudoers rule.  A same-name tmux session without a valid
# control endpoint is never assumed to be our manager.
swarm_codex_manager_ensure() {
  local _launcher="/usr/local/libexec/qofi-codex-manager-launcher"
  local _session="$SWARM_CODEX_MANAGER_SESSION" _created=0 _session_id=""
  local _tmux="${SWARM_TMUX_BIN:-tmux}"
  local _timeout="${SWARM_CODEX_MANAGER_START_TIMEOUT:-90}" _elapsed=0 _diag=""
  case "$_timeout" in ''|*[!0-9]*) _timeout=90 ;; esac
  [ "$_timeout" -ge 1 ] && [ "$_timeout" -le 300 ] || _timeout=90

  if swarm_codex_manager_socket_present; then
    if swarm_codex_manager_control ready >/dev/null 2>&1; then
      return 0
    fi
    if "$_tmux" has-session -t "$_session" 2>/dev/null; then
      echo "Codex manager: live manager session has no ready control endpoint" >&2
      return 1
    fi
  fi
  swarm_codex_manager_state_validate prepare || return 1
  if [ ! -x "$_launcher" ] || [ -L "$_launcher" ]; then
    echo "Codex manager: fixed launcher missing; run bin/swarm-codex-runtime.sh install" >&2
    return 1
  fi
  if ! /usr/bin/python3 -I -B - "$_launcher" <<'PY'
import os, stat, sys
p=sys.argv[1]; s=os.lstat(p)
raise SystemExit(0 if (stat.S_ISREG(s.st_mode) and not stat.S_ISLNK(s.st_mode)
    and s.st_uid == 0 and not (s.st_mode & 0o022) and (s.st_mode & 0o111)) else 2)
PY
  then
    echo "Codex manager: fixed launcher authority is unsafe" >&2
    return 1
  fi
  if [ "$_tmux" = tmux ]; then command -v tmux >/dev/null 2>&1; else [ -x "$_tmux" ]; fi || {
    echo "Codex manager: tmux is unavailable" >&2
    return 1
  }
  if "$_tmux" has-session -t "$_session" 2>/dev/null; then
    : # A concurrent fixed launcher won; wait only for its attested endpoint.
  elif "$_tmux" new-session -d -s "$_session" -c "$HOME" \
      "/usr/bin/sudo -n -- /usr/local/libexec/qofi-codex-manager-launcher"; then
    _created=1
    _session_id="$("$_tmux" display-message -p -t "$_session" '#{session_id}' 2>/dev/null || true)"
  elif ! "$_tmux" has-session -t "$_session" 2>/dev/null; then
    echo "Codex manager: could not create the persistent manager session" >&2
    return 1
  fi

  while [ "$_elapsed" -lt "$_timeout" ]; do
    if swarm_codex_manager_control ready >/dev/null 2>&1; then
      return 0
    fi
    if ! "$_tmux" has-session -t "$_session" 2>/dev/null; then
      break
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
  _diag="$("$_tmux" capture-pane -p -t "$_session" -S -40 2>/dev/null \
    | /usr/bin/tail -c 4096 | /usr/bin/tr '\n' ' ' || true)"
  echo "Codex manager: fixed launcher did not publish a ready endpoint${_diag:+ ($(_swarm_trim "$_diag"))}" >&2
  if [ "$_created" -eq 1 ] && [ -n "$_session_id" ] && \
     [ "$("$_tmux" display-message -p -t "$_session" '#{session_id}' 2>/dev/null || true)" = "$_session_id" ]; then
    "$_tmux" kill-session -t "$_session" 2>/dev/null || true
  fi
  return 1
}

# One bounded, exact host/toolchain/auth preflight shared by launcher + doctor.
# It deliberately ignores CODEX_BIN and PATH. Codex is selected only by the
# the fixed root attestation/runner; Bun is selected from fixed host install
# roots. All resolve to safe canonical executables
# outside the target repo, SWARM_HOME, CODEX_HOME, and temporary directories.
swarm_codex_host_preflight() {  # repo
  local _repo="$1" _helper _out _rc
  # Never let a failed or non-dedicated preflight inherit a witness from an
  # earlier successful call in the same long-lived shell.
  SWARM_CODEX_OPERATOR_CANARY_VALUE=""
  _helper="$SWARM_HOME/bin/codex-host-preflight.py"
  [ -f "$_helper" ] || {
    echo "Codex host preflight helper missing: $_helper" >&2
    return 1
  }
  if _out="$(/usr/bin/env -i HOME="${HOME:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
      /usr/bin/python3 -I -B "$_helper" "$_repo" "$SWARM_HOME" 2>&1)"; then
    _rc=0
  else
    _rc=$?
  fi
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_out" >&2
    return 1
  fi
  IFS='|' read -r \
    SWARM_CODEX_TRUSTED_BIN_REAL \
    SWARM_CODEX_TRUSTED_BUN_REAL \
    SWARM_CODEX_CANONICAL_HOME \
    SWARM_CODEX_CANONICAL_CODEX_HOME \
    SWARM_CODEX_CLI_VERSION \
    SWARM_CODEX_ARGV_PREFIX \
    SWARM_CODEX_TOOL_PATH \
    SWARM_CODEX_RUNTIME_UID \
    SWARM_CODEX_RUNTIME_USER \
    SWARM_CODEX_RUNTIME_HOME \
    SWARM_CODEX_RUNTIME_CODEX_HOME \
    SWARM_CODEX_RUNTIME_GID \
    SWARM_CODEX_RUNTIME_GROUP \
    SWARM_CODEX_RUNNER \
    SWARM_CODEX_RUNTIME_SCHEMA \
    SWARM_CODEX_OPERATOR_CANARY_VALUE <<EOF
$_out
EOF
  if [ -z "$SWARM_CODEX_TRUSTED_BIN_REAL" ] || \
     [ -z "$SWARM_CODEX_TRUSTED_BUN_REAL" ] || \
     [ -z "$SWARM_CODEX_CANONICAL_HOME" ] || \
     [ -z "$SWARM_CODEX_CANONICAL_CODEX_HOME" ] || \
     [ -z "$SWARM_CODEX_CLI_VERSION" ] || [ -z "$SWARM_CODEX_TOOL_PATH" ] || \
     [ -z "$SWARM_CODEX_RUNTIME_UID" ] || [ -z "$SWARM_CODEX_RUNTIME_USER" ] || \
     [ -z "$SWARM_CODEX_RUNTIME_HOME" ] || [ -z "$SWARM_CODEX_RUNTIME_CODEX_HOME" ] || \
     [ -z "$SWARM_CODEX_RUNTIME_GID" ] || [ -z "$SWARM_CODEX_RUNTIME_GROUP" ] || \
     [ -z "$SWARM_CODEX_RUNNER" ] || [ -z "$SWARM_CODEX_RUNTIME_SCHEMA" ]; then
    echo "Codex host preflight returned an incomplete contract" >&2
    return 1
  fi
  if [ "$SWARM_CODEX_RUNTIME_SCHEMA" = "qofi-codex-runtime/v2" ]; then
    case "$SWARM_CODEX_OPERATOR_CANARY_VALUE" in
      ''|*[!A-Za-z0-9_.:-]*)
        echo "Codex host preflight returned an invalid dedicated canary witness" >&2
        SWARM_CODEX_OPERATOR_CANARY_VALUE=""
        return 1 ;;
    esac
    if [ "${#SWARM_CODEX_OPERATOR_CANARY_VALUE}" -lt 16 ] || \
       [ "${#SWARM_CODEX_OPERATOR_CANARY_VALUE}" -gt 256 ]; then
      echo "Codex host preflight returned an invalid dedicated canary witness" >&2
      SWARM_CODEX_OPERATOR_CANARY_VALUE=""
      return 1
    fi
  fi
  SWARM_CODEX_HOME_EFFECTIVE="$SWARM_CODEX_CANONICAL_CODEX_HOME"
  export SWARM_CODEX_TRUSTED_BIN_REAL SWARM_CODEX_TRUSTED_BUN_REAL
  export SWARM_CODEX_ARGV_PREFIX
  export SWARM_CODEX_TOOL_PATH
  export SWARM_CODEX_CANONICAL_HOME SWARM_CODEX_CANONICAL_CODEX_HOME
  export SWARM_CODEX_CLI_VERSION SWARM_CODEX_HOME_EFFECTIVE
  export SWARM_CODEX_RUNTIME_UID SWARM_CODEX_RUNTIME_USER
  export SWARM_CODEX_RUNTIME_HOME SWARM_CODEX_RUNTIME_CODEX_HOME
  export SWARM_CODEX_RUNTIME_GID SWARM_CODEX_RUNTIME_GROUP
  export SWARM_CODEX_RUNNER SWARM_CODEX_RUNTIME_SCHEMA
  export SWARM_CODEX_OPERATOR_CANARY_VALUE
  return 0
}

swarm_codex_runtime_read() {  # name [max-age-seconds]
  local _name="$1" _max_age="${2:-${SWARM_CODEX_RUNTIME_MAX_AGE:-20}}"
  local _file _out _rc
  if swarm_codex_state_validate "$_name" read; then
    :
  else
    _rc=$?
    _file="${SWARM_CODEX_STATE_DIR:-$(swarm_codex_state_dir "$_name")}/runtime.json"
    SWARM_CODEX_RUNTIME_FILE="$_file"
    if [ "$_rc" -eq 1 ]; then
      SWARM_CODEX_RUNTIME_STATUS="missing"
      return 1
    fi
    SWARM_CODEX_RUNTIME_STATUS="unsafe"
    return 2
  fi
  _file="$SWARM_CODEX_STATE_DIR/runtime.json"

  SWARM_CODEX_RUNTIME_STATUS="unread"
  SWARM_CODEX_RUNTIME_FILE="$_file"
  SWARM_CODEX_RUNTIME_PID=""
  SWARM_CODEX_RUNTIME_READY=0
  SWARM_CODEX_RUNTIME_ACTIVE=0
  SWARM_CODEX_RUNTIME_QUEUE_DEPTH=0
  SWARM_CODEX_RUNTIME_CHILD_PID=""
  SWARM_CODEX_RUNTIME_AGE=""
  SWARM_CODEX_RUNTIME_LAST_COMPLETED_AGE=""
  SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT=""
  SWARM_CODEX_RUNTIME_LAST_ERROR=""

  [ -f "$_file" ] || { SWARM_CODEX_RUNTIME_STATUS="missing"; return 1; }
  case "$_max_age" in ''|*[!0-9]*) _max_age=20 ;; esac

  _out="$(/usr/bin/python3 -I -B - "$_file" "$_max_age" <<'PY'
import datetime as dt
import json
import os
import stat
import sys
import time
import unicodedata

path, max_age_s = sys.argv[1], int(sys.argv[2])

def clean(value):
    raw=str("" if value is None else value)
    out=[]
    for ch in raw:
        if ch == "|": out.append("%7C")
        elif unicodedata.category(ch).startswith("C"): out.append(" ")
        else: out.append(ch)
    return "".join(out)[:1000]

def epoch(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def fail():
    print("malformed|||||||||")
    raise SystemExit(2)

try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    fail()

if not isinstance(data, dict) or data.get("schema") != "codex-bridge-runtime/v1":
    fail()

pid = data.get("pid")
started = epoch(data.get("started_at"))
updated = epoch(data.get("updated_at"))
ready_value = data.get("ready")
active_value = data.get("active")
queue_value = data.get("queue_depth")
child_value = data.get("child_pid")
turn_value = data.get("turn_started_at")
completed_value = data.get("last_completed_at")
error_value = data.get("last_error")
backend = data.get("backend")
endpoint_value = data.get("app_server_endpoint")

if type(pid) is not int or pid <= 0 or started is None or updated is None:
    fail()
if type(ready_value) is not bool or type(active_value) is not bool:
    fail()
if type(queue_value) is not int or queue_value < 0:
    fail()
if child_value is not None and (type(child_value) is not int or child_value <= 0):
    fail()
turn = None if turn_value is None else epoch(turn_value)
completed = None if completed_value is None else epoch(completed_value)
if (turn_value is not None and turn is None) or (completed_value is not None and completed is None):
    fail()
if error_value is not None and not isinstance(error_value, str):
    fail()

def local_endpoint(value):
    if not isinstance(value, str) or not value:
        return False
    if "|" in value or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return False
    if not value.startswith("unix://"):
        return False
    socket_path = value[len("unix://"):]
    state_dir = os.path.dirname(path)
    try:
        if not os.path.isabs(socket_path) or os.path.normpath(socket_path) != socket_path:
            return False
        state_stat = os.lstat(state_dir)
        if (not stat.S_ISDIR(state_stat.st_mode) or stat.S_ISLNK(state_stat.st_mode)
                or state_stat.st_uid != os.getuid() or state_stat.st_mode & 0o077):
            return False
        real_state = os.path.realpath(state_dir)
        candidate = os.path.realpath(socket_path)
        if os.path.commonpath([real_state, candidate]) != real_state or candidate == real_state:
            return False
        parent = os.path.dirname(socket_path)
        while True:
            parent_stat = os.lstat(parent)
            if (not stat.S_ISDIR(parent_stat.st_mode) or stat.S_ISLNK(parent_stat.st_mode)
                    or parent_stat.st_uid != os.getuid() or parent_stat.st_mode & 0o077):
                return False
            if parent == state_dir:
                break
            next_parent = os.path.dirname(parent)
            if next_parent == parent or os.path.commonpath([real_state, os.path.realpath(next_parent)]) != real_state:
                return False
            parent = next_parent
        socket_stat = os.lstat(socket_path)
        return (stat.S_ISSOCK(socket_stat.st_mode) and socket_stat.st_uid == os.getuid()
                and not socket_stat.st_mode & 0o077)
    except (OSError, ValueError):
        return False

if backend == "exec":
    if endpoint_value is not None:
        fail()
    endpoint = ""
elif backend == "app-server":
    if not local_endpoint(endpoint_value):
        fail()
    endpoint = endpoint_value
else:
    fail()

now = time.time()
if updated > now + 5 or started > updated + 5:
    fail()
age = max(0, int(now - updated))
alive = True
try:
    os.kill(pid, 0)
except PermissionError:
    alive = True
except OSError:
    alive = False

last_age = "" if completed is None else str(max(0, int(now - completed)))
ready = "1" if ready_value else "0"
active = "1" if active_value else "0"
queue = queue_value
child = child_value if child_value is not None else ""
err = error_value if error_value is not None else ""

status = "healthy" if alive and age <= max_age_s else ("dead" if not alive else "stale")
print("|".join(map(clean, [status, pid, ready, active, queue, child, age, last_age, endpoint, err])))
raise SystemExit(0 if status == "healthy" else 3)
PY
)"; _rc=$?

  # Every field except human-readable strings is constrained by the producer /
  # parser above. `last_error` and endpoint have pipes/control chars sanitized.
  IFS='|' read -r \
    SWARM_CODEX_RUNTIME_STATUS \
    SWARM_CODEX_RUNTIME_PID \
    SWARM_CODEX_RUNTIME_READY \
    SWARM_CODEX_RUNTIME_ACTIVE \
    SWARM_CODEX_RUNTIME_QUEUE_DEPTH \
    SWARM_CODEX_RUNTIME_CHILD_PID \
    SWARM_CODEX_RUNTIME_AGE \
    SWARM_CODEX_RUNTIME_LAST_COMPLETED_AGE \
    SWARM_CODEX_RUNTIME_APP_SERVER_ENDPOINT \
    SWARM_CODEX_RUNTIME_LAST_ERROR <<EOF
$_out
EOF
  return "$_rc"
}

# Revalidate a native App Server endpoint immediately before handing it to
# `codex --remote`. Only a real owner-only Unix socket inside this swarm's
# owner-only state directory is accepted; loopback TCP is not an authenticated
# local transport and is deliberately rejected.
swarm_codex_endpoint_is_safe() {  # name unix://endpoint
  local state_dir endpoint
  state_dir="$(swarm_codex_state_dir "$1")"
  endpoint="$2"
  /usr/bin/python3 -I -B - "$state_dir" "$endpoint" <<'PY' >/dev/null 2>&1
import os, stat, sys
state_dir, endpoint = sys.argv[1:]
if not endpoint.startswith('unix://'):
    raise SystemExit(1)
candidate = endpoint[len('unix://'):]
if not os.path.isabs(candidate) or os.path.normpath(candidate) != candidate:
    raise SystemExit(1)
state_stat = os.lstat(state_dir)
if (not stat.S_ISDIR(state_stat.st_mode) or stat.S_ISLNK(state_stat.st_mode)
        or state_stat.st_uid != os.getuid() or state_stat.st_mode & 0o077):
    raise SystemExit(1)
real_state = os.path.realpath(state_dir)
real_candidate = os.path.realpath(candidate)
if os.path.commonpath([real_state, real_candidate]) != real_state or real_candidate == real_state:
    raise SystemExit(1)
parent = os.path.dirname(candidate)
while True:
    parent_stat = os.lstat(parent)
    if (not stat.S_ISDIR(parent_stat.st_mode) or stat.S_ISLNK(parent_stat.st_mode)
            or parent_stat.st_uid != os.getuid() or parent_stat.st_mode & 0o077):
        raise SystemExit(1)
    if parent == state_dir:
        break
    next_parent = os.path.dirname(parent)
    if next_parent == parent or os.path.commonpath([real_state, os.path.realpath(next_parent)]) != real_state:
        raise SystemExit(1)
    parent = next_parent
socket_stat = os.lstat(candidate)
if (not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_uid != os.getuid()
        or socket_stat.st_mode & 0o077):
    raise SystemExit(1)
PY
}

# ---------------------------------------------------------------------------
# 1) repo_activity — used by swarm-watch + swarm-typing + swarm-restart.
# ---------------------------------------------------------------------------
#
# Walks every Claude Code project dir associated with REPO_PATH — the lead's
# own dir AND every per-teammate worktree dir — recursively, including the
# subagents/ subdir where teammate transcripts live. Returns:
#
#     "<newest_age_seconds>|<active_teammate_count>"
#
# - newest_age_seconds: integer, ALWAYS NUMERIC. Real seconds-since-mtime
#   when a transcript exists; the sentinel SWARM_NO_TRANSCRIPT_AGE
#   (9999999 ≈ 115 days, larger than any plausible STALE_SECONDS) when
#   either NO jsonl exists at all (swarm just started) OR the scan
#   encountered an unrecoverable error. The function NEVER returns blank
#   — empty age would force every caller to add the same parsing branch
#   and the natural fail-mode of `[ "$age" -gt "$STALE_SECONDS" ]` would
#   silently flip to "fresh" on weird input. Fail-safe is silence; the
#   sentinel makes that automatic for any threshold-based predicate.
#   Callers that need to distinguish "no transcript yet" from "stale
#   transcript" compare `age == SWARM_NO_TRANSCRIPT_AGE` (see swarm-watch
#   and swarm-restart for the "🟡 starting" message).
# - active_teammate_count: number of distinct teammate worktree dirs whose
#   most recent jsonl is ≤ STALE_SECONDS old. 0 if none.
#
# Matching is by encoded-path prefix (Claude Code encodes a project's cwd by
# replacing every '/' and '.' with '-' and prepending '-'). Teammate worktree
# dirs match the prefix "<lead-encoded>--claude-worktrees-" so this never
# accidentally folds in a similarly-named sibling repo.
#
# Orphan-dir defense: a teammate transcript dir whose corresponding
# <repo>/.claude/worktrees/<name> no longer exists is skipped. Teardown
# (TEAM_LEAD.md §Worktree teardown) is the primary cleanup, but if it
# misses the transcript dir we still don't let stale teammate-only
# writes from a removed worktree poison the live signal.
SWARM_NO_TRANSCRIPT_AGE=9999999

repo_activity() {
  local repo="$1" projects="$2" stale="$3"
  python3 - "$repo" "$projects" "$stale" <<'PY'
import os, re, sys, time

NO_TRANSCRIPT = 9999999  # MUST match SWARM_NO_TRANSCRIPT_AGE in swarm-lib.sh.

try:
    repo, projects, stale = sys.argv[1], sys.argv[2], int(sys.argv[3])

    lead_enc = re.sub(r"[/.]", "-", repo)
    teammate_prefix = lead_enc + "--claude-worktrees-"

    now = time.time()
    newest_age = None
    teammate_newest = {}

    try:
        entries = os.listdir(projects)
    except FileNotFoundError:
        # No projects dir at all — fail-stale, never blank.
        print(f"{NO_TRANSCRIPT}|0")
        raise SystemExit(0)

    for entry in entries:
        is_lead = (entry == lead_enc)
        is_teammate = entry.startswith(teammate_prefix)
        if not (is_lead or is_teammate):
            continue
        if is_teammate:
            # Orphan check: skip teammate transcript dirs whose git
            # worktree has been torn down (see TEAM_LEAD.md §Worktree
            # teardown). Belt-and-suspenders to teardown removing the
            # transcript dir itself.
            wt_name = entry[len(teammate_prefix):]
            wt_path = os.path.join(repo, ".claude", "worktrees", wt_name)
            if not os.path.isdir(wt_path):
                continue
        try:
            walker = os.walk(os.path.join(projects, entry))
        except Exception:
            continue
        for root, _, files in walker:
            for f in files:
                if not f.endswith(".jsonl"):
                    continue
                try:
                    mt = os.path.getmtime(os.path.join(root, f))
                except OSError:
                    continue
                age = int(now - mt)
                if age < 0:
                    age = 0
                if newest_age is None or age < newest_age:
                    newest_age = age
                if is_teammate:
                    prev = teammate_newest.get(entry)
                    if prev is None or age < prev:
                        teammate_newest[entry] = age

    active = sum(1 for a in teammate_newest.values() if a <= stale)
    age_out = NO_TRANSCRIPT if newest_age is None else newest_age
    print(f"{age_out}|{active}")
except SystemExit:
    raise
except Exception as e:
    # Catastrophic path: never let the function return blank. The
    # liveness/typing predicates' fail-safe is silence; the sentinel
    # achieves that under any threshold-based check.
    sys.stderr.write(f"repo_activity: unexpected error: {e}\n")
    print(f"{NO_TRANSCRIPT}|0")
PY
}

# pane_working SESSION TMUX_BIN
#
# Inspect the live tmux pane for the Claude TUI footer that ONLY appears
# while a turn is in flight, and return tri-valued status:
#
#     0 — working  (capture succeeded AND footer contains "esc to interrupt")
#     1 — idle     (capture succeeded AND no "esc to interrupt" anywhere)
#     2 — uncertain (tmux missing, session absent, capture-pane failed,
#                    or empty output)
#
# Why footer-substring is the right signal: the spinner verb varies
# ("Caramelizing", "Thinking", "Baking", …) and past-tense recaps like
# "Crunched for 1m 28s" / "Worked for Ns" linger AFTER the turn finishes.
# Only the footer is a stable binary indicator — `… · esc to interrupt`
# while a turn is interruptible, `… · ← for agents` at the prompt.
#
# We grep the whole capture, not just the final line: a spinner or layout
# shift can re-flow the footer's position, but the substring presence
# survives. False positives (the literal string appearing in scrolled-back
# content) are not a practical concern — `esc to interrupt` is the TUI's
# interrupt hint, not a phrase users type into prompts.
#
# Fail-safe is silence: callers MUST treat anything other than rc=0 as
# "do not claim working". This fixes the original typing-at-idle bug —
# transcript age cannot distinguish "replied N seconds ago, now idle"
# from "actively producing"; the pane content can.
pane_working() {
  local sess="$1" tmux_bin="${2:-tmux}"
  command -v "$tmux_bin" >/dev/null 2>&1 || return 2
  local out
  out="$("$tmux_bin" capture-pane -t "$sess" -p 2>/dev/null)" || return 2
  [ -z "$out" ] && return 2
  printf '%s' "$out" | grep -qF 'esc to interrupt'
}

# pane_state SESSION TMUX_BIN
#
# A finer-grained variant of pane_working used by the active alerter in
# swarm-watch.sh. Distinguishes FIVE pane situations so the watcher can
# tell "the swarm is paused on a usage limit" apart from "the pane is in
# an unknown / unparseable state" — the original alerting bug was that
# both surface as `pane_working != 0` (idle), so a usage-throttled swarm
# read as "ready · waiting for input" and produced DEAD SILENCE.
#
# Exit codes:
#   0 — working      (footer contains "esc to interrupt")
#   1 — at-prompt    (footer contains "← for agents", i.e. clean prompt)
#   2 — paused-limit (capture contains a known Claude Code limit-message
#                     substring — see SWARM_LIMIT_PATTERNS below)
#   3 — unknown      (capture succeeded but matches none of the above —
#                     scrolled, sub-UI, or a TUI state we don't recognize)
#   4 — uncertain    (tmux missing, session absent, capture failed, empty)
#
# Side channel: when rc=2 (paused-limit) the matched limit-substring line
# is written to $SWARM_PANE_STATE_DETAIL (a shell global). The caller may
# read it to parse a reset time. Empty for any other return code.
#
# Limit substrings. These are the substrings Claude Code's TUI shows when
# a usage cap is hit; they are stable enough across versions to be useful
# matchers but specific enough that they don't appear in normal prompt
# content. The set is overridable via SWARM_LIMIT_PATTERNS (newline- or
# pipe-separated; each entry treated as a case-insensitive fixed string).
#
#   usage limit          — "Claude usage limit reached", "Approaching usage limit"
#   5-hour limit         — "5-hour limit reached · resets at 11pm"
#   limit reached        — generic suffix used across variants
#   rate limit           — provider-side rate limit surface
#   approaching usage    — early-warning variant
#
# Matching is case-insensitive (grep -i) and substring (grep -F). The
# whole capture is grep'd, not just the footer — limit messages render at
# various pane positions depending on the TUI's modal state.
SWARM_PANE_STATE_DETAIL=""

# Limit substrings that mean the account is CAPPED RIGHT NOW (a cap was HIT), not
# merely that a limit exists. The old set matched bare "usage limit", which also
# appears in Claude Code's INFORMATIONAL notices (e.g. "you can use up to 50% of
# your weekly usage limit on Fable 5") and in the leads' own conversation about
# rate limits — producing a false paused-limit verdict on every pane. These are
# narrowed to cap-HIT phrasings; benign mentions are additionally filtered by
# _swarm_default_limit_exclude_patterns below. Overridable via SWARM_LIMIT_PATTERNS.
_swarm_default_limit_patterns() {
  printf '%s\n' "usage limit reached"
  printf '%s\n' "limit reached"
  printf '%s\n' "reached your usage limit"
  printf '%s\n' "reached your limit"
  printf '%s\n' "rate limit exceeded"
  printf '%s\n' "you have hit your"
  printf '%s\n' "run out of"
}

# Benign lines that MENTION a limit word but are NOT a cap — an allowance/notice
# ("you can use up to N%"), not a hit. A limit-matching line that ALSO matches an
# exclusion here is dropped (a genuine cap line still wins if one is present).
# Overridable via SWARM_LIMIT_EXCLUDE_PATTERNS.
_swarm_default_limit_exclude_patterns() {
  printf '%s\n' "you can use up to"
  printf '%s\n' "can use up to"
}

pane_state() {
  local sess="$1" tmux_bin="${2:-tmux}"
  SWARM_PANE_STATE_DETAIL=""
  command -v "$tmux_bin" >/dev/null 2>&1 || return 4
  local out
  out="$("$tmux_bin" capture-pane -t "$sess" -p 2>/dev/null)" || return 4
  [ -z "$out" ] && return 4

  # Limit substrings checked FIRST: a session that just hit a cap may
  # still have a lingering spinner verb above the cap message; the cap
  # message wins (that's the actionable reality).
  local patterns_raw="${SWARM_LIMIT_PATTERNS:-}"
  local patterns
  if [ -n "$patterns_raw" ]; then
    # Operator override. Accept newline- OR pipe-separated entries.
    patterns="$(printf '%s' "$patterns_raw" | tr '|' '\n' | grep -v '^[[:space:]]*$')"
  else
    patterns="$(_swarm_default_limit_patterns)"
  fi
  # Benign-notice exclusion. A blank pattern line would make grep -f match every
  # line, so strip blanks from BOTH sets (an empty pattern set then matches
  # nothing, which is the correct fail-direction here — no false cap).
  local excl_raw="${SWARM_LIMIT_EXCLUDE_PATTERNS:-}"
  local excl
  if [ -n "$excl_raw" ]; then
    excl="$(printf '%s' "$excl_raw" | tr '|' '\n' | grep -v '^[[:space:]]*$')"
  else
    excl="$(_swarm_default_limit_exclude_patterns)"
  fi
  local hits real hit
  # ALL limit-matching lines (not -m1): a benign notice must not shadow a real
  # cap line elsewhere in the capture.
  hits="$(printf '%s' "$out" | grep -i -F -f <(printf '%s' "$patterns") 2>/dev/null)"
  if [ -n "$hits" ]; then
    # Drop lines that are benign informational notices. What survives is a real
    # cap-hit line, if any.
    if [ -n "$excl" ]; then
      real="$(printf '%s\n' "$hits" | grep -i -v -F -f <(printf '%s' "$excl") 2>/dev/null)"
    else
      real="$hits"
    fi
    if [ -n "$real" ]; then
      hit="$(printf '%s\n' "$real" | head -n 1)"
      # Trim ANSI / leading whitespace from the captured line for cleaner
      # downstream parsing. Best-effort; the raw line is fine too.
      hit="$(printf '%s' "$hit" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      SWARM_PANE_STATE_DETAIL="$hit"
      return 2
    fi
  fi

  if printf '%s' "$out" | grep -qF 'esc to interrupt'; then
    return 0
  fi
  if printf '%s' "$out" | grep -qF '← for agents'; then
    return 1
  fi
  return 3
}

# parse_limit_reset DETAIL
#
# Best-effort: read the limit-message line captured by pane_state and
# print a reset-time fragment to stdout (empty if nothing parseable).
# Looks for "resets at <X>" / "reset at <X>" / "resets <X>", stopping at
# the next bullet/pipe/period/newline. Used by the alerter to enrich the
# Discord push with a concrete reset hint when Claude Code provides one.
parse_limit_reset() {
  local detail="$1"
  [ -z "$detail" ] && return 0
  printf '%s' "$detail" | python3 -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"reset(?:s)?\s+(?:at\s+)?([^·|.\n]+)", s, re.IGNORECASE)
if m:
    val = m.group(1).strip().rstrip(",;:")
    # Cap to a reasonable length so weird captures cant blow up the alert.
    if len(val) > 60:
        val = val[:60] + "…"
    print(val)
' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 2) Manifest walker + per-class apply helpers.
# ---------------------------------------------------------------------------
#
# The manifest lives at $SWARM_HOME/templates/<type>/manifest.tsv where <type>
# is the swarm's archetype (resolved by swarm_type_of from .claude/swarm-type,
# default 'engineering-cto'). Each non-comment line is "behavior | src | tgt".
# See that file for what each behavior means.
#
# Consumers call manifest_apply REPO MODE with environment flags set; mode
# selects per-class policy (init / sync / onboard / check). Each class has
# its own helper so a new behavior is added in exactly two places (the
# manifest and a new manifest_apply_<class> function).
#
# Public surface:
#   manifest_walk     CALLBACK              — iterate lines, call CALLBACK <behavior> <src> <tgt>
#   manifest_apply    REPO MODE             — drive a full pass; MODE in {init,sync,onboard,check}
#   manifest_check    REPO                  — pure-report; alias for MODE=check
#
# MODE-policy flags (read from environment; absent = default):
#   SWARM_FORCE_DOCS          (onboard) overwrite refresh-class doctrine files even on conflict
#   SWARM_FORCE_HOOKS         (onboard) overwrite managed .claude/.codex hooks
#   SWARM_FORCE_PRECOMMIT     (onboard) overwrite foreign .git/hooks/pre-commit
#   SWARM_FORCE_SEED          (init)    re-seed PROJECT_SPEC.md and .claude/test-cmd
#   SWARM_FORCE_DIRTY         (sync, onboard) proceed despite dirty working tree
#   SWARM_DRY_RUN             (any)     report only, write nothing
#
# Side outputs (read by callers after manifest_apply):
#   SWARM_RESULT_CHANGED      "1" if any artifact actually changed on disk
#   SWARM_RESULT_COLLISIONS   newline-separated list of "<class>:<tgt>" entries that
#                             were refused due to collision (onboard)
#   SWARM_RESULT_FOREIGN_PRECOMMIT  "1" if a foreign pre-commit was encountered
#                                   (sync/init warn-and-skip; onboard refuses)
#
# All paths the helpers print are RELATIVE to the target repo, for readability.

# swarm_known_types — print the known archetype names, one per line.
# A type passed to swarm-init --type / swarm-new --type / swarm-add --type
# is validated against this list; an unknown type is refused so a typo
# (--type cpoo) cannot silently misclassify the swarm. Update this list
# when a new archetype is added under templates/.
swarm_known_types() {
  printf '%s\n' engineering-cto cpo company-brain
}

# swarm_type_is_known TYPE — return 0 iff TYPE is in swarm_known_types.
swarm_type_is_known() {
  local t="$1"
  swarm_known_types | grep -qxF "$t"
}

# swarm_type_of REPO
#
# Resolve a repo's archetype from the .claude/swarm-type marker file.
# Returns the type name on stdout. Defaults to 'engineering-cto' when the
# marker is absent or empty — so existing swarms (which were stamped
# before the per-type dispatch existed) keep getting engineering-cto
# doctrine without requiring a marker write. Whitespace stripped.
swarm_type_of() {
  local repo="$1"
  local marker="$repo/.claude/swarm-type"
  if [ -L "$repo/.claude" ] || \
     { [ -e "$repo/.claude" ] && [ ! -d "$repo/.claude" ]; } || \
     [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "swarm-lib: unsafe .claude/swarm-type marker — must be a regular non-symlink file" >&2
    return 2
  fi
  if [ -f "$marker" ]; then
    local t
    t="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$t" ]; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  printf '%s\n' "engineering-cto"
}

# swarm_known_profiles — print the known engineering-cto profile names, one
# per line. A profile is an ORTHOGONAL axis layered on top of the
# engineering-cto archetype (ADR-0013): it does not replace the archetype, it
# appends a stack-specific overlay to the composed CLAUDE.md only. A value
# passed to swarm-init/swarm-add/swarm-new --profile is validated against this
# list so a typo cannot silently misclassify. 'backend' is intentionally
# present but LABEL-ONLY in v1 (today's engineering-cto IS the backend case),
# so it ships no overlay fragment; 'frontend' is the only profile with overlay
# content. Update this list when a new profile overlay is added under
# templates/engineering-cto/profiles/.
swarm_known_profiles() {
  printf '%s\n' frontend backend
}

# swarm_profile_is_known PROFILE — return 0 iff PROFILE is in
# swarm_known_profiles.
swarm_profile_is_known() {
  local p="$1"
  swarm_known_profiles | grep -qxF "$p"
}

# swarm_profile_of REPO
#
# Resolve a repo's profile from the .claude/swarm-profile marker file.
# Returns the profile name on stdout, or the EMPTY string when the marker is
# absent or empty. Unlike swarm_type_of (which defaults to engineering-cto),
# an absent profile resolves to NO profile — so a markerless swarm composes
# byte-identically to a pre-profile swarm (ADR-0013: the no-op default that
# keeps existing swarms untouched; do NOT change this to default to a value).
# Whitespace stripped.
swarm_profile_of() {
  local repo="$1"
  local marker="$repo/.claude/swarm-profile"
  if [ -L "$repo/.claude" ] || \
     { [ -e "$repo/.claude" ] && [ ! -d "$repo/.claude" ]; } || \
     [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "swarm-lib: unsafe .claude/swarm-profile marker — must be a regular non-symlink file" >&2
    return 2
  fi
  if [ -f "$marker" ]; then
    local p
    p="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  printf '%s' ""
}

# swarm_canon_mode_of REPO
#
# Resolve a repo's source-of-truth mode from the .claude/canon-mode marker.
# Returns 'external' only when the marker exists and says so; ANYTHING else
# (absent marker, empty, 'local', junk) resolves to 'local' — the no-op
# default that keeps every existing swarm byte-identical (same posture as
# swarm_profile_of; do NOT change the default). Whitespace stripped.
swarm_canon_mode_of() {
  local repo="$1"
  local marker="$repo/.claude/canon-mode"
  if [ -L "$repo/.claude" ] || \
     { [ -e "$repo/.claude" ] && [ ! -d "$repo/.claude" ]; } || \
     [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "swarm-lib: unsafe .claude/canon-mode marker — must be a regular non-symlink file" >&2
    return 2
  fi
  if [ -f "$marker" ]; then
    local m
    m="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ "$m" = "external" ]; then
      printf 'external\n'
      return 0
    fi
  fi
  printf 'local\n'
}

# swarm_required_doctrine TYPE
#
# Emit the doctrine filenames (relative to the swarm repo root, one per
# line) that swarm-up's gate (c) must see stamped before it agrees to
# launch a swarm of this type. The list is INTENTIONALLY data-driven
# per archetype so adding a new type means adding a case here, not
# reopening swarm-up.sh.
#
# Unknown / future types FALL THROUGH to the engineering-cto triad
# (CLAUDE.md + ESCALATION.md + TEAM_LEAD.md). This is the fail-safe
# direction: a swarm with a misclassified or future marker still gets
# refused (with a clear "TEAM_LEAD.md missing" error) rather than
# silently launching a swarm whose doctrine never landed.
swarm_required_doctrine() {
  case "$1" in
    cpo)
      printf '%s\n' CLAUDE.md ESCALATION.md
      ;;
    engineering-cto|*)
      printf '%s\n' CLAUDE.md ESCALATION.md TEAM_LEAD.md
      ;;
  esac
}

# swarm_launch_brief TYPE
#
# Emit the initial brief swarm-up's launch_one() sends into the tmux
# pane right after `claude` finishes booting. The brief is the agent's
# first instruction set and frames its role; engineering-cto and cpo
# have fundamentally different roles, so each archetype owns its own
# brief.
#
# Unknown / future types fall through to engineering-cto for the same
# fail-safe reason as swarm_required_doctrine: a misclassified swarm
# at least gets the engineering brief (a known-good orientation),
# rather than launching with no instructions at all.
#
# Both briefs open with an explicit READ-YOURSELF-DO-NOT-DELEGATE clause.
# This is load-bearing, not boilerplate: launch_one sends `/effort
# ultracode` BEFORE this brief (swarm-up.sh), and under ultracode the lead
# defaults to fanning every substantive task out to a workflow/subagents.
# Without the clause, the lead reads its doctrine in ephemeral subagent
# contexts that are discarded — TEAM_LEAD.md / ESCALATION.md /
# PROJECT_SPEC.md (none auto-loaded; only CLAUDE.md is) never land in the
# lead's own context and it boots without its operating manual. Keep the
# clause unless ultracode is moved to AFTER the brief.
swarm_launch_brief() {
  case "$1" in
    cpo)
      printf '%s' "Read CLAUDE.md, ESCALATION.md, CONVERSATION.md, EVALUATION.md, SURFACING.md, MEMORY.md, READINESS_BAR.md NOW, yourself, directly with the file-reading tool — read them into your OWN context. Do NOT delegate this to a workflow or to subagents: your operating doctrine must live in your context, not an ephemeral one, so read the files inline before doing anything else. You are the CPO for this product-vision repo; operate per CLAUDE.md. The operator will hold the product conversation with you over Discord. You write into products/<product>/<facet>.md via the refine → ratify → write protocol in MEMORY.md. Do NOT act as an engineering team lead and do NOT execute engineering work — that is the CTOs' lane."
      ;;
    engineering-cto|*)
      printf '%s' "Read TEAM_LEAD.md, ESCALATION.md, CLAUDE.md and PROJECT_SPEC.md NOW, yourself, directly with the file-reading tool — read them into your OWN context. Do NOT delegate this to a workflow or to subagents: your operating doctrine must live in your context, not an ephemeral one, so read the files inline before doing anything else. You are the team lead (CTO) for this repo; operate per TEAM_LEAD.md. The human will hold a product design conversation with you over Discord and the spec may be empty for now — do NOT build during the conversation. When the human says to build, first author PROJECT_SPEC.md and the one-way-door ADRs from the conversation, confirm them with the human, then decompose and spawn the team. Keep the docs reconciled with the implementation as it proceeds, and message the human for any major spec decision."
      ;;
  esac
}

# swarm_effort_for TYPE
#
# Emit the `/effort` command swarm-up's launch_one() sends into the tmux pane
# right after `claude` boots, per archetype. The CPO swarm is a single
# conversational product agent that should NOT fan every turn out to a workflow,
# so it launches at medium effort; every engineering CTO swarm stays on ultracode
# (xhigh effort + automatic workflow orchestration). Effort is SESSION-ONLY
# (ultracode has no settings.json / env / --effort form — see launch_one), which
# is why it is a launch-time `/effort` send rather than config, and why this
# helper is the single tuning point for per-archetype effort.
#
# Unknown / future types fall through to ultracode — the same fail-safe direction
# as swarm_required_doctrine / swarm_launch_brief: a misclassified or future
# swarm gets the engineering path, never a silent downgrade.
swarm_effort_for() {
  case "$1" in
    cpo)
      printf '%s' "/effort medium"
      ;;
    engineering-cto|*)
      printf '%s' "/effort ultracode"
      ;;
  esac
}

# swarm_account_resolve LABEL — resolve an account label to ITS config dir,
# projects dir, access.json, and vault token-var name. SINGLE SOURCE OF TRUTH:
# every consumer that needs an account's paths/token derives all four from here
# and NEVER hand-constructs a $HOME/.claude path. A missed site silently reads
# the WRONG account's transcripts → the WORKING rail (repo_activity) disarms →
# a live swarm is killed. A repo-wide grep-assert (tests/test-account-paths-
# sole-constructor.sh) pins this function as the sole builder of those paths.
#
# Empty label = the DEFAULT account = today's behavior, byte-for-byte:
#   CONFIG_DIR  $HOME/.claude          (keychain auth; no token var)
#   PROJECTS    $HOME/.claude/projects
#   ACCESS      $HOME/.claude/channels/discord/access.json
#   TOKEN_VAR   ""   (empty → launch_one keeps keychain auth, no token export)
# A non-empty <label> maps to an ISOLATED config dir + a vault token var:
#   CONFIG_DIR  $HOME/.claude-accounts/<label>
#   TOKEN_VAR   OAUTH_TOKEN_<LABEL_UPPER>   (lowercase→UPPER, '-'→'_')
# CAVEAT (provisioning footgun, ADR-0018): the '-'→'_' fold means two labels that
# differ ONLY by '-' vs '_' (e.g. 'max-a' and 'max_a') collapse to the SAME token
# var (OAUTH_TOKEN_MAX_A) while keeping DISTINCT config dirs — a wrong-credential
# risk. Operators must not create two accounts whose labels differ only by '-'/'_'.
#
# Sets (does not echo): SWARM_ACCT_CONFIG_DIR, SWARM_ACCT_PROJECTS_DIR,
# SWARM_ACCT_ACCESS_FILE, SWARM_ACCT_TOKEN_VAR. Returns 0; 2 on a malformed
# label (rejected BEFORE any path is built — a bad label must never name a dir).
SWARM_ACCT_CONFIG_DIR=""
SWARM_ACCT_PROJECTS_DIR=""
SWARM_ACCT_ACCESS_FILE=""
SWARM_ACCT_TOKEN_VAR=""
swarm_account_resolve() {
  local label="${1:-}"
  if [ -z "$label" ]; then
    # The DEFAULT account PRESERVES the env overrides the consumers honor today,
    # so threading them through the resolver stays byte-identical:
    #   CLAUDE_PROJECTS_DIR — the WORKING-rail projects dir (watch/restart/rotate/typing)
    #   SWARM_ACCESS_FILE   — the access.json path (bus-wire/doctor; up/add/remove were
    #                         bare → now uniformly honor it, identical when unset).
    # LABELED accounts are isolated and ignore both (each lives under its own dir),
    # so an override can never leak a labeled lane onto the default's transcripts.
    SWARM_ACCT_CONFIG_DIR="$HOME/.claude"
    SWARM_ACCT_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    SWARM_ACCT_ACCESS_FILE="${SWARM_ACCESS_FILE:-$HOME/.claude/channels/discord/access.json}"
    SWARM_ACCT_TOKEN_VAR=""
    return 0
  fi
  # Validate the handle BEFORE building any path (same shape swarm-account-state
  # trusts): leading alpha, then only [A-Za-z0-9_-].
  case "$label" in
    [A-Za-z]*) ;;
    *) echo "swarm_account_resolve: invalid account label '$label' (need [A-Za-z][A-Za-z0-9_-]*)" >&2; return 2 ;;
  esac
  case "$label" in
    *[!A-Za-z0-9_-]*) echo "swarm_account_resolve: invalid account label '$label' (need [A-Za-z][A-Za-z0-9_-]*)" >&2; return 2 ;;
  esac
  SWARM_ACCT_CONFIG_DIR="$HOME/.claude-accounts/$label"
  SWARM_ACCT_PROJECTS_DIR="$SWARM_ACCT_CONFIG_DIR/projects"
  SWARM_ACCT_ACCESS_FILE="$SWARM_ACCT_CONFIG_DIR/channels/discord/access.json"
  SWARM_ACCT_TOKEN_VAR="OAUTH_TOKEN_$(printf '%s' "$label" | tr 'a-z-' 'A-Z_')"
  return 0
}

# Cooperative global lifecycle/mutation lock for swarm.conf. Every in-tree
# writer plus launch/stop uses this one lock namespace, so account changes,
# registration/migration, launch, and removal cannot cross each other's config,
# repository, or runtime-authority transitions. Existing locks fail closed;
# locks fail closed, including a dead owner: this mutex spans config plus
# repository/runtime-authority transactions, so PID death alone cannot prove
# that it is safe to discard the incomplete-transaction signal. Recovery is an
# explicit operator audit, never an automatic recursive deletion.
SWARM_CONF_LOCK_CONF=""
SWARM_CONF_LOCK_DIR=""
SWARM_CONF_LOCK_DEPTH=0
SWARM_CONF_LOCK_EVIDENCE=""
SWARM_CONF_LOCK_HELPER=""

# Resolve the atomic directory-lock helper relative to this library's physical
# source path. Callers often source swarm-lib.sh through a symlink in hermetic
# fixtures or installed wrappers; resolving from the caller script would then
# select a partial/copied bin directory and silently disable lifecycle locks.
# SWARM_ATOMIC_LOCK_BIN remains the explicit test/packaging override.
swarm_atomic_lock_helper_path() {
  local _helper="${SWARM_ATOMIC_LOCK_BIN:-}"
  if [ -n "$_helper" ]; then
    printf '%s\n' "$_helper"
    return 0
  fi
  /usr/bin/python3 -I -B - "${BASH_SOURCE[0]}" <<'PY'
import os, sys
print(os.path.join(os.path.dirname(os.path.realpath(sys.argv[1])), "atomic-directory-lock.py"))
PY
}

swarm_conf_lock_acquire() {  # conf
  local conf="$1" lock="" helper parent base acquire_error acquire_rc
  # Normalize only the containing-directory spelling before handing the path
  # to the strict atomic publisher. macOS commonly exports TMPDIR with a
  # trailing slash; callers that append another slash must still coordinate on
  # the same lock inode. Dot/dot-dot and symlinked parents collapse through the
  # physical directory here, while the config basename remains unchanged.
  case "$conf" in
    */*) parent="${conf%/*}"; base="${conf##*/}" ; [ -n "$parent" ] || parent="/" ;;
    *) parent="."; base="$conf" ;;
  esac
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || {
    echo "swarm.conf lock: config parent cannot be resolved safely ($conf)" >&2
    return 1
  }
  conf="${parent%/}/$base"
  lock="$conf.mutation.lock"
  if [ "$SWARM_CONF_LOCK_DEPTH" -gt 0 ]; then
    [ "$SWARM_CONF_LOCK_CONF" = "$conf" ] || {
      echo "swarm.conf lock: process already holds a different config lock" >&2
      return 1
    }
    SWARM_CONF_LOCK_DEPTH=$((SWARM_CONF_LOCK_DEPTH + 1))
    return 0
  fi
  helper="$(swarm_atomic_lock_helper_path)" || {
    echo "swarm.conf lock: could not resolve the trusted atomic lock publisher" >&2
    return 1
  }
  if acquire_error="$(printf '%s\n' "$$" | /usr/bin/python3 -I -B "$helper" "$lock" owner 2>&1)"; then
    acquire_rc=0
  else
    acquire_rc=$?
  fi
  if [ "$acquire_rc" -ne 0 ]; then
    if [ "$acquire_rc" -eq 17 ]; then
      echo "swarm.conf lock: mutation/incomplete transaction already exists ($lock); audit before explicit recovery" >&2
    else
      [ -z "$acquire_error" ] || printf '%s\n' "$acquire_error" >&2
      echo "swarm.conf lock: could not atomically publish transaction lock ($lock); no mutation started" >&2
    fi
    return 1
  fi
  SWARM_CONF_LOCK_EVIDENCE="$(/usr/bin/python3 -I -B - "$lock" <<'PY'
import hashlib, os, stat, sys
lock=sys.argv[1]; owner=os.path.join(lock, 'owner')
l=os.lstat(lock); o=os.lstat(owner)
if (not stat.S_ISDIR(l.st_mode) or stat.S_ISLNK(l.st_mode) or stat.S_IMODE(l.st_mode) != 0o700
        or not stat.S_ISREG(o.st_mode) or stat.S_ISLNK(o.st_mode) or stat.S_IMODE(o.st_mode) != 0o600
        or l.st_uid != os.getuid() or o.st_uid != os.getuid()): raise SystemExit(2)
fd=os.open(owner, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
try:
    before=os.fstat(fd); raw=os.read(fd, 16385); after=os.fstat(fd)
finally: os.close(fd)
if (len(raw) > 16384 or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) !=
        (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)):
    raise SystemExit(2)
print(l.st_dev,l.st_ino,o.st_dev,o.st_ino,hashlib.sha256(raw).hexdigest())
PY
)" || {
    echo "swarm.conf lock: published transaction owner could not be bound; lock retained for audited recovery" >&2
    return 1
  }
  SWARM_CONF_LOCK_CONF="$conf"
  SWARM_CONF_LOCK_DIR="$lock"
  SWARM_CONF_LOCK_HELPER="$helper"
  SWARM_CONF_LOCK_DEPTH=1
  return 0
}

swarm_conf_lock_release() {
  [ "$SWARM_CONF_LOCK_DEPTH" -gt 0 ] || return 0
  SWARM_CONF_LOCK_DEPTH=$((SWARM_CONF_LOCK_DEPTH - 1))
  [ "$SWARM_CONF_LOCK_DEPTH" -eq 0 ] || return 0
  local _ld _li _od _oi _hash _rc=0
  read -r _ld _li _od _oi _hash <<EOF
$SWARM_CONF_LOCK_EVIDENCE
EOF
  if [ -z "$_hash" ] || ! /usr/bin/python3 -I -B "$SWARM_CONF_LOCK_HELPER" release \
      "$SWARM_CONF_LOCK_DIR" owner "$_ld" "$_li" "$_od" "$_oi" "$_hash" -; then
    echo "swarm.conf lock: CRITICAL — exact transaction lock release failed; retained for audited recovery" >&2
    _rc=1
  fi
  SWARM_CONF_LOCK_CONF=""
  SWARM_CONF_LOCK_DIR=""
  SWARM_CONF_LOCK_EVIDENCE=""
  SWARM_CONF_LOCK_HELPER=""
  return "$_rc"
}

# swarm_conf_set_account CONF NAME ACCOUNT — atomically rewrite field 6 (ACCOUNT)
# of the swarm.conf row whose field-1 (name) trims to NAME, leaving every other
# row, comment, and blank line BYTE-for-byte untouched. This is the per-swarm
# persistence of a failover swap (ADR-0018): the conf rewrite IS the durable
# "which account is this swarm on" — it sticks across restarts until the next cap.
#
# Reuses swarm-remove.sh's awk temp→mv idiom (comments/blanks/non-matching rows
# pass through verbatim via the raw $0/$i fields), adapted to REWRITE field 6
# instead of deleting the row. Arity-safe across legacy widths (tightening #2):
#   - 4-/5-column rows are PADDED so the account always lands in field 6 (a 4-col
#     row gains an empty guild field-5 so positions don't shift);
#   - 6-column rows have field 6 replaced;
#   - any field 7+ (the parser's _rest catch-all) is preserved verbatim.
# Fields 1..5 are emitted from the RAW split ($i still carries each field's own
# surrounding whitespace), so the operator's column spacing on this row's other
# fields is preserved; only field 6 is (re)written.
#
# An EMPTY ACCOUNT restores the row to the DEFAULT account: a row that already had
# no account (≤5 cols) is left verbatim. A 6-col row drops field 6. A 7+-col row
# must retain an explicit empty field-6 delimiter so ENGINE and any future fields
# stay at their original indexes.
#
# Returns 0 on a successful rewrite (atomic mv), 1 if NAME matched no data row
# (conf left untouched), 2 on a write/mv failure. The CALLER validates the ACCOUNT
# label (via swarm_account_resolve) — this helper is purely mechanical.
swarm_conf_set_account() {
  local _conf="$1" _name="$2" _acct="${3:-}"
  local _tmp="$_conf.tmp.$$"
  swarm_conf_lock_acquire "$_conf" || return 2
  awk -F'|' -v n="$_name" -v acct="$_acct" '
    /^[[:space:]]*(#|$)/ { print; next }
    {
      v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != n) { print; next }
      found=1
      if (acct == "") {
        if (NF <= 5) { print; next }          # already default → verbatim
        out=$1
        for (i=2; i<=5; i++) out = out "|" $i # drop field 6 on a 6-col row
        if (NF >= 7) out = out "|"             # preserve empty ACCOUNT slot
        for (i=7; i<=NF; i++) out = out "|" $i
        print out; next
      }
      out=$1
      for (i=2; i<=5; i++) out = out "|" (i<=NF ? $i : "")   # pad short rows to col 5
      out = out "| " acct
      for (i=7; i<=NF; i++) out = out "|" $i                 # preserve any 7+ verbatim
      print out
    }
    END { exit (found ? 0 : 1) }
  ' "$_conf" > "$_tmp"
  local _rc=$?
  if [ "$_rc" -ne 0 ]; then rm -f "$_tmp"; swarm_conf_lock_release; return 1; fi      # NAME not found → no change
  if ! mv "$_tmp" "$_conf"; then rm -f "$_tmp"; swarm_conf_lock_release; return 2; fi
  swarm_conf_lock_release
  return 0
}

# swarm_codex_profiles_validate CATALOG [POOL]
#   Validate the committed, non-secret Codex profile registry and optionally
#   require POOL to exist. The accepted shape is deliberately exact so a typo
#   cannot silently change sharing or rotation policy. Profile labels and pool
#   names are canonical runtime handles, never filesystem paths.
swarm_codex_profiles_validate() {
  local _catalog="$1" _pool="${2:-}"
  /usr/bin/python3 -I -B - "$_catalog" "$_pool" <<'PY'
import json, math, os, stat, sys

path, requested_pool = sys.argv[1:3]
label_chars = frozenset("abcdefghijklmnopqrstuvwxyz0123456789_-")

def label(value):
    return (isinstance(value, str) and 1 <= len(value) <= 32
            and value[0] in "abcdefghijklmnopqrstuvwxyz"
            and all(char in label_chars for char in value))

try:
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_size > 128 * 1024:
        raise ValueError("catalog is not a bounded regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        raw = os.read(fd, 128 * 1024 + 1)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size,
                              value.st_mtime_ns, value.st_ctime_ns)
    if len(raw) > 128 * 1024 or identity(before) != identity(after):
        raise ValueError("catalog changed while being read")
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"schema", "profiles", "pools"}:
        raise ValueError("catalog keys are not exact")
    if value["schema"] != "qofi-codex-profiles/v1":
        raise ValueError("unsupported catalog schema")
    profiles = value["profiles"]
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("profiles must be a non-empty ordered array")
    known = set()
    default_shared = False
    for entry in profiles:
        if not isinstance(entry, dict) or set(entry) != {"label", "shared"}:
            raise ValueError("profile keys are not exact")
        profile = entry["label"]
        if not label(profile) or type(entry["shared"]) is not bool or profile in known:
            raise ValueError("invalid or duplicate profile")
        known.add(profile)
        if profile == "default":
            default_shared = entry["shared"] is True
    if not default_shared:
        raise ValueError("default profile must exist and be explicitly shared")
    pools = value["pools"]
    if not isinstance(pools, dict) or not pools:
        raise ValueError("pools must be a non-empty object")
    for pool, declaration in pools.items():
        if not label(pool) or not isinstance(declaration, dict) \
                or set(declaration) not in ({"profiles"}, {"profiles", "thresholdPercent"}):
            raise ValueError("invalid pool declaration")
        ordered = declaration["profiles"]
        threshold = declaration.get("thresholdPercent", 95)
        if not isinstance(ordered, list) or not ordered \
                or any(not label(item) or item not in known for item in ordered) \
                or len(set(ordered)) != len(ordered):
            raise ValueError("pool profiles must be ordered, unique known labels")
        if type(threshold) not in (int, float) or not math.isfinite(threshold) \
                or threshold <= 0 or threshold > 100:
            raise ValueError("pool thresholdPercent must be in (0, 100]")
    if "default" not in pools or "default" not in pools["default"]["profiles"]:
        raise ValueError("default pool must include the default profile")
    if requested_pool and requested_pool not in pools:
        raise ValueError("requested pool is not declared")
except (OSError, OverflowError, ValueError, TypeError, json.JSONDecodeError) as error:
    print(f"Codex profile catalog refused: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# swarm_conf_set_codex_auth_pool CONF NAME POOL — atomically rewrite the
# distinct field-8 Codex pool selector while preserving ACCOUNT (field 6),
# ENGINE (field 7), all trailing fields, and every non-target byte. POOL must
# already have been validated against codex-profiles.json by the caller.
swarm_conf_set_codex_auth_pool() {
  local _conf="$1" _name="$2" _pool="${3:-default}"
  local _tmp="$_conf.tmp.$$"
  case "$_pool" in
    [!a-z]*|*[!a-z0-9_-]*) return 2 ;;
  esac
  [ "${#_pool}" -le 32 ] || return 2
  swarm_conf_lock_acquire "$_conf" || return 2
  awk -F'|' -v n="$_name" -v pool="$_pool" '
    /^[[:space:]]*(#|$)/ { print; next }
    {
      v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != n) { print; next }
      found=1
      out=$1
      for (i=2; i<=7; i++) out = out "|" (i<=NF ? $i : "")
      out = out "| " pool
      for (i=9; i<=NF; i++) out = out "|" $i
      print out
    }
    END { exit (found ? 0 : 1) }
  ' "$_conf" > "$_tmp"
  local _rc=$?
  if [ "$_rc" -ne 0 ]; then rm -f "$_tmp"; swarm_conf_lock_release; return 1; fi
  if ! mv "$_tmp" "$_conf"; then rm -f "$_tmp"; swarm_conf_lock_release; return 2; fi
  swarm_conf_lock_release
  return 0
}

# swarm_bound_channels NAME CHANNEL — print every effective bound channel, one
# per line. This is also the ACL reconciliation set for Codex: a CPO must carry
# both its operator channel and the bus, while every other row remains single-
# bound. Empty legacy channels produce no lines.
swarm_bound_channels() {
  local name="$1" channel="$2" archetype="${3:-}"
  local cpo_name="${SWARM_CPO_NAME:-qofi-product}"
  local bus="${SWARM_BUS_CHANNEL:-1510301812434141194}"
  [ -n "$channel" ] || return 0
  printf '%s\n' "$channel"
  if { [ "$archetype" = "cpo" ] || [ "$name" = "$cpo_name" ]; } && \
     [ "$bus" != "$channel" ]; then
    printf '%s\n' "$bus"
  fi
}

# swarm_bound_exports NAME CHANNEL — emit the shell `export` statements that
# scope a swarm's Discord bridge binding. ALL swarms get DISCORD_BOUND_CHANNEL =
# their own channel (single-bound, unchanged). The ONE exception is the CPO
# swarm (name matches $SWARM_CPO_NAME, default "qofi-product"): it is bound to
# the UNION of its operator channel + the bus, and additionally gets the role
# env vars so doctrine's register-by-channel can compare a message's source id
# against DISCORD_OPERATOR_CHANNEL vs DISCORD_BUS_CHANNEL. The CPO name and bus
# id are the only deployment-specific values; both are env-overridable so this
# shared lib stays portable. Single source of truth: binding and role env are
# derived together here, so they can't disagree. A CTO swarm NEVER reaches this
# branch — its binding is exactly its own channel and it gets no bus access.
swarm_bound_exports() {
  local name="$1" channel="$2" archetype="${3:-}"
  local cpo_name="${SWARM_CPO_NAME:-qofi-product}"
  local bus="${SWARM_BUS_CHANNEL:-1510301812434141194}"
  if [ -n "$channel" ] && { [ "$archetype" = "cpo" ] || [ "$name" = "$cpo_name" ]; }; then
    local bound="" _bound_channel
    while IFS= read -r _bound_channel; do
      [ -z "$_bound_channel" ] || bound="${bound:+$bound,}$_bound_channel"
    done < <(swarm_bound_channels "$name" "$channel" "$archetype")
    printf "export DISCORD_OPERATOR_CHANNEL='%s'; export DISCORD_BUS_CHANNEL='%s'; export DISCORD_BOUND_CHANNEL='%s'" \
      "$channel" "$bus" "$bound"
  else
    # Every non-CPO swarm (and the legacy empty-channel row): single-bound, no
    # operator/bus role env. Empty channel → empty bind (prior behavior).
    printf "export DISCORD_BOUND_CHANNEL='%s'" "$channel"
  fi
}

# Resolve and verify the manifest file for a given archetype. Refuses
# (caller-side) to run if it's missing — caller checks file existence
# after this returns.
swarm_manifest_path() {
  local type="${1:-engineering-cto}"
  printf '%s\n' "$SWARM_HOME/templates/$type/manifest.tsv"
}

# Manifest and marker paths cross a trust boundary: the selected archetype and
# profile live in the target repository, while this host-side library runs with
# the operator's authority.  Keep every selection/source beneath templates and
# every target beneath the repository before the first apply helper can write.
_swarm_safe_relative_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  case "$path" in
    /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*/) return 1 ;;
  esac
  printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
  return 0
}

_swarm_safe_marker_name() {
  case "$1" in
    [A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9_-]*) return 0 ;;
  esac
  return 1
}

_swarm_template_source_is_safe() {
  local rel="$1" root parent root_real parent_real path
  _swarm_safe_relative_path "$rel" || return 1
  root="$SWARM_HOME/templates"
  path="$root/$rel"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  root_real="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  parent="$(dirname "$path")"
  parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  case "$parent_real/" in
    "$root_real/"*) return 0 ;;
  esac
  return 1
}

_swarm_authority_file_is_trusted() {  # path
  local path="$1" mode bits uid nlink
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode="$(_swarm_stat_mode "$path")" || return 1
  uid="$(_swarm_stat_uid "$path")" || return 1
  nlink="$(_swarm_stat_nlink "$path")" || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  bits=$((0$mode))
  [ "$uid" = "$(id -u)" ] && [ "$nlink" = "1" ] && \
    [ $((bits & 0400)) -ne 0 ] && \
    [ $((bits & 0022)) -eq 0 ] && \
    [ $((bits & 07000)) -eq 0 ] && \
    _swarm_file_acl_is_safe "$path"
}

_swarm_target_path_is_safe() {
  local rel="$1" current parent component old_ifs target nlink
  _swarm_safe_relative_path "$rel" || return 1
  current="$SWARM_APPLY_REPO"
  [ -d "$current" ] && [ ! -L "$current" ] || return 1
  parent="$(dirname "$rel")"
  if [ "$parent" != "." ]; then
    old_ifs="$IFS"
    IFS='/'
    set -- $parent
    IFS="$old_ifs"
    for component in "$@"; do
      current="$current/$component"
      if [ -L "$current" ]; then
        return 1
      fi
      if [ -e "$current" ] && [ ! -d "$current" ]; then
        echo "  ERROR: unsafe manifest target parent for $rel: $current is not a directory" >&2
        return 1
      fi
      # Once an ancestor is absent, mkdir -p will create the remaining
      # normalized components beneath the last proven real directory.
      [ -e "$current" ] || break
    done
  fi
  target="$SWARM_APPLY_REPO/$rel"
  if [ -L "$target" ]; then
    echo "  ERROR: unsafe manifest target path: $rel (target is a symlink)" >&2
    return 1
  fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    echo "  ERROR: unsafe manifest target path: $rel (target is not a regular file)" >&2
    return 1
  fi
  if [ -f "$target" ]; then
    nlink="$(_swarm_stat_nlink "$target")" || {
      echo "  ERROR: unsafe manifest target path: $rel (could not inspect link count)" >&2
      return 1
    }
    if [ "$nlink" != "1" ]; then
      echo "  ERROR: unsafe manifest target path: $rel (target has $nlink hard links)" >&2
      return 1
    fi
  fi
  return 0
}

_swarm_validate_repo_markers() {
  local repo="$1" marker_dir marker
  marker_dir="$repo/.claude"
  if [ -L "$marker_dir" ] || { [ -e "$marker_dir" ] && [ ! -d "$marker_dir" ]; }; then
    echo "swarm-lib: unsafe .claude marker directory — must be a real directory" >&2
    return 1
  fi
  for marker in swarm-type swarm-profile canon-mode; do
    if [ -L "$marker_dir/$marker" ] || \
       { [ -e "$marker_dir/$marker" ] && [ ! -f "$marker_dir/$marker" ]; }; then
      echo "swarm-lib: unsafe .claude/$marker marker — must be a regular non-symlink file" >&2
      return 1
    fi
  done
  return 0
}

_swarm_validate_apply_selection() {
  local type="${SWARM_APPLY_TYPE:-engineering-cto}" profile="${SWARM_APPLY_PROFILE:-}" manifest
  if ! _swarm_safe_marker_name "$type"; then
    echo "swarm-lib: unsafe swarm type marker '$type' — aborting" >&2
    return 1
  fi
  # "Known" is installation-local: a safe identifier backed by a real,
  # contained templates/<type>/manifest.tsv. This preserves extensible
  # archetypes while preventing a repo marker from selecting an arbitrary file.
  manifest="$(swarm_manifest_path "$type")"
  if ! _swarm_template_source_is_safe "$type/manifest.tsv" || \
     [ "$manifest" != "$SWARM_HOME/templates/$type/manifest.tsv" ]; then
    echo "swarm-lib: unknown or unsafe swarm type '$type' — manifest unavailable" >&2
    return 1
  fi
  if [ -n "$profile" ]; then
    if [ "$type" != "engineering-cto" ] || \
       ! _swarm_safe_marker_name "$profile" || \
       ! swarm_profile_is_known "$profile"; then
      echo "swarm-lib: unknown or invalid swarm profile '$profile' for type '$type' — aborting" >&2
      return 1
    fi
  fi
  return 0
}

_swarm_validate_manifest_entry() {
  local behavior="$1" src="$2" tgt="$3" old_ifs component
  if ! _swarm_target_path_is_safe "$tgt"; then
    echo "  ERROR: unsafe manifest target path: $tgt" >&2
    return 1
  fi
  case "$behavior" in
    refresh|seed|operator-owned|settings|git-hook)
      if ! _swarm_template_source_is_safe "$src"; then
        echo "  ERROR: unsafe or missing manifest source path: $src" >&2
        return 1
      fi
      ;;
    compose)
      case "$src" in ''|+*|*+|*++*)
        echo "  ERROR: malformed compose source list: $src" >&2
        return 1 ;;
      esac
      old_ifs="$IFS"
      IFS='+'
      set -- $src
      IFS="$old_ifs"
      for component in "$@"; do
        if ! _swarm_template_source_is_safe "$component"; then
          echo "  ERROR: unsafe or missing compose source path: $component" >&2
          return 1
        fi
      done
      ;;
    seed-text|gitignore)
      # These behaviors deliberately carry literal text rather than a source
      # pathname. Their target still passed the containment proof above.
      ;;
    *)
      echo "  ERROR: unknown manifest behavior '$behavior' for $tgt" >&2
      return 1
      ;;
  esac
  return 0
}

manifest_walk() {
  local cb="$1"
  local type="${SWARM_APPLY_TYPE:-engineering-cto}"
  local mf
  mf="$(swarm_manifest_path "$type")"
  if [ ! -f "$mf" ]; then
    echo "swarm-lib: manifest not found at $mf — aborting" >&2
    return 2
  fi
  local behavior src tgt covers line
  # Read pipe-delimited fields, skip comments + blanks, trim each field. The
  # 4th field (covers) is the optional route-before-scan note; a catch-all var
  # absorbs it (and any further '|') so tgt is always exactly field 3 — same
  # arity-safety idiom as the swarm.conf parser's trailing _rest. covers is
  # human/agent-facing only and intentionally unused here.
  while IFS='|' read -r behavior src tgt covers; do
    # Trim leading/trailing whitespace (bash 3.2: use parameter expansion + sed).
    behavior="$(printf '%s' "$behavior" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    src="$(printf '%s' "$src" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    tgt="$(printf '%s' "$tgt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$behavior" in
      ''|'#'*) continue ;;
    esac
    [ -z "$src" ] && continue
    [ -z "$tgt" ] && continue
    "$cb" "$behavior" "$src" "$tgt" || return $?
  done < "$mf"
}

# Internal: copy SRC to TGT, mkdir -p on the target dir. Sets SWARM_RESULT_CHANGED.
# Honors SWARM_DRY_RUN: when set, prints "would <label>" and returns without
# touching the filesystem. Used by onboard's preflight to detect all
# collisions/changes BEFORE any write happens (atomicity). The label is the
# past-tense verb used in live output ("wrote", "updated", etc.); for dry-
# run output we convert it to present tense so "would wrote" doesn't appear.
_swarm_copy() {
  local src="$1" tgt="$2" label="$3"
  local rel="${tgt#$SWARM_APPLY_REPO/}"
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    local pres="$label"
    case "$label" in
      wrote)                        pres="write" ;;
      updated)                      pres="update" ;;
      overwrote)                    pres="overwrite" ;;
      'overwrote (--force-docs)')   pres="overwrite (--force-docs)" ;;
      'overwrote (--force-hooks)')  pres="overwrite (--force-hooks)" ;;
      seeded)                       pres="seed" ;;
      're-seeded (--force)')        pres="re-seed (--force)" ;;
    esac
    echo "  would $pres: $rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if ! _swarm_publish_plain "$src" "$tgt" "$rel"; then
    echo "  ERROR: could not publish managed target: $rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  echo "  $label: $rel"
  SWARM_RESULT_CHANGED=1
}

# ---- per-class helpers ----------------------------------------------------
#
# Each helper takes: src (template-path relative to TPL), tgt (path relative
# to target repo). They use $SWARM_APPLY_MODE and $SWARM_APPLY_REPO from the
# enclosing manifest_apply.

manifest_apply_refresh() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    _swarm_copy "$src" "$tgt" "wrote"
    return $?
  fi
  if cmp -s "$src" "$tgt"; then
    if _swarm_plain_metadata_matches "$src" "$tgt" "$tgt_rel"; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
      [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
      return 0
    fi
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  METADATA:  $tgt_rel  (expected engine-safe readable metadata)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would repair metadata: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    if ! _swarm_copy "$src" "$tgt" "repaired metadata"; then
      return 1
    fi
    return 0
  fi
  # File exists and differs.
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      if [ "${SWARM_FORCE_DOCS:-0}" -eq 1 ] && _swarm_is_doctrine "$tgt_rel"; then
        _swarm_copy "$src" "$tgt" "overwrote (--force-docs)"
      elif [ "${SWARM_FORCE_HOOKS:-0}" -eq 1 ] && _swarm_is_hook "$tgt_rel"; then
        _swarm_copy "$src" "$tgt" "overwrote (--force-hooks)"
      else
        echo "  COLLISION: $tgt_rel  (exists and differs from template)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
refresh:$tgt_rel"
      fi
      ;;
    init|sync)
      _swarm_copy "$src" "$tgt" "updated"
      ;;
  esac
}

_swarm_is_doctrine() {
  case "$1" in
    AGENTS.md|CLAUDE.md|TEAM_LEAD.md|ESCALATION.md) return 0 ;;
  esac
  return 1
}

# _compose_to_tmp SRC_LIST OUT_PATH
#
# Concatenate '+'-joined template sources LITERALLY (no separator injected)
# into OUT_PATH. Each source path is resolved under $SWARM_HOME/templates/.
#
# Asserts the trailing-newline invariant (see templates/_base/README.md):
# every non-final source MUST end with at least one '\n'. A fragment
# stripped of its trailing newline would run into the next fragment's
# first byte at concat time (e.g., "...content## Heading" instead of
# "...content\n## Heading"), silently corrupting the composed output.
# Failing loudly here is the defense.
#
# Returns 0 on success, non-zero on any error (missing source, invariant
# violation, write failure). Caller responsible for cleaning up OUT_PATH
# on failure.
_compose_to_tmp() {
  local src_list="$1" out_path="$2"
  : > "$out_path" || return 1
  local OLD_IFS="$IFS"
  IFS='+'
  set -- $src_list
  IFS="$OLD_IFS"
  local total=$#
  local i=0 src
  for src in "$@"; do
    i=$((i + 1))
    local src_path="$SWARM_HOME/templates/$src"
    if [ ! -f "$src_path" ]; then
      echo "compose: source missing: $src" >&2
      return 1
    fi
    if [ "$i" -lt "$total" ]; then
      local last_byte
      last_byte="$(tail -c 1 "$src_path" 2>/dev/null | xxd -p 2>/dev/null)"
      if [ "$last_byte" != "0a" ]; then
        echo "compose: source '$src' lacks trailing newline (last byte 0x$last_byte)" >&2
        echo "compose: violates templates/_base/README.md trailing-newline invariant" >&2
        return 1
      fi
    fi
    cat "$src_path" >> "$out_path" || return 1
  done
  return 0
}

_swarm_is_hook() {
  case "$1" in
    .claude/hooks/*|.codex/hooks/*|.codex/hooks.json) return 0 ;;
  esac
  return 1
}

_swarm_stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

_swarm_stat_gid() {
  stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1" 2>/dev/null
}

_swarm_stat_uid() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

_swarm_stat_nlink() {
  stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1" 2>/dev/null
}

_swarm_file_acl_is_safe() {  # path; true when no extended ACL is present
  local path="$1" listing perms
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      listing="$(/bin/ls -lde "$path" 2>/dev/null)" || return 1
      perms="${listing%%[[:space:]]*}"
      case "$perms" in *+*) return 1 ;; esac
      ;;
  esac
  return 0
}

_swarm_strip_file_acl() {  # path; no-op off Darwin
  local path="$1"
  case "$(uname -s 2>/dev/null)" in
    Darwin) chmod -N "$path" 2>/dev/null || return 1 ;;
  esac
  _swarm_file_acl_is_safe "$path"
}

# Keep this filesystem split aligned with swarm-codex-runtime.py's
# operator_owned(): these are read-only doctrine/control surfaces for the
# dedicated runtime.  Everything else is an ordinary Codex-editable workspace
# file and therefore needs shared-group write as well as read.
_swarm_codex_operator_owned_target() {  # repo-relative target
  local rel="$1" first="${1%%/*}"
  case "$first" in .git|.codex|.claude|.agents|.swarm-*) return 0 ;; esac
  case "$rel" in
    AGENTS.md|CLAUDE.md|TEAM_LEAD.md|ESCALATION.md|CONVERSATION.md|EVALUATION.md|SURFACING.md|MEMORY.md|READINESS_BAR.md|CPO_BUS_PROTOCOL.md|.gitleaks.toml)
      return 0 ;;
  esac
  return 1
}

_swarm_remove_created_dirs() {  # newline-delimited, newest first
  local created="$1" old_ifs="$IFS" path
  IFS='
'
  set -- $created
  IFS="$old_ifs"
  for path in "$@"; do
    [ -n "$path" ] && rmdir "$path" 2>/dev/null || true
  done
}

_swarm_prepare_target_parent() {  # absolute target, repo-relative target
  local tgt="$1" tgt_rel="$2" dir parent_rel current rel_dir old_ifs component parent_gid mode created=""
  SWARM_CREATED_PARENT_DIRS=""
  dir="$(dirname "$tgt")"
  [ -d "$dir" ] && [ ! -L "$dir" ] && return 0

  # Direct helper callers outside manifest_apply have no authoritative repo
  # relative classification.  Retain their historical mkdir behavior; every
  # manifest call has the fully validated SWARM_APPLY_REPO context below.
  if [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ] || \
     [ -z "${SWARM_APPLY_REPO:-}" ]; then
    mkdir -p "$dir"
    return $?
  fi

  parent_rel="$(dirname "$tgt_rel")"
  [ "$parent_rel" != "." ] || return 0
  current="$SWARM_APPLY_REPO"
  rel_dir=""
  old_ifs="$IFS"
  IFS='/'
  set -- $parent_rel
  IFS="$old_ifs"
  for component in "$@"; do
    rel_dir="${rel_dir:+$rel_dir/}$component"
    current="$current/$component"
    if [ -e "$current" ] || [ -L "$current" ]; then
      if [ ! -d "$current" ] || [ -L "$current" ]; then
        _swarm_remove_created_dirs "$created"
        return 1
      fi
      continue
    fi
    parent_gid="$(_swarm_stat_gid "$(dirname "$current")")" || {
      _swarm_remove_created_dirs "$created"
      return 1
    }
    if ! mkdir "$current"; then
      _swarm_remove_created_dirs "$created"
      return 1
    fi
    created="$current${created:+
$created}"
    if ! chgrp "$parent_gid" "$current" || ! _swarm_strip_file_acl "$current"; then
      _swarm_remove_created_dirs "$created"
      return 1
    fi
    if _swarm_codex_operator_owned_target "$rel_dir"; then
      mode=750
      [ "$rel_dir" != ".git" ] || mode=2750
    else
      mode=2770
    fi
    if ! chmod "$mode" "$current" || \
       { case "$mode" in 2*) true ;; *) false ;; esac && \
         { [ "$(_swarm_stat_mode "$current")" != "${mode#2}" ] || [ ! -g "$current" ]; }; } || \
       { case "$mode" in 2*) false ;; *) true ;; esac && \
         [ "$(_swarm_stat_mode "$current")" != "$mode" ]; } || \
       [ "$(_swarm_stat_gid "$current")" != "$parent_gid" ] || \
       ! _swarm_file_acl_is_safe "$current"; then
      _swarm_remove_created_dirs "$created"
      return 1
    fi
  done
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    SWARM_CREATED_PARENT_DIRS="$created"
    return 0
  fi
  _swarm_remove_created_dirs "$created"
  return 1
}

_swarm_plain_mode_is_safe() {
  local mode="$1" bits
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  bits=$((0$mode))
  # Plain Claude workspace files may intentionally be group-writable (shared
  # repositories commonly use 0664/0775).  Preserve that established behavior
  # while refusing world-write and special permission bits.
  [ $((bits & 0400)) -ne 0 ] && \
    [ $((bits & 0002)) -eq 0 ] && \
    [ $((bits & 07000)) -eq 0 ]
}

# Plan and publish ordinary (non-compose) manifest files.  A prepared Codex
# checkout is shared with the dedicated runtime through the target directory's
# group, so publishing a template's private mode/group (or a /tmp staging
# inode) can make a previously valid checkout unreadable.  Claude retains any
# safe existing metadata; Codex receives the explicit shared contract:
# parent gid and group-readable/executable parity. Runtime operator-owned paths
# are never group/world-writable; ordinary Codex-editable paths retain the
# shared-group write bit required by the workspace contract.
_swarm_plain_metadata_plan() {  # source target target-relative
  local src="$1" tgt="$2" tgt_rel="$3" dir parent_gid current_mode current_gid source_mode bits
  dir="$(dirname "$tgt")"
  parent_gid="$(_swarm_stat_gid "$dir")" || return 1
  current_mode=""
  if [ -f "$tgt" ] && [ ! -L "$tgt" ]; then
    current_mode="$(_swarm_stat_mode "$tgt")" || return 1
  fi
  source_mode="$(_swarm_stat_mode "$src")" || return 1

  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ]; then
    bits=0
    case "$current_mode" in ''|*[!0-7]*) ;; *) bits=$((0$current_mode)) ;; esac
    case "$source_mode" in ''|*[!0-7]*) ;; *) bits=$((bits | 0$source_mode)) ;; esac
    if _swarm_codex_operator_owned_target "$tgt_rel"; then
      if [ $((bits & 0100)) -ne 0 ]; then
        printf '750 %s' "$parent_gid"
      else
        printf '640 %s' "$parent_gid"
      fi
    elif [ $((bits & 0100)) -ne 0 ]; then
      printf '770 %s' "$parent_gid"
    else
      printf '660 %s' "$parent_gid"
    fi
    return 0
  fi

  # Preserve the established Claude target's safe mode and group exactly.
  if [ -n "$current_mode" ] && _swarm_plain_mode_is_safe "$current_mode"; then
    current_gid="$(_swarm_stat_gid "$tgt")" || return 1
    printf '%s %s' "$current_mode" "$current_gid"
    return 0
  fi

  # A new Claude target follows its template's safe mode.  Unsafe template or
  # target metadata falls back to the historical conventional file/hook mode.
  if _swarm_plain_mode_is_safe "$source_mode"; then
    printf '%s %s' "$source_mode" "$parent_gid"
  elif _swarm_is_hook "$tgt_rel" || [ $((0$source_mode & 0100)) -ne 0 ]; then
    printf '755 %s' "$parent_gid"
  else
    printf '644 %s' "$parent_gid"
  fi
}

_swarm_plain_metadata_matches() {  # source target target-relative
  local src="$1" tgt="$2" tgt_rel="$3" plan desired_mode desired_gid target_mode target_gid
  [ -f "$tgt" ] && [ ! -L "$tgt" ] || return 1
  plan="$(_swarm_plain_metadata_plan "$src" "$tgt" "$tgt_rel")" || return 1
  desired_mode="${plan%% *}"
  desired_gid="${plan#* }"
  target_mode="$(_swarm_stat_mode "$tgt")" || return 1
  target_gid="$(_swarm_stat_gid "$tgt")" || return 1
  [ "$target_mode" = "$desired_mode" ] && [ "$target_gid" = "$desired_gid" ] || return 1
  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ]; then
    _swarm_file_acl_is_safe "$tgt"
  fi
}

_swarm_publish_plain() {  # source target target-relative
  # The staging inode lives beside the target, receives its final metadata,
  # and is then atomically renamed.  Copying an existing target into staging
  # first retains safe Claude ACL/xattr behavior while content is replaced.
  local src="$1" tgt="$2" tgt_rel="$3" dir staged plan desired_mode desired_gid created
  dir="$(dirname "$tgt")"
  _swarm_prepare_target_parent "$tgt" "$tgt_rel" || return 1
  created="${SWARM_CREATED_PARENT_DIRS:-}"
  if [ -L "$tgt" ] || { [ -e "$tgt" ] && [ ! -f "$tgt" ]; }; then
    _swarm_remove_created_dirs "$created"
    return 1
  fi
  staged="$(mktemp "$dir/.swarm-publish.XXXXXX")" || {
    _swarm_remove_created_dirs "$created"
    return 1
  }
  plan="$(_swarm_plain_metadata_plan "$src" "$tgt" "$tgt_rel")" || {
    rm -f "$staged"
    _swarm_remove_created_dirs "$created"
    return 1
  }
  desired_mode="${plan%% *}"
  desired_gid="${plan#* }"
  if [ -f "$tgt" ] && [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ] && \
     ! cp -p "$tgt" "$staged"; then
    rm -f "$staged"
    _swarm_remove_created_dirs "$created"
    return 1
  fi
  # An existing safe target may be owner-read-only.  Staging is private and
  # not yet published, so make it writable only for the content replacement;
  # the final planned mode is restored before rename.
  if ! chmod u+w "$staged" || \
     ! cat "$src" > "$staged" || \
     ! chgrp "$desired_gid" "$staged" || \
     ! chmod "$desired_mode" "$staged" || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_strip_file_acl "$staged"; } || \
     [ "$(_swarm_stat_mode "$staged")" != "$desired_mode" ] || \
     [ "$(_swarm_stat_gid "$staged")" != "$desired_gid" ] || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_file_acl_is_safe "$staged"; } || \
     ! mv -f "$staged" "$tgt"; then
    rm -f "$staged"
    _swarm_remove_created_dirs "$created"
    return 1
  fi
  return 0
}

_swarm_compose_conventional_mode() {
  case "$1" in
    .claude/hooks/*|.codex/hooks/*) printf '755' ;;
    *)                              printf '644' ;;
  esac
}

_swarm_compose_sources_executable() {
  local src_list="$1" OLD_IFS="$IFS" src
  IFS='+'
  set -- $src_list
  IFS="$OLD_IFS"
  for src in "$@"; do
    [ -x "$SWARM_HOME/templates/$src" ] && return 0
  done
  return 1
}

_swarm_compose_mode_is_safe() {
  local mode="$1" bits
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  bits=$((0$mode))
  # Owner must be able to read it; group/world may read or execute but never
  # write. Do not preserve special permission bits on managed compositions.
  [ $((bits & 0400)) -ne 0 ] && \
    [ $((bits & 0022)) -eq 0 ] && \
    [ $((bits & 07000)) -eq 0 ]
}

_swarm_compose_metadata_plan() {
  # Print: MODE GID. Claude retains safe metadata on an existing regular
  # target, avoiding behavioral churn. Codex must be readable by its dedicated
  # group and is bash-invoked, so it is 0640 unless owner execution was already
  # part of the target/source contract (then 0750).
  local tgt="$1" tgt_rel="$2" src_list="$3" dir parent_gid current_mode current_gid bits
  dir="$(dirname "$tgt")"
  parent_gid="$(_swarm_stat_gid "$dir")" || return 1
  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ]; then
    current_mode=""
    [ ! -e "$tgt" ] || current_mode="$(_swarm_stat_mode "$tgt")" || return 1
    bits=0
    case "$current_mode" in ''|*[!0-7]*) ;; *) bits=$((0$current_mode)) ;; esac
    if [ $((bits & 0100)) -ne 0 ] || _swarm_compose_sources_executable "$src_list"; then
      printf '750 %s' "$parent_gid"
    else
      printf '640 %s' "$parent_gid"
    fi
    return 0
  fi
  if [ -f "$tgt" ] && [ ! -L "$tgt" ]; then
    current_mode="$(_swarm_stat_mode "$tgt")" || return 1
    current_gid="$(_swarm_stat_gid "$tgt")" || return 1
    if _swarm_compose_mode_is_safe "$current_mode"; then
      printf '%s %s' "$current_mode" "$current_gid"
      return 0
    fi
  fi
  printf '%s %s' "$(_swarm_compose_conventional_mode "$tgt_rel")" "$parent_gid"
}

_swarm_compose_metadata_matches() {
  local tgt="$1" tgt_rel="$2" src_list="$3" plan desired_mode desired_gid target_mode target_gid
  plan="$(_swarm_compose_metadata_plan "$tgt" "$tgt_rel" "$src_list")" || return 1
  desired_mode="${plan%% *}"
  desired_gid="${plan#* }"
  target_mode="$(_swarm_stat_mode "$tgt")" || return 1
  target_gid="$(_swarm_stat_gid "$tgt")" || return 1
  [ "$target_mode" = "$desired_mode" ] && [ "$target_gid" = "$desired_gid" ] || return 1
  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ]; then
    _swarm_file_acl_is_safe "$tgt"
  fi
}

_swarm_publish_composed() {
  # Copy the already-validated composition into a same-directory staging file,
  # set its complete metadata contract, and only then atomically publish it.
  # Check/dry-run callers never reach this helper, so their preflight remains
  # read-only and does not create target parents or staging names.
  local content="$1" tgt="$2" tgt_rel="$3" src_list="$4" dir staged plan desired_mode desired_gid created
  dir="$(dirname "$tgt")"
  _swarm_prepare_target_parent "$tgt" "$tgt_rel" || return 1
  created="${SWARM_CREATED_PARENT_DIRS:-}"
  staged="$(mktemp "$dir/.swarm-compose.XXXXXX")" || {
    _swarm_remove_created_dirs "$created"
    return 1
  }
  plan="$(_swarm_compose_metadata_plan "$tgt" "$tgt_rel" "$src_list")" || {
    rm -f "$staged"
    _swarm_remove_created_dirs "$created"
    return 1
  }
  desired_mode="${plan%% *}"
  desired_gid="${plan#* }"
  if ! cat "$content" > "$staged" || \
     ! chgrp "$desired_gid" "$staged" || \
     ! chmod "$desired_mode" "$staged" || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_strip_file_acl "$staged"; } || \
     [ "$(_swarm_stat_mode "$staged")" != "$desired_mode" ] || \
     [ "$(_swarm_stat_gid "$staged")" != "$desired_gid" ] || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_file_acl_is_safe "$staged"; } || \
     ! mv -f "$staged" "$tgt"; then
    rm -f "$staged"
    _swarm_remove_created_dirs "$created"
    return 1
  fi
  return 0
}

# Codex project files are a migration-sensitive managed namespace. Repos may
# already have their own Codex entrypoint/hooks/rules/skills, so a newly-added
# manifest entry in this namespace must be adopted before the ordinary refresh
# policy is allowed to write it. AGENTS.md is included because it arrived with
# this integration and is also a standard operator-owned Codex surface.
_swarm_is_codex_managed_target() {
  case "$1" in
    AGENTS.md|.codex/*|.agents/skills/*) return 0 ;;
  esac
  return 1
}

manifest_apply_compose() {
  local src_list="$1" tgt_rel="$2"
  # Profile overlay (ADR-0013) — engineering-cto only, CLAUDE.md only.
  # When the repo's resolved profile has an overlay fragment on disk, append
  # it as the FINAL compose source so the profile's stack-specific doctrine
  # layers on top of the base teammate manual. THREE states fall out of one
  # guard, by design:
  #   - absent/empty profile        -> nothing appended; a markerless swarm
  #     composes byte-identically to a pre-profile swarm (the no-op default)
  #   - a profile with no fragment   -> nothing appended; v1 'backend' is
  #     label-only (today's engineering-cto IS the backend case), so the
  #     marker is a label and the compose is unchanged
  #   - a profile WITH a fragment    -> appended (e.g. 'frontend')
  # Gated on SWARM_APPLY_TYPE=engineering-cto so a non-engineering-cto compose
  # (e.g. the cpo CLAUDE.md, same target name) is never touched even if a
  # stray marker exists. This and the canon-mode overlay below are the ONLY
  # dynamically-sourced compose inputs; every other source is the static
  # '+'-joined list on the manifest line, which stays profile- and
  # mode-agnostic (see templates/engineering-cto/manifest.tsv header +
  # templates/_base/README.md).
  if [ "$tgt_rel" = "CLAUDE.md" ] && \
     [ "${SWARM_APPLY_TYPE:-}" = "engineering-cto" ] && \
     [ -n "${SWARM_APPLY_PROFILE:-}" ]; then
    local _overlay_rel="engineering-cto/profiles/${SWARM_APPLY_PROFILE}/CLAUDE.md"
    if [ -f "$SWARM_HOME/templates/$_overlay_rel" ]; then
      src_list="${src_list}+${_overlay_rel}"
    fi
  fi
  # Canon-mode overlay (source-of-truth axis) — engineering-cto only,
  # CLAUDE.md only, external mode only. Appends AFTER any profile overlay:
  # first the shared external-canon doctrine fragment (template-sourced),
  # then — post-compose, below — the repo-local canon binding, which names
  # this repo's canon/spec repo and cannot live in templates/. A repo in
  # 'local' mode (the default; absent/any-other marker) composes
  # byte-identically to a pre-canon-mode swarm.
  local _canon_binding=""
  if [ "$tgt_rel" = "CLAUDE.md" ] && \
     [ "${SWARM_APPLY_TYPE:-}" = "engineering-cto" ] && \
     [ "${SWARM_APPLY_CANON_MODE:-local}" = "external" ]; then
    local _canon_rel="engineering-cto/canon/CLAUDE.external-canon.md"
    if [ -f "$SWARM_HOME/templates/$_canon_rel" ]; then
      src_list="${src_list}+${_canon_rel}"
    fi
    if [ -f "$SWARM_APPLY_REPO/.claude/canon-binding.md" ]; then
      _canon_binding="$SWARM_APPLY_REPO/.claude/canon-binding.md"
    fi
  fi
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  local tmp
  tmp="$(mktemp -t swarm-compose.XXXXXX)" || {
    echo "  ERROR: mktemp failed for compose: $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  }
  if ! _compose_to_tmp "$src_list" "$tmp"; then
    echo "  ERROR: compose failed for $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    rm -f "$tmp"
    return 1
  fi
  # Repo-local canon binding: the ONE compose input sourced from the target
  # repo itself (seeded by bin/swarm-canon-enable.sh, operator/CTO-owned).
  # Appended last so the binding always terminates the composed manual.
  if [ -n "$_canon_binding" ]; then
    cat "$_canon_binding" >> "$tmp" || {
      echo "  ERROR: compose failed appending canon binding for $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      rm -f "$tmp"
      return 1
    }
  fi

  # Managed composition never follows or writes through an existing special
  # target. In particular, `mv STAGED EXISTING_DIRECTORY` would otherwise move
  # the staging file inside that directory and falsely report a successful
  # target update.
  if [ -L "$tgt" ] || { [ -e "$tgt" ] && [ ! -f "$tgt" ]; }; then
    echo "  ERROR: composed target is not a regular file: $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    rm -f "$tmp"
    return 1
  fi

  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (compose)"
      SWARM_RESULT_DRIFT=1
      rm -f "$tmp"
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel  (composed)"
      SWARM_RESULT_CHANGED=1
      rm -f "$tmp"
      return 0
    fi
    if ! _swarm_publish_composed "$tmp" "$tgt" "$tgt_rel" "$src_list"; then
      echo "  ERROR: could not publish composed target: $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
    echo "  wrote: $tgt_rel  (composed)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if cmp -s "$tmp" "$tgt"; then
    if _swarm_compose_metadata_matches "$tgt" "$tgt_rel" "$src_list"; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
      [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
      rm -f "$tmp"
      return 0
    fi
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      local _metadata_plan _metadata_mode
      if _metadata_plan="$(_swarm_compose_metadata_plan "$tgt" "$tgt_rel" "$src_list" 2>/dev/null)"; then
        _metadata_mode="${_metadata_plan%% *}"
        echo "  METADATA:  $tgt_rel  (expected mode 0$_metadata_mode and engine-safe group)"
      else
        echo "  METADATA:  $tgt_rel  (expected engine-safe readable metadata)"
      fi
      SWARM_RESULT_DRIFT=1
      rm -f "$tmp"
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would repair metadata: $tgt_rel  (composed)"
      SWARM_RESULT_CHANGED=1
      rm -f "$tmp"
      return 0
    fi
    if ! _swarm_publish_composed "$tmp" "$tgt" "$tgt_rel" "$src_list"; then
      echo "  ERROR: could not repair composed target metadata: $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
    echo "  repaired metadata: $tgt_rel  (composed)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      rm -f "$tmp"
      ;;
    onboard)
      if [ "${SWARM_FORCE_DOCS:-0}" -eq 1 ] && _swarm_is_doctrine "$tgt_rel"; then
        if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
          echo "  would overwrite (--force-docs): $tgt_rel"
          SWARM_RESULT_CHANGED=1
          rm -f "$tmp"
        else
          if ! _swarm_publish_composed "$tmp" "$tgt" "$tgt_rel" "$src_list"; then
            echo "  ERROR: could not publish composed target: $tgt_rel" >&2
            SWARM_RESULT_FATAL=1
            rm -f "$tmp"
            return 1
          fi
          rm -f "$tmp"
          echo "  overwrote (--force-docs): $tgt_rel  (composed)"
          SWARM_RESULT_CHANGED=1
        fi
      elif [ "${SWARM_FORCE_HOOKS:-0}" -eq 1 ] && _swarm_is_hook "$tgt_rel"; then
        if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
          echo "  would overwrite (--force-hooks): $tgt_rel"
          SWARM_RESULT_CHANGED=1
          rm -f "$tmp"
        else
          if ! _swarm_publish_composed "$tmp" "$tgt" "$tgt_rel" "$src_list"; then
            echo "  ERROR: could not publish composed target: $tgt_rel" >&2
            SWARM_RESULT_FATAL=1
            rm -f "$tmp"
            return 1
          fi
          rm -f "$tmp"
          echo "  overwrote (--force-hooks): $tgt_rel  (composed)"
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  COLLISION: $tgt_rel  (composed differs from existing)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
compose:$tgt_rel"
        rm -f "$tmp"
      fi
      ;;
    init|sync)
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would update: $tgt_rel  (composed)"
        SWARM_RESULT_CHANGED=1
        rm -f "$tmp"
      else
        if ! _swarm_publish_composed "$tmp" "$tgt" "$tgt_rel" "$src_list"; then
          echo "  ERROR: could not publish composed target: $tgt_rel" >&2
          SWARM_RESULT_FATAL=1
          rm -f "$tmp"
          return 1
        fi
        rm -f "$tmp"
        echo "  updated: $tgt_rel  (composed)"
        SWARM_RESULT_CHANGED=1
      fi
      ;;
  esac
}

manifest_apply_seed() {
  # seed-class is per-repo content. By design:
  #   - init/onboard: write if absent (placeholder/template for the CTO).
  #   - sync: NEVER touch — these files are operator-owned, not infra.
  #   - check: report MISSING as informational, NOT as drift (sync can't
  #     fix it; run swarm-init to seed).
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "init" ] && [ "${SWARM_FORCE_SEED:-0}" -eq 1 ]; then
      _swarm_copy "$src" "$tgt" "re-seeded (--force)"
      return 0
    fi
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (seed; not drift — sync won't fix; init/onboard would)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (seed; sync does not seed): $tgt_rel"
    return 0
  fi
  _swarm_copy "$src" "$tgt" "seeded"
}

manifest_apply_operator_owned() {
  # operator-owned: per-repo content the OPERATOR authors (product vision,
  # strategy doc, etc.). The CRITICAL difference from `seed`: --force does
  # NOT re-seed. By design:
  #   - init/onboard: write if absent (initial placeholder for the operator).
  #   - sync: NEVER touch — operator-owned, not infra.
  #   - init --force / SWARM_FORCE_SEED=1: IGNORED. Operator-authored
  #     content is sacred; --force on init is for re-seeding infra
  #     templates, never for clobbering operator content. To reset
  #     operator content, the operator deletes the file by hand and
  #     re-runs init.
  #   - check: report MISSING informationally, NOT as drift.
  #
  # SUBTREE SEMANTICS. An entry whose target is `<dir>/.keep` declares the
  # WHOLE `<dir>/` subtree operator-owned, not just the .keep marker. The
  # .keep file is the seed anchor; the protected unit is the directory.
  # An entry whose target is a real file (no `.keep` basename) protects
  # exactly that path. The pre-walk in manifest_apply collects these as
  # SWARM_OO_PREFIXES / SWARM_OO_FILES and refuses any other manifest
  # entry that would write under a protected prefix or onto a protected
  # file — so a future `refresh | ... | products/foo.md` is a fatal
  # manifest defect, not a silent clobber.
  #
  # Paired with the staging protection in templates/<type>/git-hooks/
  # pre-commit (Layer 3): the auto-stamped .claude/operator-owned-paths
  # list contains the canonical form (prefix entries end in `/`; exact
  # entries do not) and the hook prefix-matches `/`-suffixed lines so a
  # teammate cannot stage a file anywhere under an operator-owned subtree.
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ -e "$tgt" ]; then
    # NO SWARM_FORCE_SEED branch — that is the whole point.
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel  (operator-owned)"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (operator-owned; exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (operator-owned; not drift — sync won't fix; init/onboard would seed)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (operator-owned; sync does not seed): $tgt_rel"
    return 0
  fi
  _swarm_copy "$src" "$tgt" "seeded (operator-owned)"
}

manifest_apply_seed_text() {
  # seed-text is per-repo content (e.g., .claude/test-cmd). Same policy as
  # seed: init/onboard seed if absent; sync never touches; check reports
  # MISSING informationally but does NOT mark drift.
  local text="$1" tgt_rel="$2"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ -e "$tgt" ]; then
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    if [ "$SWARM_APPLY_MODE" = "init" ] && [ "${SWARM_FORCE_SEED:-0}" -eq 1 ]; then
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would re-seed (--force): $tgt_rel"
      else
        local generated
        generated="$(mktemp -t swarm-seed-text.XXXXXX)" || return 1
        if ! chmod 0644 "$generated" || ! printf '%s\n' "$text" > "$generated" || \
           ! _swarm_publish_plain "$generated" "$tgt" "$tgt_rel"; then
          rm -f "$generated"
          SWARM_RESULT_FATAL=1
          return 1
        fi
        rm -f "$generated"
        echo "  re-seeded (--force): $tgt_rel"
      fi
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (seed-text; not drift — sync won't fix; init/onboard would)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (seed-text; sync does not seed): $tgt_rel"
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would seed: $tgt_rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  local generated
  generated="$(mktemp -t swarm-seed-text.XXXXXX)" || return 1
  if ! chmod 0644 "$generated" || ! printf '%s\n' "$text" > "$generated" || \
     ! _swarm_publish_plain "$generated" "$tgt" "$tgt_rel"; then
    rm -f "$generated"
    SWARM_RESULT_FATAL=1
    return 1
  fi
  rm -f "$generated"
  echo "  seeded: $tgt_rel  (initial content; edit to your repo's real value)"
  SWARM_RESULT_CHANGED=1
}

manifest_apply_settings() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (settings)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    _swarm_copy "$src" "$tgt" "wrote"
    return $?
  fi
  # Existing settings — structured merge.
  if [ "$SWARM_APPLY_MODE" = "check" ] || [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    if settings_merge_swarm "$tgt" "$src" --check; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
      [ "${SWARM_DRY_RUN:-0}" -eq 1 ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    else
      local cc=$?
      if [ "$cc" -eq 3 ]; then
        if [ "$SWARM_APPLY_MODE" = "check" ]; then
          if [ "${SWARM_SETTINGS_CONTENT_DRIFT:-0}" -eq 1 ]; then
            echo "  MERGE_NEEDED: $tgt_rel  (swarm hook registrations missing or stale)"
          fi
          if [ "${SWARM_SETTINGS_METADATA_DRIFT:-0}" -eq 1 ]; then
            echo "  METADATA:  $tgt_rel  (expected engine-safe readable metadata)"
          fi
          SWARM_RESULT_DRIFT=1
        else
          if [ "${SWARM_SETTINGS_CONTENT_DRIFT:-0}" -eq 1 ]; then
            echo "  would merge: $tgt_rel"
          fi
          if [ "${SWARM_SETTINGS_METADATA_DRIFT:-0}" -eq 1 ]; then
            echo "  would repair metadata: $tgt_rel"
          fi
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  ERROR: settings parse failed for $tgt_rel (rc=$cc)" >&2
        SWARM_RESULT_FATAL=1
        return 1
      fi
    fi
    return 0
  fi
  if settings_merge_swarm "$tgt" "$src"; then
    # Returns 0 on a structural change applied, 3 on no-op (see helper).
    if [ "${SWARM_SETTINGS_CONTENT_DRIFT:-0}" -eq 1 ]; then
      echo "  merged: $tgt_rel  (swarm hooks registered; foreign entries preserved)"
    else
      echo "  repaired metadata: $tgt_rel  (settings content preserved)"
    fi
    SWARM_RESULT_CHANGED=1
  else
    local rc=$?
    if [ "$rc" -eq 3 ]; then
      [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    else
      echo "  ERROR: settings merge failed for $tgt_rel (rc=$rc)" >&2
      SWARM_RESULT_FATAL=1
      return 1
    fi
  fi
}

manifest_apply_git_hook() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  # Not a git working tree → skip silently. swarm-init has historically
  # tolerated this (non-git scaffold dirs).
  if [ ! -d "$SWARM_APPLY_REPO/.git" ] && [ ! -f "$SWARM_APPLY_REPO/.git" ]; then
    [ "$SWARM_APPLY_MODE" != "check" ] && echo "  skip: $tgt_rel  (not a git working tree)"
    return 0
  fi
  local marker='# SWARM-MANAGED pre-commit'
  # Distinct marker for the tooling/source-repo variant (anti-secret-only,
  # no docs-touch gate). When seen on a pre-commit, that's an intentional
  # opt-out from the standard hook — preserve it; do NOT overwrite back to
  # the standard variant on sync / init / onboard. See
  # templates/engineering-cto/git-hooks/pre-commit-anti-secret-only.
  local variant_marker='SWARM-MANAGED pre-commit (anti-secret-only'
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (git-hook)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    _swarm_copy "$src" "$tgt" "wrote"
    return $?
  fi
  # Variant check FIRST: an anti-secret-only variant is swarm-managed but
  # deliberately different from the standard. Never clobber it.
  if head -n 5 "$tgt" | grep -qF "$variant_marker"; then
    case "$SWARM_APPLY_MODE" in
      check)
        echo "  OK:        $tgt_rel  (swarm-managed variant: anti-secret-only — preserved)"
        ;;
      *)
        [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip: $tgt_rel  (swarm-managed variant: anti-secret-only — preserved)"
        ;;
    esac
    return 0
  fi
  # Existing pre-commit — marker-aware (standard).
  if head -n 5 "$tgt" | grep -qF "$marker"; then
    # It's our own hook from a previous stamp.
    if cmp -s "$src" "$tgt"; then
      if _swarm_plain_metadata_matches "$src" "$tgt" "$tgt_rel"; then
        [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
        [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
        return 0
      fi
      if [ "$SWARM_APPLY_MODE" = "check" ]; then
        echo "  METADATA:  $tgt_rel  (expected engine-safe readable metadata)"
        SWARM_RESULT_DRIFT=1
        return 0
      fi
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would repair metadata: $tgt_rel"
        SWARM_RESULT_CHANGED=1
        return 0
      fi
      if ! _swarm_publish_plain "$src" "$tgt" "$tgt_rel"; then
        SWARM_RESULT_FATAL=1
        return 1
      fi
      echo "  repaired metadata: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would update: $tgt_rel  (existing is swarm-managed)"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    if ! _swarm_publish_plain "$src" "$tgt" "$tgt_rel"; then
      echo "  ERROR: could not publish managed target: $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      return 1
    fi
    echo "  updated: $tgt_rel  (existing was swarm-managed)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  # Foreign pre-commit (no marker).
  SWARM_RESULT_FOREIGN_PRECOMMIT=1
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  FOREIGN:   $tgt_rel  (existing pre-commit has no SWARM-MANAGED marker)"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      if [ "${SWARM_FORCE_PRECOMMIT:-0}" -eq 1 ]; then
        if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
          echo "  would overwrite (--force-precommit): $tgt_rel"
          SWARM_RESULT_CHANGED=1
        else
          if ! _swarm_publish_plain "$src" "$tgt" "$tgt_rel"; then
            echo "  ERROR: could not publish managed target: $tgt_rel" >&2
            SWARM_RESULT_FATAL=1
            return 1
          fi
          echo "  overwrote (--force-precommit): $tgt_rel"
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  COLLISION: $tgt_rel  (foreign pre-commit; pass --force-precommit to replace)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
git-hook:$tgt_rel"
      fi
      ;;
    init|sync)
      echo "  NOTE: kept existing $tgt_rel  (no SWARM-MANAGED marker); review"
      echo "        $SWARM_HOME/templates/$src_rel and merge by hand if you want"
      echo "        the docs-touch + anti-secret gate active."
      ;;
  esac
}

manifest_apply_gitignore() {
  # template-path field = the literal line we want present in .gitignore.
  local line="$1" tgt_rel="$2"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (no .gitignore; line '$line' would be added)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel  (would create with '$line' entry)"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    local generated
    generated="$(mktemp -t swarm-gitignore.XXXXXX)" || return 1
    if ! chmod 0644 "$generated" || ! {
      echo "# Per-teammate git worktrees (CTO provisions before spawn;"
      echo "# never tracked in the integration tree)."
      echo "$line"
    } > "$generated" || ! _swarm_publish_plain "$generated" "$tgt" "$tgt_rel"; then
      rm -f "$generated"
      SWARM_RESULT_FATAL=1
      return 1
    fi
    rm -f "$generated"
    echo "  wrote: $tgt_rel  (created with $line entry)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if grep -qxF "$line" "$tgt"; then
    if _swarm_plain_metadata_matches "$tgt" "$tgt" "$tgt_rel"; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel  ('$line' present)"
      [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (already gitignored): $line"
      return 0
    fi
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  METADATA:  $tgt_rel  (expected engine-safe readable metadata)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would repair metadata: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    if ! _swarm_publish_plain "$tgt" "$tgt" "$tgt_rel"; then
      SWARM_RESULT_FATAL=1
      return 1
    fi
    echo "  repaired metadata: $tgt_rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING_LINE: $tgt_rel  ('$line' absent)"
    SWARM_RESULT_DRIFT=1
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would append: $tgt_rel  ('$line' entry)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  local generated
  generated="$(mktemp -t swarm-gitignore.XXXXXX)" || return 1
  if ! chmod 0644 "$generated" || ! cat "$tgt" > "$generated" || ! {
    echo ""
    echo "# Per-teammate git worktrees (CTO provisions before spawn;"
    echo "# never tracked in the integration tree)."
    echo "$line"
  } >> "$generated" || ! _swarm_publish_plain "$generated" "$tgt" "$tgt_rel"; then
    rm -f "$generated"
    SWARM_RESULT_FATAL=1
    return 1
  fi
  rm -f "$generated"
  echo "  appended: $tgt_rel  ($line entry)"
  SWARM_RESULT_CHANGED=1
}

# Dispatch one manifest line to the right helper.
#
# Before dispatch, refuse any non-operator-owned entry whose target falls
# under an operator-owned subtree prefix (or exactly matches an operator-
# owned file). This enforces the doctrine "products/ is operator-owned"
# against every other class: a stray `refresh | ... | products/foo.md`
# is rejected as a fatal manifest defect, never silently honored.
_manifest_apply_one() {
  local behavior="$1" src="$2" tgt="$3"
  # AGENTS.md predates the Codex engine and historically rendered the tiny
  # _base pointer for every Claude repo. Preserve that byte-for-byte contract;
  # only Codex rows adopt the archetype-specific AGENTS source named by the
  # manifest and ledger.
  if [ "$tgt" = "AGENTS.md" ] && [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ]; then
    src="_base/AGENTS.md"
  fi
  # Codex repository surfaces are opt-in by the configured engine. Legacy,
  # standalone, and Claude contexts skip them completely: no preflight, check,
  # write, delete, or ledger mutation.
  if _swarm_is_codex_managed_target "$tgt" && [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ] && [ "$tgt" != "AGENTS.md" ]; then
    return 0
  fi
  if [ "$behavior" != "operator-owned" ] && _swarm_target_in_oo_subtree "$tgt"; then
    echo "  ERROR: manifest entry '$behavior | $src | $tgt' targets operator-owned content (refused)" >&2
    echo "         operator-owned subtrees + files in this manifest:" >&2
    local p
    for p in $SWARM_OO_PREFIXES $SWARM_OO_FILES; do
      echo "           $p" >&2
    done
    SWARM_RESULT_FATAL=1
    return 1
  fi
  # The adoption preflight builds an in-memory allow/refuse set before the
  # manifest walk. This dispatcher check is the second half of the contract:
  # no managed Codex target can reach a write helper unless it was already
  # ledger-owned or proved absent/byte-identical (or an explicit onboard
  # --force-hooks operation for a hook path). Check/onboard refusals were
  # already reported by preflight and are skipped here to avoid contradictory
  # OK/OUTDATED output or a partial onboard write.
  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && _swarm_is_codex_managed_target "$tgt"; then
    if _swarm_codex_list_has "${SWARM_CODEX_REFUSED_LIST:-}" "$tgt"; then
      case "$SWARM_APPLY_MODE" in
        check|onboard) return 0 ;;
      esac
      echo "  ERROR: managed Codex target was refused by adoption preflight: $tgt" >&2
      SWARM_RESULT_FATAL=1
      return 1
    fi
    if [ "$SWARM_APPLY_MODE" != "check" ] && \
       ! _swarm_codex_list_has "${SWARM_CODEX_ALLOWED_LIST:-}" "$tgt"; then
      echo "  ERROR: managed Codex target lacks adoption authorization: $tgt" >&2
      SWARM_RESULT_FATAL=1
      return 1
    fi
  fi
  case "$behavior" in
    refresh)        manifest_apply_refresh        "$src" "$tgt" ;;
    compose)        manifest_apply_compose        "$src" "$tgt" ;;
    seed)           manifest_apply_seed           "$src" "$tgt" ;;
    seed-text)      manifest_apply_seed_text      "$src" "$tgt" ;;
    operator-owned) manifest_apply_operator_owned "$src" "$tgt" ;;
    settings)       manifest_apply_settings       "$src" "$tgt" ;;
    git-hook)       manifest_apply_git_hook       "$src" "$tgt" ;;
    gitignore)      manifest_apply_gitignore      "$src" "$tgt" ;;
    *)
      echo "  ERROR: unknown manifest behavior '$behavior' for $tgt" >&2
      SWARM_RESULT_FATAL=1
      return 1
      ;;
  esac
}

# _swarm_oo_canonical TGT_REL — print the canonical operator-owned form
# of a manifest target. A target whose basename is `.keep` declares the
# WHOLE parent directory operator-owned, so it canonicalizes to
# `<dir>/` (subtree prefix, trailing slash). Any other target
# canonicalizes to itself (exact file). This is the single rule both
# the prefix collector (manifest_apply) and the paths-list stamper
# (_swarm_stamp_operator_owned_list) consume — keeping the in-memory
# refusal set and the on-disk pre-commit contract in lockstep.
_swarm_oo_canonical() {
  local tgt_rel="$1"
  case "$tgt_rel" in
    */.keep|.keep)
      local dir
      dir="${tgt_rel%.keep}"
      [ -z "$dir" ] && dir="./"
      printf '%s' "$dir"
      ;;
    *)
      printf '%s' "$tgt_rel"
      ;;
  esac
}

# _swarm_target_in_oo_subtree TGT_REL — return 0 if TGT_REL falls under
# any operator-owned prefix (canonical form ending in `/`) or exactly
# equals any operator-owned file (canonical form without `/`). Reads
# SWARM_OO_PREFIXES + SWARM_OO_FILES, populated by manifest_apply's
# pre-walk.
_swarm_target_in_oo_subtree() {
  local tgt_rel="$1" p
  for p in $SWARM_OO_FILES; do
    [ "$tgt_rel" = "$p" ] && return 0
  done
  for p in $SWARM_OO_PREFIXES; do
    case "$tgt_rel" in
      "$p"*) return 0 ;;
    esac
  done
  return 1
}

# _swarm_load_oo_from_list REPO — populate SWARM_OO_PREFIXES + SWARM_OO_FILES
# from REPO's stamped .claude/operator-owned-paths (the same canonical list
# manifest_apply writes via _swarm_stamp_operator_owned_list and the Layer-3
# pre-commit hook reads: subtree-prefix entries end in `/`, exact-file entries
# do not). After this, _swarm_target_in_oo_subtree classifies a repo-relative
# path against EXACTLY the set manifest_apply will skip-and-never-commit.
#
# RESETS both vars first (so a stale set from an earlier call never leaks). A
# MISSING or empty list yields EMPTY sets — so nothing classifies as operator-
# owned and any caller's dirty-tree test fails SAFE to refuse. This is read-only
# and independent of manifest_apply's own pre-walk (which resets and repopulates
# these vars itself), so calling it before manifest_apply is harmless.
_swarm_load_oo_from_list() {
  local repo="$1" list="$1/.claude/operator-owned-paths" line path seen
  local prefixes="" files=""
  SWARM_OO_PREFIXES=""
  SWARM_OO_FILES=""
  [ ! -e "$list" ] && [ ! -L "$list" ] && return 0
  _swarm_authority_file_is_trusted "$list" || return 1
  seen="$(mktemp -t swarm-oo-ledger-seen.XXXXXX)" || return 1
  : > "$seen"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      */) path="${line%/}" ;;
      *)  path="$line" ;;
    esac
    if ! _swarm_safe_relative_path "$path" || \
       printf '%s' "$line" | LC_ALL=C grep -q '[[:space:][:cntrl:]]' || \
       grep -Fqx -- "$line" "$seen"; then
      rm -f "$seen"
      return 1
    fi
    printf '%s\n' "$line" >> "$seen"
    case "$line" in
      */) prefixes="$prefixes $line" ;;
      *)  files="$files $line" ;;
    esac
  done < "$list"
  rm -f "$seen"
  SWARM_OO_PREFIXES="$prefixes"
  SWARM_OO_FILES="$files"
  return 0
}

# swarm_dirty_classify_oo REPO — classify a repo's dirty working tree against
# its operator-owned set. Reads `git status --porcelain` and prints, to stdout,
# one line per dirty path that is NOT operator-owned (a sync-managed path:
# doctrine / hooks / settings / gitignore / anything outside products etc.).
# Empty stdout + a dirty tree => every dirty path is operator-owned (sync skips
# them all and will not commit them). Renames are split so BOTH the old and new
# path must be operator-owned. Return: 0 if the tree is dirty AND every dirty
# path is operator-owned; 1 otherwise (clean tree, OR at least one sync-managed
# path is dirty — printed). Unparseable/quoted paths fall through as NON-owned
# (fail-safe to refuse). Caller must have loaded the OO set first
# (_swarm_load_oo_from_list).
swarm_dirty_classify_oo() {
  local repo="$1" porcelain line path any_dirty=0 any_foreign=0
  porcelain="$(git -C "$repo" status --porcelain 2>/dev/null)"
  [ -n "$porcelain" ] || return 1   # clean tree: not "dirty-but-all-oo"
  # Split each porcelain entry into its path(s): strip the 2-col status + space,
  # and turn a rename "old -> new" into two paths so both must be operator-owned.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    any_dirty=1
    line="${line#???}"                 # drop the "XY " status prefix
    case "$line" in
      *" -> "*)
        for path in "${line%% -> *}" "${line##* -> }"; do
          _swarm_target_in_oo_subtree "$path" || { printf '%s\n' "$path"; any_foreign=1; }
        done ;;
      *)
        _swarm_target_in_oo_subtree "$line" || { printf '%s\n' "$line"; any_foreign=1; } ;;
    esac
  done <<EOF
$porcelain
EOF
  [ "$any_dirty" -eq 1 ] && [ "$any_foreign" -eq 0 ]
}

# _swarm_collect_oo_prefixes — manifest_walk callback that populates
# SWARM_OO_PREFIXES (space-separated subtree prefixes, each ending in `/`)
# and SWARM_OO_FILES (space-separated exact-file paths). Called in the
# pre-walk before _manifest_apply_one so the dispatcher's refusal set is
# fully known by the time any entry is processed.
_swarm_collect_oo_prefixes() {
  local behavior="$1" tgt="$3"
  [ "$behavior" = "operator-owned" ] || return 0
  local canon
  canon="$(_swarm_oo_canonical "$tgt")"
  case "$canon" in
    */)  SWARM_OO_PREFIXES="$SWARM_OO_PREFIXES $canon" ;;
    *)   SWARM_OO_FILES="$SWARM_OO_FILES $canon" ;;
  esac
}

# _swarm_stamp_operator_owned_list REPO
#
# Maintain .claude/operator-owned-paths — a flat list of every operator-
# owned target in the current archetype's manifest, one per line, in
# CANONICAL form: a `<dir>/.keep` manifest entry stamps as `<dir>/` (the
# whole directory, subtree-prefix form, trailing slash); any other
# operator-owned entry stamps as itself (exact-file form). Read by
# templates/<type>/git-hooks/pre-commit (Layer 3) which prefix-matches
# `/`-suffixed lines and exact-matches the rest, so a teammate cannot
# stage anything under an operator-owned subtree or onto an exact
# operator-owned file.
#
# Always reflects the current manifest exactly:
#   - has entries → file written with current set (overwrites stale).
#   - no entries → file removed (so removing operator-owned entries from
#     the manifest does not leave a stale block-list behind).
#   - check mode  → reports drift, no writes.
#   - dry-run     → reports the would-be change, no writes.
#
# Called once at the end of manifest_apply so each init/sync/onboard
# leaves the list in sync with the manifest.
_swarm_stamp_operator_owned_list() {
  local repo="$1"
  local list_path="$repo/.claude/operator-owned-paths"
  local list_path_rel=".claude/operator-owned-paths"
  local tmp
  tmp="$(mktemp -t swarm-oo.XXXXXX)" || return 1
  : > "$tmp"
  _collect_oo() {
    case "$1" in
      operator-owned) _swarm_oo_canonical "$3" >> "$tmp"; printf '\n' >> "$tmp" ;;
    esac
  }
  manifest_walk _collect_oo >/dev/null

  if [ -L "$list_path" ] || { [ -e "$list_path" ] && [ ! -f "$list_path" ]; }; then
    echo "  ERROR: unsafe $list_path_rel (must be a regular non-symlink file)" >&2
    SWARM_RESULT_FATAL=1
    rm -f "$tmp"
    return 1
  fi
  if [ -e "$list_path" ] && ! _swarm_authority_file_is_trusted "$list_path"; then
    echo "  ERROR: unsafe $list_path_rel (not a trusted operator authority file)" >&2
    SWARM_RESULT_FATAL=1
    rm -f "$tmp"
    return 1
  fi

  local has_entries=0
  [ -s "$tmp" ] && has_entries=1

  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    if [ "$has_entries" -eq 1 ]; then
      if [ ! -f "$list_path" ] || ! cmp -s "$tmp" "$list_path"; then
        echo "  DRIFT:     $list_path_rel  (operator-owned paths list)"
        SWARM_RESULT_DRIFT=1
      elif ! _swarm_plain_metadata_matches "$tmp" "$list_path" "$list_path_rel"; then
        echo "  METADATA:  $list_path_rel  (expected engine-safe readable metadata)"
        SWARM_RESULT_DRIFT=1
      fi
    elif [ -f "$list_path" ]; then
      echo "  DRIFT:     $list_path_rel  (should be removed; no operator-owned entries)"
      SWARM_RESULT_DRIFT=1
    fi
    rm -f "$tmp"
    return 0
  fi

  if [ "$has_entries" -eq 0 ]; then
    rm -f "$tmp"
    if [ -f "$list_path" ]; then
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would remove: $list_path_rel  (no operator-owned entries)"
      else
        rm -f "$list_path"
        echo "  removed: $list_path_rel  (no operator-owned entries)"
      fi
      SWARM_RESULT_CHANGED=1
    fi
    return 0
  fi

  if [ -f "$list_path" ] && [ ! -L "$list_path" ] && \
     cmp -s "$tmp" "$list_path" && \
     _swarm_plain_metadata_matches "$tmp" "$list_path" "$list_path_rel"; then
    rm -f "$tmp"
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would write: $list_path_rel  (operator-owned paths)"
    SWARM_RESULT_CHANGED=1
    rm -f "$tmp"
    return 0
  fi
  if ! _swarm_publish_plain "$tmp" "$list_path" "$list_path_rel"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  echo "  wrote: $list_path_rel  (operator-owned paths)"
  SWARM_RESULT_CHANGED=1
}

# ---------------------------------------------------------------------------
# Codex managed-path adoption ledger.
# ---------------------------------------------------------------------------
#
# `.claude/codex-managed-paths` is the ownership boundary for refresh-class
# `AGENTS.md`, `.codex/**`, and `.agents/skills/**` files. The first apply (and
# any later manifest expansion) may adopt only an absent or byte-identical target.
# A differing unowned target, symlink, or non-regular file is foreign and is
# refused before ANY manifest write. Once a target is in a valid ledger its
# ordinary content drift may be refreshed, but symlinks/non-regular files are
# always refused because copying through them could write outside the repo.
#
# The desired ledger is collected in manifest order, one exact repo-relative
# path per line. A successful live apply replaces it atomically from a temp in
# `.claude/`; check/dry-run never write it.

_swarm_codex_path_is_safe() {
  local path="$1"
  _swarm_is_codex_managed_target "$path" || return 1
  case "$path" in
    /*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;;
  esac
  printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
  return 0
}

_swarm_codex_list_has() {
  local list="${1:-}" path="$2"
  [ -n "$list" ] && [ -f "$list" ] || return 1
  grep -Fqx -- "$path" "$list" 2>/dev/null
}

_swarm_codex_list_add() {
  local list="$1" path="$2"
  printf '%s\n' "$path" >> "$list"
}

_swarm_codex_record_foreign() {
  local tgt_rel="$1" reason="$2"
  _swarm_codex_list_has "$SWARM_CODEX_REFUSED_LIST" "$tgt_rel" || \
    _swarm_codex_list_add "$SWARM_CODEX_REFUSED_LIST" "$tgt_rel"
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  FOREIGN:   $tgt_rel  ($reason)"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      echo "  COLLISION: $tgt_rel  ($reason; Codex path not adopted)"
      SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
codex-adoption:$tgt_rel"
      ;;
    init|sync)
      echo "  REFUSED:   $tgt_rel  ($reason; Codex path is not ledger-owned)" >&2
      SWARM_RESULT_FATAL=1
      ;;
  esac
}

_swarm_codex_validate_ledger() {
  local ledger="$SWARM_APPLY_REPO/.claude/codex-managed-paths"
  local seen line
  SWARM_CODEX_LEDGER_VALID=0
  SWARM_CODEX_LEDGER_PRESENT=0

  if [ -L "$ledger" ]; then
    SWARM_CODEX_LEDGER_ERROR="ownership ledger is a symlink"
    return 1
  fi
  if [ -e "$ledger" ] && [ ! -f "$ledger" ]; then
    SWARM_CODEX_LEDGER_ERROR="ownership ledger is not a regular file"
    return 1
  fi
  if [ ! -e "$ledger" ]; then
    SWARM_CODEX_LEDGER_VALID=1
    return 0
  fi
  SWARM_CODEX_LEDGER_PRESENT=1
  if [ ! -r "$ledger" ]; then
    SWARM_CODEX_LEDGER_ERROR="ownership ledger is unreadable"
    return 1
  fi
  # This file grants overwrite authority over every listed Codex surface.
  # Missing shared gid/read is repairable, but content that another principal
  # can mutate (or a hard-link alias can replace) is never trusted as a ledger.
  if ! _swarm_authority_file_is_trusted "$ledger"; then
    SWARM_CODEX_LEDGER_ERROR="ownership ledger is not an operator-owned single-link non-writable authority file"
    return 1
  fi

  seen="$(mktemp -t swarm-codex-ledger-seen.XXXXXX)" || {
    SWARM_CODEX_LEDGER_ERROR="could not validate ownership ledger"
    return 1
  }
  : > "$seen"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ] || \
       ! _swarm_codex_path_is_safe "$line" || \
       printf '%s' "$line" | LC_ALL=C grep -q '[[:cntrl:]]' || \
       _swarm_codex_list_has "$seen" "$line"; then
      rm -f "$seen"
      SWARM_CODEX_LEDGER_ERROR="ownership ledger has an invalid or duplicate entry"
      return 1
    fi
    _swarm_codex_list_add "$seen" "$line"
  done < "$ledger"
  rm -f "$seen"
  SWARM_CODEX_LEDGER_VALID=1
  return 0
}

_swarm_codex_report_bad_ledger() {
  local rel=".claude/codex-managed-paths"
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  FOREIGN:   $rel  ($SWARM_CODEX_LEDGER_ERROR)"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      echo "  COLLISION: $rel  ($SWARM_CODEX_LEDGER_ERROR)"
      SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
codex-ledger:$rel"
      ;;
    init|sync)
      echo "  REFUSED:   $rel  ($SWARM_CODEX_LEDGER_ERROR)" >&2
      SWARM_RESULT_FATAL=1
      ;;
  esac
}

# manifest_walk callback: build the exact desired ledger and classify every
# managed target without writing. It intentionally keeps scanning after a
# foreign collision so check/onboard can report the full set in one run.
_swarm_codex_preflight_one() {
  local behavior="$1" src_rel="$2" tgt_rel="$3"
  local src expected tmp="" owned=0
  _swarm_is_codex_managed_target "$tgt_rel" || return 0

  if ! _swarm_codex_path_is_safe "$tgt_rel"; then
    echo "  ERROR: unsafe managed Codex target in manifest: $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if _swarm_codex_list_has "$SWARM_CODEX_MANAGED_LIST" "$tgt_rel"; then
    echo "  ERROR: duplicate managed Codex target in manifest: $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  _swarm_codex_list_add "$SWARM_CODEX_MANAGED_LIST" "$tgt_rel"

  case "$behavior" in
    refresh)
      src="$SWARM_HOME/templates/$src_rel"
      if [ ! -f "$src" ]; then
        echo "  ERROR: template missing: $src_rel" >&2
        SWARM_RESULT_FATAL=1
        return 1
      fi
      expected="$src"
      ;;
    compose)
      tmp="$(mktemp -t swarm-codex-compose.XXXXXX)" || {
        echo "  ERROR: mktemp failed for Codex adoption: $tgt_rel" >&2
        SWARM_RESULT_FATAL=1
        return 1
      }
      if ! _compose_to_tmp "$src_rel" "$tmp"; then
        rm -f "$tmp"
        echo "  ERROR: compose failed for Codex adoption: $tgt_rel" >&2
        SWARM_RESULT_FATAL=1
        return 1
      fi
      expected="$tmp"
      ;;
    *)
      echo "  ERROR: managed Codex target must use refresh/compose: $behavior | $src_rel | $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      return 1
      ;;
  esac

  if [ "$SWARM_CODEX_LEDGER_VALID" -eq 1 ] && \
     [ "$SWARM_CODEX_LEDGER_PRESENT" -eq 1 ] && \
     _swarm_codex_list_has "$SWARM_APPLY_REPO/.claude/codex-managed-paths" "$tgt_rel"; then
    owned=1
  fi

  # Never follow a target symlink, even when a prior ledger claims ownership.
  if [ -L "$SWARM_APPLY_REPO/$tgt_rel" ]; then
    _swarm_codex_record_foreign "$tgt_rel" "target is a symlink"
  elif [ -e "$SWARM_APPLY_REPO/$tgt_rel" ] && [ ! -f "$SWARM_APPLY_REPO/$tgt_rel" ]; then
    _swarm_codex_record_foreign "$tgt_rel" "target is not a regular file"
  elif [ ! -e "$SWARM_APPLY_REPO/$tgt_rel" ] || \
       cmp -s "$expected" "$SWARM_APPLY_REPO/$tgt_rel"; then
    _swarm_codex_list_add "$SWARM_CODEX_ALLOWED_LIST" "$tgt_rel"
  elif [ "$tgt_rel" = "AGENTS.md" ] && \
       [ -f "$SWARM_HOME/templates/_base/AGENTS.md" ] && \
       cmp -s "$SWARM_HOME/templates/_base/AGENTS.md" "$SWARM_APPLY_REPO/$tgt_rel"; then
    # The tiny _base/AGENTS.md pointer is itself the canonical managed Claude
    # surface. Treat that one exact byte sequence as a safe first Codex
    # adoption so a normally initialized Claude repo can migrate. This does
    # not authorize arbitrary doctrine replacement: every differing unowned
    # AGENTS file still follows the foreign-content refusal below.
    _swarm_codex_list_add "$SWARM_CODEX_ALLOWED_LIST" "$tgt_rel"
  elif [ "$owned" -eq 1 ]; then
    # Ledger ownership permits ordinary managed drift to be refreshed. The
    # onboard helper still applies its explicit collision/force policy.
    _swarm_codex_list_add "$SWARM_CODEX_ALLOWED_LIST" "$tgt_rel"
  elif [ "$SWARM_APPLY_MODE" = "onboard" ] && \
       [ "${SWARM_FORCE_HOOKS:-0}" -eq 1 ] && _swarm_is_hook "$tgt_rel"; then
    # The only adoption bypass is the already-public, concern-specific
    # onboarding flag. --force-docs/--force-seed never authorize Codex paths.
    _swarm_codex_list_add "$SWARM_CODEX_ALLOWED_LIST" "$tgt_rel"
  elif [ "$SWARM_APPLY_MODE" = "onboard" ] && \
       [ "${SWARM_FORCE_DOCS:-0}" -eq 1 ] && _swarm_is_doctrine "$tgt_rel"; then
    # AGENTS.md remains under the existing explicit doctrine force flag.
    _swarm_codex_list_add "$SWARM_CODEX_ALLOWED_LIST" "$tgt_rel"
  else
    _swarm_codex_record_foreign "$tgt_rel" "existing file differs from template"
  fi
  [ -z "$tmp" ] || rm -f "$tmp"
  return 0
}

_swarm_codex_adoption_preflight() {
  local ledger="$SWARM_APPLY_REPO/.claude/codex-managed-paths"
  SWARM_CODEX_MANAGED_LIST="$(mktemp -t swarm-codex-managed.XXXXXX)" || return 1
  SWARM_CODEX_ALLOWED_LIST="$(mktemp -t swarm-codex-allowed.XXXXXX)" || {
    rm -f "$SWARM_CODEX_MANAGED_LIST"; return 1; }
  SWARM_CODEX_REFUSED_LIST="$(mktemp -t swarm-codex-refused.XXXXXX)" || {
    rm -f "$SWARM_CODEX_MANAGED_LIST" "$SWARM_CODEX_ALLOWED_LIST"; return 1; }
  : > "$SWARM_CODEX_MANAGED_LIST"
  : > "$SWARM_CODEX_ALLOWED_LIST"
  : > "$SWARM_CODEX_REFUSED_LIST"
  SWARM_CODEX_LEDGER_ERROR=""

  if ! _swarm_codex_validate_ledger; then
    _swarm_codex_report_bad_ledger
  fi
  manifest_walk _swarm_codex_preflight_one || return $?

  # Check reports both content ownership problems above and the exact-ledger
  # drift here. A first-time safe adoption therefore reports the missing
  # ledger without writing it.
  if [ "$SWARM_APPLY_MODE" = "check" ] && [ "$SWARM_CODEX_LEDGER_VALID" -eq 1 ]; then
    if [ ! -e "$ledger" ]; then
      if [ -s "$SWARM_CODEX_MANAGED_LIST" ]; then
        echo "  MISSING:   .claude/codex-managed-paths  (Codex ownership ledger)"
        SWARM_RESULT_DRIFT=1
      fi
    elif ! cmp -s "$SWARM_CODEX_MANAGED_LIST" "$ledger"; then
      echo "  DRIFT:     .claude/codex-managed-paths  (Codex ownership ledger)"
      SWARM_RESULT_DRIFT=1
    elif ! _swarm_plain_metadata_matches \
        "$SWARM_CODEX_MANAGED_LIST" "$ledger" ".claude/codex-managed-paths"; then
      echo "  METADATA:  .claude/codex-managed-paths  (expected Codex-readable metadata)"
      SWARM_RESULT_DRIFT=1
    fi
  fi

  [ "$SWARM_RESULT_FATAL" -eq 0 ]
}

_swarm_cleanup_codex_preflight() {
  local list
  for list in "${SWARM_CODEX_MANAGED_LIST:-}" \
              "${SWARM_CODEX_ALLOWED_LIST:-}" \
              "${SWARM_CODEX_REFUSED_LIST:-}"; do
    [ -z "$list" ] || rm -f "$list"
  done
  SWARM_CODEX_MANAGED_LIST=""
  SWARM_CODEX_ALLOWED_LIST=""
  SWARM_CODEX_REFUSED_LIST=""
}

_swarm_stamp_codex_managed_list() {
  local repo="$1" ledger="$1/.claude/codex-managed-paths"
  local rel=".claude/codex-managed-paths" tmp

  [ "$SWARM_APPLY_MODE" != "check" ] || return 0
  if [ ! -s "$SWARM_CODEX_MANAGED_LIST" ]; then
    if [ -e "$ledger" ] || [ -L "$ledger" ]; then
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would remove: $rel  (no managed Codex paths)"
      else
        rm -f "$ledger" || return 1
        echo "  removed: $rel  (no managed Codex paths)"
      fi
      SWARM_RESULT_CHANGED=1
    fi
    return 0
  fi
  if [ -f "$ledger" ] && [ ! -L "$ledger" ] && \
     cmp -s "$SWARM_CODEX_MANAGED_LIST" "$ledger" && \
     _swarm_plain_metadata_matches \
       "$SWARM_CODEX_MANAGED_LIST" "$ledger" "$rel"; then
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would write: $rel  (Codex ownership ledger)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi

  if ! _swarm_publish_plain "$SWARM_CODEX_MANAGED_LIST" "$ledger" "$rel"; then
    return 1
  fi
  echo "  wrote: $rel  (Codex ownership ledger)"
  SWARM_RESULT_CHANGED=1
  return 0
}

# Read-only launch integrity gate for a configured Codex row. It requires the
# ownership ledger to be exact for the selected archetype and every managed
# Codex surface to remain a regular, byte-canonical file. This catches a Claude
# row that was manually relabeled `codex`, partial migrations, removed skills,
# and hook/rule/AGENTS drift before the daemon starts. The explicit launcher
# sanity bypass may skip this policy gate; subscription/toolchain/state floors
# remain mandatory.
swarm_codex_managed_surfaces_check() {  # repo
  local repo="$1" ledger tmp_expected rc=0
  ledger="$repo/.claude/codex-managed-paths"
  if [ -L "$ledger" ] || [ ! -f "$ledger" ]; then
    echo "Codex managed-surface check: ownership ledger missing/unsafe: $ledger" >&2
    return 1
  fi
  SWARM_APPLY_REPO="$repo"
  SWARM_APPLY_TYPE="$(swarm_type_of "$repo")"
  SWARM_APPLY_PROFILE="$(swarm_profile_of "$repo")"
  SWARM_APPLY_CANON_MODE="$(swarm_canon_mode_of "$repo")"
  export SWARM_APPLY_REPO SWARM_APPLY_TYPE SWARM_APPLY_PROFILE SWARM_APPLY_CANON_MODE
  tmp_expected="$(mktemp -t swarm-codex-launch-ledger.XXXXXX)" || return 1
  : > "$tmp_expected"
  _swarm_codex_launch_check_one() {
    local behavior="$1" src_rel="$2" tgt_rel="$3" expected="" composed=""
    _swarm_is_codex_managed_target "$tgt_rel" || return 0
    if ! _swarm_codex_path_is_safe "$tgt_rel" || grep -Fqx -- "$tgt_rel" "$tmp_expected"; then
      echo "Codex managed-surface check: unsafe/duplicate manifest target: $tgt_rel" >&2
      rc=1
      return 0
    fi
    printf '%s\n' "$tgt_rel" >> "$tmp_expected"
    case "$behavior" in
      refresh) expected="$SWARM_HOME/templates/$src_rel" ;;
      compose)
        composed="$(mktemp -t swarm-codex-launch-content.XXXXXX)" || { rc=1; return 0; }
        if ! _compose_to_tmp "$src_rel" "$composed"; then
          rm -f "$composed"; rc=1; return 0
        fi
        expected="$composed"
        ;;
      *)
        echo "Codex managed-surface check: unsupported behavior for $tgt_rel: $behavior" >&2
        rc=1
        return 0
        ;;
    esac
    if [ ! -f "$expected" ] || [ -L "$repo/$tgt_rel" ] || \
       [ ! -f "$repo/$tgt_rel" ] || ! cmp -s "$expected" "$repo/$tgt_rel"; then
      echo "Codex managed-surface check: missing/unsafe/drifted target: $tgt_rel" >&2
      rc=1
    fi
    [ -z "$composed" ] || rm -f "$composed"
    return 0
  }
  manifest_walk _swarm_codex_launch_check_one || rc=1
  unset -f _swarm_codex_launch_check_one
  if [ ! -s "$tmp_expected" ] || ! cmp -s "$tmp_expected" "$ledger"; then
    echo "Codex managed-surface check: ledger does not exactly match the archetype manifest" >&2
    rc=1
  fi
  # A syntactically odd ledger must never become an ownership oracle even if
  # byte comparison happened to match a malformed manifest.
  SWARM_APPLY_MODE=check
  SWARM_CODEX_LEDGER_ERROR=""
  _swarm_codex_validate_ledger >/dev/null 2>&1 || rc=1
  rm -f "$tmp_expected"
  return "$rc"
}

# manifest_apply REPO MODE [QUIET_UNCHANGED]
#   Modes:
#     init     — first stamp; --force re-seeds spec + test-cmd via SWARM_FORCE_SEED=1
#     sync     — upgrade existing repo; structured-merge settings
#     onboard  — pre-existing real repo; refuse-and-report on conflict
#     check    — dry-run drift report; never writes
#
# Resets and exports SWARM_RESULT_* outputs so callers can read them.
manifest_apply() {
  local repo="$1" mode="$2"
  [ -d "$repo" ] || { echo "swarm-lib: not a directory: $repo" >&2; return 1; }
  case "$mode" in init|sync|onboard|check) ;; *)
    echo "swarm-lib: invalid mode '$mode'" >&2; return 1 ;;
  esac
  # Prove marker objects before the resolver reads repo-controlled type/profile/
  # canon selections. A final or parent symlink must not turn those reads into
  # an access outside the repository.
  _swarm_validate_repo_markers "$repo" || return 1
  SWARM_APPLY_REPO="$repo"
  SWARM_APPLY_MODE="$mode"
  SWARM_APPLY_ENGINE="${SWARM_APPLY_ENGINE_OVERRIDE:-claude}"
  case "$SWARM_APPLY_ENGINE" in
    claude|codex) ;;
    *) echo "swarm-lib: invalid apply engine '$SWARM_APPLY_ENGINE'" >&2; return 1 ;;
  esac
  SWARM_APPLY_TYPE="${SWARM_APPLY_TYPE_OVERRIDE:-$(swarm_type_of "$repo")}" # init may preselect before marker stamp
  # Orthogonal profile axis (ADR-0013): empty for markerless swarms (no-op).
  # Consumed by manifest_apply_compose to optionally append a profile overlay
  # to the composed CLAUDE.md (engineering-cto only).
  if [ "${SWARM_APPLY_PROFILE_OVERRIDE_SET:-0}" -eq 1 ]; then
    SWARM_APPLY_PROFILE="${SWARM_APPLY_PROFILE_OVERRIDE:-}"
  else
    SWARM_APPLY_PROFILE="$(swarm_profile_of "$repo")"
  fi
  # Orthogonal source-of-truth axis: 'local' (default, no-op) or 'external'.
  # Consumed by manifest_apply_compose to append the external-canon overlay
  # + the repo-local canon binding to the composed CLAUDE.md
  # (engineering-cto only). See docs/CANON-MODES.md.
  SWARM_APPLY_CANON_MODE="$(swarm_canon_mode_of "$repo")"
  SWARM_RESULT_CHANGED=0
  SWARM_RESULT_DRIFT=0
  SWARM_RESULT_COLLISIONS=""
  SWARM_RESULT_FOREIGN_PRECOMMIT=0
  SWARM_RESULT_FATAL=0
  export SWARM_APPLY_REPO SWARM_APPLY_MODE SWARM_APPLY_TYPE SWARM_APPLY_PROFILE SWARM_APPLY_CANON_MODE SWARM_APPLY_ENGINE
  # Validate repo-controlled marker selection plus the complete manifest before
  # any helper is allowed to create, overwrite, or remove a target.
  if ! _swarm_validate_apply_selection || \
     ! manifest_walk _swarm_validate_manifest_entry >/dev/null; then
    SWARM_RESULT_FATAL=1
    return 1
  fi
  # Pre-walk: collect operator-owned prefixes + exact files so the
  # dispatcher can refuse any other manifest entry that would write into
  # an operator-owned subtree (the doctrine "products/ is sacred"
  # enforced across every class, every --force flag).
  SWARM_OO_PREFIXES=""
  SWARM_OO_FILES=""
  manifest_walk _swarm_collect_oo_prefixes >/dev/null || return $?
  # Migration gate: scan every managed Codex target before the first manifest
  # helper is allowed to write. This is deliberately ahead of the ordinary
  # walk so one foreign file cannot cause partial updates elsewhere.
  SWARM_CODEX_MANAGED_LIST=""
  SWARM_CODEX_ALLOWED_LIST=""
  SWARM_CODEX_REFUSED_LIST=""
  if [ "$SWARM_APPLY_ENGINE" = "codex" ]; then
    if ! _swarm_codex_adoption_preflight; then
      _swarm_cleanup_codex_preflight
      return 1
    fi
  fi
  # A live direct onboard call must not write around an adoption collision.
  # The wrapper's SWARM_DRY_RUN preflight may continue so it can report the
  # rest of the manifest plan without writing anything.
  if [ "$mode" = "onboard" ] && [ -n "$SWARM_RESULT_COLLISIONS" ] && \
     [ "${SWARM_DRY_RUN:-0}" -ne 1 ]; then
    _swarm_cleanup_codex_preflight
    return 0
  fi
  if ! manifest_walk _manifest_apply_one; then
    _swarm_cleanup_codex_preflight
    return 1
  fi
  if [ "$SWARM_RESULT_FATAL" -eq 1 ]; then
    _swarm_cleanup_codex_preflight
    return 1
  fi
  # Auto-stamp the operator-owned paths list (no-op if no entries; deletes
  # the file if entries were removed from the manifest). MUST run after the
  # walk so the list reflects the current manifest, never partial state.
  if ! _swarm_stamp_operator_owned_list "$repo"; then
    SWARM_RESULT_FATAL=1
    _swarm_cleanup_codex_preflight
    return 1
  fi
  # Stamp only after the entire manifest walk succeeds. The file is replaced
  # atomically and always contains exactly the current managed target set.
  if [ "$SWARM_APPLY_ENGINE" = "codex" ] && [ -z "$SWARM_RESULT_COLLISIONS" ]; then
    if ! _swarm_stamp_codex_managed_list "$repo"; then
      echo "  ERROR: could not stamp .claude/codex-managed-paths" >&2
      SWARM_RESULT_FATAL=1
      _swarm_cleanup_codex_preflight
      return 1
    fi
  fi
  _swarm_cleanup_codex_preflight
  return 0
}

manifest_check() {
  manifest_apply "$1" check
}

# ---------------------------------------------------------------------------
# 3) Structured settings.json merger.
# ---------------------------------------------------------------------------
#
# settings_merge_swarm TARGET TEMPLATE [--check]
#
# Reads TARGET (existing repo .claude/settings.json) and TEMPLATE
# ($SWARM_HOME/templates/<type>/settings.example.json), produces a merged object,
# and atomically writes it back to TARGET. Foreign hook entries (anything
# whose command does NOT reference $CLAUDE_PROJECT_DIR/.claude/hooks/) are
# preserved. Swarm hooks are deduplicated by command path — running this
# multiple times is idempotent.
#
# Merge rules:
#   - Top-level scalars: template wins if target's value is missing.
#     Existing target scalars are LEFT ALONE (operator may have customized
#     env.CLAUDE_TEST_CMD, teammateMode, etc.).
#   - env: union; target's existing keys keep their values.
#   - enabledPlugins: union; target's existing entries keep their values.
#   - permissions.allow: union (dedup, sorted).
#   - hooks.<event>: for each swarm hook in the template, ensure it appears
#     exactly once in the target's flat list of {type,command,timeout}
#     entries. Foreign entries preserved in place; swarm entries that drift
#     (e.g., wrong timeout) are corrected to the template value.
#
# Exit codes:
#   0 — merge applied and written (target changed).
#   3 — already in sync (no changes needed). [non-zero so callers branch easily]
#   2 — fatal: parse failure, write failure, etc.
#
# With --check: 0 if already-in-sync, 3 if merge would change something, 2 on
# error. (Caller reads exit code, never writes.)
settings_merge_swarm() {
  local target="$1" template="$2" check_only=""
  [ "${3:-}" = "--check" ] && check_only="1"
  SWARM_SETTINGS_CONTENT_DRIFT=0
  SWARM_SETTINGS_METADATA_DRIFT=0
  if [ -L "$target" ] || [ ! -f "$target" ] || [ -L "$template" ] || [ ! -f "$template" ]; then
    echo "settings_merge_swarm: missing file: $target or $template" >&2
    return 2
  fi
  local tmp dir plan desired_mode desired_gid target_rel="$target"
  if [ -n "${SWARM_APPLY_REPO:-}" ]; then
    target_rel="${target#"${SWARM_APPLY_REPO}/"}"
  fi
  if ! _swarm_plain_metadata_matches "$template" "$target" "$target_rel"; then
    SWARM_SETTINGS_METADATA_DRIFT=1
  fi
  if [ -n "$check_only" ]; then
    tmp="$(mktemp -t swarm-settings.XXXXXX)" || return 2
  else
    dir="$(dirname "$target")"
    tmp="$(mktemp "$dir/.swarm-settings.XXXXXX")" || return 2
    # Preserve safe Claude ACL/xattr state on the unpublished staging inode.
    # chmod is temporary; the exact final plan is restored before rename.
    if { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! cat "$target" > "$tmp"; } || \
       { [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ] && ! cp -p "$target" "$tmp"; } || \
       ! chmod u+w "$tmp"; then
      rm -f "$tmp"
      return 2
    fi
  fi

  # Run merger in python3, write result to $tmp, signal status via exit code.
  # argv[5]: optional retired-rules file — permission rules doctrine has
  # explicitly RETIRED; the merge REMOVES exact matches from the target's
  # permissions.allow/deny (the merge is otherwise additive-only, so a rule
  # doctrine walked back would persist in every stamped repo forever).
  python3 - "$target" "$template" "$tmp" "${check_only:-}" "${SWARM_HOME:+$SWARM_HOME/templates/settings-retired.conf}" <<'PY'
import json, sys, os

target_path, template_path, out_path, check_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

retired = set()
retired_path = sys.argv[5] if len(sys.argv) > 5 else ""
if retired_path and os.path.exists(retired_path):
    try:
        with open(retired_path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line:
                    retired.add(line)
    except Exception as e:
        sys.stderr.write(f"settings_merge_swarm: retired-rules read failure: {e}\n")
        sys.exit(2)

def load(p):
    with open(p) as f:
        return json.load(f)

try:
    tgt = load(target_path)
    tpl = load(template_path)
except Exception as e:
    sys.stderr.write(f"settings_merge_swarm: parse failure: {e}\n")
    sys.exit(2)

if not isinstance(tgt, dict) or not isinstance(tpl, dict):
    sys.stderr.write("settings_merge_swarm: settings root must be an object\n")
    sys.exit(2)

import copy
before = json.dumps(tgt, sort_keys=True)

# --- Top-level scalars: only fill missing ---
for k, v in tpl.items():
    if k in ("env", "enabledPlugins", "permissions", "hooks"):
        continue
    if k not in tgt:
        tgt[k] = copy.deepcopy(v)

# --- env: union, target wins on conflict ---
tpl_env = tpl.get("env") or {}
tgt_env = tgt.get("env") or {}
for k, v in tpl_env.items():
    if k not in tgt_env:
        tgt_env[k] = v
if tpl_env or tgt_env:
    tgt["env"] = tgt_env

# --- enabledPlugins: union, target wins ---
tpl_ep = tpl.get("enabledPlugins") or {}
tgt_ep = tgt.get("enabledPlugins") or {}
for k, v in tpl_ep.items():
    if k not in tgt_ep:
        tgt_ep[k] = v
if tpl_ep or tgt_ep:
    tgt["enabledPlugins"] = tgt_ep

# --- permissions.allow/deny: union + dedup, preserve order with new items
# appended; then drop doctrine-RETIRED rules from both lists (the only
# subtractive step in the merge, driven solely by settings-retired.conf) ---
tpl_perm = tpl.get("permissions") or {}
tgt_perm = tgt.get("permissions") or {}
def union_rules(key):
    tpl_list = list(tpl_perm.get(key) or [])
    tgt_list = list(tgt_perm.get(key) or [])
    seen = set(tgt_list)
    for item in tpl_list:
        if item not in seen:
            tgt_list.append(item)
            seen.add(item)
    return [r for r in tgt_list if r not in retired]
if tpl_perm or tgt_perm:
    tgt_perm["allow"] = union_rules("allow")
    tgt_perm["deny"] = union_rules("deny")
    # Preserve any other fields the operator may have under permissions.
    for k, v in tpl_perm.items():
        if k not in ("allow", "deny") and k not in tgt_perm:
            tgt_perm[k] = copy.deepcopy(v)
    tgt["permissions"] = tgt_perm

# --- hooks: per-event swarm-aware merge ---
SWARM_HOOK_MARKER = "$CLAUDE_PROJECT_DIR/.claude/hooks/"

def hook_cmd_filename(cmd):
    """Return the swarm hook's filename (e.g., 'test-gate.sh') if the
    command references a swarm-managed hook; else None."""
    if not isinstance(cmd, str):
        return None
    idx = cmd.find(SWARM_HOOK_MARKER)
    if idx < 0:
        return None
    rest = cmd[idx + len(SWARM_HOOK_MARKER):]
    # Strip a possible trailing quote and anything beyond the .sh.
    for q in ('"', "'", " "):
        cut = rest.find(q)
        if cut >= 0:
            rest = rest[:cut]
    return rest or None

def collect_swarm_entries(event_block):
    """From the template's event_block, return dict: filename -> entry."""
    out = {}
    for matcher in event_block or []:
        for h in matcher.get("hooks") or []:
            fn = hook_cmd_filename(h.get("command"))
            if fn:
                out[fn] = h
    return out

tpl_hooks = tpl.get("hooks") or {}
tgt_hooks = tgt.get("hooks") or {}

for event, tpl_event in tpl_hooks.items():
    tpl_swarm = collect_swarm_entries(tpl_event)
    if not tpl_swarm:
        continue
    tgt_event = tgt_hooks.get(event)
    if not tgt_event:
        # No entries yet for this event — drop the template's full block in.
        tgt_hooks[event] = copy.deepcopy(tpl_event)
        continue
    # Walk existing matchers, dedup-by-command and update swarm entries.
    seen_swarm = set()
    for matcher in tgt_event:
        new_hooks = []
        for h in matcher.get("hooks") or []:
            fn = hook_cmd_filename(h.get("command"))
            if fn and fn in tpl_swarm:
                if fn in seen_swarm:
                    # Drop duplicate swarm entry.
                    continue
                seen_swarm.add(fn)
                # Replace with template's version (corrects timeout drift).
                new_hooks.append(copy.deepcopy(tpl_swarm[fn]))
            else:
                # Foreign or unknown — preserve verbatim.
                new_hooks.append(h)
        matcher["hooks"] = new_hooks
    # Any swarm entry not yet present anywhere: add to a fresh matcher block.
    missing = [fn for fn in tpl_swarm if fn not in seen_swarm]
    if missing:
        tgt_event.append({"hooks": [copy.deepcopy(tpl_swarm[fn]) for fn in missing]})

if tpl_hooks or tgt_hooks:
    tgt["hooks"] = tgt_hooks

after = json.dumps(tgt, sort_keys=True)
changed = (before != after)

if check_only:
    sys.exit(3 if changed else 0)

if not changed:
    sys.exit(3)

# Write the merged bytes to the caller-provided staging path.  The shell sets
# final metadata and performs the same-directory atomic rename.
try:
    with open(out_path, "w") as f:
        json.dump(tgt, f, indent=2)
        f.write("\n")
except Exception as e:
    sys.stderr.write(f"settings_merge_swarm: write failure: {e}\n")
    sys.exit(2)
sys.exit(0)
PY
  local rc=$?
  if [ -n "$check_only" ]; then
    rm -f "$tmp"
    case "$rc" in
      0) ;;
      3) SWARM_SETTINGS_CONTENT_DRIFT=1 ;;
      *) return "$rc" ;;
    esac
    if [ "$SWARM_SETTINGS_CONTENT_DRIFT" -eq 1 ] || \
       [ "$SWARM_SETTINGS_METADATA_DRIFT" -eq 1 ]; then
      return 3
    fi
    return 0
  fi
  case "$rc" in
    0) SWARM_SETTINGS_CONTENT_DRIFT=1 ;;
    3)
      if [ "$SWARM_SETTINGS_METADATA_DRIFT" -eq 0 ]; then
        rm -f "$tmp"
        return 3
      fi
      ;;
    *) rm -f "$tmp"; return "$rc" ;;
  esac

  plan="$(_swarm_plain_metadata_plan "$template" "$target" "$target_rel")" || {
    rm -f "$tmp"
    return 2
  }
  desired_mode="${plan%% *}"
  desired_gid="${plan#* }"
  if ! chgrp "$desired_gid" "$tmp" || \
     ! chmod "$desired_mode" "$tmp" || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_strip_file_acl "$tmp"; } || \
     [ "$(_swarm_stat_mode "$tmp")" != "$desired_mode" ] || \
     [ "$(_swarm_stat_gid "$tmp")" != "$desired_gid" ] || \
     { [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ] && ! _swarm_file_acl_is_safe "$tmp"; } || \
     ! mv -f "$tmp" "$target"; then
    echo "settings_merge_swarm: rename failed for $target" >&2
    rm -f "$tmp"
    return 2
  fi
  return 0
}
