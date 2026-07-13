#!/usr/bin/env bash
# swarm-restart.sh — cycle ONE swarm: down then up.
#
# Usage:
#   swarm-restart.sh <name> [--force]
#
# What it does:
#   swarm-up.sh down <name>      # kill only this swarm's tmux session
#   swarm-up.sh up   <name>      # relaunch from the current on-disk state
#
# What it does NOT do:
#   Sync from templates. This is "reload session from disk" only. To pull
#   the latest templates into the repo AND restart the session in one step,
#   use swarm-update.sh instead.
#
# Safety rail (the WORKING check):
#   Before tearing down, query the shared liveness signal (repo_activity
#   in swarm-lib.sh — the same signal swarm-watch.sh uses for the
#   heartbeat). If the swarm has produced a transcript write within
#   ${SWARM_STALE_SECONDS:-300} seconds, it is currently WORKING and
#   restart will lose any uncommitted in-process teammate work. In that
#   case the script REFUSES unless --force is given. Flag-driven, no
#   interactive prompts.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-restart: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so swarm-update.sh can substitute a stub in tests.
SWARM_UP="${SWARM_UP_BIN:-$SCRIPT_DIR/swarm-up.sh}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
# The projects dir is resolved from THIS swarm's account (field 6) below, after
# we know NAME's conf row — not from a global. swarm_account_resolve maps the
# account label to its projects dir; the empty (default) account resolves to
# ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}, byte-identical to the value
# this script used before the multi-account partition.
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"

# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

usage() {
  sed -n '1,28p' "$0"
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
NAME=""
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    -h|--help)  usage 0 ;;
    --*)        echo "swarm-restart: unknown flag: $arg" >&2; usage 1 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$arg"
      else echo "swarm-restart: too many positional args ('$NAME' and '$arg')" >&2; usage 1
      fi
      ;;
  esac
done
[ -z "$NAME" ] && { echo "swarm-restart: missing <name>" >&2; usage 1; }

# ---------------------------------------------------------------------------
# Resolve exactly one valid <name> row from swarm.conf.
# ---------------------------------------------------------------------------
list_swarm_names() {
  grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1 }'
}

# Do not validate the name with raw awk and then silently retain the historical
# ENGINE=claude initializer when the canonical parser rejects field 7. That
# shape can stop a live session and only then discover that `up` cannot launch
# the malformed row. Count raw matching names (so a rejected duplicate cannot
# disappear), but derive every lifecycle field only from the canonical parser.
REPO=""
ACCOUNT=""
ENGINE=""
FOUND=0
ROW_INVALID=0
while IFS= read -r _line || [ -n "$_line" ]; do
  _trimmed="$(_swarm_trim "$_line")"
  case "$_trimmed" in ''|'#'*) continue ;; esac
  _raw_name="$(_swarm_trim "${_line%%|*}")"
  [ "$_raw_name" = "$NAME" ] || continue
  FOUND=$((FOUND + 1))
  if ! swarm_conf_parse_line "$_line"; then
    ROW_INVALID=1
    continue
  fi
  REPO="$SWARM_CONF_F_REPO"
  ACCOUNT="$SWARM_CONF_F_ACCOUNT"
  ENGINE="$SWARM_CONF_F_ENGINE"
done < "$CONF"

if [ "$FOUND" -eq 0 ]; then
  {
    echo "swarm-restart: no swarm named '$NAME' in $CONF"
    echo "configured swarms:"
    list_swarm_names | sed 's/^/  /'
  } >&2
  exit 1
fi
if [ "$FOUND" -ne 1 ]; then
  echo "swarm-restart: REFUSED — swarm.conf has $FOUND rows named '$NAME'; no session was stopped." >&2
  exit 2
fi
if [ "$ROW_INVALID" -ne 0 ] || [ -z "$ENGINE" ]; then
  echo "swarm-restart: REFUSED — the configured row for '$NAME' is malformed; no session was stopped." >&2
  exit 2
fi
[ -z "$REPO" ] && { echo "swarm-restart: could not resolve repo path for '$NAME' in $CONF" >&2; exit 1; }

