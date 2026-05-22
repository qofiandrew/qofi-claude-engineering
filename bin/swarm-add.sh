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
ACCESS="$HOME/.claude/channels/discord/access.json"
PLUGIN_KEY="discord-b2b@qofi-swarm"

usage() {
  sed -n '1,35p' "$0"
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing — positional [name [repo [channel]]] + flags in any order.
# ---------------------------------------------------------------------------
NAME=""
REPO=""
CHANNEL=""
ROTATE_TOKEN=0
SKIP_WALKTHROUGH=0
POS_COUNT=0

for arg in "$@"; do
  case "$arg" in
    --rotate-token)     ROTATE_TOKEN=1 ;;
    --skip-walkthrough) SKIP_WALKTHROUGH=1 ;;
    -h|--help)          usage 0 ;;
    --*)                echo "swarm-add: unknown flag: $arg" >&2; usage 1 ;;
    *)
      POS_COUNT=$((POS_COUNT + 1))
      case "$POS_COUNT" in
        1) NAME="$arg" ;;
        2) REPO="$arg" ;;
        3) CHANNEL="$arg" ;;
        *) echo "swarm-add: too many positional args (got '$arg' after name/repo/channel)" >&2; usage 1 ;;
      esac
      ;;
  esac
done

[ -z "$NAME" ] && { echo "swarm-add: missing <name>" >&2; usage 1; }
[ -z "$REPO" ] && { echo "swarm-add: missing <repo_path>" >&2; usage 1; }

# Name + repo validation.
echo "$NAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$' || {
  echo "swarm-add: name must match [a-zA-Z][a-zA-Z0-9_-]* (got: $NAME)" >&2; exit 1; }
