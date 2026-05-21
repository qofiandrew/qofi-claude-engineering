#!/usr/bin/env bash
# swarm-add.sh — register a new swarm (repo + Discord channel + dedicated bot).
#
# Usage: swarm-add.sh <name> <repo_path> <channel_id>
#
# A Discord bot token can hold only one gateway connection, so every swarm
# needs its own bot. This script walks the operator through the manual bot-
# creation step, then writes the local config (tokens.env, swarm.conf,
# .claude/, access.json) so `swarm-up.sh up` brings the swarm online.
#
# Does NOT launch the swarm. Run `swarm-up.sh up` when ready.

set -euo pipefail

SWARM_HOME="${SWARM_HOME:-$HOME/claude-swarm}"
TOKENS="$SWARM_HOME/tokens.env"
CONF="$SWARM_HOME/swarm.conf"
OWNER_ID="${SWARM_OWNER_DISCORD_ID:-1507069153335443608}"
ACCESS="$HOME/.claude/channels/discord/access.json"

usage() { echo "usage: swarm-add.sh <name> <repo_path> <channel_id>" >&2; exit 1; }

NAME="${1:-}"; REPO="${2:-}"; CHANNEL="${3:-}"
{ [ -z "$NAME" ] || [ -z "$REPO" ] || [ -z "$CHANNEL" ]; } && usage

# --- validate ---------------------------------------------------------------
echo "$NAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$' || {
  echo "swarm-add: name must match [a-zA-Z][a-zA-Z0-9_-]* (got: $NAME)" >&2; exit 1; }
echo "$CHANNEL" | grep -qE '^[0-9]+$' || {
  echo "swarm-add: channel_id must be numeric (got: $CHANNEL)" >&2; exit 1; }
[ -d "$REPO" ] || { echo "swarm-add: repo not found: $REPO" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"

# Refuse duplicate.
if [ -f "$CONF" ] && grep -qE "^[[:space:]]*${NAME}[[:space:]]*\|" "$CONF"; then
  echo "swarm-add: a swarm named '$NAME' already exists in $CONF" >&2; exit 1
fi

TOK_VAR="BOT_$(echo "$NAME" | tr '[:lower:]-' '[:upper:]_')"

# --- 1) manual bot-creation checklist ---------------------------------------
cat <<EOF
====================================================================
Manual step: create the Discord bot for swarm '$NAME'.

  1. Open https://discord.com/developers/applications
  2. New Application — name it "swarm-$NAME".
  3. Sidebar -> Bot -> "Reset Token" -> copy the token NOW (Discord will not
     show it again).
  4. Same Bot page -> enable "Message Content Intent".
  5. Sidebar -> OAuth2 -> URL Generator. Scopes: 'bot'.
     Bot Permissions: 'Send Messages' (+ 'Read Message History' if desired).
     Open the generated URL and invite the bot to your server.
  6. Confirm the bot appears in the server member list.

When the bot token is on your clipboard, press Enter to continue.
====================================================================
EOF
read -r _

# --- 2) silent token read + write to chmod-600 tokens.env -------------------
printf 'Paste bot token (input hidden): '
IFS= read -r -s TOKEN
printf '\n'
[ -z "$TOKEN" ] && { echo "swarm-add: token was empty -- aborting." >&2; exit 1; }
# Catch obvious paste errors without echoing the value.
echo "$TOKEN" | grep -qE '^[A-Za-z0-9._-]{40,}$' || {
  echo "swarm-add: token does not look like a Discord bot token (length/chars) -- aborting." >&2
  unset TOKEN; exit 1; }

# Create tokens.env with mode 600 if absent.
if [ ! -e "$TOKENS" ]; then
  ( umask 077; : > "$TOKENS" )
  echo "swarm-add: created $TOKENS (mode 600)"
fi
chmod 600 "$TOKENS"
# If tokens.env doesn't already end in a newline, add one before appending so
# our 'export FOO="..."' line doesn't get concatenated onto the previous one
# (which would corrupt the previous variable's value AND lose our new one).
if [ -s "$TOKENS" ] && [ "$(tail -c 1 "$TOKENS" | od -An -tu1 | tr -d ' ')" != "10" ]; then
  printf '\n' >> "$TOKENS"
fi
printf 'export %s="%s"\n' "$TOK_VAR" "$TOKEN" >> "$TOKENS"
unset TOKEN
echo "swarm-add: appended $TOK_VAR to tokens.env"

# Gitignore check -- FAIL LOUDLY if tokens.env is not ignored.
if ! git -C "$SWARM_HOME" check-ignore -q tokens.env 2>/dev/null; then
  cat >&2 <<EOF
swarm-add: FATAL -- tokens.env is NOT gitignored in $SWARM_HOME.
Add 'tokens.env' to $SWARM_HOME/.gitignore and re-run, or remove the
'export $TOK_VAR=' line you just appended to $TOKENS by hand.
EOF
  exit 2
fi
echo "swarm-add: confirmed tokens.env is gitignored"

# --- 3) append line to swarm.conf -------------------------------------------
if [ ! -e "$CONF" ]; then
  cat > "$CONF" <<'EOF'
# swarm.conf -- one repo per line:  session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID
# session_name: short, no spaces (becomes tmux session "swarm-<name>")
# TOKEN_VAR_NAME: name of the env var in tokens.env holding that repo's bot token
# CHANNEL_ID: Discord channel id this swarm is bound to (used by swarm-watch.sh
#   for the per-channel heartbeat). Required even though swarm-up.sh does not use it.
#
# Keep this list short to start -- one or two repos. A single Max pool will not feed
# more than ~1-2 teams running concurrently.

EOF
  echo "swarm-add: created $CONF"
fi
printf '%s | %s | %s | %s\n' "$NAME" "$REPO" "$TOK_VAR" "$CHANNEL" >> "$CONF"
echo "swarm-add: appended swarm '$NAME' to swarm.conf"

# --- 4) stamp the target repo with operating docs / hooks / settings --------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/swarm-init.sh" "$REPO"

# --- 5) pre-write access.json group so the owner is allowed immediately -----
mkdir -p "$(dirname "$ACCESS")"
if [ ! -e "$ACCESS" ]; then
  cat > "$ACCESS" <<EOF
{
  "dmPolicy": "pairing",
  "allowFrom": ["$OWNER_ID"],
  "groups": {},
  "pending": {}
}
EOF
  echo "swarm-add: created $ACCESS"
fi
python3 - "$ACCESS" "$CHANNEL" "$OWNER_ID" <<'PY'
import json, os, sys
path, channel, owner = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: cfg = json.load(f)
cfg.setdefault("groups", {})[channel] = {"requireMention": True, "allowFrom": [owner]}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
os.replace(tmp, path)
with open(path) as f: json.load(f)  # validate the file we just wrote
print("swarm-add: access.json group for channel {} set "
      "(requireMention=true, allowFrom=[{}])".format(channel, owner))
PY

# --- 6) summary --------------------------------------------------------------
cat <<EOF

----------------------------------------------------------------------
Swarm '$NAME' registered.
  repo:    $REPO
  channel: $CHANNEL
  bot:     \$$TOK_VAR  (token in $TOKENS)
  access:  $ACCESS  (group $CHANNEL -> owner $OWNER_ID, mention-gated)

The watcher (launchd com.qofi.swarm-watch) picks this up on its next fire
-- no further config needed.

To bring it up (operator runs this -- swarm-add does NOT auto-launch):
    bin/swarm-up.sh up
----------------------------------------------------------------------
EOF
