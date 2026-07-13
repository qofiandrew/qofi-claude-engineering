#!/usr/bin/env bash
# Migration safety for newly managed `.codex/**` and `.agents/skills/**`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-managed-adoption.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else bad "$2"; fi; }
assert_absent() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok "$2"; else bad "$2"; fi; }
assert_same_file() { if cmp -s "$1" "$2"; then ok "$3"; else bad "$3 (files differ: $1 $2)"; fi; }

HOME_DIR="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$HOME_DIR/templates/_base" "$HOME_DIR/templates/testtype" "$REPO/.claude" "$REPO/.codex"
: > "$HOME_DIR/swarm.conf"
printf 'Canonical Claude pointer.\n\nRead CLAUDE.md exactly.\n' > "$HOME_DIR/templates/_base/AGENTS.md"
printf 'testtype\n' > "$REPO/.claude/swarm-type"
printf 'canonical ordinary v1\n' > "$HOME_DIR/templates/testtype/ordinary.txt"
printf 'canonical agents v1\n' > "$HOME_DIR/templates/testtype/AGENTS.md"
printf 'canonical config v1\n' > "$HOME_DIR/templates/testtype/config.toml"
printf 'canonical skill v1\n' > "$HOME_DIR/templates/testtype/SKILL.md"
cat > "$HOME_DIR/templates/testtype/manifest.tsv" <<'MANIFEST'
refresh | testtype/ordinary.txt | ordinary.txt
refresh | testtype/AGENTS.md    | AGENTS.md
refresh | testtype/config.toml  | .codex/config.toml
refresh | testtype/SKILL.md     | .agents/skills/example/SKILL.md
MANIFEST

run_apply() {
  local mode="$1"
  set +e
  APPLY_OUT="$(SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex bash -c '
    . "$1/bin/swarm-lib.sh"
    manifest_apply "$2" "$3"
    rc=$?
    printf "__RESULT__ fatal=%s drift=%s changed=%s collisions=%s\n" \
      "$SWARM_RESULT_FATAL" "$SWARM_RESULT_DRIFT" "$SWARM_RESULT_CHANGED" \
      "$(printf %s "$SWARM_RESULT_COLLISIONS" | tr "\n" ",")"
    exit "$rc"
  ' _ "$ROOT" "$REPO" "$mode" 2>&1)"
  APPLY_RC=$?
  set -e
}

echo "=== Claude engine skips every Codex-only surface without blocking sync ==="
CLAUDE_FRESH_REPO="$TMP/claude-fresh-repo"
mkdir -p "$CLAUDE_FRESH_REPO/.claude"
printf 'testtype\n' > "$CLAUDE_FRESH_REPO/.claude/swarm-type"
SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=claude bash -c \
  '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" init' _ "$ROOT" "$CLAUDE_FRESH_REPO" >/dev/null
assert_same_file "$HOME_DIR/templates/_base/AGENTS.md" "$CLAUDE_FRESH_REPO/AGENTS.md" "fresh Claude apply installs the base AGENTS.md byte-for-byte"
assert_absent "$CLAUDE_FRESH_REPO/.codex/config.toml" "fresh Claude apply skips Codex config"
assert_absent "$CLAUDE_FRESH_REPO/.agents/skills/example/SKILL.md" "fresh Claude apply skips Codex skills"
assert_absent "$CLAUDE_FRESH_REPO/.claude/codex-managed-paths" "fresh Claude apply does not stamp a Codex ledger"

