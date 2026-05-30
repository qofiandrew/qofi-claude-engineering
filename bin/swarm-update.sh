#!/usr/bin/env bash
# swarm-update.sh — pull latest templates AND restart, for ONE swarm (or --all).
#
# Usage:
#   swarm-update.sh <name> [--force]
#   swarm-update.sh --all  [--force]
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
# If sync fails (non-zero), update ABORTS BEFORE restart for that swarm.
# The running session keeps operating on its current in-memory doctrine —
# better than landing partway through a half-synced upgrade.
#
# --all walks every swarm in swarm.conf. It is RESILIENT, not atomic: a
# failure on one swarm (sync error, or a restart refused because the swarm
# is busy and --force was not given) is recorded and the run continues to
# the next swarm. The script exits non-zero if ANY swarm failed, and prints
# a per-swarm summary at the end. --all and <name> are mutually exclusive.
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
  sed -n '1,34p' "$0"
  exit "${1:-0}"
}

NAME=""
FORCE=0
ALL=0
for arg in "$@"; do
  case "$arg" in
    --all)      ALL=1 ;;
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

if [ "$ALL" -eq 1 ] && [ -n "$NAME" ]; then
  echo "swarm-update: --all and <name> ('$NAME') are mutually exclusive" >&2
  usage 1
fi
if [ "$ALL" -eq 0 ] && [ -z "$NAME" ]; then
  echo "swarm-update: missing <name> (or pass --all)" >&2
  usage 1
fi

# List of configured swarm names, one per line.
list_swarm_names() {
  grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }'
}

# update_one <name> — sync then restart a single swarm.
# Returns 0 on success, non-zero if sync or restart failed.
update_one() {
  _name="$1"

  # -------------------------------------------------------------------------
  # Step 1 — sync.
  #
  # NOTE on the `rc` capture pattern: we run sync, then read $? on the next
  # line — NOT inside `if ! cmd; then rc=$?`, which would capture the `!`
  # operator's exit status (always 0 in the failure branch) instead of the
  # original command's. T9 in the verification suite caught that.
  # -------------------------------------------------------------------------
  echo "===================================================================="
  echo "swarm-update: [$_name] step 1/2 — swarm-sync.sh $_name"
  echo "===================================================================="
  "$SWARM_SYNC" "$_name"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "swarm-update: [$_name] ABORT — swarm-sync.sh failed (rc=$rc). The" >&2
    echo "running session is unchanged. Resolve the sync failure (likely a" >&2
    echo "dirty working tree in the target repo, or a manifest/template" >&2
    echo "issue), then re-run swarm-update.sh $_name." >&2
    return "$rc"
  fi

  # -------------------------------------------------------------------------
  # Step 2 — restart (re-checks activity itself, may refuse without --force).
  # -------------------------------------------------------------------------
  echo ""
  echo "===================================================================="
  echo "swarm-update: [$_name] step 2/2 — swarm-restart.sh $_name"
  echo "===================================================================="
  if [ "$FORCE" -eq 1 ]; then
    "$SWARM_RESTART" "$_name" --force
  else
    "$SWARM_RESTART" "$_name"
  fi
  return $?
}

# ---------------------------------------------------------------------------
# --all: walk every swarm, resilient. Record failures, exit non-zero if any.
# ---------------------------------------------------------------------------
if [ "$ALL" -eq 1 ]; then
  names="$(list_swarm_names)"
  if [ -z "$names" ]; then
    echo "swarm-update: --all found no swarms in $CONF" >&2
    exit 1
  fi

  ok_list=""
  fail_list=""
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if update_one "$n"; then
      ok_list="$ok_list $n"
    else
      fail_list="$fail_list $n"
    fi
    echo ""
  done <<EOF
$names
EOF

  echo "===================================================================="
  echo "swarm-update: --all summary"
  echo "===================================================================="
  [ -n "$ok_list" ]   && echo "  updated:$ok_list"
  [ -n "$fail_list" ] && echo "  FAILED: $fail_list" >&2
  if [ -n "$fail_list" ]; then
    echo "" >&2
    echo "swarm-update: one or more swarms failed (see above)." >&2
    exit 1
  fi
  echo "  all swarms updated."
  exit 0
fi

# ---------------------------------------------------------------------------
# Single swarm: validate the name, then update it. Exit code propagates.
# ---------------------------------------------------------------------------
if ! list_swarm_names | grep -qxF "$NAME"; then
  {
    echo "swarm-update: no swarm named '$NAME' in $CONF"
    echo "configured swarms:"
    list_swarm_names | sed 's/^/  /'
  } >&2
  exit 1
fi

update_one "$NAME"
exit $?
