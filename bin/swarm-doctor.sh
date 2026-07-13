#!/usr/bin/env bash
# swarm-doctor.sh — assert the full operational set for an engineering-cto
# swarm and BLOCK on ANY gap (ADR-0015). No partial state passes silently:
# every checked precondition is reported PASS or FAIL, and a single FAIL exits
# non-zero. This is the precondition gate that makes bus wiring (and the rest
# of standup) verifiable — it answers "is this CTO actually wired up?" without
# trusting a summary.
#
# Usage:
#   swarm-doctor.sh <name>
#
#   <name>   swarm name; must have a row in $SWARM_HOME/swarm.conf
#
# What it asserts, for an engineering-cto swarm with a swarm.conf row:
#   1. doctrine stamped      — the per-archetype required doctrine files
#                              (swarm_required_doctrine) exist in the repo,
#                              AND enabledPlugins["discord-b2b@qofi-swarm"] is
#                              true in .claude/settings.json (the bridge spawns).
#   2. bot token PRESENT     — the swarm's token var exists in tokens.env.
#                              PRESENCE ONLY — the value is NEVER read, printed,
#                              echoed, or logged.
#   3. config.json wired     — cto-watcher/config.json (the routing AUTHORITY,
#                              ADR-0014) has a ctoChannels[<name>] entry with a
#                              channelId matching swarm.conf and a non-empty
#                              botUserId. ctoChannels is read as the authority;
#                              NO roster table is consulted.
#   4. allowFrom wired       — this channel's access.json group has the
#                              cto-watcher bot id in allowFrom (else the new
#                              CTO silently drops reposted CPO directives).
#
# It also emits the STANDING flag that restarting the cto-watcher (so it loads
# a freshly-written ctoChannels entry) is OPERATOR-MANUAL — swarm-doctor cannot
# and does not restart it.
#
# Env overrides (for tests; mirror swarm-add.sh / swarm-bus-wire.sh):
#   CTO_WATCHER_CONFIG       path to cto-watcher/config.json
#                            (default: $SWARM_HOME/cto-watcher/config.json)
#   CTO_BUS_WATCHER_BOT_ID   the cto-watcher bot's own user id
#                            (default: 1510298728148369448)
#   SWARM_ACCESS_FILE        path to access.json
#                            (default: $HOME/.claude/channels/discord/access.json)
#   SWARM_TOKENS_FILE        path to tokens.env
#                            (default: $SWARM_HOME/tokens.env)
#
# Exit: 0 = every assertion passed (CTO fully operational). 1 = at least one
# gap (BLOCK). 2 = usage / lookup error (no swarm.conf row, etc.).

set -euo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-doctor: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

usage() {
  sed -n '1,52p' "$0"
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
  "") echo "swarm-doctor: missing <name>" >&2; usage 2 ;;
esac

if [ "$#" -ne 1 ]; then
  echo "swarm-doctor: expected exactly 1 arg (<name>), got $#" >&2
  usage 2
fi

NAME="$1"

CONF="$SWARM_HOME/swarm.conf"
CTO_WATCHER_CONFIG="${CTO_WATCHER_CONFIG:-$SWARM_HOME/cto-watcher/config.json}"
CTO_BUS_WATCHER_BOT_ID="${CTO_BUS_WATCHER_BOT_ID:-1510298728148369448}"
SWARM_OWNER_DISCORD_ID="${SWARM_OWNER_DISCORD_ID:-1507069153335443608}"
SWARM_BUS_CHANNEL="${SWARM_BUS_CHANNEL:-1510301812434141194}"
# ACCESS is resolved from THIS swarm's account (swarm.conf field 6), below,
# once its row is parsed — never a hand-built $HOME/.claude path. An empty
# account (every row today) resolves byte-for-byte to today's path, honoring
# SWARM_ACCESS_FILE exactly as this line did before.
TOKENS="${SWARM_TOKENS_FILE:-$SWARM_HOME/tokens.env}"
PLUGIN_KEY="discord-b2b@qofi-swarm"