CLAUDE_REPO="$TMP/claude-repo"
mkdir -p "$CLAUDE_REPO/.claude" "$CLAUDE_REPO/.codex"
printf 'testtype\n' > "$CLAUDE_REPO/.claude/swarm-type"
printf 'ordinary drift\n' > "$CLAUDE_REPO/ordinary.txt"
printf 'operator Claude AGENTS\n' > "$CLAUDE_REPO/AGENTS.md"
printf 'operator Claude Codex config\n' > "$CLAUDE_REPO/.codex/config.toml"
printf 'preexisting-ledger-sentinel\n' > "$CLAUDE_REPO/.claude/codex-managed-paths"
set +e
CLAUDE_OUT="$(SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=claude bash -c '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" sync' _ "$ROOT" "$CLAUDE_REPO" 2>&1)"; CLAUDE_RC=$?
set -e
assert_eq 0 "$CLAUDE_RC" "Claude sync is not blocked by foreign AGENTS/.codex"
assert_eq "canonical ordinary v1" "$(cat "$CLAUDE_REPO/ordinary.txt")" "Claude sync still refreshes ordinary doctrine"
assert_same_file "$HOME_DIR/templates/_base/AGENTS.md" "$CLAUDE_REPO/AGENTS.md" "Claude sync refreshes the base AGENTS.md byte-for-byte"
assert_eq "operator Claude Codex config" "$(cat "$CLAUDE_REPO/.codex/config.toml")" "Claude sync preserves foreign .codex content"
assert_absent "$CLAUDE_REPO/.agents/skills/example/SKILL.md" "Claude sync does not create Codex skills"
assert_eq "preexisting-ledger-sentinel" "$(cat "$CLAUDE_REPO/.claude/codex-managed-paths")" "reverse/Claude apply does not delete an existing Codex ledger"

CLAUDE_SYNC_REPO="$TMP/claude-sync-repo"
mkdir -p "$CLAUDE_SYNC_REPO/.claude" "$CLAUDE_SYNC_REPO/.codex"
printf 'testtype\n' > "$CLAUDE_SYNC_REPO/.claude/swarm-type"
printf 'ordinary wrapper drift\n' > "$CLAUDE_SYNC_REPO/ordinary.txt"
printf 'operator wrapper AGENTS\n' > "$CLAUDE_SYNC_REPO/AGENTS.md"
printf 'operator wrapper config\n' > "$CLAUDE_SYNC_REPO/.codex/config.toml"
git -C "$CLAUDE_SYNC_REPO" init -q
git -C "$CLAUDE_SYNC_REPO" config user.email test@example.com
git -C "$CLAUDE_SYNC_REPO" config user.name "Codex Adoption Test"
git -C "$CLAUDE_SYNC_REPO" add -A && git -C "$CLAUDE_SYNC_REPO" commit -q -m initial
printf 'claude-row | %s | BOT_CLAUDE | 122\n' "$CLAUDE_SYNC_REPO" > "$HOME_DIR/swarm.conf"
SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" claude-row >/dev/null 2>&1
assert_same_file "$HOME_DIR/templates/_base/AGENTS.md" "$CLAUDE_SYNC_REPO/AGENTS.md" "swarm-sync wrapper refreshes Claude row AGENTS.md byte-for-byte"
assert_same_file "$HOME_DIR/templates/_base/AGENTS.md" <(git -C "$CLAUDE_SYNC_REPO" show HEAD:AGENTS.md) "Claude sync commit includes the refreshed AGENTS.md"
assert_eq "operator wrapper config" "$(cat "$CLAUDE_SYNC_REPO/.codex/config.toml")" "swarm-sync wrapper preserves Claude row .codex"
assert_absent "$CLAUDE_SYNC_REPO/.claude/codex-managed-paths" "Claude wrapper sync does not stamp a Codex ledger"