# Resolve THIS swarm's projects dir from ITS account (field 6). The validated
# target scan above read the account label through swarm_conf_parse_line (the
# single source of truth for the column schema); swarm_account_resolve — the SOLE
# constructor of account paths — now maps it to the projects dir. Empty account
# → ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects} (default, byte-identical to
# the pre-partition global); labeled → $HOME/.claude-accounts/<label>/projects.
# Resolving from NAME's OWN account is what keeps the WORKING safety rail
# (repo_activity below) from reading another account's transcripts — which would
# make a working swarm look idle and let restart tear it down.
if [ "$ENGINE" = "codex" ]; then
  # Codex does not use a Claude account/projects dir. Its atomic runtime state
  # below is the sole working rail; leave this empty so the Claude branch can
  # never accidentally inspect a stale pre-Codex transcript.
  CLAUDE_PROJECTS=""
elif swarm_account_resolve "$ACCOUNT"; then
  CLAUDE_PROJECTS="$SWARM_ACCT_PROJECTS_DIR"
else
  # Invalid account label in this swarm's conf row → we cannot determine its
  # projects dir, so the WORKING-rail check below would read a stale/foreign dir
  # and could tear down a working swarm. Fail SAFE: refuse unless --force.
  if [ "$FORCE" -eq 1 ]; then
    echo "swarm-restart: WARNING — '$NAME' has an invalid account '$ACCOUNT'; cannot probe activity. Proceeding because --force (any in-process work may be lost)." >&2
    CLAUDE_PROJECTS=""   # no safe probe; the rail will note 'dir not found' and proceed
  else
    echo "swarm-restart: REFUSED — '$NAME' has an invalid account '$ACCOUNT' in swarm.conf; cannot safely probe its activity before restarting. Fix the ACCOUNT field, or pass --force to restart anyway (risking in-process work)." >&2
    exit 2
  fi
fi

SESS="${PREFIX}-${NAME}"

# ---------------------------------------------------------------------------
# Safety rail — is the swarm currently working?
# ---------------------------------------------------------------------------
ALIVE=0
if command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
  ALIVE=1
fi

if [ "$ALIVE" -eq 0 ]; then
  echo "swarm-restart: no live session '$SESS' — restart degenerates to up only"
elif [ "$ENGINE" = "codex" ]; then
  if swarm_codex_runtime_read "$NAME"; then
    if [ "$SWARM_CODEX_RUNTIME_ACTIVE" -eq 1 ] || \
       [ "$SWARM_CODEX_RUNTIME_QUEUE_DEPTH" -gt 0 ] || \
       [ -n "$SWARM_CODEX_RUNTIME_CHILD_PID" ]; then
      if [ "$FORCE" -eq 1 ]; then
        echo "swarm-restart: WARNING — Codex swarm '$NAME' is ACTIVE (active=$SWARM_CODEX_RUNTIME_ACTIVE, queued=$SWARM_CODEX_RUNTIME_QUEUE_DEPTH, child=${SWARM_CODEX_RUNTIME_CHILD_PID:-none}). Proceeding because --force; in-flight work may be lost." >&2
      else
        echo "swarm-restart: REFUSED — Codex swarm '$NAME' is ACTIVE (active=$SWARM_CODEX_RUNTIME_ACTIVE, queued=$SWARM_CODEX_RUNTIME_QUEUE_DEPTH, child=${SWARM_CODEX_RUNTIME_CHILD_PID:-none}). Wait for runtime.json to report idle, or pass --force." >&2
        exit 2
      fi
    else
      echo "swarm-restart: Codex swarm '$NAME' runtime is healthy and idle — safe to cycle"
    fi
  else
    if [ "$FORCE" -eq 1 ]; then
      echo "swarm-restart: WARNING — Codex runtime state is $SWARM_CODEX_RUNTIME_STATUS ($SWARM_CODEX_RUNTIME_FILE); proceeding because --force." >&2
    else
      echo "swarm-restart: REFUSED — live Codex session has $SWARM_CODEX_RUNTIME_STATUS runtime state ($SWARM_CODEX_RUNTIME_FILE). Cannot prove a clean boundary; pass --force only after inspecting the pane." >&2
      exit 2
    fi
  fi