# ---------------------------------------------------------------------------
# Resolve the swarm.conf row for <name>. A missing row is a usage error (2):
# swarm-doctor checks a registered swarm; an unregistered name is not a "gap".
# ---------------------------------------------------------------------------
REPO=""
TOKVAR=""
CHANNEL=""
ACCOUNT=""
ENGINE=""
FOUND=0
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$NAME" ]; then
    REPO="$SWARM_CONF_F_REPO"
    TOKVAR="$SWARM_CONF_F_TOKVAR"
    CHANNEL="$SWARM_CONF_F_CHANNEL"
    ACCOUNT="$SWARM_CONF_F_ACCOUNT"
    ENGINE="$SWARM_CONF_F_ENGINE"
    FOUND=1
    break
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$FOUND" -eq 0 ]; then
  echo "swarm-doctor: no swarm.conf row for '$NAME' in $CONF — nothing to check." >&2
  exit 2
fi

# Resolve the access.json for THIS swarm's account (field 6, empty today). The
# resolver is the SOLE constructor of the path: an empty account maps to today's
# $HOME/.claude/... (honoring SWARM_ACCESS_FILE), a label to its isolated dir.
ACCESS_ACCOUNT="$ACCOUNT"
[ "$ENGINE" = "codex" ] && ACCESS_ACCOUNT=""
swarm_account_resolve "$ACCESS_ACCOUNT" || {
  echo "swarm-doctor: invalid account '$ACCOUNT' in swarm.conf row for '$NAME'" >&2
  exit 2
}
ACCESS="$SWARM_ACCT_ACCESS_FILE"

# Resolve archetype. swarm-doctor's full operational set is engineering-cto's
# (the bus halves only apply to CTOs). A non-CTO swarm is not an error, but the
# bus assertions don't apply — report and exit 0 (nothing to gate here).
REPO_TYPE="$(swarm_type_of "$REPO")"

echo "===================================================================="
echo "swarm-doctor: $NAME"
echo "  repo:    $REPO"
echo "  type:    $REPO_TYPE"
echo "  engine:  $ENGINE"
echo "  channel: ${CHANNEL:-<none>}"
echo "===================================================================="

# Assertion machinery is initialized before archetype dispatch because Codex
# CPO rows have engine-native ACL requirements even though the historical CTO
# bus checklist does not apply to them.
BLOCKED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; BLOCKED=1; }

if [ "$ENGINE" = "codex" ]; then
  if CODEX_ACL_OUT="$(/usr/bin/python3 -I -B - "$ACCESS" "$CHANNEL" "$REPO_TYPE" "$SWARM_BUS_CHANNEL" "$SWARM_OWNER_DISCORD_ID" "$CTO_BUS_WATCHER_BOT_ID" <<'PY'
import json, os, stat, sys
path, primary, archetype, bus, owner, watcher = sys.argv[1:7]
try:
    st=os.lstat(path); parent=os.path.dirname(os.path.realpath(path)); pst=os.lstat(parent)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600):
        raise ValueError('file must be current-user regular mode 0600')
    if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
            or pst.st_uid != os.getuid() or stat.S_IMODE(pst.st_mode) != 0o700):
        raise ValueError('parent must be current-user real mode 0700')
    cfg=json.load(open(path)); top=cfg.get('allowFrom')
    if not isinstance(top,list) or owner not in top:
        raise ValueError('top-level allowFrom lacks the explicit operator id')
    channels=[primary] + ([bus] if archetype == 'cpo' and bus != primary else [])
    for channel in channels:
        group=(cfg.get('groups') or {}).get(channel)
        allow=group.get('allowFrom') if isinstance(group,dict) else None
        if not isinstance(allow,list) or owner not in allow:
            raise ValueError('group %s lacks the explicit operator id' % channel)
    if archetype == 'cpo' and watcher not in cfg['groups'][bus]['allowFrom']:
        raise ValueError('CPO bus group lacks the watcher id')
except Exception as exc:
    print(str(exc)); raise SystemExit(1)
print('mode 0600; explicit operator; effective groups=' + ','.join(channels))
PY
)"; then
    pass "Codex canonical ACL: $CODEX_ACL_OUT"
  else
    fail "Codex canonical ACL: ${CODEX_ACL_OUT:-missing/unreadable} ($ACCESS)"
  fi
fi

if [ "$REPO_TYPE" != "engineering-cto" ]; then
  echo "  type '$REPO_TYPE' is not a CTO — the #cpo-cto-bus operational set"
  echo "  does not apply. (Doctrine/token checks for non-CTO archetypes are"
  echo "  swarm-up's preflight gates, not swarm-doctor's bus precondition set.)"
  if [ "$BLOCKED" -ne 0 ]; then
    echo "swarm-doctor: BLOCKED — '$NAME' has an engine-native operational gap." >&2
    exit 1
  fi
  echo "  PASS (n/a): not a CTO swarm; no CTO bus preconditions to assert."
  exit 0