CLAUDE_ONBOARD_REPO="$TMP/claude-onboard-repo"
mkdir -p "$CLAUDE_ONBOARD_REPO/.claude"
printf 'testtype\n' > "$CLAUDE_ONBOARD_REPO/.claude/swarm-type"
git -C "$CLAUDE_ONBOARD_REPO" init -q
git -C "$CLAUDE_ONBOARD_REPO" config user.email test@example.com
git -C "$CLAUDE_ONBOARD_REPO" config user.name "Codex Adoption Test"
git -C "$CLAUDE_ONBOARD_REPO" add -A && git -C "$CLAUDE_ONBOARD_REPO" commit -q -m initial
CLAUDE_ONBOARD_OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-onboard.sh" "$CLAUDE_ONBOARD_REPO" --engine claude 2>&1)"
assert_same_file "$HOME_DIR/templates/_base/AGENTS.md" <(git -C "$CLAUDE_ONBOARD_REPO" show HEAD:AGENTS.md) "Claude onboard commit includes the base AGENTS.md"
assert_eq "" "$(git -C "$CLAUDE_ONBOARD_REPO" status --porcelain -- AGENTS.md)" "Claude onboard leaves no untracked AGENTS.md outside rollback/staging inventory"
assert_has "$CLAUDE_ONBOARD_OUT" "bin/swarm-add.sh <name> $CLAUDE_ONBOARD_REPO <channel_id> --engine claude" "Claude onboard carries its explicit engine into the registration command"

CODEX_ONBOARD_REPO="$TMP/codex-onboard-repo"
mkdir -p "$CODEX_ONBOARD_REPO/.claude"
printf 'testtype\n' > "$CODEX_ONBOARD_REPO/.claude/swarm-type"
git -C "$CODEX_ONBOARD_REPO" init -q
git -C "$CODEX_ONBOARD_REPO" config user.email test@example.com
git -C "$CODEX_ONBOARD_REPO" config user.name "Codex Adoption Test"
git -C "$CODEX_ONBOARD_REPO" add -A && git -C "$CODEX_ONBOARD_REPO" commit -q -m initial
CODEX_ONBOARD_OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-onboard.sh" "$CODEX_ONBOARD_REPO" --engine codex 2>&1)"
assert_has "$CODEX_ONBOARD_OUT" "bin/swarm-add.sh <name> $CODEX_ONBOARD_REPO <channel_id> --engine codex" "Codex onboard carries its explicit engine into the registration command"

echo "=== foreign targets block the whole apply before its first write ==="
printf 'operator ordinary\n' > "$REPO/ordinary.txt"
printf 'operator AGENTS\n' > "$REPO/AGENTS.md"
printf 'operator Codex config\n' > "$REPO/.codex/config.toml"
run_apply sync
if [ "$APPLY_RC" -ne 0 ]; then ok "sync refuses an unowned differing Codex file"; else bad "sync refuses an unowned differing Codex file"; fi
assert_has "$APPLY_OUT" "REFUSED:   .codex/config.toml" "refusal identifies the foreign Codex path"
assert_has "$APPLY_OUT" "REFUSED:   AGENTS.md" "new Codex entrypoint is adoption-protected"
assert_eq "operator ordinary" "$(cat "$REPO/ordinary.txt")" "ordinary refresh is not partially overwritten"
assert_eq "operator AGENTS" "$(cat "$REPO/AGENTS.md")" "foreign AGENTS.md is byte-preserved"
assert_eq "operator Codex config" "$(cat "$REPO/.codex/config.toml")" "foreign Codex file is byte-preserved"
assert_absent "$REPO/.agents/skills/example/SKILL.md" "later absent managed target is not partially created"
assert_absent "$REPO/.claude/codex-managed-paths" "failed adoption does not stamp ownership"

echo ""
echo "=== check reports foreign/drift and remains read-only ==="
run_apply check
assert_eq 0 "$APPLY_RC" "check returns normally for reportable drift"
assert_has "$APPLY_OUT" "FOREIGN:   .codex/config.toml" "check classifies the unowned differing file as foreign"
assert_has "$APPLY_OUT" "MISSING:   .claude/codex-managed-paths" "check reports the missing ownership ledger"
assert_has "$APPLY_OUT" "drift=1" "check exposes drift to its caller"
assert_eq "operator ordinary" "$(cat "$REPO/ordinary.txt")" "check does not refresh ordinary content"
assert_absent "$REPO/.claude/codex-managed-paths" "check does not stamp the ledger"

