#!/usr/bin/env bash
# swarm-bus-wire.sh — wire (or re-wire) one engineering-cto swarm onto the
# #cpo-cto-bus. Extracted from swarm-add.sh phase 4e so the bus wiring is a
# single shared, independently-runnable, IDEMPOTENT operation (ADR-0015).
#
# A CTO rides the #cpo-cto-bus only once BOTH halves are wired:
#   (1) a ctoChannels entry in cto-watcher/config.json
#       (name -> {channelId, botUserId}), and
#   (2) the cto-watcher bot's id in this channel's access.json allowFrom —
#       the watcher reposts CPO directives AS ITSELF, so the new CTO's bridge
#       silently drops them unless the watcher id is allow-listed.
# Both halves are additive and idempotent: re-running on an already-wired
# swarm is a safe no-op (no duplicate entries, no churn).
#
# Usage:
#   swarm-bus-wire.sh <name> <channel> <bot-user-id>
#
#   <name>          swarm name (the ctoChannels key)
#   <channel>       numeric Discord channel id this swarm lives in
#   <bot-user-id>   numeric Discord BOT USER id (== the app's Application ID)
#                   for this swarm — mentioned by the watcher on delivery.
#                   May be the EMPTY string on a re-run where the bus entry is
#                   already current and no id is on hand: Half 1 (the
#                   ctoChannels write) is then SKIPPED and only Half 2 (the
#                   allowFrom append, which needs no bot id) runs. This mirrors
#                   swarm-add.sh's original phase-4e re-run behavior exactly.
#
# Env overrides (for tests; mirror swarm-add.sh):
#   CTO_WATCHER_CONFIG       path to cto-watcher/config.json
#                            (default: $SWARM_HOME/cto-watcher/config.json)
#   CTO_BUS_WATCHER_BOT_ID   the cto-watcher bot's own user id to allow-list
#                            (default: 1510298728148369448)
#   SWARM_ACCESS_FILE        path to access.json
#                            (default: $HOME/.claude/channels/discord/access.json)
#
# This script ONLY wires the bus. It does not stamp doctrine, capture tokens,
# or write swarm.conf — swarm-add.sh owns the rest of standup and calls this
# for phase 4e. Restarting the cto-watcher so it loads the new ctoChannels
# entry remains an operator-manual step (printed at the end).
#
# Exit: 0 on success (wired or already-wired), 2 on a write/parse failure.

set -euo pipefail

usage() {
  sed -n '1,40p' "$0"
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

if [ "$#" -ne 3 ]; then
  echo "swarm-bus-wire: expected 3 args (<name> <channel> <bot-user-id>), got $#" >&2
  usage 1
fi

NAME="$1"
CHANNEL="$2"
BOT_USER_ID="$3"

# Argument validation — fail fast on malformed input at the contract surface.
# bot-user-id may be EMPTY (re-run where the ctoChannels entry is already
# current and no id is on hand); an empty id skips Half 1 only. A NON-empty id
# must be numeric.
echo "$NAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$' || {
  echo "swarm-bus-wire: name must match [a-zA-Z][a-zA-Z0-9_-]* (got: $NAME)" >&2; exit 1; }
echo "$CHANNEL" | grep -qE '^[0-9]+$' || {
  echo "swarm-bus-wire: channel must be numeric (got: $CHANNEL)" >&2; exit 1; }
if [ -n "$BOT_USER_ID" ]; then
  echo "$BOT_USER_ID" | grep -qE '^[0-9]+$' || {
    echo "swarm-bus-wire: bot-user-id must be numeric when given (got: $BOT_USER_ID)" >&2; exit 1; }
fi

# Paths. CTO_WATCHER_CONFIG / CTO_BUS_WATCHER_BOT_ID default off SWARM_HOME but
# are overridable for tests; access.json defaults under $HOME but is overridable
# via SWARM_ACCESS_FILE. We require SWARM_HOME only when a path isn't overridden.
if [ -z "${CTO_WATCHER_CONFIG:-}" ] || [ -z "${SWARM_ACCESS_FILE:-}" ]; then
  if [ -z "${SWARM_HOME:-}" ]; then
    echo "swarm-bus-wire: SWARM_HOME unset — export SWARM_HOME, or set CTO_WATCHER_CONFIG and SWARM_ACCESS_FILE explicitly" >&2
    exit 1
  fi
