#!/usr/bin/env bash
# swarm-add.sh — complete, interactive end-to-end standup for a new swarm.
#
# Walks the operator through every step of bringing up a new swarm — the
# manual Discord-portal steps (with exact instructions), the silent token
# read, and the local config writes — and ends with a verification
# checklist for confirming the swarm is actually live.
#
# A Discord bot token can hold only one gateway connection, so every swarm
# needs its own bot. The Discord portal steps are manual (the portal has no
# usable API for app creation). Everything else is scripted here.
#
# Usage:
#   swarm-add.sh <name> <repo_path> [<channel_id>] [flags...]
#
#   <name>         short, no spaces, [a-zA-Z][a-zA-Z0-9_-]*  (becomes tmux
#                  session "swarm-<name>")
#   <repo_path>    absolute or relative path to the product repo
#   <channel_id>   OPTIONAL numeric Discord channel ID. If omitted, the
#                  script walks you through Developer Mode + Copy ID and
#                  prompts for it interactively (phase 2).
#
# Flags:
#   --rotate-token       force a re-prompt for the bot token even if one is
#                        already present in tokens.env (default: keep it)
#   --skip-walkthrough   skip the Discord-portal walkthrough (phase 1) —
#                        for re-runs or operators who set up the Discord
#                        side another way
#   --type <name>        stamp the swarm as a specific archetype
#                        (engineering-cto / cpo / company-brain). Default
#                        is engineering-cto when omitted; no marker is
#                        written. Threaded to swarm-init.
#   --profile <name>     engineering-cto-only profile overlay (frontend /
#                        backend; ADR-0013). Threaded to swarm-init, which
#                        stamps .claude/swarm-profile and composes a
#                        stack-specific overlay onto CLAUDE.md. v1 'backend'
#                        is label-only. Refused with a non-engineering-cto
#                        --type. Omit for no profile.
#   --engine <name>      lead runtime: claude (default) or codex. Codex uses
#                        codex-bridge + the dedicated hidden-account login from
#                        `swarm-codex-runtime.sh login`; Claude remains the
#                        byte-compatible default.
#   --codex-auth-pool <name>
#                        named ordered profile pool from codex-profiles.json.
#                        Codex-only; blank field 8 resolves to `default`.
#   --bot-user-id <id>   the new swarm's Discord BOT USER id (== the app's
#                        Application ID). For engineering-cto swarms this is
#                        written into cto-watcher/config.json so the CTO
#                        rides the #cpo-cto-bus. If omitted, phase 2 prompts
#                        for it (engineering-cto only).
#   -h, --help           this help
#
# Does NOT launch the swarm. Phase 6 prints the verification commands the
# operator runs after this script returns.
#
# Idempotent: re-running on a partially-configured swarm SKIPs each phase
# whose effect is already present rather than failing or double-applying.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-add: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
TOKENS="$SWARM_HOME/tokens.env"
CONF="$SWARM_HOME/swarm.conf"
OWNER_ID="${SWARM_OWNER_DISCORD_ID:-1507069153335443608}"
# ACCESS (the new swarm's access.json) is the account-resolver's job, never a
# hand-built $HOME/.claude path. It's resolved from the new swarm's account
# AFTER swarm-lib.sh is sourced below — swarm-add adds the default (empty)
# account for now, which the resolver maps byte-for-byte to today's path
# (honoring SWARM_ACCESS_FILE). ACCESS is first USED in phase 4d, long after.
PLUGIN_KEY="discord-b2b@qofi-swarm"

# cto-watcher bus wiring. An engineering-cto swarm only rides the
# #cpo-cto-bus once it has BOTH a ctoChannels entry in the watcher's
# config.json AND the watcher bot's id in its channel's access.json
# allowFrom (else the watcher reposts CPO directives the new CTO silently
# drops). Phase 4e does both. cpo / company-brain swarms are not CTOs and
# are skipped. Override CTO_WATCHER_CONFIG / CTO_BUS_WATCHER_BOT_ID via env
# for tests.
CTO_WATCHER_CONFIG="${CTO_WATCHER_CONFIG:-$SWARM_HOME/cto-watcher/config.json}"
CTO_BUS_WATCHER_BOT_ID="${CTO_BUS_WATCHER_BOT_ID:-1510298728148369448}"
SWARM_BUS_CHANNEL="${SWARM_BUS_CHANNEL:-1510301812434141194}"

case "$OWNER_ID" in ''|*[!0-9]*) echo "swarm-add: SWARM_OWNER_DISCORD_ID must be numeric" >&2; exit 1 ;; esac
case "$CTO_BUS_WATCHER_BOT_ID" in ''|*[!0-9]*) echo "swarm-add: CTO_BUS_WATCHER_BOT_ID must be numeric" >&2; exit 1 ;; esac
case "$SWARM_BUS_CHANNEL" in ''|*[!0-9]*) echo "swarm-add: SWARM_BUS_CHANNEL must be numeric" >&2; exit 1 ;; esac

SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
CODEX_RUNTIME_BIN="${SWARM_CODEX_RUNTIME_BIN:-$SCRIPT_DIR_EARLY/swarm-codex-runtime.sh}"
# Source the lib for swarm_type_is_known (used to validate --type before
# any Discord-side side-effects).
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR_EARLY/swarm-lib.sh"

# Resolve a provisional default access path for new/Codex rows. After the
# existing row is parsed below, a Claude target is re-resolved through its
# actual ACCOUNT label. This resolver remains the sole path constructor.
if ! swarm_account_resolve ""; then
  echo "swarm-add: could not resolve the account's access.json path" >&2
  exit 1
fi
ACCESS="$SWARM_ACCT_ACCESS_FILE"

usage() {
  sed -n '1,53p' "$0"
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing — positional [name [repo [channel]]] + flags in any order.
# --type takes a value (next arg, or --type=<val>); use while/shift so the
# two-arg form works.
# ---------------------------------------------------------------------------
NAME=""
REPO=""
CHANNEL=""
CHANNEL_EXPLICIT=0
ROTATE_TOKEN=0
SKIP_WALKTHROUGH=0
TYPE=""
PROFILE=""
BOT_USER_ID=""
ENGINE="claude"
ENGINE_EXPLICIT=0
CODEX_AUTH_POOL="default"
CODEX_AUTH_POOL_EXPLICIT=0
POS_COUNT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --rotate-token)     ROTATE_TOKEN=1; shift ;;
    --skip-walkthrough) SKIP_WALKTHROUGH=1; shift ;;
    --type)
      [ $# -ge 2 ] || { echo "swarm-add: --type requires a value" >&2; usage 1; }
      TYPE="$2"; shift 2 ;;
    --type=*)
      TYPE="${1#--type=}"; shift ;;
    --profile)
      [ $# -ge 2 ] || { echo "swarm-add: --profile requires a value" >&2; usage 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#--profile=}"; shift ;;
    --engine)
      [ $# -ge 2 ] || { echo "swarm-add: --engine requires a value" >&2; usage 1; }
      ENGINE="$2"; ENGINE_EXPLICIT=1; shift 2 ;;
    --engine=*)
      ENGINE="${1#--engine=}"; ENGINE_EXPLICIT=1; shift ;;
    --codex-auth-pool)
      [ $# -ge 2 ] || { echo "swarm-add: --codex-auth-pool requires a value" >&2; usage 1; }
      CODEX_AUTH_POOL="$2"; CODEX_AUTH_POOL_EXPLICIT=1; shift 2 ;;
    --codex-auth-pool=*)
      CODEX_AUTH_POOL="${1#--codex-auth-pool=}"; CODEX_AUTH_POOL_EXPLICIT=1; shift ;;
    --bot-user-id)
      [ $# -ge 2 ] || { echo "swarm-add: --bot-user-id requires a value" >&2; usage 1; }
      BOT_USER_ID="$2"; shift 2 ;;
    --bot-user-id=*)
      BOT_USER_ID="${1#--bot-user-id=}"; shift ;;
    -h|--help)          usage 0 ;;
    --*)                echo "swarm-add: unknown flag: $1" >&2; usage 1 ;;
    *)
      POS_COUNT=$((POS_COUNT + 1))
      case "$POS_COUNT" in
        1) NAME="$1" ;;
        2) REPO="$1" ;;
        3) CHANNEL="$1"; CHANNEL_EXPLICIT=1 ;;
        *) echo "swarm-add: too many positional args (got '$1' after name/repo/channel)" >&2; usage 1 ;;
      esac
      shift ;;
  esac
done

[ -z "$NAME" ] && { echo "swarm-add: missing <name>" >&2; usage 1; }
[ -z "$REPO" ] && { echo "swarm-add: missing <repo_path>" >&2; usage 1; }

case "$ENGINE" in
  claude|codex) : ;;
  *) echo "swarm-add: --engine must be claude or codex (got: $ENGINE)" >&2; exit 1 ;;
esac

[ -n "$CODEX_AUTH_POOL" ] || CODEX_AUTH_POOL="default"
case "$CODEX_AUTH_POOL" in
  [!a-z]*|*[!a-z0-9_-]*)
    echo "swarm-add: --codex-auth-pool must match [a-z][a-z0-9_-]{0,31} (got: $CODEX_AUTH_POOL)" >&2
    exit 1 ;;
esac
if [ "${#CODEX_AUTH_POOL}" -gt 32 ]; then
  echo "swarm-add: --codex-auth-pool must be at most 32 characters (got: $CODEX_AUTH_POOL)" >&2
  exit 1
fi

if [ -n "$TYPE" ]; then
  if ! swarm_type_is_known "$TYPE"; then
    {
      echo "swarm-add: unknown --type '$TYPE'"
      echo "  known types:"
      swarm_known_types | sed 's/^/    /'
    } >&2
    exit 1
  fi
fi

# Fail-fast flag-level --profile check (ADR-0013). The AUTHORITATIVE refusal
# (incl. an already-stamped repo of another type) lives in swarm-init, which
# this script invokes in phase 4c; this catches the obvious cases early,
# before the Discord walkthrough, so the operator isn't sent through the
# portal only to be refused at stamp time.
if [ -n "$PROFILE" ]; then
  if [ "${TYPE:-engineering-cto}" != "engineering-cto" ]; then
    echo "swarm-add: --profile is only valid for engineering-cto swarms (got --type '$TYPE')" >&2
    exit 1
  fi
  if ! swarm_profile_is_known "$PROFILE"; then
    {
      echo "swarm-add: unknown --profile '$PROFILE'"
      echo "  known profiles:"
      swarm_known_profiles | sed 's/^/    /'
    } >&2
    exit 1
  fi
fi

# Name + repo validation.
echo "$NAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$' || {
  echo "swarm-add: name must match [a-zA-Z][a-zA-Z0-9_-]* (got: $NAME)" >&2; exit 1; }