echo ""
echo "=== target symlinks are never adopted or followed ==="
cp "$HOME_DIR/templates/testtype/config.toml" "$REPO/.codex/config.toml"
rm -f "$REPO/AGENTS.md"
printf 'outside agents sentinel\n' > "$TMP/outside-agents"
ln -s "$TMP/outside-agents" "$REPO/AGENTS.md"
mkdir -p "$REPO/.agents/skills/example"
printf 'outside sentinel\n' > "$TMP/outside-skill"
ln -s "$TMP/outside-skill" "$REPO/.agents/skills/example/SKILL.md"
run_apply init
if [ "$APPLY_RC" -ne 0 ]; then ok "init refuses a managed target symlink"; else bad "init refuses a managed target symlink"; fi
assert_has "$APPLY_OUT" "target is a symlink" "symlink refusal is explicit"
assert_eq "outside agents sentinel" "$(cat "$TMP/outside-agents")" "AGENTS.md symlink destination is untouched"
assert_eq "outside sentinel" "$(cat "$TMP/outside-skill")" "symlink destination is untouched"
assert_eq "operator ordinary" "$(cat "$REPO/ordinary.txt")" "symlink refusal occurs before unrelated writes"
assert_absent "$REPO/.claude/codex-managed-paths" "symlink refusal does not claim ownership"

echo ""
echo "=== absent/byte-identical targets are adopted with an exact ledger ==="
rm -f "$REPO/.agents/skills/example/SKILL.md"
rm -f "$REPO/AGENTS.md"
cp "$HOME_DIR/templates/testtype/AGENTS.md" "$REPO/AGENTS.md"
rmdir "$REPO/.agents/skills/example" "$REPO/.agents/skills" "$REPO/.agents" 2>/dev/null || true
run_apply sync
assert_eq 0 "$APPLY_RC" "safe adoption succeeds"
assert_eq "canonical ordinary v1" "$(cat "$REPO/ordinary.txt")" "ordinary refresh runs after safe preflight"
assert_eq "canonical skill v1" "$(cat "$REPO/.agents/skills/example/SKILL.md")" "absent managed skill is created"
assert_file "$REPO/.claude/codex-managed-paths" "ownership ledger is stamped"
EXPECTED_LEDGER="$(printf '%s\n' 'AGENTS.md' '.codex/config.toml' '.agents/skills/example/SKILL.md')"
assert_eq "$EXPECTED_LEDGER" "$(cat "$REPO/.claude/codex-managed-paths")" "ledger exactly matches current manifest targets"

echo ""
echo "=== ledger ownership permits updates; new foreign paths still block all writes ==="
printf 'managed drift\n' > "$REPO/.codex/config.toml"
run_apply sync
assert_eq 0 "$APPLY_RC" "ledger-owned content drift refreshes"
assert_eq "canonical config v1" "$(cat "$REPO/.codex/config.toml")" "owned target is restored to canonical bytes"

printf 'canonical rule\n' > "$HOME_DIR/templates/testtype/new.rules"
cat >> "$HOME_DIR/templates/testtype/manifest.tsv" <<'MANIFEST'
refresh | testtype/new.rules | .codex/rules/new.rules
MANIFEST
mkdir -p "$REPO/.codex/rules"
printf 'operator rule\n' > "$REPO/.codex/rules/new.rules"
printf 'managed drift blocked\n' > "$REPO/.codex/config.toml"
printf 'ordinary drift blocked\n' > "$REPO/ordinary.txt"
OLD_LEDGER="$(cat "$REPO/.claude/codex-managed-paths")"
run_apply sync
if [ "$APPLY_RC" -ne 0 ]; then ok "new unowned differing manifest target is refused"; else bad "new unowned differing manifest target is refused"; fi
assert_eq "managed drift blocked" "$(cat "$REPO/.codex/config.toml")" "owned update is not partially applied around new foreign path"
assert_eq "ordinary drift blocked" "$(cat "$REPO/ordinary.txt")" "ordinary update is not partially applied around new foreign path"
assert_eq "$OLD_LEDGER" "$(cat "$REPO/.claude/codex-managed-paths")" "failed expansion leaves prior exact ledger unchanged"

