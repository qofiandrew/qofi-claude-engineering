#!/usr/bin/env bash
# Focused contract for the committed Codex profile registry consumed by
# swarm-add. The registry is policy only: labels/shared flags, named ordered
# pools, and per-pool soft-limit thresholds. It must never contain credentials.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../bin/swarm-lib.sh
. "$ROOT/bin/swarm-lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-profiles-config.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
accepts() {
  if swarm_codex_profiles_validate "$1" "${2:-}" >/dev/null 2>&1; then ok "$3"; else bad "$3"; fi
}
refuses() {
  if swarm_codex_profiles_validate "$1" "${2:-}" >/dev/null 2>&1; then bad "$3"; else ok "$3"; fi
}

echo '=== committed exact registry ==='
accepts "$ROOT/codex-profiles.json" default 'committed catalog validates and declares the default pool'
if python3 - "$ROOT/codex-profiles.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    catalog = json.load(handle)
raise SystemExit(catalog["pools"]["default"]["thresholdPercent"] != 95)
PY
then ok 'committed default Codex pool rotates at 95 percent'
else bad 'committed default Codex pool rotates at 95 percent'
fi
refuses "$ROOT/codex-profiles.json" missing 'an undeclared requested pool fails closed'

cat > "$TMP/default-threshold.json" <<'JSON'
{
  "schema": "qofi-codex-profiles/v1",
  "profiles": [{"label":"default","shared":true}],
  "pools": {"default":{"profiles":["default"]}}
}
JSON
accepts "$TMP/default-threshold.json" default 'omitted thresholdPercent normalizes to the manager default of 95'

cat > "$TMP/extra-key.json" <<'JSON'
{
  "schema": "qofi-codex-profiles/v1",
  "profiles": [{"label":"default","shared":true}],
  "pools": {"default":{"profiles":["default"],"thresholdPercent":85}},
  "credentials": "must-never-be-here"
}
JSON
refuses "$TMP/extra-key.json" default 'unknown top-level keys are refused'

cat > "$TMP/not-shared.json" <<'JSON'
{
  "schema": "qofi-codex-profiles/v1",
  "profiles": [{"label":"default","shared":false}],
  "pools": {"default":{"profiles":["default"],"thresholdPercent":85}}
}
JSON
refuses "$TMP/not-shared.json" default 'default profile must be explicitly shared'

cat > "$TMP/bad-pool.json" <<'JSON'
{
  "schema": "qofi-codex-profiles/v1",
  "profiles": [
    {"label":"default","shared":true},
    {"label":"premium_a","shared":false}
  ],
  "pools": {
    "default":{"profiles":["default"],"thresholdPercent":85},
    "premium":{"profiles":["premium_a","premium_a"],"thresholdPercent":101}
  }
}
JSON
refuses "$TMP/bad-pool.json" premium 'duplicate ordered entries and out-of-range thresholds are refused'

echo ''
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
