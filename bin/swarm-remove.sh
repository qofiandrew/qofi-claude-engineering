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
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

CONF="$SWARM_HOME/swarm.conf"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
# ACCESS (which account's access.json holds this channel's group) is resolved
# from the removed swarm's account — swarm.conf field 6, parsed below from the
# matched row — never a hand-built $HOME/.claude path. An empty account (every
# row today) resolves byte-for-byte to today's path.
PREFIX="swarm"

usage() { echo "usage: swarm-remove.sh <name>" >&2; exit 1; }
NAME="${1:-}"
[ -z "$NAME" ] && usage
[ -f "$CONF" ] || { echo "swarm-remove: $CONF not found" >&2; exit 1; }

# Locate the line.
LINE="$(awk -F'|' -v n="$NAME" '
  /^[[:space:]]*(#|$)/ { next }
  { v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v); if (v == n) { print; exit } }
' "$CONF")"
[ -z "$LINE" ] && { echo "swarm-remove: no swarm named '$NAME' in $CONF" >&2; exit 1; }

# Extract the other fields from the matched line.
REPO="$(echo    "$LINE" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }')"
TOK_VAR="$(echo "$LINE" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }')"
CHANNEL="$(echo "$LINE" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4 }')"
ACCOUNT="$(echo "$LINE" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6 }')"

# Resolve the removed swarm's account → its access.json. The resolver is the
# SOLE constructor of the path: empty account → today's $HOME/.claude/... ,
# a label → that account's isolated dir.
swarm_account_resolve "$ACCOUNT" || {
  echo "swarm-remove: invalid account '$ACCOUNT' in swarm.conf row for '$NAME'" >&2
  exit 1
}
ACCESS="$SWARM_ACCT_ACCESS_FILE"

cat <<EOF
About to remove swarm '$NAME':
  repo:    $REPO
  channel: $CHANNEL
  bot var: \$$TOK_VAR  (will be left in tokens.env)
EOF

# 1) Kill ONLY this swarm's tmux session.
#    (swarm-up.sh down kills ALL swarm sessions -- too broad for a single remove.)
SESS="${PREFIX}-${NAME}"
if tmux has-session -t "$SESS" 2>/dev/null; then
  tmux kill-session -t "$SESS"
  echo "swarm-remove: killed tmux session $SESS"
else
  echo "swarm-remove: tmux session $SESS not running"
fi

# 2) Remove the line from swarm.conf (atomic rewrite, comments preserved).
tmp="$CONF.tmp.$$"
awk -F'|' -v n="$NAME" '
  /^[[:space:]]*(#|$)/ { print; next }
  { saved=$0; v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v); if (v == n) next; print saved }
' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
echo "swarm-remove: removed '$NAME' from swarm.conf"

# 3a) Optional: remove heartbeat state file (prompt; default no).
ID_FILE="$STATE_DIR/heartbeat-$CHANNEL.id"
if [ -f "$ID_FILE" ]; then
  printf "Remove heartbeat state %s ? [y/N] " "$ID_FILE"
  read -r ans
  case "$ans" in
    y|Y) rm -f "$ID_FILE"; echo "swarm-remove: removed $ID_FILE" ;;
    *)   echo "swarm-remove: left $ID_FILE in place" ;;
  esac
fi

# 3b) Optional: remove access.json group (prompt; default no per spec).
if [ -f "$ACCESS" ] && \
   python3 -c "import json,sys; cfg=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in (cfg.get('groups') or {}) else 1)" \
     "$ACCESS" "$CHANNEL" 2>/dev/null; then
  printf "Remove channel %s group from %s ? [y/N] " "$CHANNEL" "$ACCESS"
  read -r ans
  case "$ans" in
    y|Y)
      python3 - "$ACCESS" "$CHANNEL" <<'PY'
import json, os, sys
path, channel = sys.argv[1], sys.argv[2]
with open(path) as f: cfg = json.load(f)
cfg.get("groups", {}).pop(channel, None)
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(cfg, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
      echo "swarm-remove: removed group $CHANNEL from access.json"
      ;;
    *) echo "swarm-remove: left access.json untouched" ;;
  esac
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