fi

# ---------------------------------------------------------------------------
# Assertion machinery. Each check prints PASS/FAIL; any FAIL flips BLOCKED.
# ---------------------------------------------------------------------------
# --- 1) doctrine stamped --------------------------------------------------
# (a) required doctrine files present (per archetype).
MISSING=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$REPO/$f" ] || MISSING="$MISSING $f"
done < <(swarm_required_doctrine "$REPO_TYPE")
if [ -n "$MISSING" ]; then
  fail "doctrine stamped: missing in $REPO —$MISSING"
else
  pass "doctrine stamped: required files present ($(swarm_required_doctrine "$REPO_TYPE" | tr '\n' ' '))"
fi

# (b) Claude rows require the channel plugin. Codex uses its direct bridge and
# must never be diagnosed against Claude's plugin/account runtime.
SETTINGS="$REPO/.claude/settings.json"
if [ "$ENGINE" = "codex" ]; then
  pass "Claude channel plugin: n/a (engine=codex uses codex-bridge)"
elif [ ! -f "$SETTINGS" ]; then
  fail "doctrine stamped: $SETTINGS missing (bridge plugin cannot be verified)"
elif /usr/bin/python3 -I -B - "$SETTINGS" "$PLUGIN_KEY" <<'PY' >/dev/null 2>&1
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ep = s.get("enabledPlugins") or {}
sys.exit(0 if ep.get(sys.argv[2]) is True else 1)
PY
then
  pass "doctrine stamped: enabledPlugins[\"$PLUGIN_KEY\"] === true"
else
  fail "doctrine stamped: enabledPlugins[\"$PLUGIN_KEY\"] not true in $SETTINGS (bridge MCP will not spawn)"
fi

# Codex-native diagnostics. These are read-only and use the same bounded CLI
# line/auth/config contracts as the unattended launcher. Runtime is checked
# when present; a stopped daemon is n/a rather than a wiring failure.
if [ "$ENGINE" = "codex" ]; then
  CODEX_HOST_OK=0
  if swarm_codex_host_preflight "$REPO"; then
    CODEX_HOST_OK=1
    pass "Codex CLI: trusted canonical executable, bounded version $SWARM_CODEX_CLI_VERSION"
    pass "Codex auth: exact ChatGPT subscription status verified"
    pass "Codex runtime authority: $SWARM_CODEX_RUNTIME_SCHEMA via $SWARM_CODEX_RUNNER (uid=$SWARM_CODEX_RUNTIME_UID group=$SWARM_CODEX_RUNTIME_GROUP)"
  else
    fail "Codex host/auth: trusted bounded preflight failed"
  fi

  if [ -e "$REPO/.codex/config.toml" ] || [ -L "$REPO/.codex/config.toml" ]; then
    if [ "$CODEX_HOST_OK" -eq 1 ] && \
       /usr/bin/env -i HOME="$SWARM_CODEX_CANONICAL_HOME" CODEX_HOME="$SWARM_CODEX_CANONICAL_CODEX_HOME" \
       PATH="$SWARM_CODEX_TOOL_PATH" LANG=C LC_ALL=C \
       "$SWARM_CODEX_TRUSTED_BUN_REAL" --no-env-file --config=/dev/null --no-install \
       --no-addons --no-macros --cwd="$SWARM_HOME/codex-bridge" \
       "$SWARM_HOME/bin/codex-project-config-check.ts" "$REPO/.codex/config.toml" >/dev/null 2>&1; then
      pass "Codex project config: strict allowlist passes"
    else
      fail "Codex project config: unsafe/unreviewed or checker unavailable"
    fi
  else
    pass "Codex project config: n/a (no .codex/config.toml)"
  fi
  if [ -e "$(swarm_codex_state_dir "$NAME")/runtime.json" ]; then
    if swarm_codex_runtime_read "$NAME"; then
      pass "Codex runtime: healthy (ready=$SWARM_CODEX_RUNTIME_READY active=$SWARM_CODEX_RUNTIME_ACTIVE queued=$SWARM_CODEX_RUNTIME_QUEUE_DEPTH)"
    else
      fail "Codex runtime: $SWARM_CODEX_RUNTIME_STATUS ($SWARM_CODEX_RUNTIME_FILE)"
    fi
  else
    pass "Codex runtime: n/a (daemon not currently running)"
  fi
  if [ -f "$REPO/.codex/hooks.json" ] && /usr/bin/python3 -I -B - "$REPO/.codex/hooks.json" <<'PY' >/dev/null 2>&1
