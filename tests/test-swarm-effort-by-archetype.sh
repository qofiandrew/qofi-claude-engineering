#!/usr/bin/env bash
# test-swarm-effort-by-archetype.sh — pins the per-archetype launch effort.
#
# swarm-up's launch_one() sends a `/effort` command into each freshly-booted
# swarm pane (effort is session-only; ultracode has no settings/env form). The
# level is data-driven per archetype via swarm_effort_for() in swarm-lib.sh:
#   cpo                 -> /effort medium   (single conversational product agent)
#   engineering-cto     -> /effort ultracode (CTO swarms fan out under workflows)
#   unknown / future    -> /effort ultracode (fail-safe to the engineering path,
#                          consistent with swarm_required_doctrine/_launch_brief)
#
# Run from $SWARM_HOME:  bash tests/test-swarm-effort-by-archetype.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }
pass() { printf '  ok   %s\n' "$*"; }

# shellcheck source=/dev/null
source "$ROOT/bin/swarm-lib.sh"

eq() {  # eq EXPECT ACTUAL LABEL
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}

echo "=== swarm_effort_for() per archetype ==="
eq "/effort medium"    "$(swarm_effort_for cpo)"             "cpo            -> /effort medium"
eq "/effort ultracode" "$(swarm_effort_for engineering-cto)" "engineering-cto -> /effort ultracode"
eq "/effort ultracode" "$(swarm_effort_for company-brain)"   "unknown/future  -> /effort ultracode (fail-safe)"
eq "/effort ultracode" "$(swarm_effort_for '')"              "empty type      -> /effort ultracode (fail-safe)"

echo ""
echo "=== launch_one() is wired to the helper (no hardcoded effort) ==="
if grep -q 'swarm_effort_for' "$ROOT/bin/swarm-up.sh"; then
  pass "swarm-up.sh launch path calls swarm_effort_for"
else
  fail "swarm-up.sh no longer references swarm_effort_for"
fi
if grep -Eq 'send-keys[^"]*"/effort ultracode"' "$ROOT/bin/swarm-up.sh"; then
  fail "swarm-up.sh still hardcodes a literal '/effort ultracode' send-keys"
else
  pass "no hardcoded '/effort ultracode' send-keys remains in swarm-up.sh"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then echo "  ALL PASS"; exit 0; else echo "  FAILURES" >&2; exit 1; fi