elif [ ! -d "$CLAUDE_PROJECTS" ]; then
  echo "swarm-restart: NOTE — Claude projects dir not found ($CLAUDE_PROJECTS); cannot probe activity. Proceeding."
else
  ACT="$(repo_activity "$REPO" "$CLAUDE_PROJECTS" "$STALE_SECONDS")"
  AGE="${ACT%%|*}"
  TN="${ACT##*|}"
  [ -z "${TN:-}" ] && TN=0
  # repo_activity now always returns a numeric age (sentinel
  # SWARM_NO_TRANSCRIPT_AGE when no transcript exists). Defend against
  # any malformed output by coercing non-numeric to the sentinel.
  case "$AGE" in ''|*[!0-9]*) AGE="$SWARM_NO_TRANSCRIPT_AGE" ;; esac

  if [ "$AGE" -eq "$SWARM_NO_TRANSCRIPT_AGE" ]; then
    # No jsonl yet — session is starting; nothing in-flight to lose.
    echo "swarm-restart: session '$SESS' is alive but starting (no transcript yet) — safe to cycle"
  elif [ "$AGE" -le "$STALE_SECONDS" ]; then
    # WORKING — refuse unless --force.
    if [ "$FORCE" -eq 1 ]; then
      cat >&2 <<EOF
swarm-restart: WARNING — '$NAME' is WORKING (transcript write ${AGE}s ago; active teammates: ${TN}).
  Proceeding because --force was given. Any uncommitted teammate progress
  is being discarded. The lead will rebuild from disk on relaunch.
EOF
    else
      if [ "$AGE" -lt 60 ]; then age_fmt="${AGE}s"; else age_fmt="$(( AGE/60 ))m$(( AGE%60 ))s"; fi
      cat >&2 <<EOF
swarm-restart: REFUSED — swarm '$NAME' is currently WORKING.
  Most recent transcript write: ${age_fmt} ago (threshold: ${STALE_SECONDS}s)
  Active teammates: ${TN}

  Restarting will kill the tmux session. In-process teammates are
  RAM-only and do NOT survive a relaunch — uncommitted teammate
  progress is gone. The lead itself rebuilds from disk on relaunch
  (its stamped doctrine + any committed branches per the archetype),
  but anything not yet committed is lost.

  Either wait for the swarm to idle (>${STALE_SECONDS}s without a
  transcript write — swarm-status + the watcher's heartbeat are
  your signal), or pass --force to proceed anyway.
EOF
      exit 2
    fi
  else
    if [ "$AGE" -lt 60 ]; then age_fmt="${AGE}s"; else age_fmt="$(( AGE/60 ))m"; fi
    echo "swarm-restart: '$NAME' is idle (last transcript write ${age_fmt} ago > ${STALE_SECONDS}s threshold) — safe to cycle"
  fi
fi

# ---------------------------------------------------------------------------
# Down + up.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-restart: cycling '$NAME'"
if [ "$ALIVE" -eq 1 ]; then
  "$SWARM_UP" down "$NAME"; down_rc=$?
  if [ "$down_rc" -ne 0 ]; then
    echo "swarm-restart: ERROR — down failed for '$NAME'; refusing to run up over an unknown live state." >&2
    exit "$down_rc"
  fi
fi
"$SWARM_UP" up "$NAME"; up_rc=$?
if [ "$up_rc" -ne 0 ]; then
  echo "swarm-restart: ERROR — relaunch failed for '$NAME' (exit $up_rc). The swarm may be down; inspect the swarm-up error and retry." >&2
  exit "$up_rc"
fi

# Engine-specific operator handoff. The Codex primary pane is a daemon, while
# the historical Claude path retains its dev-channels prompt reminder exactly.
if [ "$ENGINE" = "codex" ]; then
cat <<EOF

swarm-restart: Codex lead relaunched. Open the supported operator view with:

    "$SCRIPT_DIR/swarm-view.sh" $NAME

EOF
else
cat <<EOF

swarm-restart: heads-up — if the dev-channels prompt is still waiting on
'$SESS' when you attach, press Enter to accept it (the auto-Enter in
swarm-up.sh can race; this is the manual clear):

    tmux send-keys -t $SESS Enter
EOF
fi
