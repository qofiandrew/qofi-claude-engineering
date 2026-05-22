#!/usr/bin/env bash
# swarm-update.sh — pull latest templates AND restart, for ONE swarm.
#
# Usage:
#   swarm-update.sh <name> [--force]
#
# The "make this swarm fully current with templates" command:
#   swarm-sync.sh    <name>       # write latest manifest to disk + commit
#   swarm-restart.sh <name>       # reload the live session from disk
#
# Bundles sync + restart so an operator can't sync-and-forget-restart
# (the SYNC ≠ LIVE reminder in swarm-sync.sh exists because the running
# lead has the OLD doctrine/hooks in memory until the session is cycled).
#
# Safety rail: same as swarm-restart.sh. The activity check runs TWICE —
# once up front (refuse to start an update against a swarm that's
# working, unless --force), and then again inside swarm-restart.sh after
# sync (sync took time; status may have changed). --force passes through
# to the restart step.
#
# If sync fails (non-zero), update ABORTS BEFORE restart. The running
# session keeps operating on its current in-memory doctrine — better
# than landing partway through a half-synced upgrade.
#
# Bash 3.2-safe.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-update: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_SYNC="${SWARM_SYNC_BIN:-$SCRIPT_DIR/swarm-sync.sh}"
SWARM_RESTART="${SWARM_RESTART_BIN:-$SCRIPT_DIR/swarm-restart.sh}"

usage() {
  sed -n '1,28p' "$0"
  exit "${1:-0}"
}

NAME=""
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    -h|--help)  usage 0 ;;
    --*)        echo "swarm-update: unknown flag: $arg" >&2; usage 1 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$arg"
      else echo "swarm-update: too many positional args ('$NAME' and '$arg')" >&2; usage 1
      fi
      ;;
  esac
done
[ -z "$NAME" ] && { echo "swarm-update: missing <name>" >&2; usage 1; }

# Validate name (reuse the conf-listing logic locally so we can fail fast
# before we shell out to sync/restart).
list_swarm_names() {
  grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }'
}
if ! list_swarm_names | grep -qxF "$NAME"; then
  {
    echo "swarm-update: no swarm named '$NAME' in $CONF"
    echo "configured swarms:"
    list_swarm_names | sed 's/^/  /'
  } >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — sync.
#
# NOTE on the `rc` capture pattern: we run sync, then read $? on the next
# line — NOT inside `if ! cmd; then rc=$?`, which would capture the `!`
# operator's exit status (always 0 in the failure branch) instead of the
# original command's. T9 in the verification suite caught that.
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "swarm-update: step 1/2 — swarm-sync.sh $NAME"
echo "===================================================================="
"$SWARM_SYNC" "$NAME"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "" >&2
  echo "swarm-update: ABORT — swarm-sync.sh failed (rc=$rc). The running" >&2
  echo "session is unchanged. Resolve the sync failure (likely a dirty" >&2
  echo "working tree in the target repo, or a manifest/template issue)," >&2
  echo "then re-run swarm-update.sh $NAME." >&2
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# Step 2 — restart (re-checks activity itself, may refuse without --force).
# ---------------------------------------------------------------------------
echo ""
echo "===================================================================="
echo "swarm-update: step 2/2 — swarm-restart.sh $NAME"
echo "===================================================================="
if [ "$FORCE" -eq 1 ]; then
  "$SWARM_RESTART" "$NAME" --force
else
  "$SWARM_RESTART" "$NAME"
fi
