#!/usr/bin/env bash
# swarm-account-provision.sh <label> [--dry-run] [--force]
#
# Idempotently create an account's ISOLATED config-dir SKELETON so a labeled swarm
# can launch under it (ADR-0018, the multi-account partition). This is the
# CC-TOOLED half of activation; the OPERATOR-ONLY half (the actual credential) is
# never touched here.
#
# ── WHAT IT CREATES (all under the resolver's config dir, never a hand-built path)
#   <CONFIG_DIR>/plugins/known_marketplaces.json   the qofi-swarm marketplace
#       (directory source → $SWARM_HOME) so the discord-b2b plugin RESOLVES for a
#       claude launched with CLAUDE_CONFIG_DIR=<CONFIG_DIR>.
#   <CONFIG_DIR>/plugins/installed_plugins.json    discord-b2b@qofi-swarm recorded
#       installed (user scope, loaded from $SWARM_HOME/bridge — the directory source).
#   <CONFIG_DIR>/channels/discord/access.json      a SYMMETRIC access.json: one group
#       per swarm.conf channel (allowFrom = owner + cto-watcher bot, requireMention
#       false). Symmetric = identical group set across every account, so a failover
#       swap is a conf field edit + restart with NO access re-write (ADR-0018 §P2).
#   The config dir + projects/ + channels/discord/ are created so the WORKING rail
#   (repo_activity) and the bridge have their directories.
#
# ── WHAT IT DOES NOT DO (the floor) ──────────────────────────────────────────
#   - Reads NO token. Writes NO token. Never runs `claude setup-token`. The
#     OAUTH_TOKEN_<LABEL> credential is an OPERATOR-ONLY, terms-cleared step.
#   - Never edits swarm.conf (does not label any swarm). Labeling is the operator's
#     ratify-and-apply step.
#   - Never touches the LIVE fleet. Provisioning a skeleton is inert until the
#     operator adds the token, labels rows, and restarts.
#   It PRINTS the operator's remaining MANUAL steps at the end.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  skeleton present (created or already-complete; --dry-run that found no error)
#   1  usage / SWARM_HOME unset-or-wrong
#   2  invalid account label (rejected by swarm_account_resolve before any path)
#   3  write failure (mkdir / file write / json validation)
#
# ── SEAMS (tests inject these) ───────────────────────────────────────────────
#   HOME                     the resolver builds $HOME/.claude-accounts/<label>;
#                            tests point HOME at a temp dir.
#   SWARM_OWNER_DISCORD_ID   owner id seeded into every access.json group
#                            (default mirrors swarm-add.sh).
#   CTO_BUS_WATCHER_BOT_ID   cto-watcher bot id added to every group's allowFrom
#                            (default mirrors swarm-add.sh / swarm-bus-wire.sh).
#   SWARM_CONF               override the swarm.conf read for the channel set.
#
# Run from $SWARM_HOME:  bin/swarm-account-provision.sh max-b
# bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-account-provision"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

CONF="${SWARM_CONF:-$SWARM_HOME/swarm.conf}"
OWNER_ID="${SWARM_OWNER_DISCORD_ID:-1507069153335443608}"
WATCHER_ID="${CTO_BUS_WATCHER_BOT_ID:-1510298728148369448}"
case "$OWNER_ID" in ''|*[!0-9]*) echo "$PROG: SWARM_OWNER_DISCORD_ID must be numeric" >&2; exit 2 ;; esac
case "$WATCHER_ID" in ''|*[!0-9]*) echo "$PROG: CTO_BUS_WATCHER_BOT_ID must be numeric" >&2; exit 2 ;; esac

log()  { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
DRY=0
LABEL=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force)   : ;;  # accepted for symmetry; provisioning is already idempotent
    -h|--help) sed -n '1,46p' "$0"; exit 0 ;;
    --*)       echo "$PROG: unknown flag: $arg" >&2; sed -n '1,2p' "$0" >&2; exit 1 ;;
    *)
      if [ -z "$LABEL" ]; then LABEL="$arg"
      else echo "$PROG: too many positional args (one <label>)" >&2; exit 1; fi ;;
  esac
done

