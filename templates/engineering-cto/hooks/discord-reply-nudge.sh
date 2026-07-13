#!/usr/bin/env bash
# Compatibility-named Claude Stop adapter. Delivery policy is harness-owned;
# this repo-stamped hook only translates the native lifecycle control point.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "$SWARM_HOME/bin/swarm-stop-hook.ts" ]; then
  reason="operator-controlled swarm stop harness is unavailable"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  printf 'discord-stop-adapter: BLOCKED — %s\n' "$reason" >&2
  exit 2
fi

exec "$SWARM_HOME/bin/swarm-stop-hook.ts"