if ! /usr/bin/python3 -I -B - "$REPO" <<'PY' >/dev/null 2>&1
import sys
path=sys.argv[1]
safe=('|' not in path and path==path.rstrip()
      and not any(ord(ch)<32 or ord(ch)==127 for ch in path))
raise SystemExit(0 if safe else 1)
PY
then
  echo "swarm-add: repo path cannot contain pipe/control characters or trailing whitespace" >&2
  exit 1
fi
[ -d "$REPO" ] || { echo "swarm-add: repo not found: $REPO" >&2; exit 1; }
REPO="$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os, stat, sys
raw=sys.argv[1]; path=os.path.realpath(raw)
st=os.stat(path,follow_symlinks=False)
safe=(stat.S_ISDIR(st.st_mode) and '|' not in path and path==path.rstrip()
      and not any(ord(ch)<32 or ord(ch)==127 for ch in path))
if not safe: raise SystemExit(1)
sys.stdout.write(path)
PY
)" || {
  echo "swarm-add: canonical repo path cannot contain pipe/control characters or trailing whitespace: $REPO" >&2
  exit 1
}
REPO_BASENAME="$(basename "$REPO")"

# Channel validation if given up front.
if [ -n "$CHANNEL" ]; then
  echo "$CHANNEL" | grep -qE '^[0-9]+$' || {
    echo "swarm-add: channel_id must be numeric (got: $CHANNEL)" >&2; exit 1; }
fi

# bot-user-id validation if given up front.
if [ -n "$BOT_USER_ID" ]; then
  echo "$BOT_USER_ID" | grep -qE '^[0-9]+$' || {
    echo "swarm-add: --bot-user-id must be numeric (got: $BOT_USER_ID)" >&2; exit 1; }
fi

# Effective archetype: an explicit --type wins; otherwise honor an existing
# marker before falling back to engineering-cto. A CPO re-run without --type
# must not be miswired as a CTO or lose its dual-channel ACL.
EFFECTIVE_TYPE="${TYPE:-$(swarm_type_of "$REPO")}"

TOK_VAR="BOT_$(echo "$NAME" | tr '[:lower:]-' '[:upper:]_')"

# ---------------------------------------------------------------------------
# Small helpers.
#
# /dev/tty handling: in a real interactive session we want to read prompts
# from the operator's terminal even if the script's stdin is redirected
# (e.g. some pipe is feeding stdout). But in a non-interactive context
# (CI, automated tests, a piped invocation with no controlling terminal)
# /dev/tty can either not exist at all or refuse to open ("Device not
# configured"). Probe once at startup; if it isn't usable, fall back to
# reading from this script's stdin.
# ---------------------------------------------------------------------------

HAVE_TTY=0
if : </dev/tty 2>/dev/null; then HAVE_TTY=1; fi

# pause "Prompt text" — print prompt and wait for the operator to press Enter.
pause() {
  local label="${1:-Press Enter to continue}"
  printf '\n%s\n' "$label"
  if [ "$HAVE_TTY" -eq 1 ]; then IFS= read -r _ </dev/tty; else IFS= read -r _; fi
}

# read_line VARNAME "Prompt: "
read_line() {
  local var="$1" prompt="$2" val
  if [ "$HAVE_TTY" -eq 1 ]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r val </dev/tty || return 1
  else
    printf '%s' "$prompt"
    IFS= read -r val || return 1
  fi
  eval "$var=\$val"
}

# read_secret VARNAME "Prompt: " — silent read for token paste.
read_secret() {
  local var="$1" prompt="$2" val
  if [ "$HAVE_TTY" -eq 1 ]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r -s val </dev/tty
    printf '\n' >/dev/tty
  else
    printf '%s' "$prompt"
    IFS= read -r -s val
    printf '\n'
  fi
  eval "$var=\$val"
}

# phase HEADER — visual divider.
phase() {
  echo ""
  echo "===================================================================="
  echo "$*"
  echo "===================================================================="
}

# ---------------------------------------------------------------------------
# PHASE 0 — preflight + partial-state detection
# ---------------------------------------------------------------------------
EXISTING_ENGINE=""
EXISTING_REPO=""
EXISTING_CHANNEL=""
EXISTING_TOK_VAR=""
EXISTING_ACCOUNT=""
EXISTING_CODEX_AUTH_POOL="default"
EXISTING_ROW_RAW=""
EXISTING_ROW=0
EXISTING_MATCHES=0
if [ -f "$CONF" ]; then
  while IFS= read -r _line; do
    _trimmed_line="$(_swarm_trim "$_line")"
    case "$_trimmed_line" in ''|'#'*) continue ;; esac
    _raw_name="$(_swarm_trim "${_line%%|*}")"
    [ "$_raw_name" = "$NAME" ] || continue
    EXISTING_MATCHES=$((EXISTING_MATCHES + 1))
    if ! swarm_conf_parse_line "$_line"; then
      echo "swarm-add: REFUSED — existing row '$NAME' is malformed (repo/token/engine fields must parse safely)." >&2
      exit 2
    fi
    if [ -z "$SWARM_CONF_F_TOKVAR" ]; then
      echo "swarm-add: REFUSED — existing row '$NAME' has a missing or malformed TOKEN_VAR_NAME." >&2
      exit 2
    fi
    EXISTING_ENGINE="$SWARM_CONF_F_ENGINE"
    EXISTING_REPO="$SWARM_CONF_F_REPO"
    EXISTING_CHANNEL="$SWARM_CONF_F_CHANNEL"
    EXISTING_TOK_VAR="$SWARM_CONF_F_TOKVAR"
    EXISTING_ACCOUNT="$SWARM_CONF_F_ACCOUNT"
    EXISTING_CODEX_AUTH_POOL="$SWARM_CONF_F_CODEX_AUTH_POOL"
    EXISTING_ROW_RAW="$_line"
    EXISTING_ROW=1
  done < "$CONF"
fi
if [ "$EXISTING_MATCHES" -gt 1 ]; then
  echo "swarm-add: REFUSED — swarm.conf has $EXISTING_MATCHES rows named '$NAME'; identity is ambiguous." >&2
  exit 2
fi

