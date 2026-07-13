#!/usr/bin/env bash
# A direct, flagless swarm-init must not downgrade a configured/shared Codex
# repository to the historical Claude AGENTS.md surface.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-init-engine.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
mode_of(){ stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
gid_of(){ stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1"; }

SWARM="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$SWARM/templates/_base" "$SWARM/templates/cpo" "$REPO/.claude"
printf 'claude base pointer\n' > "$SWARM/templates/_base/AGENTS.md"
printf 'codex cpo entrypoint\n' > "$SWARM/templates/cpo/AGENTS.md"
cat > "$SWARM/templates/cpo/manifest.tsv" <<'MANIFEST'
refresh | cpo/AGENTS.md | AGENTS.md
MANIFEST
printf 'cpo\n' > "$REPO/.claude/swarm-type"
printf 'claude-sibling | %s | BOT_CLAUDE | 1 | | | claude\n' "$REPO" > "$SWARM/swarm.conf"
printf 'codex-sibling | %s | BOT_CODEX | 2 | | | codex\n' "$REPO" >> "$SWARM/swarm.conf"

echo '=== configured mixed-engine repository resolves to Codex ==='
SWARM_HOME="$SWARM" "$ROOT/bin/swarm-init.sh" "$REPO" --engine codex >/dev/null
before="$(cat "$REPO/AGENTS.md")"
out="$(SWARM_HOME="$SWARM" "$ROOT/bin/swarm-init.sh" "$REPO" 2>&1)"; rc=$?
eq 0 "$rc" 'flagless direct init succeeds for configured mixed repo'
eq 'codex cpo entrypoint' "$before" 'fixture begins on Codex AGENTS surface'
eq 'codex cpo entrypoint' "$(cat "$REPO/AGENTS.md")" 'flagless direct init preserves Codex AGENTS surface'
if printf '%s' "$out" | grep -qF 'configured repo surface resolved to codex'; then
  ok 'direct init reports configured Codex resolution'
else
  bad 'direct init reports configured Codex resolution'
fi
if [ -f "$REPO/.claude/codex-managed-paths" ] && grep -qxF 'AGENTS.md' "$REPO/.claude/codex-managed-paths"; then
  ok 'Codex ownership ledger remains coherent'
else
  bad 'Codex ownership ledger remains coherent'
fi

echo '=== unconfigured direct repository keeps the Claude default ==='
ADHOC="$TMP/adhoc"
mkdir -p "$ADHOC/.claude"
printf 'cpo\n' > "$ADHOC/.claude/swarm-type"
SWARM_HOME="$SWARM" "$ROOT/bin/swarm-init.sh" "$ADHOC" >/dev/null
eq 'claude base pointer' "$(cat "$ADHOC/AGENTS.md")" 'unconfigured flagless init keeps historical Claude surface'
if [ ! -e "$ADHOC/.claude/codex-managed-paths" ]; then
  ok 'unconfigured Claude init does not create Codex ledger'
else
  bad 'unconfigured Claude init does not create Codex ledger'
fi

echo '=== a newly stamped Codex marker retains the shared parent boundary ==='
MARKED="$TMP/marked"
mkdir -p "$MARKED/.claude"
printf 'marked-codex | %s | BOT_MARKED | 3 | | | codex\n' "$MARKED" >> "$SWARM/swarm.conf"
parent_gid="$(gid_of "$MARKED/.claude")"
SWARM_HOME="$SWARM" "$ROOT/bin/swarm-init.sh" "$MARKED" --type cpo --engine codex >/dev/null
eq cpo "$(cat "$MARKED/.claude/swarm-type")" 'Codex type marker is stamped after apply'
eq 640 "$(mode_of "$MARKED/.claude/swarm-type")" 'Codex type marker is shared-group readable'
eq "$parent_gid" "$(gid_of "$MARKED/.claude/swarm-type")" 'Codex type marker inherits the prepared parent group'

printf 'swarm-init-configured-engine: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