[ -d "$REPO" ] || { echo "swarm-add: repo not found: $REPO" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"

# Channel validation if given up front.
if [ -n "$CHANNEL" ]; then
  echo "$CHANNEL" | grep -qE '^[0-9]+$' || {
    echo "swarm-add: channel_id must be numeric (got: $CHANNEL)" >&2; exit 1; }
fi

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
    IFS= read -r val </dev/tty
  else
    printf '%s' "$prompt"
    IFS= read -r val
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
phase "Phase 0 — preflight"

echo "  name:      $NAME"
echo "  repo:      $REPO"
echo "  channel:   ${CHANNEL:-(will prompt in phase 2)}"
echo "  token var: \$$TOK_VAR (in $TOKENS)"

STATE_TOKEN_PRESENT=0
STATE_CONF_PRESENT=0
STATE_REPO_STAMPED=0
STATE_ACCESS_GROUP_PRESENT=0

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

echo ""
echo "  detected existing state:"
[ "$STATE_TOKEN_PRESENT"        -eq 1 ] && echo "    + token in tokens.env             (phase 3 will SKIP unless --rotate-token)"
[ "$STATE_CONF_PRESENT"         -eq 1 ] && echo "    + swarm.conf row already present  (phase 4 will SKIP the conf append)"
[ "$STATE_REPO_STAMPED"         -eq 1 ] && echo "    + repo already stamped            (phase 4's swarm-init becomes a no-op)"
[ "$STATE_ACCESS_GROUP_PRESENT" -eq 1 ] && echo "    + access.json group for channel   (phase 4 will overwrite-as-no-op)"
if [ "$STATE_TOKEN_PRESENT" -eq 0 ] && [ "$STATE_CONF_PRESENT" -eq 0 ] && \
   [ "$STATE_REPO_STAMPED" -eq 0 ] && [ "$STATE_ACCESS_GROUP_PRESENT" -eq 0 ]; then
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
   3. Name it  "swarm-$NAME"        (convention; mirrors tmux session name)
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

fi  # /SKIP_WALKTHROUGH

# ---------------------------------------------------------------------------
# PHASE 2 — Channel ID (skip if already provided)
# ---------------------------------------------------------------------------
if [ -n "$CHANNEL" ]; then
  phase "Phase 2 — Channel ID  [PROVIDED on CLI: $CHANNEL]"
else
  phase "Phase 2 — Channel ID"

cat <<'EOF'

You need the Discord channel ID this swarm will live in (the bot's home
channel; required even though swarm-up.sh itself doesn't read it — the
heartbeat watcher does, and access.json keys on channel ID).

  1. In Discord:  User Settings (cog icon) -> "Advanced" -> enable
        "Developer Mode"
  2. Right-click the target channel in the server (or use the "..."
     menu on its row).
  3. Click  "Copy Channel ID".

Now paste it here.
EOF
  while [ -z "$CHANNEL" ]; do
    read_line CHANNEL "Channel ID: "
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
if [ ! -e "$CONF" ]; then
  cat > "$CONF" <<'EOF'
# swarm.conf — one repo per line:  session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID
# session_name: short, no spaces (becomes tmux session "swarm-<name>")
# TOKEN_VAR_NAME: name of the env var in tokens.env holding that repo's bot token
# CHANNEL_ID: Discord channel id this swarm is bound to (used by swarm-watch.sh
#   for the per-channel heartbeat). Required even though swarm-up.sh does not use it.
#
# Keep this list short to start — one or two repos. A single Max pool will not feed
# more than ~1–2 teams running concurrently.

EOF
  echo "  created: $CONF"
fi

if [ "$STATE_CONF_PRESENT" -eq 1 ]; then
  echo "  SKIP swarm.conf append (row for '$NAME' already present)"
else
  printf '%s | %s | %s | %s\n' "$NAME" "$REPO" "$TOK_VAR" "$CHANNEL" >> "$CONF"
  echo "  appended: '$NAME' -> swarm.conf"
fi

# 4c) swarm-init (already idempotent via manifest) ------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo ""
echo "  running swarm-init.sh against $REPO"
echo "  ----------------------------------------------------------------"
"$SCRIPT_DIR/swarm-init.sh" "$REPO" | sed 's/^/    /'
INIT_RC=${PIPESTATUS[0]}
echo "  ----------------------------------------------------------------"
if [ "$INIT_RC" -ne 0 ]; then
  echo "swarm-add: FATAL — swarm-init.sh failed (rc=$INIT_RC). Resolve and re-run." >&2
  exit 2
fi

# 4d) access.json ----------------------------------------------------------
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
  echo "  created: $ACCESS"
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
print("  access.json group for channel {} set "
      "(requireMention=true, allowFrom=[{}])".format(channel, owner))
PY

# ---------------------------------------------------------------------------
# PHASE 5 — Post-init verification (the reserve-backend-2 trap)
#
# The lead launches `claude --dangerously-load-development-channels
# plugin:discord-b2b@qofi-swarm`, but the bridge MCP only spawns if the
# repo's .claude/settings.json has enabledPlugins["discord-b2b@qofi-swarm"]
# set to TRUE. If that key is missing or false, the lead comes up with no
# Discord tools — silent failure mode. Verify (and repair) here.
# ---------------------------------------------------------------------------
phase "Phase 5 — verify enabledPlugins[\"$PLUGIN_KEY\"] === true"

SETTINGS_FILE="$REPO/.claude/settings.json"
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
  read_line REPAIR_ANS "Repair now? [Y/n]: "
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

# ---------------------------------------------------------------------------
# PHASE 6 — Verification checklist (printed; operator runs it)
# ---------------------------------------------------------------------------
phase "Phase 6 — Verification checklist"

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
       - The initial brief lands (Read TEAM_LEAD.md / CLAUDE.md / ...)
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

# ---------------------------------------------------------------------------
# PHASE 7 — Summary + alias re-source reminder
# ---------------------------------------------------------------------------
phase "Phase 7 — Summary"

cat <<EOF

  Swarm '$NAME' registered.
    repo:    $REPO
    channel: $CHANNEL
    bot:     \$$TOK_VAR  (token in $TOKENS, chmod 600, gitignored)
    access:  $ACCESS  (group $CHANNEL -> owner $OWNER_ID, mention-gated)
    plugin:  $PLUGIN_KEY enabled in $SETTINGS_FILE

  A per-swarm shell alias 'swarm-$NAME' is now generated by
  bin/swarm-aliases.sh from swarm.conf, but it isn't live in this shell
  yet. Pick up the new alias with:

       source ~/.zshrc        # (or open a new terminal)

  Then:
       swarm-$NAME            # attach-or-launch this swarm

  The launchd watcher (com.qofi.swarm-watch) picks the new conf row up
  on its next fire — nothing else to wire.

  swarm-add does NOT auto-launch. When you're ready, run the steps in
  phase 6's checklist above to bring it up and confirm.

EOF