[ -z "$LABEL" ] && { echo "$PROG: missing <label> (the account to provision)" >&2; echo "usage: $PROG <label> [--dry-run]" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve — the SOLE constructor of the account's paths. An empty/invalid label
# never names a dir (the default account is keychain auth, not a provisionable
# skeleton; refuse it explicitly).
# ---------------------------------------------------------------------------
if ! swarm_account_resolve "$LABEL"; then
  exit 2  # resolver already explained the bad label on stderr
fi
if [ -z "$SWARM_ACCT_TOKEN_VAR" ]; then
  echo "$PROG: '$LABEL' resolved to the DEFAULT (keychain) account — nothing to provision." >&2
  echo "$PROG: the default account uses the operator's existing keychain config dir; pass a real label." >&2
  exit 2
fi

CONFIG_DIR="$SWARM_ACCT_CONFIG_DIR"
PROJECTS_DIR="$SWARM_ACCT_PROJECTS_DIR"
ACCESS_FILE="$SWARM_ACCT_ACCESS_FILE"
TOKEN_VAR="$SWARM_ACCT_TOKEN_VAR"
PLUGINS_DIR="$CONFIG_DIR/plugins"
KNOWN_MKT="$PLUGINS_DIR/known_marketplaces.json"
INSTALLED="$PLUGINS_DIR/installed_plugins.json"
BRIDGE_DIR="$SWARM_HOME/bridge"

# Channel set for the symmetric access.json: every data row's field-4 (channel).
CHANNELS="$(awk -F'|' '
  /^[[:space:]]*(#|$)/ { next }
  { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); if ($4 != "") print $4 }
' "$CONF" | sort -u)"

echo "=== $PROG: account '$LABEL' ==="
echo "  config dir : $CONFIG_DIR"
echo "  token var  : \$$TOKEN_VAR   (operator-provided; NOT read or written here)"
echo "  marketplace: qofi-swarm (directory → $SWARM_HOME)  plugin: discord-b2b"
echo "  access.json: $ACCESS_FILE   (symmetric, $(printf '%s\n' "$CHANNELS" | grep -c . ) channel group(s))"
echo ""

if [ "$DRY" -eq 1 ]; then
  echo "  --dry-run: would create/ensure:"
  echo "    mkdir -p $CONFIG_DIR $PROJECTS_DIR $PLUGINS_DIR $(dirname "$ACCESS_FILE")"
  echo "    write $KNOWN_MKT (register qofi-swarm marketplace)"
  echo "    write $INSTALLED (record discord-b2b@qofi-swarm)"
  echo "    write $ACCESS_FILE (symmetric groups for: $(printf '%s ' $CHANNELS))"
  echo "  (no files touched, no token read/written)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) Directory skeleton.
# ---------------------------------------------------------------------------
( umask 077; mkdir -p "$PROJECTS_DIR" "$PLUGINS_DIR" "$(dirname "$ACCESS_FILE")" ) \
  || { echo "$PROG: FATAL — could not create the config-dir skeleton under $CONFIG_DIR" >&2; exit 3; }
log "config-dir skeleton ensured: $CONFIG_DIR"

# ---------------------------------------------------------------------------
# 2) Marketplace registration (idempotent merge — preserve any other marketplaces).
# ---------------------------------------------------------------------------
python3 - "$KNOWN_MKT" "$SWARM_HOME" <<'PY' || { echo "$PROG: FATAL — could not write known_marketplaces.json" >&2; exit 3; }
import json, os, sys
path, home = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data["qofi-swarm"] = {
    "source": {"source": "directory", "path": home},
    "installLocation": home,
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os.replace(tmp, path)
json.load(open(path))  # validate
print("  registered marketplace qofi-swarm -> " + home)
PY

# ---------------------------------------------------------------------------
# 3) Plugin install record (idempotent — discord-b2b@qofi-swarm, user scope, loaded
#    from the directory source $SWARM_HOME/bridge). Preserves other plugins.
# ---------------------------------------------------------------------------
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","0.1.0"))' "$BRIDGE_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo 0.1.0)"
python3 - "$INSTALLED" "$BRIDGE_DIR" "$PLUGIN_VERSION" <<'PY' || { echo "$PROG: FATAL — could not write installed_plugins.json" >&2; exit 3; }
import json, os, sys
path, bridge, version = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"version": 2, "plugins": {}}
if os.path.exists(path):
    try:
        cur = json.load(open(path))
        if isinstance(cur, dict):
            data = cur; data.setdefault("version", 2); data.setdefault("plugins", {})
    except Exception:
        pass
