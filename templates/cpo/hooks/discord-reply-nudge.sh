#!/usr/bin/env bash
# Compatibility-named Claude Stop adapter. The same harness boundary serves CPO,
# engineering CTO, and Codex workers; archetype-specific policy does not live here.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "$SWARM_HOME/bin/swarm-stop-hook.ts" ]; then
  reason="operator-controlled swarm stop harness is unavailable"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  printf 'discord-stop-adapter: BLOCKED — %s\n' "$reason" >&2
  exit 2
fi

exec "$SWARM_HOME/bin/swarm-stop-hook.ts"