# An existing row is the registration identity. Never stamp one repository or
# rewrite one ACL and then flip the engine on a same-name row that still points
# somewhere else. Canonicalize the configured repo, compare an explicitly
# supplied channel, and use the row's actual token variable on idempotent runs.
if [ "$EXISTING_ROW" -eq 1 ]; then
  case "$EXISTING_CHANNEL" in ''|*[!0-9]*)
    [ -z "$EXISTING_CHANNEL" ] || { echo "swarm-add: REFUSED — existing row '$NAME' has a nonnumeric channel." >&2; exit 2; }
    ;;
  esac
  case "$EXISTING_REPO" in
    /*) ;;
    *) echo "swarm-add: REFUSED — existing row '$NAME' has a non-absolute repo path: $EXISTING_REPO" >&2; exit 2 ;;
  esac
  if [ ! -d "$EXISTING_REPO" ]; then
    echo "swarm-add: REFUSED — existing row '$NAME' repo is missing: $EXISTING_REPO" >&2
    exit 2
  fi
  EXISTING_REPO_CANON="$(cd "$EXISTING_REPO" && pwd -P)" || {
    echo "swarm-add: REFUSED — could not canonicalize existing row repo: $EXISTING_REPO" >&2
    exit 2
  }
  if [ "$EXISTING_REPO_CANON" != "$REPO" ]; then
    echo "swarm-add: REFUSED — name '$NAME' is already registered to repo $EXISTING_REPO_CANON (not $REPO)." >&2
    exit 2
  fi
  if [ "$CHANNEL_EXPLICIT" -eq 1 ] && [ -n "$EXISTING_CHANNEL" ] && [ "$CHANNEL" != "$EXISTING_CHANNEL" ]; then
    echo "swarm-add: REFUSED — name '$NAME' is already registered to channel '${EXISTING_CHANNEL:-<empty>}' (not '$CHANNEL')." >&2
    exit 2
  fi
  if [ "$CHANNEL_EXPLICIT" -eq 0 ] && [ -n "$EXISTING_CHANNEL" ]; then
    CHANNEL="$EXISTING_CHANNEL"
  fi
  TOK_VAR="$EXISTING_TOK_VAR"
fi

# A re-run without --engine preserves the row's engine. An explicit change is
# a migration and remains uncommitted until every target-engine setup phase has
# succeeded below.
if [ "$EXISTING_ROW" -eq 1 ] && [ "$ENGINE_EXPLICIT" -eq 0 ]; then
  ENGINE="$EXISTING_ENGINE"
fi
if [ "$EXISTING_ROW" -eq 1 ] && [ "$CODEX_AUTH_POOL_EXPLICIT" -eq 0 ]; then
  CODEX_AUTH_POOL="$EXISTING_CODEX_AUTH_POOL"
fi
if [ "$CODEX_AUTH_POOL_EXPLICIT" -eq 1 ] && [ "$ENGINE" != "codex" ]; then
  echo "swarm-add: --codex-auth-pool is only valid when the effective engine is codex" >&2
  exit 1
fi
if [ "$ENGINE" = "codex" ] && ! swarm_codex_profiles_validate \
    "$SWARM_HOME/codex-profiles.json" "$CODEX_AUTH_POOL"; then
  echo "swarm-add: REFUSED — invalid Codex profile catalog or unknown auth pool '$CODEX_AUTH_POOL'." >&2
  exit 2
fi

# Claude channel ACLs are account-partitioned. Resolve the target row's actual
# ACCOUNT after authoritative engine selection; an idempotent labeled Claude
# rerun and a Codex->Claude migration must prepare the same access.json that
# launch will consume. Codex intentionally always uses the default canonical
# ACL, regardless of a dormant ACCOUNT field retained for reversible migration.
ACCESS_ACCOUNT=""
if [ "$ENGINE" = "claude" ] && [ "$EXISTING_ROW" -eq 1 ]; then
  ACCESS_ACCOUNT="$EXISTING_ACCOUNT"
fi
if ! swarm_account_resolve "$ACCESS_ACCOUNT"; then
  echo "swarm-add: REFUSED — invalid ACCOUNT '$ACCESS_ACCOUNT' in the existing row." >&2
  exit 2
fi
ACCESS="$SWARM_ACCT_ACCESS_FILE"

# Count configured Codex consumers of one canonical repo. Lifecycle authority
# is repo-scoped, while swarm.conf rows are bot/channel-scoped, so revocation
# must be reference-aware. Any malformed active row makes the answer unsafe;
# callers then retain authority or refuse the destructive transition.
swarm_codex_repo_ref_count() {  # repo [excluded-name]
  local _repo="$1" _exclude="${2:-}" _line _trimmed _configured_repo
  SWARM_CODEX_REPO_REF_COUNT=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_line"; then
      return 2
    fi
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

codex_runtime_remediation() {
  cat >&2 <<EOF
swarm-add: Codex dedicated runtime is not ready; swarm.conf remains on the prior engine.
Complete the one-time host lifecycle, then re-run this command:
  $SCRIPT_DIR_EARLY/swarm-codex-runtime.sh install --repo "$REPO"
  $SCRIPT_DIR_EARLY/swarm-codex-runtime.sh login
  log out/in to refresh group membership and restart existing tmux servers
  $SCRIPT_DIR_EARLY/swarm-codex-runtime.sh verify --repo "$REPO"
EOF
}

codex_runtime_prepare_and_verify() {
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed before Codex workspace preparation." >&2
    return 1
  fi
  if [ ! -x "$CODEX_RUNTIME_BIN" ]; then
    echo "swarm-add: Codex runtime lifecycle command is missing or not executable: $CODEX_RUNTIME_BIN" >&2
    codex_runtime_remediation
    return 1
  fi
  if ! "$CODEX_RUNTIME_BIN" prepare-workspace --repo "$REPO"; then
    codex_runtime_remediation
    return 1
  fi
  CODEX_RUNTIME_PREPARED=1
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed during Codex workspace preparation." >&2
    return 1
  fi
  if ! "$CODEX_RUNTIME_BIN" verify --repo "$REPO"; then
    codex_runtime_remediation
    return 1
  fi
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed during Codex runtime verification." >&2
    return 1
  fi
  return 0
}

codex_runtime_release_if_unreferenced() {
  if ! swarm_codex_repo_ref_count "$REPO"; then
    echo "swarm-add: WARNING — malformed swarm.conf prevents safe Codex authority rollback; retaining workspace authority." >&2
    return 2
  fi
  if [ "$SWARM_CODEX_REPO_REF_COUNT" -gt 0 ]; then
    return 0
  fi
  if ! "$CODEX_RUNTIME_BIN" release-workspace --repo "$REPO"; then
    echo "swarm-add: CRITICAL — failed to roll back uncommitted Codex workspace authority for $REPO" >&2
    return 1
  fi
  CODEX_RUNTIME_PREPARED=0
  return 0
}

engine_migration_quiescent() {
  local _tmux _codex_state _boundary
  _tmux="${SWARM_TMUX_BIN:-tmux}"
  if ! command -v "$_tmux" >/dev/null 2>&1; then
    echo "swarm-add: REFUSED — cannot prove engine quiescence because tmux is unavailable: $_tmux" >&2
    return 1
  fi
  if "$_tmux" has-session -t "swarm-$NAME" 2>/dev/null; then
    echo "swarm-add: REFUSED — cannot change ENGINE $EXISTING_ENGINE -> $ENGINE while swarm-$NAME is live. Stop it cleanly first." >&2
    return 1
  fi
  # Read PIDs independently of schema validity so a damaged record with a live
  # salvageable PID still blocks. Present-but-unclassifiable state is also a
  # refusal: malformed evidence is never proof that an old daemon is stopped.
  _codex_state="$(swarm_codex_state_dir "$NAME")"
  _boundary="$(/usr/bin/python3 -I -B - "$_codex_state/runtime.json" "$_codex_state/daemon.lock" <<'PY'
import datetime as dt, json, os, sys
runtime,lock=sys.argv[1:3]; pids=[]; issues=[]
def stamp(value):
  if not isinstance(value,str) or not value: return False
  try: dt.datetime.fromisoformat(value.replace('Z','+00:00')); return True
  except Exception: return False
if os.path.lexists(runtime):
  try:
    d=json.load(open(runtime))
    if isinstance(d,dict):
      for key in ('pid','child_pid'):
        value=d.get(key)
        if type(value) is int and value>0 and value not in pids: pids.append(value)
    if (not isinstance(d,dict) or d.get('schema')!='codex-bridge-runtime/v1'
        or type(d.get('pid')) is not int or d['pid']<=0
        or not stamp(d.get('started_at')) or not stamp(d.get('updated_at'))
        or type(d.get('ready')) is not bool or type(d.get('active')) is not bool
        or type(d.get('queue_depth')) is not int or d['queue_depth']<0
        or (d.get('child_pid') is not None and (type(d.get('child_pid')) is not int or d['child_pid']<=0))
        or d.get('backend') not in ('exec','app-server')): raise ValueError()
  except Exception: issues.append('runtime-unreadable')
if os.path.lexists(lock):
  owner=os.path.join(lock,'owner.json')
  try:
    d=json.load(open(owner))
    if isinstance(d,dict):
      value=d.get('pid')
      if type(value) is int and value>0 and value not in pids: pids.append(value)
    if (not isinstance(d,dict) or d.get('schema')!='codex-bridge-lock/v1'
        or type(d.get('pid')) is not int or d['pid']<=0): raise ValueError()
  except Exception: issues.append('lock-owner-unreadable')
live=[]
for pid in pids:
  try: os.kill(pid,0)
  except PermissionError: live.append(pid)
  except OSError: pass
  else: live.append(pid)
if live: print('live|' + ','.join(map(str,live)))
elif issues: print('unsafe|' + ','.join(issues))
else: print('ok|')
PY
)"
  case "$_boundary" in
    live\|*)
      echo "swarm-add: REFUSED — cannot change ENGINE while Codex runtime PID(s) or lock owner PID(s) ${_boundary#live|} are live. Stop them cleanly first." >&2
      return 1 ;;
    unsafe\|*)
      echo "swarm-add: REFUSED — cannot prove engine quiescence because Codex process state is ${_boundary#unsafe|}." >&2
      return 1 ;;
    ok\|) return 0 ;;
    *)
      echo "swarm-add: REFUSED — Codex process boundary could not be classified." >&2
      return 1 ;;
  esac
}

ENGINE_SWITCH_PENDING=0
if [ "$EXISTING_ROW" -eq 1 ] && [ "$ENGINE_EXPLICIT" -eq 1 ] && [ "$ENGINE" != "$EXISTING_ENGINE" ]; then
  engine_migration_quiescent || exit 2
  ENGINE_SWITCH_PENDING=1
fi

release_engine_switch_lock() {
  swarm_conf_lock_release
}
CODEX_RUNTIME_PREPARED=0
CODEX_ADOPTION_PENDING=0
ADD_TRANSACTION_LOCK_HELD=0
ENGINE_SURFACE_ROLLBACK_PENDING=0
ENGINE_SURFACE_SNAPSHOT_DIR=""
ENGINE_SURFACE_AGENTS_KIND=""
ENGINE_SURFACE_AGENTS_MODE=""
ENGINE_SURFACE_AGENTS_ID=""
REPO_IDENTITY=""

bind_repo_identity() {
  REPO_IDENTITY="$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os, stat, sys
path=sys.argv[1]
if os.path.realpath(path) != path: raise SystemExit(2)
flags=os.O_RDONLY | getattr(os,'O_DIRECTORY',0) | getattr(os,'O_NOFOLLOW',0)
fd=os.open(path,flags)
try:
    opened=os.fstat(fd); current=os.lstat(path)
    if (not stat.S_ISDIR(opened.st_mode) or stat.S_ISLNK(current.st_mode)
            or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)):
        raise SystemExit(2)
    print(f'{opened.st_dev}:{opened.st_ino}')
finally: os.close(fd)
PY
)" || return 1
  [ -n "$REPO_IDENTITY" ]
}

repo_identity_matches() {
  local _current
  [ -n "$REPO_IDENTITY" ] || return 1
  _current="$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os, stat, sys
path=sys.argv[1]
if os.path.realpath(path) != path: raise SystemExit(2)
flags=os.O_RDONLY | getattr(os,'O_DIRECTORY',0) | getattr(os,'O_NOFOLLOW',0)
fd=os.open(path,flags)
try:
    opened=os.fstat(fd); current=os.lstat(path)
    if (not stat.S_ISDIR(opened.st_mode) or stat.S_ISLNK(current.st_mode)
            or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)):
        raise SystemExit(2)
    print(f'{opened.st_dev}:{opened.st_ino}')
finally: os.close(fd)
PY
)" || return 1
  [ "$_current" = "$REPO_IDENTITY" ]
}

snapshot_engine_surface() {
  local _out
  [ "$ENGINE_SWITCH_PENDING" -eq 1 ] || return 0
  ENGINE_SURFACE_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swarm-add-surface.XXXXXX")" || return 1
  _out="$(/usr/bin/python3 -I -B - "$REPO" "$REPO_IDENTITY" "$ENGINE_SURFACE_SNAPSHOT_DIR/AGENTS.md" <<'PY'
import errno, os, stat, sys
repo, expected, dest=sys.argv[1:4]
dev,ino=(int(v) for v in expected.split(':',1))
flags=os.O_RDONLY|getattr(os,'O_DIRECTORY',0)|getattr(os,'O_NOFOLLOW',0)
root=os.open(repo,flags)
try:
    rst=os.fstat(root)
    if (rst.st_dev,rst.st_ino)!=(dev,ino): raise SystemExit(2)
    try: fd=os.open('AGENTS.md',os.O_RDONLY|getattr(os,'O_NOFOLLOW',0),dir_fd=root)
    except FileNotFoundError:
        print('absent'); raise SystemExit(0)
    except OSError as exc:
        if exc.errno==errno.ELOOP: raise SystemExit(3)
        raise
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size>2*1024*1024: raise SystemExit(3)
        data=b''
        while len(data)<=2*1024*1024:
            chunk=os.read(fd,65536)
            if not chunk: break
            data+=chunk
        after=os.fstat(fd)
        if (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)!=(
            before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns): raise SystemExit(3)
    finally: os.close(fd)
    out=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        view=memoryview(data)
        while view: view=view[os.write(out,view):]
        os.fsync(out)
    finally: os.close(out)
    print(f'file:{stat.S_IMODE(before.st_mode):o}:{before.st_dev}:{before.st_ino}')
finally: os.close(root)
PY
)" || return 1
  case "$_out" in
    absent) ENGINE_SURFACE_AGENTS_KIND="absent" ;;
    file:*)
      ENGINE_SURFACE_AGENTS_KIND="file"
      IFS=: read -r _kind ENGINE_SURFACE_AGENTS_MODE _agents_dev _agents_ino <<EOF
$_out
EOF
      ENGINE_SURFACE_AGENTS_ID="${_agents_dev}:${_agents_ino}"
      ;;
    *) return 1 ;;
  esac
  ENGINE_SURFACE_ROLLBACK_PENDING=1
  return 0
}

restore_engine_surface() {
  [ "$ENGINE_SURFACE_ROLLBACK_PENDING" -eq 1 ] || return 0
  /usr/bin/python3 -I -B - "$REPO" "$REPO_IDENTITY" "$ENGINE_SURFACE_AGENTS_KIND" \
    "$ENGINE_SURFACE_AGENTS_MODE" "$ENGINE_SURFACE_AGENTS_ID" "$ENGINE_SURFACE_SNAPSHOT_DIR/AGENTS.md" <<'PY' || return 1
import errno, os, secrets, stat, sys
repo, expected, kind, mode_text, original_id, source=sys.argv[1:7]
dev,ino=(int(v) for v in expected.split(':',1))
flags=os.O_RDONLY|getattr(os,'O_DIRECTORY',0)|getattr(os,'O_NOFOLLOW',0)
root=os.open(repo,flags)
tmp=''
try:
    rst=os.fstat(root)
    if (rst.st_dev,rst.st_ino)!=(dev,ino): raise SystemExit(2)
    try: current=os.stat('AGENTS.md',dir_fd=root,follow_symlinks=False)
    except FileNotFoundError: current=None
    if current is not None and not stat.S_ISREG(current.st_mode): raise SystemExit(3)
    if kind=='absent':
        if current is not None: os.unlink('AGENTS.md',dir_fd=root)
        raise SystemExit(0)
    if kind!='file': raise SystemExit(3)
    src=os.open(source,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        sinfo=os.fstat(src)
        if not stat.S_ISREG(sinfo.st_mode) or sinfo.st_size>2*1024*1024: raise SystemExit(3)
        data=b''
        while len(data)<=2*1024*1024:
            chunk=os.read(src,65536)
            if not chunk: break
            data+=chunk
    finally: os.close(src)
    mode=int(mode_text,8)
    original_dev,original_ino=(int(v) for v in original_id.split(':',1))
    if (current is not None and (current.st_dev,current.st_ino)==(original_dev,original_ino)
            and stat.S_IMODE(current.st_mode)==mode):
        unchanged=os.open('AGENTS.md',os.O_RDONLY|getattr(os,'O_NOFOLLOW',0),dir_fd=root)
        try:
            unchanged_info=os.fstat(unchanged)
            current_data=b''
            while len(current_data)<=2*1024*1024:
                chunk=os.read(unchanged,65536)
                if not chunk: break
                current_data+=chunk
        finally: os.close(unchanged)
        if ((unchanged_info.st_dev,unchanged_info.st_ino)==(original_dev,original_ino)
                and stat.S_IMODE(unchanged_info.st_mode)==mode and current_data==data):
            raise SystemExit(0)
    for _ in range(20):
        tmp='.AGENTS.md.rollback.'+secrets.token_hex(12)
        try:
            out=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600,dir_fd=root)
            break
        except FileExistsError: continue
    else: raise SystemExit(3)
    try:
        view=memoryview(data)
        while view: view=view[os.write(out,view):]
        os.fchmod(out,mode); os.fsync(out)
    finally: os.close(out)
    os.rename(tmp,'AGENTS.md',src_dir_fd=root,dst_dir_fd=root)
    tmp=''
finally:
    if tmp:
        try: os.unlink(tmp,dir_fd=root)
        except FileNotFoundError: pass
    os.close(root)
PY
  ENGINE_SURFACE_ROLLBACK_PENDING=0
  return 0
}

discard_engine_surface_snapshot() {
  ENGINE_SURFACE_ROLLBACK_PENDING=0
  if [ -n "$ENGINE_SURFACE_SNAPSHOT_DIR" ]; then
    rm -rf "$ENGINE_SURFACE_SNAPSHOT_DIR"
  fi
  ENGINE_SURFACE_SNAPSHOT_DIR=""
  ENGINE_SURFACE_AGENTS_KIND=""
  ENGINE_SURFACE_AGENTS_MODE=""
  ENGINE_SURFACE_AGENTS_ID=""
}

validate_add_registration_snapshot() {
  local _line _trimmed _raw_name _matches=0 _current=""
  if [ ! -f "$CONF" ]; then
    [ "$EXISTING_ROW" -eq 0 ]
    return
  fi
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    _raw_name="$(_swarm_trim "${_line%%|*}")"
    [ "$_raw_name" = "$NAME" ] || continue
    _matches=$((_matches + 1))
    _current="$_line"
  done < "$CONF"
  if [ "$EXISTING_ROW" -eq 1 ]; then
    [ "$_matches" -eq 1 ] && [ "$_current" = "$EXISTING_ROW_RAW" ]
  else
    [ "$_matches" -eq 0 ]
  fi
}

cleanup_swarm_add() {
  _swarm_add_exit=$?
  trap - EXIT
  # Roll back authority and the one cross-engine repo surface while the global
  # lifecycle lock is still held. Releasing the lock first lets a second
  # adopter or launcher observe and take ownership of this transaction's
  # uncommitted state.
  if [ "$CODEX_ADOPTION_PENDING" -eq 1 ] && [ "$CODEX_RUNTIME_PREPARED" -eq 1 ]; then
    if repo_identity_matches; then
      codex_runtime_release_if_unreferenced || true
    else
      echo "swarm-add: CRITICAL — repo identity changed; refusing pathname-based Codex authority rollback for $REPO" >&2
    fi
  fi
  if [ "$ENGINE_SURFACE_ROLLBACK_PENDING" -eq 1 ]; then
    restore_engine_surface || \
      echo "swarm-add: CRITICAL — failed to restore AGENTS.md after uncommitted engine migration" >&2
  fi
  discard_engine_surface_snapshot
  while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
  exit "$_swarm_add_exit"
}
trap cleanup_swarm_add EXIT

acquire_engine_switch_lock() {
  swarm_conf_lock_acquire "$CONF"
}

commit_engine_switch() {
  local _rc _conf_digest _released_workspace=0
  [ "$ENGINE_SWITCH_PENDING" -eq 1 ] || return 0
  acquire_engine_switch_lock || return 1
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed before engine commit." >&2
    release_engine_switch_lock
    return 2
  fi
  # Setup may be interactive and long-running. Re-check the process boundary
  # under the commit lock immediately before changing the configured engine.
  if ! engine_migration_quiescent; then
    release_engine_switch_lock
    return 2
  fi
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed during final engine quiescence check." >&2
    release_engine_switch_lock
    return 2
  fi
  _conf_digest="$(/usr/bin/python3 -I -B - "$CONF" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)" || {
    release_engine_switch_lock
    return 2
  }

  # A last-reference Codex -> Claude transition revokes service access before
  # the row changes. Keep the cooperative config lock across both operations;
  # the digest below also rejects a non-cooperating writer. If the row CAS
  # loses, restore and verify Codex authority before returning failure.
  if [ "$EXISTING_ENGINE" = "codex" ] && [ "$ENGINE" = "claude" ]; then
    if ! swarm_codex_repo_ref_count "$REPO" "$NAME"; then
      echo "swarm-add: REFUSED — malformed swarm.conf prevents a safe last-reference Codex release." >&2
      release_engine_switch_lock
      return 2
    fi
    if [ "$SWARM_CODEX_REPO_REF_COUNT" -eq 0 ]; then
      if [ ! -x "$CODEX_RUNTIME_BIN" ] \
         || ! "$CODEX_RUNTIME_BIN" release-workspace --repo "$REPO"; then
        echo "swarm-add: REFUSED — could not release Codex workspace authority; engine remains codex." >&2
        release_engine_switch_lock
        return 2
      fi
      _released_workspace=1
      CODEX_RUNTIME_PREPARED=0
      if ! repo_identity_matches; then
        echo "swarm-add: CRITICAL — repo identity changed during Codex authority release; engine remains uncommitted." >&2
        release_engine_switch_lock
        return 2
      fi
    fi
  fi

  /usr/bin/python3 -I -B - "$CONF" "$NAME" "$EXISTING_ENGINE" "$ENGINE" "$EXISTING_ROW_RAW" "$CHANNEL" "$_conf_digest" "$REPO" "$REPO_IDENTITY" "$CODEX_AUTH_POOL" <<'PY'
import hashlib, os, stat, sys, tempfile
path, name, old_engine, new_engine, expected, channel, expected_digest, canonical_repo, expected_identity, codex_auth_pool = sys.argv[1:11]
expected_dev, expected_ino = (int(v) for v in expected_identity.split(':', 1))
repo_flags = os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0) | getattr(os, 'O_NOFOLLOW', 0)
repo_fd = os.open(canonical_repo, repo_flags)
def repo_matches():
    try:
        opened = os.fstat(repo_fd)
        current = os.lstat(canonical_repo)
    except OSError:
        return False
    return (stat.S_ISDIR(opened.st_mode) and not stat.S_ISLNK(current.st_mode)
            and (opened.st_dev, opened.st_ino) == (expected_dev, expected_ino)
            and (current.st_dev, current.st_ino) == (expected_dev, expected_ino)
            and os.path.realpath(canonical_repo) == canonical_repo)
if not repo_matches():
    raise SystemExit(10)
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit(2)
if hashlib.sha256(open(path, 'rb').read()).hexdigest() != expected_digest:
    raise SystemExit(9)
with open(path, "r", newline="") as f:
    original = f.read()
lines = original.splitlines(keepends=True)
named=[]
for index, raw in enumerate(lines):
    body=raw[:-2] if raw.endswith("\r\n") else (raw[:-1] if raw.endswith("\n") else raw)
    if body.lstrip().startswith("#") or not body.strip():
        continue
    fields=body.split("|")
    if fields[0].strip() == name:
        named.append((index, body, fields, raw[len(body):]))
if len(named) != 1:
    raise SystemExit(3)
index, body, fields, ending = named[0]
if body != expected:
    raise SystemExit(4)
current = fields[6].strip() if len(fields) >= 7 and fields[6].strip() else "claude"
if current != old_engine:
    raise SystemExit(5)
while len(fields) < 4:
    fields.append(" ")
current_channel=fields[3].strip()
if current_channel and current_channel != channel:
    raise SystemExit(7)
if not current_channel:
    if not channel.isdigit():
        raise SystemExit(8)
    fields[3] = " " + channel
while len(fields) < 7:
    fields.append(" ")
fields[6] = " " + new_engine
if new_engine == "codex":
    while len(fields) < 8:
        fields.append(" ")
    fields[7] = " " + codex_auth_pool
    fields[1] = " " + canonical_repo + " "
lines[index] = "|".join(fields) + ending
updated = "".join(lines)
directory=os.path.dirname(path) or "."
fd, tmp=tempfile.mkstemp(prefix=".swarm.conf.engine.", dir=directory)
try:
    with os.fdopen(fd, "w", newline="") as f:
        f.writelines(lines)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, stat.S_IMODE(st.st_mode))
    # Best-effort whole-file CAS against non-cooperating writers in addition
    # to the cooperative lock used by swarm-add migrations.
    with open(path, "r", newline="") as f:
        if f.read() != original:
            raise SystemExit(6)
    if not repo_matches():
        raise SystemExit(10)
    os.replace(tmp, path)
    # Validate the repository namespace after the config replacement too. If
    # it changed in the final window, restore the exact prior config while the
    # lifecycle lock is still held rather than registering an unprepared inode.
    if not repo_matches():
        rfd, rollback = tempfile.mkstemp(prefix=".swarm.conf.engine.rollback.", dir=directory)
        try:
            with os.fdopen(rfd, "w", newline="") as f:
                f.write(original)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(rollback, stat.S_IMODE(st.st_mode))
            with open(path, "r", newline="") as f:
                if f.read() != updated:
                    raise SystemExit(11)
            os.replace(rollback, path)
        finally:
            try: os.unlink(rollback)
            except FileNotFoundError: pass
        raise SystemExit(10)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
  _rc=$?
  if [ "$_rc" -ne 0 ] && [ "$_released_workspace" -eq 1 ]; then
    if ! swarm_codex_repo_ref_count "$REPO"; then
      echo "swarm-add: CRITICAL — concurrent malformed config prevents safe Codex authority reconciliation; workspace access remains revoked." >&2
      release_engine_switch_lock
      return 2
    fi
    if [ "$SWARM_CODEX_REPO_REF_COUNT" -gt 0 ] && ! codex_runtime_prepare_and_verify; then
      echo "swarm-add: CRITICAL — a Codex row still references the repo but workspace authority rollback failed; repair the dedicated runtime before launch." >&2
      release_engine_switch_lock
      return 2
    fi
  fi
  release_engine_switch_lock
  if [ "$_rc" -ne 0 ]; then
    echo "swarm-add: REFUSED — swarm.conf row changed during setup (CAS rc=$_rc); engine remains uncommitted." >&2
  fi
  return "$_rc"
}

commit_new_row() {  # exact row text, after all setup verifies
  local _row="$1" _rc
  swarm_conf_lock_acquire "$CONF" || return 1
  if ! repo_identity_matches; then
    echo "swarm-add: REFUSED — repo identity changed before new-row commit." >&2
    swarm_conf_lock_release
    return 2
  fi
  /usr/bin/python3 -I -B - "$CONF" "$NAME" "$_row" "$REPO" "$REPO_IDENTITY" <<'PY'
import os, stat, sys, tempfile
path,name,row,repo,expected_identity=sys.argv[1:6]
expected_dev,expected_ino=(int(v) for v in expected_identity.split(':',1))
repo_flags=os.O_RDONLY|getattr(os,'O_DIRECTORY',0)|getattr(os,'O_NOFOLLOW',0)
repo_fd=os.open(repo,repo_flags)
def repo_matches():
    try:
        opened=os.fstat(repo_fd); current=os.lstat(repo)
    except OSError:
        return False
    return (stat.S_ISDIR(opened.st_mode) and not stat.S_ISLNK(current.st_mode)
            and (opened.st_dev,opened.st_ino)==(expected_dev,expected_ino)
            and (current.st_dev,current.st_ino)==(expected_dev,expected_ino)
            and os.path.realpath(repo)==repo)
if not repo_matches(): raise SystemExit(5)
st=os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise SystemExit(2)
with open(path,'r',newline='') as f: original=f.read()
for raw in original.splitlines():
    if raw.lstrip().startswith('#') or not raw.strip(): continue
    if raw.split('|',1)[0].strip() == name: raise SystemExit(3)
content=original
if content and not content.endswith('\n'): content+='\n'
content+=row+'\n'
directory=os.path.dirname(path) or '.'
fd,tmp=tempfile.mkstemp(prefix='.swarm.conf.add.',dir=directory)
try:
    with os.fdopen(fd,'w',newline='') as f:
        f.write(content); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(st.st_mode))
    with open(path,'r',newline='') as f:
        if f.read()!=original: raise SystemExit(4)
    if not repo_matches(): raise SystemExit(5)
    os.replace(tmp,path)
    if not repo_matches():
        rfd,rollback=tempfile.mkstemp(prefix='.swarm.conf.add.rollback.',dir=directory)
        try:
            with os.fdopen(rfd,'w',newline='') as f:
                f.write(original); f.flush(); os.fsync(f.fileno())
            os.chmod(rollback,stat.S_IMODE(st.st_mode))
            with open(path,'r',newline='') as f:
                if f.read()!=content: raise SystemExit(6)
            os.replace(rollback,path)
        finally:
            try: os.unlink(rollback)
            except FileNotFoundError: pass
        raise SystemExit(5)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
  _rc=$?
  swarm_conf_lock_release
  [ "$_rc" -eq 0 ] || echo "swarm-add: REFUSED — swarm.conf changed before new-row commit (rc=$_rc)." >&2
  return "$_rc"
}

phase "Phase 0 — preflight"

echo "  name:      $NAME"
echo "  repo:      $REPO"
echo "  type:      $EFFECTIVE_TYPE"
[ -n "$PROFILE" ] && echo "  profile:   $PROFILE"
echo "  engine:    $ENGINE"
[ "$ENGINE" = "codex" ] && echo "  auth pool: $CODEX_AUTH_POOL"
echo "  channel:   ${CHANNEL:-(will prompt in phase 2)}"
echo "  token var: \$$TOK_VAR (in $TOKENS)"
if [ "$EFFECTIVE_TYPE" = "engineering-cto" ]; then
  echo "  bot id:    ${BOT_USER_ID:-(will prompt in phase 2 — for cto-watcher bus)}"
fi

STATE_TOKEN_PRESENT=0
STATE_CONF_PRESENT=0
STATE_REPO_STAMPED=0
STATE_ACCESS_GROUP_PRESENT=0
STATE_BUS_REGISTERED=0

if [ -f "$TOKENS" ] && grep -qE "^export ${TOK_VAR}=" "$TOKENS"; then
  STATE_TOKEN_PRESENT=1
fi
if [ -f "$CONF" ] && grep -qE "^[[:space:]]*${NAME}[[:space:]]*\|" "$CONF"; then
  STATE_CONF_PRESENT=1
fi
if [ -f "$REPO/.claude/settings.json" ] && [ -f "$REPO/CLAUDE.md" ]; then
  STATE_REPO_STAMPED=1
fi
if [ -n "$CHANNEL" ] && [ -f "$ACCESS" ] && \
   python3 -c '
import json, sys
try:
    a = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (a.get("groups") or {}).get(sys.argv[2]) else 1)
' "$ACCESS" "$CHANNEL" >/dev/null 2>&1; then
  STATE_ACCESS_GROUP_PRESENT=1
fi
# Bus registration is "done" only when BOTH halves are present: the
# ctoChannels entry in the watcher config AND the watcher bot id in this
# channel's allowFrom. Only meaningful for engineering-cto swarms.
if [ "$EFFECTIVE_TYPE" = "engineering-cto" ] && [ -n "$CHANNEL" ] && \
   [ -f "$CTO_WATCHER_CONFIG" ] && [ -f "$ACCESS" ] && \
   python3 -c '
import json, sys
cfg_p, acc_p, name, ch, watcher = sys.argv[1:6]
try:
    cfg = json.load(open(cfg_p)); acc = json.load(open(acc_p))
except Exception:
    sys.exit(1)
in_map = bool((cfg.get("ctoChannels") or {}).get(name))
grp = (acc.get("groups") or {}).get(ch) or {}
in_acl = watcher in (grp.get("allowFrom") or [])
sys.exit(0 if (in_map and in_acl) else 1)
' "$CTO_WATCHER_CONFIG" "$ACCESS" "$NAME" "$CHANNEL" "$CTO_BUS_WATCHER_BOT_ID" >/dev/null 2>&1; then
  STATE_BUS_REGISTERED=1
fi

echo ""
echo "  detected existing state:"
[ "$STATE_TOKEN_PRESENT"        -eq 1 ] && echo "    + token in tokens.env             (phase 3 will SKIP unless --rotate-token)"
[ "$STATE_CONF_PRESENT"         -eq 1 ] && echo "    + swarm.conf row already present  (phase 4 will SKIP the conf append)"
[ "$STATE_REPO_STAMPED"         -eq 1 ] && echo "    + repo already stamped            (phase 4's swarm-init becomes a no-op)"
[ "$STATE_ACCESS_GROUP_PRESENT" -eq 1 ] && echo "    + access.json group for channel   (phase 4 will overwrite-as-no-op)"
[ "$STATE_BUS_REGISTERED"       -eq 1 ] && echo "    + cto-watcher bus registration   (phase 4e already wired; will SKIP)"
if [ "$STATE_TOKEN_PRESENT" -eq 0 ] && [ "$STATE_CONF_PRESENT" -eq 0 ] && \
   [ "$STATE_REPO_STAMPED" -eq 0 ] && [ "$STATE_ACCESS_GROUP_PRESENT" -eq 0 ] && \
   [ "$STATE_BUS_REGISTERED" -eq 0 ]; then
  echo "    (fresh standup; nothing pre-existing)"
fi

# ---------------------------------------------------------------------------
# PHASE 1 — Discord portal walkthrough (manual)
# ---------------------------------------------------------------------------
if [ "$SKIP_WALKTHROUGH" -eq 1 ]; then
  phase "Phase 1 — Discord portal walkthrough  [SKIPPED via --skip-walkthrough]"
else
  phase "Phase 1 — Discord portal walkthrough"

cat <<EOF

This is the only part of standup that can't be automated — the Discord
developer portal has no API for app creation. Follow each group exactly;
press Enter between groups.

A) CREATE THE APPLICATION

   1. Open  https://discord.com/developers/applications
   2. Click  "New Application"
   3. Name it  "$REPO_BASENAME-bot"        (convention: <repo>-bot)
   4. Accept the terms; click  "Create"
EOF
pause "Press Enter when the application exists in the portal."

cat <<'EOF'

B) ENABLE THE PRIVILEGED INTENT

   The bridge requests four gateway intents. Three are non-privileged (no
   toggle required): Guilds, GuildMessages, DirectMessages. ONE is
   privileged and MUST be enabled in the portal — without it, message
   content arrives empty and the bot looks online but does nothing.

   1. Sidebar -> "Bot"
   2. Scroll to  "Privileged Gateway Intents"
   3. Enable  "MESSAGE CONTENT INTENT"     (the only one you need to toggle)
   4. Click  "Save Changes"
EOF
pause "Press Enter when the MESSAGE CONTENT INTENT toggle is ON and saved."

cat <<'EOF'

C) GENERATE THE INVITE URL (OAuth2)

   1. Sidebar -> "OAuth2" -> "URL Generator"
   2. Under  "Scopes", check ONLY:
        [x] bot
   3. Under  "Bot Permissions", check:
        [x] View Channels
        [x] Send Messages
        [x] Send Messages in Threads
        [x] Read Message History
        [x] Attach Files
        [x] Add Reactions
   4. Under  "Integration Type", choose:
        Guild Install
   5. Copy the generated URL at the bottom, open it in a new tab, pick
      your server, and click "Authorize" to invite the bot.
   6. In Discord, confirm the bot appears in the server's member list
      (you may need to switch to a channel + open the member sidebar).
EOF
pause "Press Enter when the bot is visible in the server's member list."

cat <<'EOF'

D) RESET THE BOT TOKEN

   1. Sidebar -> "Bot"  (still on the same application)
   2. Under  "Token", click  "Reset Token"  -> confirm
   3. Copy the token NOW — Discord will not show it again.
   4. You will paste it in phase 3 via a silent prompt (NEVER paste it
      into a terminal that echoes or into chat).
EOF
pause "Press Enter when the token is on your clipboard."

if [ "$EFFECTIVE_TYPE" = "engineering-cto" ] && [ -z "$BOT_USER_ID" ]; then
cat <<'EOF'

E) COPY THE BOT (APPLICATION) ID    [engineering-cto only — for the bus]

   A CTO swarm rides the #cpo-cto-bus. The cto-watcher reposts CPO
   directives into this bot's channel as a mention, so it needs the bot's
   own user id. For a Discord bot that id IS the Application ID.

   1. Sidebar -> "General Information"
   2. Under  "Application ID", click  "Copy".
      (Equivalently: in Discord with Developer Mode on, right-click the
       bot's name in the member list -> "Copy User ID" — same number.)
   3. You'll paste it in phase 2 below.
EOF
pause "Press Enter when the Application ID is on your clipboard."
fi

fi  # /SKIP_WALKTHROUGH

# ---------------------------------------------------------------------------
# PHASE 2 — Channel ID (skip if already provided)
# ---------------------------------------------------------------------------
if [ -n "$CHANNEL" ]; then
  phase "Phase 2 — Channel ID  [PROVIDED on CLI: $CHANNEL]"
else
  phase "Phase 2 — Channel ID"

cat <<EOF

You need the Discord channel ID this swarm will live in (the bot's home
channel; required even though swarm-up.sh itself doesn't read it — the
heartbeat watcher does, and access.json keys on channel ID).

Convention: name the channel "$REPO_BASENAME" (matching the repo
directory exactly). The swarm still routes by channel ID below — the
name is just for your own organization.

  1. In Discord, create or pick a channel named "$REPO_BASENAME".
  2. User Settings (cog icon) -> "Advanced" -> enable "Developer Mode"
  3. Right-click the channel in the server (or use the "..."
     menu on its row).
  4. Click  "Copy Channel ID".

Now paste it here.
EOF
  while [ -z "$CHANNEL" ]; do
    if ! read_line CHANNEL "Channel ID: "; then
      echo "swarm-add: input ended before a Channel ID was received; aborting." >&2
      exit 2
    fi
    if ! echo "$CHANNEL" | grep -qE '^[0-9]+$'; then
      echo "  Not a valid channel ID — must be all digits. Try again." >&2
      CHANNEL=""
    fi
  done
  echo "  got channel: $CHANNEL"

  # Re-check access-state with the now-known channel.
  if [ -f "$ACCESS" ] && \
     python3 -c '
import json, sys
try:
    a = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (a.get("groups") or {}).get(sys.argv[2]) else 1)
' "$ACCESS" "$CHANNEL" >/dev/null 2>&1; then
    STATE_ACCESS_GROUP_PRESENT=1
  fi
fi

# ---------------------------------------------------------------------------
# PHASE 2b — Bot (Application) ID  [engineering-cto only — for the bus]
#
# Needed to register this CTO in cto-watcher/config.json (phase 4e). Skip
# entirely for non-CTO archetypes and when the bus is already wired.
# ---------------------------------------------------------------------------
if [ "$EFFECTIVE_TYPE" = "engineering-cto" ]; then
  if [ -n "$BOT_USER_ID" ]; then
    phase "Phase 2b — Bot (Application) ID  [PROVIDED on CLI: $BOT_USER_ID]"
  elif [ "$STATE_BUS_REGISTERED" -eq 1 ]; then
    phase "Phase 2b — Bot (Application) ID  [SKIP: bus already registered]"
  else
    phase "Phase 2b — Bot (Application) ID"
cat <<'EOF'

This CTO rides the #cpo-cto-bus. Paste the bot's user id — the same number
as the application's "Application ID" (Developer Portal -> General
Information -> Copy), or right-click the bot in Discord -> Copy User ID.
EOF
    while [ -z "$BOT_USER_ID" ]; do
      if ! read_line BOT_USER_ID "Bot user id: "; then
        echo "swarm-add: input ended before a Bot user id was received; aborting." >&2
        exit 2
      fi
      if ! echo "$BOT_USER_ID" | grep -qE '^[0-9]+$'; then
        echo "  Not a valid id — must be all digits. Try again." >&2
        BOT_USER_ID=""
      fi
    done
    echo "  got bot user id: $BOT_USER_ID"
  fi
fi

# ---------------------------------------------------------------------------
# PHASE 3 — Token capture
# ---------------------------------------------------------------------------
phase "Phase 3 — Token capture"

if [ "$STATE_TOKEN_PRESENT" -eq 1 ] && [ "$ROTATE_TOKEN" -eq 0 ]; then
  echo "  SKIP: \$$TOK_VAR is already in $TOKENS"
  echo "        (pass --rotate-token to replace it; not needed for a normal re-run)"
  TOKEN=""
else
  if [ "$ROTATE_TOKEN" -eq 1 ] && [ "$STATE_TOKEN_PRESENT" -eq 1 ]; then
    echo "  --rotate-token: will replace the existing \$$TOK_VAR line."
  fi
  read_secret TOKEN "Paste bot token (input hidden): "
  if [ -z "$TOKEN" ]; then
    echo "swarm-add: token was empty — aborting (re-run when ready)." >&2
    exit 1
  fi
  # Sanity-check shape without echoing the value.
  if ! echo "$TOKEN" | grep -qE '^[A-Za-z0-9._-]{40,}$'; then
    echo "swarm-add: token does not look like a Discord bot token (length/charset) — aborting." >&2
    unset TOKEN
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# PHASE 4 — Local writes (idempotent)
# ---------------------------------------------------------------------------
phase "Phase 4 — Local config writes (idempotent)"

# Treat onboarding, migration, and their repository/runtime side effects as one
# cooperative lifecycle transaction. The lock starts before the first local
# write and remains held through the engine-specific setup, runtime authority
# preparation, and exact row commit. This prevents a concurrent up/remove/add
# from observing partial adoption state. Token prompting remains outside the
# lock so an unattended peer cannot be blocked by operator input.
if ! swarm_conf_lock_acquire "$CONF"; then
  echo "swarm-add: REFUSED — swarm.conf lifecycle mutation is already in progress; no local setup was changed." >&2
  exit 2
fi
ADD_TRANSACTION_LOCK_HELD=1
if ! validate_add_registration_snapshot; then
  echo "swarm-add: REFUSED — the registration row changed before setup began; re-run against the current swarm.conf." >&2
  exit 2
fi
if ! bind_repo_identity; then
  echo "swarm-add: REFUSED — could not bind setup to the canonical repository identity: $REPO" >&2
  exit 2
fi
if ! snapshot_engine_surface; then
  echo "swarm-add: REFUSED — could not snapshot AGENTS.md before engine migration." >&2
  exit 2
fi

# 4a) tokens.env -----------------------------------------------------------
if [ -n "$TOKEN" ]; then
  # Create with mode 600 if absent.
  if [ ! -e "$TOKENS" ]; then
    ( umask 077; : > "$TOKENS" )
    echo "  created: $TOKENS (mode 600)"
  fi
  chmod 600 "$TOKENS"
  if [ "$ROTATE_TOKEN" -eq 1 ] && [ "$STATE_TOKEN_PRESENT" -eq 1 ]; then
    # Rewrite the existing line atomically. Avoid sed -i portability woes
    # by streaming through awk to a temp file.
    tmp="$TOKENS.tmp.$$"
    ( umask 077; awk -v var="$TOK_VAR" -v tok="$TOKEN" '
        $0 ~ "^export " var "=" { print "export " var "=\"" tok "\""; next }
        { print }
      ' "$TOKENS" > "$tmp" )
    mv "$tmp" "$TOKENS"
    chmod 600 "$TOKENS"
    echo "  rotated: \$$TOK_VAR in tokens.env"
  else
    # Ensure file ends in a newline before appending so the new export line
    # doesn't get concatenated onto the previous one.
    if [ -s "$TOKENS" ] && [ "$(tail -c 1 "$TOKENS" | od -An -tu1 | tr -d ' ')" != "10" ]; then
      printf '\n' >> "$TOKENS"
    fi
    printf 'export %s="%s"\n' "$TOK_VAR" "$TOKEN" >> "$TOKENS"
    echo "  appended: \$$TOK_VAR to tokens.env"
  fi
  unset TOKEN

  # FAIL LOUDLY if tokens.env is not gitignored.
  if ! git -C "$SWARM_HOME" check-ignore -q tokens.env 2>/dev/null; then
    cat >&2 <<EOF
swarm-add: FATAL — tokens.env is NOT gitignored in $SWARM_HOME.
Add 'tokens.env' to $SWARM_HOME/.gitignore and re-run, or remove the
'export $TOK_VAR=' line you just wrote from $TOKENS by hand.
EOF
    exit 2
  fi
  echo "  confirmed: tokens.env is gitignored"
else
  echo "  skip tokens.env (token was already present; phase 3 SKIP)"
fi

# 4b) swarm.conf -----------------------------------------------------------
NEW_ROW_PENDING=0
if [ ! -e "$CONF" ]; then
  cat > "$CONF" <<'EOF'
# swarm.conf — one repo per line:  session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID | GUILD_ID | ACCOUNT | ENGINE | CODEX_AUTH_POOL
# session_name: short, no spaces (becomes tmux session "swarm-<name>")
# TOKEN_VAR_NAME: name of the env var in tokens.env holding that repo's bot token
# CHANNEL_ID: Discord channel id this swarm is bound to (used by swarm-watch.sh
#   for the per-channel heartbeat). Required even though swarm-up.sh does not use it.
# GUILD_ID: Discord guild (server) snowflake. Used with CHANNEL_ID by the iOS
#   widget to build discord://channels/<guild>/<channel> deep-links per the
#   frozen swarm-status/v1 contract. Optional (blank → emits null, widget
#   falls back to opening the app); fill it in as soon as you know it.
# ACCOUNT is Claude-only. CODEX_AUTH_POOL is a distinct Codex-only selector;
#   blank means the `default` pool declared in codex-profiles.json.
#
# Keep this list short to start — one or two repos. A single Max pool will not feed
# more than ~1–2 teams running concurrently.

EOF
  echo "  created: $CONF"
fi

if [ "$STATE_CONF_PRESENT" -eq 1 ]; then
  if [ "$ENGINE_SWITCH_PENDING" -eq 1 ]; then
    echo "  defer: ENGINE $EXISTING_ENGINE -> $ENGINE until target-engine setup verifies"
  else
    echo "  SKIP swarm.conf append (row for '$NAME' already present)"
  fi
else
  NEW_ROW_PENDING=1
  echo "  defer: new '$NAME' row until engine-specific setup verifies"
fi

# AGENTS.md and the Codex ownership ledger are repository-scoped even though
# engine selection is row-scoped. A Claude row sharing a physical repo with any
# Codex row must leave the repo on the Codex surface; Claude ignores that
# additional entrypoint, while rewriting it to the Claude pointer would make
# every Codex sibling fail its exact managed-surface launch gate. Exclude the
# row being migrated only when it is itself the current Codex reference.
SURFACE_ENGINE="$ENGINE"
if [ "$ENGINE" = "claude" ]; then
  _surface_exclude=""
  if [ "$ENGINE_SWITCH_PENDING" -eq 1 ] && [ "$EXISTING_ENGINE" = "codex" ]; then
    _surface_exclude="$NAME"
  fi
  if ! swarm_codex_repo_ref_count "$REPO" "$_surface_exclude"; then
    echo "swarm-add: REFUSED — malformed swarm.conf prevents safe shared-repo surface selection." >&2
    exit 2
  fi
  if [ "$SWARM_CODEX_REPO_REF_COUNT" -gt 0 ]; then
    SURFACE_ENGINE="codex"
    echo "  shared repo: retaining Codex AGENTS/managed surfaces for $SWARM_CODEX_REPO_REF_COUNT configured Codex sibling(s)"
  fi
fi

# 4c) swarm-init (already idempotent via manifest) ------------------------
# SCRIPT_DIR_EARLY was set at the top of the file (sourcing swarm-lib).
SCRIPT_DIR="$SCRIPT_DIR_EARLY"
echo ""
echo "  running swarm-init.sh against $REPO"
echo "  ----------------------------------------------------------------"
# Thread --type and --profile through to swarm-init so .claude/swarm-type and
# .claude/swarm-profile get stamped before manifest_apply resolves the
# archetype + profile. Build the arg list dynamically so the bare form (no
# flags) preserves engineering-cto-default, no-profile behavior.
INIT_ARGS=("$REPO")
[ -n "$TYPE" ]    && INIT_ARGS+=(--type "$TYPE")
[ -n "$PROFILE" ] && INIT_ARGS+=(--profile "$PROFILE")
INIT_ARGS+=(--engine "$SURFACE_ENGINE")
if ! repo_identity_matches; then
  echo "swarm-add: REFUSED — repo identity changed before swarm-init; no row was committed." >&2
  exit 2
fi
"$SCRIPT_DIR/swarm-init.sh" "${INIT_ARGS[@]}" | sed 's/^/    /'
INIT_RC=${PIPESTATUS[0]}
echo "  ----------------------------------------------------------------"
if [ "$INIT_RC" -ne 0 ]; then
  echo "swarm-add: FATAL — swarm-init.sh failed (rc=$INIT_RC). Resolve and re-run." >&2
  exit 2
fi
if ! repo_identity_matches; then
  echo "swarm-add: REFUSED — repo identity changed during swarm-init; no row was committed." >&2
  exit 2
fi

# 4d) access.json ----------------------------------------------------------
( umask 077; mkdir -p "$(dirname "$ACCESS")" ) || {
  echo "swarm-add: FATAL — could not create access.json parent" >&2; exit 2; }
if [ ! -e "$ACCESS" ]; then
  ( umask 077; cat > "$ACCESS" <<EOF
{
  "dmPolicy": "pairing",
  "loginControlOwnerId": "$OWNER_ID",
  "allowFrom": ["$OWNER_ID"],
  "groups": {},
  "pending": {}
}
EOF
  ) || { echo "swarm-add: FATAL — could not create $ACCESS" >&2; exit 2; }
  echo "  created: $ACCESS"
fi
if [ -L "$ACCESS" ] || [ ! -f "$ACCESS" ]; then
  echo "swarm-add: FATAL — access.json must be a regular non-symlink: $ACCESS" >&2
  exit 2
fi
if ! /usr/bin/python3 -I -B - "$ACCESS" "$CHANNEL" "$OWNER_ID" "$EFFECTIVE_TYPE" "$SWARM_BUS_CHANNEL" "$CTO_BUS_WATCHER_BOT_ID" "$ENGINE" <<'PY'
import ctypes, errno, json, os, stat, sys, tempfile
path, channel, owner, archetype, bus, watcher, engine = sys.argv[1:8]
st=os.lstat(path)
if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != os.getuid()):
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
if not isinstance(cfg, dict): raise SystemExit('access.json must be an object')
top=cfg.setdefault("allowFrom", [])
if not isinstance(top, list): raise SystemExit('top-level allowFrom must be a list')
if owner not in top: top.append(owner)
cfg["loginControlOwnerId"] = owner
cfg.setdefault("groups", {})[channel] = {"requireMention": False, "allowFrom": [owner]}
if archetype == 'cpo':
    if bus == channel: raise SystemExit('CPO operator and bus channels must be distinct')
    grp=cfg.setdefault("groups", {}).setdefault(bus, {"requireMention": False, "allowFrom": []})
    if not isinstance(grp, dict): raise SystemExit('bus ACL group must be an object')
    grp["requireMention"] = False
    allow=grp.setdefault("allowFrom", [])
    if not isinstance(allow, list): raise SystemExit('bus allowFrom must be a list')
    for sender in (owner, watcher):
        if sender not in allow: allow.append(sender)
fd,tmp=tempfile.mkstemp(prefix='.access.json.',dir=os.path.dirname(path) or '.')
try:
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
with open(path) as f: json.load(f)  # validate the file we just wrote
print("  access.json group for channel {} set "
      "(requireMention=false, allowFrom=[{}])".format(channel, owner))
if archetype == 'cpo':
    print("  access.json CPO bus group {} ensured (explicit owner + watcher)".format(bus))
PY
then
  echo "swarm-add: FATAL — access.json reconciliation failed; engine row remains unchanged" >&2
  exit 2
fi

# 4e) cto-watcher bus registration (engineering-cto only) ------------------
#
# A CTO rides the #cpo-cto-bus only once BOTH halves are wired:
#   (1) a ctoChannels entry in cto-watcher/config.json (name -> channelId +
#       botUserId), and
#   (2) the cto-watcher bot's id in this channel's access.json allowFrom —
#       the watcher reposts CPO directives AS ITSELF, so the new CTO's
#       bridge drops them unless the watcher id is allow-listed.
# Both are idempotent. 4d above resets this channel's allowFrom to [owner];
# the wire script (re-)appends the watcher id here, so a re-run is
# self-healing.
#
# The actual wiring is a THIN CALL into bin/swarm-bus-wire.sh (ADR-0015) — the
# single shared, independently-runnable implementation of both halves. We pass
# CTO_WATCHER_CONFIG / CTO_BUS_WATCHER_BOT_ID / SWARM_ACCESS_FILE through so the
# script uses the exact same paths swarm-add resolved (and tests can override).
if [ "$EFFECTIVE_TYPE" != "engineering-cto" ]; then
  echo ""
  echo "  4e) cto-watcher bus: SKIP (type '$EFFECTIVE_TYPE' is not a CTO; off the #cpo-cto-bus)"
else
  echo ""
  echo "  4e) cto-watcher bus registration for CTO '$NAME'"
  CTO_WATCHER_CONFIG="$CTO_WATCHER_CONFIG" \
  CTO_BUS_WATCHER_BOT_ID="$CTO_BUS_WATCHER_BOT_ID" \
  SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_ACCESS_REQUIRE_NO_ACL="$([ "$ENGINE" = codex ] && printf 1 || printf 0)" \
    "$SCRIPT_DIR/swarm-bus-wire.sh" "$NAME" "$CHANNEL" "$BOT_USER_ID" \
    || { echo "swarm-add: FATAL — bus wiring (swarm-bus-wire.sh) failed" >&2; exit 2; }
fi

# ---------------------------------------------------------------------------
# PHASE 5 — Post-init verification (the reserve-backend-2 trap)
#
# The lead launches `claude --dangerously-load-development-channels
# plugin:discord-b2b@qofi-swarm`, but the bridge MCP only spawns if the
# repo's .claude/settings.json has enabledPlugins["discord-b2b@qofi-swarm"]
# set to TRUE. If that key is missing or false, the lead comes up with no
# Discord tools — silent failure mode. Verify (and repair) here.
# ---------------------------------------------------------------------------
SETTINGS_FILE="$REPO/.claude/settings.json"
if [ "$ENGINE" = "codex" ]; then
  phase "Phase 5 — Claude channel-plugin verification  [SKIPPED: engine=codex]"
  echo "  Codex uses the standalone codex-bridge daemon; .claude enabledPlugins is not its runtime gate."
else
phase "Phase 5 — verify enabledPlugins[\"$PLUGIN_KEY\"] === true"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "swarm-add: FATAL — $SETTINGS_FILE missing after swarm-init. Something is very wrong; investigate before bringing the swarm up." >&2
  exit 2
fi

verify_plugins() {
  python3 - "$SETTINGS_FILE" "$PLUGIN_KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(path))
except Exception as e:
    print("PARSE_FAIL:" + str(e))
    sys.exit(2)
ep = s.get("enabledPlugins") or {}
val = ep.get(key)
if val is True:
    print("OK")
    sys.exit(0)
if key not in ep:
    print("MISSING_KEY")
elif val is False:
    print("FALSE")
else:
    print("UNEXPECTED:" + repr(val))
sys.exit(3)
PY
}

VERIFY_OUT="$(verify_plugins)"
VERIFY_RC=$?
echo "  status: $VERIFY_OUT"

if [ "$VERIFY_RC" -eq 0 ]; then
  echo "  OK — bridge MCP will spawn on launch."
elif [ "$VERIFY_RC" -eq 3 ]; then
  cat <<EOF

  enabledPlugins["$PLUGIN_KEY"] is not TRUE in $SETTINGS_FILE.
  This is the EXACT trap that broke reserve-backend-2's first bringup:
  the lead launches but the bridge MCP never spawns, so the bot looks
  online while every Discord tool call fails silently.

  Repair: set "enabledPlugins": { "$PLUGIN_KEY": true } in
  $SETTINGS_FILE (additive; existing keys preserved).

EOF
  REPAIR_ANS=""
  if ! read_line REPAIR_ANS "Repair now? [Y/n]: "; then
    echo "swarm-add: input ended before plugin repair confirmation; no repair was applied." >&2
    exit 2
  fi
  case "$REPAIR_ANS" in
    n|N|no|No|NO) echo "  declined — exit 2"; exit 2 ;;
  esac
  python3 - "$SETTINGS_FILE" "$PLUGIN_KEY" <<'PY' || { echo "swarm-add: FATAL — repair failed" >&2; exit 2; }
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f: s = json.load(f)
s.setdefault("enabledPlugins", {})[key] = True
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2); f.write("\n")
os.replace(tmp, path)
print("  repaired: set enabledPlugins[{!r}] = true".format(key))
PY
  # Re-verify.
  VERIFY_OUT="$(verify_plugins)"
  if [ $? -ne 0 ]; then
    echo "swarm-add: FATAL — verification still failing after repair: $VERIFY_OUT" >&2
    exit 2
  fi
  echo "  re-verified: OK"
else
  echo "swarm-add: FATAL — could not parse $SETTINGS_FILE: $VERIFY_OUT" >&2
  exit 2
fi
fi

# Codex rows are committed only after the root-attested dedicated runtime can
# both prepare and verify this exact canonical workspace. This deliberately
# has no Claude branch: Claude keeps its historical native setup and launch
# path byte-for-byte. A new/adopting Codex row is transactional; the EXIT trap
# releases workspace authority if any later config CAS fails.
if [ "$ENGINE" = "codex" ]; then
  phase "Phase 5b — dedicated Codex runtime preparation + verification"
  if [ "$EXISTING_ROW" -eq 0 ] \
     || { [ "$ENGINE_SWITCH_PENDING" -eq 1 ] && [ "$EXISTING_ENGINE" != "codex" ]; }; then
    CODEX_ADOPTION_PENDING=1
  fi
  if ! codex_runtime_prepare_and_verify; then
    echo "swarm-add: FATAL — Codex runtime verification failed; no Codex row was committed." >&2
    exit 2
  fi
  echo "  OK — dedicated runtime and workspace authority verified."
fi

# Commit an engine migration only after target-engine init and verification
# have both succeeded. A failure before here leaves the old row truthful.
if [ "$ENGINE_SWITCH_PENDING" -eq 1 ]; then
  if ! commit_engine_switch; then
    echo "swarm-add: FATAL — target-engine setup passed but ENGINE row commit failed; old engine remains configured" >&2
    exit 2
  fi
  CODEX_ADOPTION_PENDING=0
  discard_engine_surface_snapshot
  echo "  committed: '$NAME' ENGINE $EXISTING_ENGINE -> $ENGINE in swarm.conf"
fi
if [ "$EXISTING_ROW" -eq 1 ] && [ "$ENGINE_SWITCH_PENDING" -eq 0 ] \
   && [ "$ENGINE" = "codex" ] && [ "$CODEX_AUTH_POOL_EXPLICIT" -eq 1 ] \
   && [ "$CODEX_AUTH_POOL" != "$EXISTING_CODEX_AUTH_POOL" ]; then
  if ! validate_add_registration_snapshot \
     || ! swarm_conf_set_codex_auth_pool "$CONF" "$NAME" "$CODEX_AUTH_POOL"; then
    echo "swarm-add: FATAL — target setup passed but CODEX_AUTH_POOL update could not be committed" >&2
    exit 2
  fi
  EXISTING_ROW_RAW="$(grep -E "^[[:space:]]*${NAME}[[:space:]]*\\|" "$CONF")"
  echo "  committed: '$NAME' CODEX_AUTH_POOL $EXISTING_CODEX_AUTH_POOL -> $CODEX_AUTH_POOL in swarm.conf"
fi
if [ "$NEW_ROW_PENDING" -eq 1 ]; then
  # GUILD_ID is left blank; preserve the historical five-field Claude row.
  if [ "$ENGINE" = "codex" ]; then
    _new_row="$(printf '%s | %s | %s | %s | | | codex | %s' "$NAME" "$REPO" "$TOK_VAR" "$CHANNEL" "$CODEX_AUTH_POOL")"
  else
    _new_row="$(printf '%s | %s | %s | %s | ' "$NAME" "$REPO" "$TOK_VAR" "$CHANNEL")"
  fi
  if ! commit_new_row "$_new_row"; then
    echo "swarm-add: FATAL — setup passed but the new row could not be committed" >&2
    exit 2
  fi
  CODEX_ADOPTION_PENDING=0
  echo "  committed: new '$NAME' row -> swarm.conf (engine=$ENGINE)"
fi

# No engine/config transaction remains after the exact commit (or a verified
# idempotent rerun). Release before printing the operator-only checklist.
if [ "$ADD_TRANSACTION_LOCK_HELD" -eq 1 ]; then
  swarm_conf_lock_release
  ADD_TRANSACTION_LOCK_HELD=0
fi

# ---------------------------------------------------------------------------
# PHASE 6 — Verification checklist (printed; operator runs it)
# ---------------------------------------------------------------------------
phase "Phase 6 — Verification checklist"

if [ "$ENGINE" = "codex" ]; then
cat <<EOF

Standup is complete on disk. Confirm the Codex lead:

  1) Bring it up (auth preflight requires a ChatGPT subscription login):
       bin/swarm-up.sh up $NAME

  2) Smoke-test #<your-channel> with an allowed sender. The canonical channel
     allowFrom is reconciled into the Codex state dir on every launch; launch
     fails closed if that list is empty. This first successful turn creates the
     configured channel's resumable thread.

  3) Open the supported operator view:
       bin/swarm-view.sh $NAME
     Once the configured channel has a persisted thread and the manager/facade
     proofs are healthy, this opens the native same-thread Codex TUI through the
     read-only per-swarm gateway. Before that first successful turn, or whenever
     a proof is unavailable, it truthfully opens the bounded redacted fallback.

  4) Check the external heartbeat/status feed on the next watcher tick.

Troubleshooting: inspect $HOME/.codex/channels/discord-$NAME/runtime.json and
events.jsonl through swarm-view; never type into or interrupt the daemon pane.
EOF
else
cat <<EOF

Standup is complete on the host. Confirm the swarm is actually live with
the steps below. If any step fails, see TROUBLESHOOTING at the end.

  1) Bring up the lead:
       bin/swarm-up.sh up $NAME

  2) ATTACH to watch it land. Pick one:
       bin/swarm-attach.sh $NAME
       # or, if you've sourced bin/swarm-aliases.sh (see phase 7):
       swarm-$NAME

  3) Watch the pane render. Expected, in order:
       - shell unsets ANTHROPIC_API_KEY, sources tokens.env
       - 'claude --dangerously-load-development-channels plugin:$PLUGIN_KEY' starts
       - DEV-CHANNELS PROMPT appears:
           > 1. I am using this for local development
             2. Exit
         swarm-up.sh polls for this and sends Enter automatically. If it
         races and the prompt is still waiting when you attach, clear it:
             tmux send-keys -t swarm-$NAME Enter
       - The Claude UI renders; the footer shows "auto mode"
       - The archetype-appropriate initial brief lands (per
         swarm_launch_brief — engineering-cto reads TEAM_LEAD/CLAUDE/...,
         cpo reads CLAUDE/CONVERSATION/EVALUATION/...)
       - In Discord, the bot's status flips ONLINE in the server member list

  4) Smoke-test the channel. In #<your-channel>, @mention the bot:
         @swarm-$NAME hi
     Expected: the lead acknowledges (typed reply or reaction). If you
     get NO response, the bridge MCP didn't spawn — re-run this script
     with --skip-walkthrough and let phase 5 re-verify enabledPlugins.

  5) Watch the heartbeat:
       bin/swarm-watch-log
     A SWARM-HEARTBEAT for '$NAME' should land in #<channel> on the
     next watcher fire (com.qofi.swarm-watch launchd job).

TROUBLESHOOTING

  Bot online but no MCP tools / silent in chat:
    Phase 5 above failed or got bypassed. Re-run:
        bin/swarm-add.sh $NAME $REPO $CHANNEL --skip-walkthrough
    Phase 5 will detect + repair enabledPlugins.

  Bot offline in Discord:
    Token bad or not loaded. Check:
        grep '^export $TOK_VAR=' $TOKENS    # line exists?
        bin/swarm-up.sh down $NAME && bin/swarm-up.sh up $NAME
    If still offline, rotate the token in the Discord portal and re-run:
        bin/swarm-add.sh $NAME $REPO $CHANNEL --skip-walkthrough --rotate-token

  Message-content empty / bot ignores @mentions:
    MESSAGE CONTENT INTENT is OFF in the portal. Re-do phase 1 group B.

  Permission errors when bot tries to send:
    OAuth permission set is incomplete. Re-do phase 1 group C — the full
    set is View Channels / Send Messages / Send Messages in Threads /
    Read Message History / Attach Files / Add Reactions.

  Dev-channels prompt sits forever:
    The auto-Enter from swarm-up.sh raced and lost. Manual clear:
        tmux send-keys -t swarm-$NAME Enter

EOF
fi

# ---------------------------------------------------------------------------
# PHASE 7 — Summary + alias re-source reminder
# ---------------------------------------------------------------------------
phase "Phase 7 — Summary"

if [ "$EFFECTIVE_TYPE" = "engineering-cto" ]; then
  BUS_SUMMARY="    bus:     #cpo-cto-bus via cto-watcher (ctoChannels['$NAME'] = {channel $CHANNEL, bot ${BOT_USER_ID:-<unchanged>}}; watcher id on allowFrom) — restart the watcher to load it"
else
  BUS_SUMMARY="    bus:     n/a ($EFFECTIVE_TYPE is not a CTO)"
fi

if [ "$ENGINE" = "codex" ]; then
  ACCESS_SUMMARY="$ACCESS  (group $CHANNEL -> owner $OWNER_ID, direct bound-channel allowlist; requireMention=false)"
  PLUGIN_SUMMARY="n/a (codex-bridge daemon; Claude channel plugin not used)"
  ALIAS_SUMMARY="open the supported Codex operator view"
else
  ACCESS_SUMMARY="$ACCESS  (group $CHANNEL -> owner $OWNER_ID, mention-gated)"
  PLUGIN_SUMMARY="$PLUGIN_KEY enabled in $SETTINGS_FILE"
  ALIAS_SUMMARY="attach-or-launch this swarm"
fi

cat <<EOF

  Swarm '$NAME' registered.
    repo:    $REPO
    type:    $EFFECTIVE_TYPE${PROFILE:+  (profile: $PROFILE)}
    engine:  $ENGINE
    channel: $CHANNEL
    bot:     \$$TOK_VAR  (token in $TOKENS, chmod 600, gitignored)
    access:  $ACCESS_SUMMARY
    plugin:  $PLUGIN_SUMMARY
$BUS_SUMMARY

  A per-swarm shell alias 'swarm-$NAME' is now generated by
  bin/swarm-aliases.sh from swarm.conf, but it isn't live in this shell
  yet. Pick up the new alias with:

       source ~/.zshrc        # (or open a new terminal)

  Then:
       swarm-$NAME            # $ALIAS_SUMMARY

  The launchd watcher (com.qofi.swarm-watch) picks the new conf row up
  on its next fire — nothing else to wire.

  swarm-add does NOT auto-launch. When you're ready, run the steps in
  phase 6's checklist above to bring it up and confirm.

EOF
