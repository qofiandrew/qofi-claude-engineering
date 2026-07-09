#!/usr/bin/env bash
# adversarial-review.sh — engine-aware dispatcher for the contrarian review lane.
#
# The lane's whole value is a reviewer from a DIFFERENT model family than the
# code's author, so the reviewer is chosen by the swarm's ENGINE (swarm.conf
# field 7, resolved by matching the current repo to its conf row):
#
#   engine claude (default) -> codex-review.sh   (Codex reviews Claude's work)
#   engine codex            -> claude-review.sh  (Claude/Fable reviews Codex's work)
#
# All args (--range, --check) pass through. Advisory, never gating — both
# underlying lanes carry the same subscription-only money-path floor and
# advisory-down semantics. If the repo isn't in swarm.conf (or SWARM_HOME is
# unset), the engine defaults to claude — codex-review.sh, today's behavior.
#
# Bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

engine="claude"
CONF="${SWARM_HOME:-}/swarm.conf"
if [ -n "${SWARM_HOME:-}" ] && [ -f "$CONF" ]; then
  # shellcheck source=swarm-lib.sh
  . "$SCRIPT_DIR/swarm-lib.sh"
  here="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    if [ "$SWARM_CONF_F_REPO" = "$here" ]; then
      engine="$SWARM_CONF_F_ENGINE"
      break
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
fi

if [ "$engine" = "codex" ]; then
  exec "$SCRIPT_DIR/claude-review.sh" "$@"
else
  exec "$SCRIPT_DIR/codex-review.sh" "$@"
fi