data["plugins"]["discord-b2b@qofi-swarm"] = [{
    "scope": "user",
    "installPath": bridge,
    "version": version,
}]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os.replace(tmp, path)
json.load(open(path))  # validate
print("  recorded plugin discord-b2b@qofi-swarm (user scope) <- " + bridge)
PY

# ---------------------------------------------------------------------------
# 4) Symmetric access.json — a group for EVERY swarm.conf channel, identical set
#    across accounts. allowFrom = [owner, cto-watcher]. Idempotent: rebuild the
#    group superset, preserve any existing top-level keys/pending.
# ---------------------------------------------------------------------------
CHANNELS_CSV="$(printf '%s' "$CHANNELS" | tr '\n' ',' | sed 's/,$//')"
/usr/bin/python3 -I -B - "$ACCESS_FILE" "$OWNER_ID" "$WATCHER_ID" "$CHANNELS_CSV" <<'PY' || { echo "$PROG: FATAL — could not write access.json" >&2; exit 3; }
import json, os, stat, sys, tempfile
path, owner, watcher, channels_csv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
channels = [c for c in channels_csv.split(",") if c]
cfg = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}
if os.path.lexists(path):
    st=os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != os.getuid()):
        raise SystemExit('unsafe access.json owner/type')
    try:
        cur = json.load(open(path))
        if isinstance(cur, dict): cfg = cur
    except Exception:
        pass
cfg.setdefault("dmPolicy", "pairing")
top=cfg.setdefault("allowFrom", [])
if not isinstance(top,list): raise SystemExit('top-level allowFrom must be a list')
if owner not in top: top.append(owner)
cfg["loginControlOwnerId"] = owner
cfg.setdefault("groups", {})
cfg.setdefault("pending", {})
allow = [owner]
if watcher and watcher not in allow: allow.append(watcher)
for ch in channels:
    cfg["groups"][ch] = {"requireMention": False, "allowFrom": list(allow)}
fd,tmp=tempfile.mkstemp(prefix='.access.json.',dir=os.path.dirname(path) or '.')
try:
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
json.load(open(path))  # validate
print("  symmetric access.json: {} group(s), allowFrom=[owner{}]".format(
    len(channels), "+watcher" if watcher else ""))
PY

# ---------------------------------------------------------------------------
# 5) The operator's remaining MANUAL steps (the floor this script never crosses).
# ---------------------------------------------------------------------------
LABEL_UPPER="$(printf '%s' "$LABEL" | tr 'a-z-' 'A-Z_')"
cat <<EOF

=== SKELETON READY for '$LABEL'. Remaining steps are OPERATOR-ONLY: ===

  1. Provision the credential (in-browser, terms-cleared):
         CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude setup-token
     This authenticates THIS account into its own isolated config dir. Running
     more than one real Max subscription in concurrent automation is the
     terms-relevant act ADR-0018 gates — your call, not the build's.

  2. Add the token to the vault ($SWARM_HOME/tokens.env), by NAME:
         export $TOKEN_VAR='<the token from step 1>'
     (Var name is OAUTH_TOKEN_<LABEL_UPPER> = \$$TOKEN_VAR. Labels must be unique
     after the '-'/'_' fold; '$LABEL' folds to $LABEL_UPPER.)

  3. Run the preflight check, then RATIFY + apply the label assignment:
         bin/swarm-account-preflight.sh
         # edit swarm.conf field-6 ACCOUNT to '$LABEL' for the chosen swarm(s)
         bin/swarm-restart.sh <name>        # restart each labeled swarm

  4. Confirm independence (read-only canary):
         bin/swarm-account-verify.sh

  See docs/ACTIVATION-RUNBOOK.md for the full ordered runbook.
EOF
exit 0