cp "$HOME_DIR/templates/testtype/new.rules" "$REPO/.codex/rules/new.rules"
run_apply sync
assert_eq 0 "$APPLY_RC" "byte-identical manifest expansion is safely adopted"
assert_eq "canonical config v1" "$(cat "$REPO/.codex/config.toml")" "prior owned drift updates after expansion becomes safe"
assert_has "$(cat "$REPO/.claude/codex-managed-paths")" ".codex/rules/new.rules" "successful expansion atomically extends the ledger"

echo ""
echo "=== onboarding keeps force scope explicit ==="
ONBOARD="$TMP/onboard"
mkdir -p "$HOME_DIR/templates/onboard" "$ONBOARD/.claude" "$ONBOARD/.codex/hooks"
printf 'onboard\n' > "$ONBOARD/.claude/swarm-type"
printf 'canonical hook\n' > "$HOME_DIR/templates/onboard/hook.sh"
printf 'refresh | onboard/hook.sh | .codex/hooks/example.sh\n' > "$HOME_DIR/templates/onboard/manifest.tsv"
printf 'operator hook\n' > "$ONBOARD/.codex/hooks/example.sh"
set +e
OUT="$(SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_HOOKS=0 bash -c '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" onboard' _ "$ROOT" "$ONBOARD" 2>&1)"; RC=$?
set -e
assert_eq 0 "$RC" "ordinary onboard reports collision without a fatal apply error"
assert_has "$OUT" "COLLISION: .codex/hooks/example.sh" "ordinary onboard makes adoption collision explicit"
assert_eq "operator hook" "$(cat "$ONBOARD/.codex/hooks/example.sh")" "ordinary onboard preserves foreign hook"
assert_absent "$ONBOARD/.claude/codex-managed-paths" "ordinary onboard does not claim refused hook"
SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_HOOKS=1 bash -c '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" onboard' _ "$ROOT" "$ONBOARD" >/dev/null
assert_eq "canonical hook" "$(cat "$ONBOARD/.codex/hooks/example.sh")" "explicit --force-hooks authorizes hook adoption"
assert_eq ".codex/hooks/example.sh" "$(cat "$ONBOARD/.claude/codex-managed-paths")" "forced hook adoption records exact ownership"

DOCS="$TMP/onboard-docs"
mkdir -p "$HOME_DIR/templates/onboard-docs" "$DOCS/.claude"
printf 'onboard-docs\n' > "$DOCS/.claude/swarm-type"
printf 'canonical agents\n' > "$HOME_DIR/templates/onboard-docs/AGENTS.md"
printf 'refresh | onboard-docs/AGENTS.md | AGENTS.md\n' > "$HOME_DIR/templates/onboard-docs/manifest.tsv"
printf 'operator agents\n' > "$DOCS/AGENTS.md"
SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_DOCS=0 bash -c '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" onboard' _ "$ROOT" "$DOCS" >/dev/null
assert_eq "operator agents" "$(cat "$DOCS/AGENTS.md")" "ordinary onboard preserves foreign AGENTS.md"
SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_FORCE_DOCS=1 bash -c '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" onboard' _ "$ROOT" "$DOCS" >/dev/null
assert_eq "canonical agents" "$(cat "$DOCS/AGENTS.md")" "explicit --force-docs authorizes AGENTS.md adoption"
assert_eq "AGENTS.md" "$(cat "$DOCS/.claude/codex-managed-paths")" "forced AGENTS.md adoption records ownership"

echo ""
echo "=== swarm-init does not stamp markers before a refused adoption ==="
INIT_REPO="$TMP/init-repo"
mkdir -p "$HOME_DIR/templates/cpo" "$INIT_REPO/.codex"
printf 'ordinary init\n' > "$HOME_DIR/templates/cpo/init.txt"
printf 'canonical init codex\n' > "$HOME_DIR/templates/cpo/init-codex"
cat > "$HOME_DIR/templates/cpo/manifest.tsv" <<'MANIFEST'
refresh | cpo/init.txt   | init.txt
refresh | cpo/init-codex | .codex/config.toml
MANIFEST
printf 'foreign init codex\n' > "$INIT_REPO/.codex/config.toml"
set +e
OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-init.sh" "$INIT_REPO" --type cpo --engine codex 2>&1)"; RC=$?
set -e
if [ "$RC" -ne 0 ]; then ok "swarm-init refuses foreign Codex adoption"; else bad "swarm-init refuses foreign Codex adoption"; fi
assert_absent "$INIT_REPO/.claude/swarm-type" "refused init leaves type marker absent"
assert_absent "$INIT_REPO/init.txt" "refused init leaves earlier ordinary manifest target absent"

