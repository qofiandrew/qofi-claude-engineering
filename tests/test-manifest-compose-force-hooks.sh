#!/usr/bin/env bash
# Composed hooks must honor onboard's concern-specific --force-hooks policy.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compose-force-hooks.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

SWARM_HOME="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$SWARM_HOME/templates/meta" "$REPO/.claude/hooks"
printf 'canonical prelude\n' > "$SWARM_HOME/templates/meta/pre.sh"
printf 'canonical policy\n' > "$SWARM_HOME/templates/meta/policy.sh"
HOOK="$REPO/.claude/hooks/permission-gate.sh"
printf 'foreign hook\n' > "$HOOK"
chmod 666 "$HOOK"

PASS=0
FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
mode_of(){ stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
gid_of(){ stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1"; }

# shellcheck source=/dev/null
. "$ROOT/bin/swarm-lib.sh"

reset_context(){
  SWARM_APPLY_REPO="$REPO"
  SWARM_APPLY_MODE=onboard
  SWARM_APPLY_ENGINE=claude
  SWARM_RESULT_CHANGED=0
  SWARM_RESULT_DRIFT=0
  SWARM_RESULT_FATAL=0
  SWARM_RESULT_COLLISIONS=""
  unset SWARM_DRY_RUN SWARM_FORCE_DOCS SWARM_FORCE_HOOKS
}

echo '=== composed hook remains a collision without hook authority ==='
reset_context
manifest_apply_compose 'meta/pre.sh+meta/policy.sh' '.claude/hooks/permission-gate.sh' > "$TMP/unforced.out" 2>&1; rc=$?
eq 0 "$rc" 'unforced onboard reports rather than fatally aborting'
has "$SWARM_RESULT_COLLISIONS" 'compose:.claude/hooks/permission-gate.sh' 'unforced composed hook is a collision'
eq 'foreign hook' "$(cat "$HOOK")" 'unforced composed hook preserves foreign content'

echo '=== force-docs alone cannot authorize a hook ==='
reset_context; SWARM_FORCE_DOCS=1
manifest_apply_compose 'meta/pre.sh+meta/policy.sh' '.claude/hooks/permission-gate.sh' >/dev/null; rc=$?
eq 0 "$rc" 'force-docs-only onboard completes collision scan'
has "$SWARM_RESULT_COLLISIONS" 'compose:.claude/hooks/permission-gate.sh' 'force-docs alone leaves hook collision'
eq 'foreign hook' "$(cat "$HOOK")" 'force-docs alone preserves foreign hook'

echo '=== force-hooks dry-run is mutation-free ==='
reset_context; SWARM_FORCE_HOOKS=1; SWARM_DRY_RUN=1
before_mode="$(mode_of "$HOOK")"; before_gid="$(gid_of "$HOOK")"
manifest_apply_compose 'meta/pre.sh+meta/policy.sh' '.claude/hooks/permission-gate.sh' > "$TMP/dry.out" 2>&1; rc=$?
out="$(cat "$TMP/dry.out")"
eq 0 "$rc" 'force-hooks dry-run succeeds'
has "$out" 'would overwrite (--force-hooks)' 'force-hooks dry-run reports exact authority'
eq 1 "$SWARM_RESULT_CHANGED" 'force-hooks dry-run reports planned change'
eq '' "$SWARM_RESULT_COLLISIONS" 'force-hooks dry-run clears the hook collision'
eq 'foreign hook' "$(cat "$HOOK")" 'force-hooks dry-run preserves bytes'
eq "$before_mode" "$(mode_of "$HOOK")" 'force-hooks dry-run preserves mode'
eq "$before_gid" "$(gid_of "$HOOK")" 'force-hooks dry-run preserves group'

echo '=== force-hooks live publishes canonical hook with safe metadata ==='
reset_context; SWARM_FORCE_HOOKS=1
parent_gid="$(gid_of "$REPO/.claude/hooks")"
manifest_apply_compose 'meta/pre.sh+meta/policy.sh' '.claude/hooks/permission-gate.sh' > "$TMP/live.out" 2>&1; rc=$?
out="$(cat "$TMP/live.out")"
eq 0 "$rc" 'force-hooks live succeeds'
has "$out" 'overwrote (--force-hooks)' 'force-hooks live reports exact authority'
eq $'canonical prelude\ncanonical policy' "$(cat "$HOOK")" 'force-hooks live publishes canonical composition'
eq 755 "$(mode_of "$HOOK")" 'unsafe Claude hook falls back to conventional executable mode'
eq "$parent_gid" "$(gid_of "$HOOK")" 'unsafe Claude hook falls back to parent group'
eq '' "$SWARM_RESULT_COLLISIONS" 'force-hooks live leaves no collision'

printf 'manifest-compose-force-hooks: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