fi
CTO_WATCHER_CONFIG="${CTO_WATCHER_CONFIG:-$SWARM_HOME/cto-watcher/config.json}"
CTO_BUS_WATCHER_BOT_ID="${CTO_BUS_WATCHER_BOT_ID:-1510298728148369448}"
ACCESS="${SWARM_ACCESS_FILE:-$HOME/.claude/channels/discord/access.json}"

echo "  cto-watcher bus wiring for CTO '$NAME' (channel $CHANNEL, bot ${BOT_USER_ID:-<none on hand>})"

# ---------------------------------------------------------------------------
# Half 1 — ctoChannels entry in the watcher's config.json.
#
# Additive + idempotent: an entry already equal to the desired value is
# reported "already current" and rewrites nothing material. config.json is the
# routing AUTHORITY (ADR-0014) — we write/read it directly and never consult a
# roster table. Skipped when no bot id is on hand (re-run: entry already
# current) or when the config file doesn't exist.
# ---------------------------------------------------------------------------
if [ ! -f "$CTO_WATCHER_CONFIG" ]; then
  echo "  WARN: $CTO_WATCHER_CONFIG not found — skipping ctoChannels write." >&2
  echo "        Create it (cp cto-watcher/config.example.json cto-watcher/config.json)," >&2
  echo "        then re-run: bin/swarm-bus-wire.sh $NAME $CHANNEL <bot-user-id>" >&2
elif [ -z "$BOT_USER_ID" ]; then
  echo "  SKIP ctoChannels write: no bot user id on hand (bus already registered, or none supplied)."
else
  python3 - "$CTO_WATCHER_CONFIG" "$NAME" "$CHANNEL" "$BOT_USER_ID" <<'PY' || { echo "swarm-bus-wire: FATAL — failed to update cto-watcher config.json" >&2; exit 2; }
import json, os, sys
path, name, channel, bot = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f: cfg = json.load(f)
ctos = cfg.setdefault("ctoChannels", {})
prev = ctos.get(name)
desired = {"channelId": channel, "botUserId": bot}
if prev == desired:
    print("  ctoChannels['{}'] already current (channelId={}, botUserId={})".format(name, channel, bot))
else:
    ctos[name] = desired
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    os.replace(tmp, path)
    with open(path) as f: json.load(f)  # validate the file we just wrote
    verb = "updated" if prev is not None else "set"
    print("  ctoChannels['{}'] {} (channelId={}, botUserId={})".format(name, verb, channel, bot))
PY
fi

# ---------------------------------------------------------------------------
# Half 2 — watcher bot id in this channel's access.json allowFrom (additive).
#
# The watcher reposts CPO directives as itself; the new CTO's bridge drops
# them unless the watcher id is allow-listed. Append-once: if already present,
# no write happens (idempotent no-op).
# ---------------------------------------------------------------------------
if [ ! -f "$ACCESS" ]; then
  echo "  WARN: $ACCESS not found — skipping allowFrom write." >&2
  echo "        swarm-add phase 4d creates it; run swarm-add first, or create it by hand." >&2
else
  python3 - "$ACCESS" "$CHANNEL" "$CTO_BUS_WATCHER_BOT_ID" <<'PY' || { echo "swarm-bus-wire: FATAL — failed to add watcher id to access.json allowFrom" >&2; exit 2; }
import json, os, sys
path, channel, watcher = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: cfg = json.load(f)
grp = cfg.setdefault("groups", {}).setdefault(channel, {"requireMention": False, "allowFrom": []})
af = grp.setdefault("allowFrom", [])
if watcher in af:
    print("  access.json: watcher id {} already in allowFrom for channel {}".format(watcher, channel))
else:
    af.append(watcher)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    os.replace(tmp, path)
    with open(path) as f: json.load(f)  # validate
    print("  access.json: added watcher id {} to allowFrom for channel {}".format(watcher, channel))
PY
fi

echo "  REMINDER: restart the cto-watcher so it loads the new ctoChannels entry"
echo "            (watcher-control skill / bin/cto-watch-*.sh) — operator-manual."