echo ""
echo "=== sync stages and commits the auto-stamped ledger ==="
STAGE_REPO="$TMP/stage-repo"
mkdir -p "$HOME_DIR/templates/stage" "$STAGE_REPO/.claude" "$STAGE_REPO/.codex"
printf 'stage\n' > "$STAGE_REPO/.claude/swarm-type"
printf 'canonical stage\n' > "$HOME_DIR/templates/stage/config.toml"
printf 'refresh | stage/config.toml | .codex/config.toml\n' > "$HOME_DIR/templates/stage/manifest.tsv"
cp "$HOME_DIR/templates/stage/config.toml" "$STAGE_REPO/.codex/config.toml"
git -C "$STAGE_REPO" init -q
git -C "$STAGE_REPO" config user.email test@example.com
git -C "$STAGE_REPO" config user.name "Codex Adoption Test"
git -C "$STAGE_REPO" add -A
git -C "$STAGE_REPO" commit -q -m initial
printf 'stage-row | %s | BOT_STAGE | 123 | | | codex\n' "$STAGE_REPO" > "$HOME_DIR/swarm.conf"
SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" stage-row >/dev/null 2>&1
COMMITTED="$(git -C "$STAGE_REPO" show --pretty='' --name-only HEAD)"
assert_has "$COMMITTED" ".claude/codex-managed-paths" "sync commit stages the ownership ledger"

ADHOC_REPO="$TMP/ad-hoc-stage"
mkdir -p "$ADHOC_REPO/.claude" "$ADHOC_REPO/.codex"
printf 'stage\n' > "$ADHOC_REPO/.claude/swarm-type"
cp "$HOME_DIR/templates/stage/config.toml" "$ADHOC_REPO/.codex/config.toml"
git -C "$ADHOC_REPO" init -q
git -C "$ADHOC_REPO" config user.email test@example.com
git -C "$ADHOC_REPO" config user.name "Codex Adoption Test"
git -C "$ADHOC_REPO" add -A; git -C "$ADHOC_REPO" commit -q -m initial
printf '# no matching row\n' > "$HOME_DIR/swarm.conf"
SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" "$ADHOC_REPO" --engine codex >/dev/null 2>&1
assert_file "$ADHOC_REPO/.claude/codex-managed-paths" "explicit ad-hoc --engine codex applies Codex ownership surfaces"

printf 'dup-a | %s | BOT_A | 1 | | | codex\ndup-b | %s | BOT_B | 2 | | | claude\n' "$ADHOC_REPO" "$ADHOC_REPO" > "$HOME_DIR/swarm.conf"
set +e
OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" "$ADHOC_REPO" --check 2>&1)"; RC=$?
set -e
assert_eq 0 "$RC" "ad-hoc inference aggregates shared-repo engine identity"
assert_absent "$ADHOC_REPO/.claude/.unexpected" "shared-repo ad-hoc check remains read-only"

echo ""
echo "=== fleet sync selects one Codex surface per physical mixed-engine repo ==="
MIXED_REPO="$TMP/mixed-sync-repo"
mkdir -p "$MIXED_REPO/.claude"
printf 'testtype\n' > "$MIXED_REPO/.claude/swarm-type"
SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE=codex bash -c \
  '. "$1/bin/swarm-lib.sh"; manifest_apply "$2" init' _ "$ROOT" "$MIXED_REPO" >/dev/null
