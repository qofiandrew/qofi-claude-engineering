#!/usr/bin/env bash
# --force-hooks must repair Codex managed hooks exactly like Claude hooks.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-force-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$HOME_DIR/templates/testtype/codex" "$REPO/.claude" "$REPO/.codex/hooks"
printf 'testtype\n' > "$REPO/.claude/swarm-type"
printf 'canonical hook\n' > "$HOME_DIR/templates/testtype/codex/hook.sh"
printf '{"canonical":true}\n' > "$HOME_DIR/templates/testtype/codex/hooks.json"
cat > "$HOME_DIR/templates/testtype/manifest.tsv" <<'MANIFEST'
refresh | testtype/codex/hook.sh   | .codex/hooks/example.sh
refresh | testtype/codex/hooks.json | .codex/hooks.json
MANIFEST
printf 'operator hook\n' > "$REPO/.codex/hooks/example.sh"
printf '{"operator":true}\n' > "$REPO/.codex/hooks.json"

export SWARM_HOME="$HOME_DIR"
. "$ROOT/bin/swarm-lib.sh"

PASS=0
FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }

SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_HOOKS=0 manifest_apply "$REPO" onboard >/dev/null
if grep -qF 'operator hook' "$REPO/.codex/hooks/example.sh"; then ok 'ordinary onboard preserves colliding Codex hook'; else bad 'ordinary onboard preserves colliding Codex hook'; fi
if grep -qF '"operator":true' "$REPO/.codex/hooks.json"; then ok 'ordinary onboard preserves colliding hooks.json'; else bad 'ordinary onboard preserves colliding hooks.json'; fi

SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_HOOKS=1 manifest_apply "$REPO" onboard >/dev/null
if cmp -s "$REPO/.codex/hooks/example.sh" "$HOME_DIR/templates/testtype/codex/hook.sh"; then ok '--force-hooks repairs .codex/hooks/*'; else bad '--force-hooks repairs .codex/hooks/*'; fi
if cmp -s "$REPO/.codex/hooks.json" "$HOME_DIR/templates/testtype/codex/hooks.json"; then ok '--force-hooks repairs .codex/hooks.json'; else bad '--force-hooks repairs .codex/hooks.json'; fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