import json,sys
assert json.load(open(sys.argv[1])) == {"hooks": {}}
PY
  then
    pass "Codex command hooks: empty managed neutralizer present"
  else
    fail "Codex command hooks: .codex/hooks.json is not the empty neutralizer"
  fi
fi

# --- 2) bot token PRESENT (presence only — value NEVER read/printed) -------
if [ -z "$TOKVAR" ]; then
  fail "bot token: swarm.conf row has no token var name"
elif [ -f "$TOKENS" ] && grep -qE "^export ${TOKVAR}=" "$TOKENS"; then
  # Presence confirmed by matching the line PREFIX only; the value after '='
  # is never captured, expanded, printed, or logged.
  pass "bot token: \$$TOKVAR present in $TOKENS (presence only; value not read)"
else
  fail "bot token: \$$TOKVAR not present in $TOKENS"
fi

# --- 3) config.json ctoChannels wired (the routing AUTHORITY, ADR-0014) ----
if [ ! -f "$CTO_WATCHER_CONFIG" ]; then
  fail "config.json ctoChannels: $CTO_WATCHER_CONFIG not found"
else
  CFG_OUT="$(/usr/bin/python3 -I -B - "$CTO_WATCHER_CONFIG" "$NAME" "$CHANNEL" <<'PY'
import json, sys
path, name, channel = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(path))
except Exception as e:
    print("PARSE_FAIL:" + str(e)); sys.exit(1)
entry = (cfg.get("ctoChannels") or {}).get(name)
if not entry:
    print("NO_ENTRY"); sys.exit(1)
cid = entry.get("channelId")
bot = entry.get("botUserId")
if not bot:
    print("NO_BOTUSERID"); sys.exit(1)
if channel and cid != channel:
    print("CHANNEL_MISMATCH:conf={} cfg={}".format(channel, cid)); sys.exit(1)
print("OK:channelId={} botUserId={}".format(cid, bot)); sys.exit(0)
PY
)" && CFG_RC=0 || CFG_RC=$?
  if [ "${CFG_RC:-1}" -eq 0 ]; then
    pass "config.json ctoChannels['$NAME'] wired ($CFG_OUT)"
  else
    fail "config.json ctoChannels['$NAME'] gap: $CFG_OUT"
  fi
fi

# --- 4) allowFrom wired (watcher id allow-listed for this channel) ---------
if [ -z "$CHANNEL" ]; then
  fail "access.json allowFrom: swarm.conf row has no channel id"
elif [ ! -f "$ACCESS" ]; then
  fail "access.json allowFrom: $ACCESS not found"
elif /usr/bin/python3 -I -B - "$ACCESS" "$CHANNEL" "$CTO_BUS_WATCHER_BOT_ID" <<'PY' >/dev/null 2>&1
import json, sys
path, channel, watcher = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    acc = json.load(open(path))
except Exception:
    sys.exit(1)
grp = (acc.get("groups") or {}).get(channel) or {}
sys.exit(0 if watcher in (grp.get("allowFrom") or []) else 1)
PY
then
  pass "access.json allowFrom: watcher id $CTO_BUS_WATCHER_BOT_ID present for channel $CHANNEL"
else
  fail "access.json allowFrom: watcher id $CTO_BUS_WATCHER_BOT_ID NOT in allowFrom for channel $CHANNEL (reposted CPO directives would be dropped)"
fi

# ---------------------------------------------------------------------------
# Standing flag — restarting the cto-watcher is operator-manual.
# ---------------------------------------------------------------------------
echo "--------------------------------------------------------------------"
echo "  FLAG (standing): restarting the cto-watcher so it loads a freshly-"
echo "  written ctoChannels entry is OPERATOR-MANUAL — swarm-doctor does not"
echo "  and cannot restart it (watcher-control skill / bin/cto-watch-*.sh)."
echo "===================================================================="

if [ "$BLOCKED" -ne 0 ]; then
  echo "swarm-doctor: BLOCKED — '$NAME' has at least one operational gap (see FAIL above)." >&2
  exit 1
fi
echo "swarm-doctor: OK — '$NAME' is fully wired for the #cpo-cto-bus."
exit 0