git -C "$MIXED_REPO" init -q
git -C "$MIXED_REPO" config user.email test@example.com
git -C "$MIXED_REPO" config user.name "Codex Adoption Test"
git -C "$MIXED_REPO" add -A; git -C "$MIXED_REPO" commit -q -m initial

for order in claude-first codex-first; do
  if [ "$order" = claude-first ]; then
    printf 'mixed-claude | %s | BOT_MC | 31 | | | claude\nmixed-codex | %s | BOT_MX | 32 | | | codex\n' "$MIXED_REPO" "$MIXED_REPO" > "$HOME_DIR/swarm.conf"
  else
    printf 'mixed-codex | %s | BOT_MX | 32 | | | codex\nmixed-claude | %s | BOT_MC | 31 | | | claude\n' "$MIXED_REPO" "$MIXED_REPO" > "$HOME_DIR/swarm.conf"
  fi
  cp "$HOME_DIR/templates/_base/AGENTS.md" "$MIXED_REPO/AGENTS.md"
  SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" --force >/dev/null 2>&1
  assert_same_file "$HOME_DIR/templates/testtype/AGENTS.md" "$MIXED_REPO/AGENTS.md" "mixed-engine $order fleet sync retains Codex AGENTS"
  assert_file "$MIXED_REPO/.claude/codex-managed-paths" "mixed-engine $order fleet sync retains Codex ledger"
done

echo ""
echo "=== configured path sync cannot bypass engine authority or lifecycle lease ==="
CODEX_AGENTS_BEFORE="$TMP/codex-agents-before"
cp "$MIXED_REPO/AGENTS.md" "$CODEX_AGENTS_BEFORE"
set +e
OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" "$MIXED_REPO" --engine claude --check 2>&1)"; RC=$?
set -e
assert_eq 2 "$RC" "configured path rejects an explicit engine override"
assert_has "$OUT" "field 7 is authoritative" "configured-path refusal explains engine authority"
assert_same_file "$CODEX_AGENTS_BEFORE" "$MIXED_REPO/AGENTS.md" "rejected Claude override cannot degrade the Codex AGENTS surface"

printf 'bad-row | %s | BOT_BAD | 99 | | | future\n' "$MIXED_REPO" >> "$HOME_DIR/swarm.conf"
set +e
OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" "$MIXED_REPO" --check 2>&1)"; RC=$?
set -e
assert_eq 2 "$RC" "malformed config fails configured-path resolution closed"
assert_same_file "$CODEX_AGENTS_BEFORE" "$MIXED_REPO/AGENTS.md" "malformed config path check remains read-only"
sed '$d' "$HOME_DIR/swarm.conf" > "$HOME_DIR/swarm.conf.tmp" && mv "$HOME_DIR/swarm.conf.tmp" "$HOME_DIR/swarm.conf"

printf 'canonical ordinary v2\n' > "$HOME_DIR/templates/testtype/ordinary.txt"
PATH_LOCK_MARKER="$TMP/path-lock-observed"
cat > "$MIXED_REPO/.git/hooks/pre-commit" <<EOF
#!/bin/sh
[ -d '$HOME_DIR/swarm.conf.mutation.lock' ] || exit 42
: > '$PATH_LOCK_MARKER'
EOF
chmod +x "$MIXED_REPO/.git/hooks/pre-commit"
OUT="$(SWARM_HOME="$HOME_DIR" "$ROOT/bin/swarm-sync.sh" "$MIXED_REPO" 2>&1)"; RC=$?
assert_eq 0 "$RC" "configured path sync succeeds with authoritative Codex surface"
if [ -f "$PATH_LOCK_MARKER" ]; then ok "configured path commit observes the lifecycle lease"; else bad "configured path commit observes the lifecycle lease"; fi
assert_same_file "$HOME_DIR/templates/testtype/AGENTS.md" "$MIXED_REPO/AGENTS.md" "configured path sync retains Codex AGENTS"
rm -f "$MIXED_REPO/.git/hooks/pre-commit" "$PATH_LOCK_MARKER"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
