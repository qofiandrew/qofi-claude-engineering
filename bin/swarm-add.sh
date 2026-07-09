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

SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
# Source the lib for swarm_type_is_known (used to validate --type before
# any Discord-side side-effects).
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR_EARLY/swarm-lib.sh"

# Resolve the access.json for the account this swarm is being added with. There
# is no --account flag yet (Phase 2+), so the new swarm gets the DEFAULT account
# — resolve "" → SWARM_ACCT_ACCESS_FILE, which the resolver maps to exactly
# today's $HOME/.claude/channels/discord/access.json (honoring SWARM_ACCESS_FILE
# if set). A labeled account would land in $HOME/.claude-accounts/<label>/...
# instead. This is the SOLE constructor of the path — never hand-built here.
# The rc-check is a no-op today (the literal "" always resolves) but is here so a
# future --account flag that threads a VARIABLE label is fail-safe by default
# (refuse rather than read a stale SWARM_ACCT_ACCESS_FILE) — same discipline as
# the WORKING-rail consumers (ADR-0018, Phase-2 Finding 1).
if ! swarm_account_resolve ""; then
  echo "swarm-add: could not resolve the account's access.json path" >&2
  exit 1
fi
ACCESS="$SWARM_ACCT_ACCESS_FILE"

usage() {
  sed -n '1,50p' "$0"
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
ROTATE_TOKEN=0
SKIP_WALKTHROUGH=0
TYPE=""
PROFILE=""
BOT_USER_ID=""
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
        3) CHANNEL="$1" ;;
        *) echo "swarm-add: too many positional args (got '$1' after name/repo/channel)" >&2; usage 1 ;;
      esac
      shift ;;
  esac
done

[ -z "$NAME" ] && { echo "swarm-add: missing <name>" >&2; usage 1; }
[ -z "$REPO" ] && { echo "swarm-add: missing <repo_path>" >&2; usage 1; }

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
[ -d "$REPO" ] || { echo "swarm-add: repo not found: $REPO" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"
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

# Effective archetype: TYPE may be blank (engineering-cto default). Only
# engineering-cto swarms are CTOs that ride the #cpo-cto-bus, so phase 4e's
# cto-watcher registration is gated on this.
EFFECTIVE_TYPE="${TYPE:-engineering-cto}"

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
echo "  type:      $EFFECTIVE_TYPE"
[ -n "$PROFILE" ] && echo "  profile:   $PROFILE"
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
      read_line BOT_USER_ID "Bot user id: "
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
# swarm.conf — one repo per line:  session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID | GUILD_ID
# session_name: short, no spaces (becomes tmux session "swarm-<name>")
# TOKEN_VAR_NAME: name of the env var in tokens.env holding that repo's bot token
# CHANNEL_ID: Discord channel id this swarm is bound to (used by swarm-watch.sh
#   for the per-channel heartbeat). Required even though swarm-up.sh does not use it.
# GUILD_ID: Discord guild (server) snowflake. Used with CHANNEL_ID by the iOS
#   widget to build discord://channels/<guild>/<channel> deep-links per the
#   frozen swarm-status/v1 contract. Optional (blank → emits null, widget
#   falls back to opening the app); fill it in as soon as you know it.
#
# Keep this list short to start — one or two repos. A single Max pool will not feed
# more than ~1–2 teams running concurrently.

EOF
  echo "  created: $CONF"
fi

if [ "$STATE_CONF_PRESENT" -eq 1 ]; then
  echo "  SKIP swarm.conf append (row for '$NAME' already present)"
else
  # 5-field row. GUILD_ID is left blank — swarm-add doesn't yet prompt for it
  # (a follow-up to this conformance change). The watcher emits null for an
  # empty 5th column, which the swarm-status/v1 receiver tolerates during the
  # transition window. Fill in by hand to unlock iOS-widget deep-links.
  printf '%s | %s | %s | %s | \n' "$NAME" "$REPO" "$TOK_VAR" "$CHANNEL" >> "$CONF"
  echo "  appended: '$NAME' -> swarm.conf  (GUILD_ID left blank — fill in by hand for deep-links)"
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
"$SCRIPT_DIR/swarm-init.sh" "${INIT_ARGS[@]}" | sed 's/^/    /'
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
cfg.setdefault("groups", {})[channel] = {"requireMention": False, "allowFrom": [owner]}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
os.replace(tmp, path)
with open(path) as f: json.load(f)  # validate the file we just wrote
print("  access.json group for channel {} set "
      "(requireMention=false, allowFrom=[{}])".format(channel, owner))
PY

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

# ---------------------------------------------------------------------------
# PHASE 7 — Summary + alias re-source reminder
# ---------------------------------------------------------------------------
phase "Phase 7 — Summary"

if [ "$EFFECTIVE_TYPE" = "engineering-cto" ]; then
  BUS_SUMMARY="    bus:     #cpo-cto-bus via cto-watcher (ctoChannels['$NAME'] = {channel $CHANNEL, bot ${BOT_USER_ID:-<unchanged>}}; watcher id on allowFrom) — restart the watcher to load it"
else
  BUS_SUMMARY="    bus:     n/a ($EFFECTIVE_TYPE is not a CTO)"
fi

cat <<EOF

  Swarm '$NAME' registered.
    repo:    $REPO
    type:    $EFFECTIVE_TYPE${PROFILE:+  (profile: $PROFILE)}
    channel: $CHANNEL
    bot:     \$$TOK_VAR  (token in $TOKENS, chmod 600, gitignored)
    access:  $ACCESS  (group $CHANNEL -> owner $OWNER_ID, mention-gated)
    plugin:  $PLUGIN_KEY enabled in $SETTINGS_FILE
$BUS_SUMMARY

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
