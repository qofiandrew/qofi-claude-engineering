#!/usr/bin/env bash
# Engine-aware metadata and atomic publication for non-compose manifest paths.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d /private/tmp/qofi-plain-metadata.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM
SWARM_HOME="$TMP/swarm"; REPO="$TMP/repo"; STUB="$TMP/stub"; MV_LOG="$TMP/mv.log"
mkdir -p "$SWARM_HOME/templates/plainmeta" "$REPO" "$STUB"
export SWARM_HOME MV_LOG

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
eq(){ if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected=[$1] got=[$2])"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing [$2])"; fi; }
mode_of(){ stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
full_mode_of(){ local mode; mode="$(mode_of "$1")"; [ -g "$1" ] && printf '2%s' "$mode" || printf '%s' "$mode"; }
gid_of(){ stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1" 2>/dev/null; }

cat > "$STUB/mv" <<'SH'
#!/bin/sh
previous=""; last=""
for argument in "$@"; do
  case "$argument" in -*) continue ;; esac
  previous="$last"; last="$argument"
done
mode="$(stat -f '%Lp' "$previous" 2>/dev/null || stat -c '%a' "$previous")"
gid="$(stat -f '%g' "$previous" 2>/dev/null || stat -c '%g' "$previous")"
printf '%s|%s|%s|%s|%s|%s\n' "$previous" "$last" "$mode" "$gid" \
  "$(dirname "$previous")" "$(dirname "$last")" >> "$MV_LOG"
[ -z "${MV_FAIL_TARGET:-}" ] || [ "$last" != "$MV_FAIL_TARGET" ] || exit 91
exec /bin/mv "$@"
SH
chmod 755 "$STUB/mv"
PATH="$STUB:$PATH"; export PATH

printf 'codex doctrine\n' > "$SWARM_HOME/templates/plainmeta/AGENTS.md"
printf 'ordinary v1\n' > "$SWARM_HOME/templates/plainmeta/ordinary.txt"
printf '#!/bin/sh\nexit 0\n' > "$SWARM_HOME/templates/plainmeta/hook.sh"
printf '{"env":{"QOFI":"1"}}\n' > "$SWARM_HOME/templates/plainmeta/settings.json"
printf 'product seed\n' > "$SWARM_HOME/templates/plainmeta/product.keep"
printf 'codex config\n' > "$SWARM_HOME/templates/plainmeta/codex.conf"
printf '#!/bin/sh\n# SWARM-MANAGED pre-commit\nexit 0\n' > "$SWARM_HOME/templates/plainmeta/pre-commit"
chmod 755 "$SWARM_HOME/templates/plainmeta/hook.sh" "$SWARM_HOME/templates/plainmeta/pre-commit"
cat > "$SWARM_HOME/templates/plainmeta/manifest.tsv" <<'EOF'
refresh | plainmeta/AGENTS.md | AGENTS.md
refresh | plainmeta/ordinary.txt | generated/deep/ordinary.txt
refresh | plainmeta/hook.sh | .claude/hooks/tool.sh
settings | plainmeta/settings.json | .claude/settings.json
operator-owned | plainmeta/product.keep | products/.keep
refresh | plainmeta/codex.conf | .codex/nested/config
git-hook | plainmeta/pre-commit | .git/hooks/pre-commit
seed-text | npm test | .claude/test-cmd
gitignore | .worktrees/ | .gitignore
EOF

# Model a prepared repository root and .git root. Choose a supplementary group
# when available so inheritance is proved independently of the process gid.
shared_gid="$(id -g)"
for candidate in $(id -G); do
  if [ "$candidate" != "$(id -g)" ] && chgrp "$candidate" "$REPO" 2>/dev/null; then
    shared_gid="$candidate"
    break
  fi
done
shared_gid="$(gid_of "$REPO")"
chmod 2770 "$REPO"
mkdir "$REPO/.git"
chgrp "$shared_gid" "$REPO/.git" 2>/dev/null || true
chmod 2750 "$REPO/.git"

# shellcheck source=/dev/null
. "$ROOT/bin/swarm-lib.sh"
apply(){
  local mode="$1"
  SWARM_APPLY_TYPE_OVERRIDE=plainmeta SWARM_APPLY_ENGINE_OVERRIDE=codex \
    manifest_apply "$REPO" "$mode"
}

echo '=== first Codex publication creates runtime-valid parents and files ==='
: > "$MV_LOG"
apply init > "$TMP/init.out"; rc=$?
eq 0 "$rc" 'Codex plain manifest init succeeds'
eq 2770 "$(full_mode_of "$REPO/generated")" 'ordinary missing parent is shared setgid rwx'
eq 2770 "$(full_mode_of "$REPO/generated/deep")" 'nested ordinary parent is shared setgid rwx'
eq "$shared_gid" "$(gid_of "$REPO/generated/deep")" 'ordinary parent inherits prepared shared gid'
eq 750 "$(mode_of "$REPO/.claude")" 'operator-owned .claude parent is runtime-readable without group write'
eq 750 "$(mode_of "$REPO/.claude/hooks")" 'nested operator-owned parent retains no-write policy'
eq "$shared_gid" "$(gid_of "$REPO/.claude/hooks")" 'operator parent inherits prepared shared gid'
eq 750 "$(mode_of "$REPO/.git/hooks")" 'missing .git child uses exact operator-owned directory mode'
eq 640 "$(mode_of "$REPO/AGENTS.md")" 'operator doctrine is group-readable and not group-writable'
eq 660 "$(mode_of "$REPO/generated/deep/ordinary.txt")" 'ordinary Codex file remains group-writable'
eq 750 "$(mode_of "$REPO/.claude/hooks/tool.sh")" 'operator executable carries group execute only'
eq 640 "$(mode_of "$REPO/.claude/settings.json")" 'settings are Codex-readable without group write'
eq 660 "$(mode_of "$REPO/products/.keep")" 'runtime-editable operator-policy seed remains group-writable'
eq 640 "$(mode_of "$REPO/.codex/nested/config")" 'Codex control file is group-readable without write'
eq 750 "$(mode_of "$REPO/.git/hooks/pre-commit")" 'git hook is published with runtime read/execute'
eq 640 "$(mode_of "$REPO/.claude/test-cmd")" 'generated seed-text is group-readable under operator controls'
eq 660 "$(mode_of "$REPO/.gitignore")" 'generated gitignore remains ordinary group-writable content'
eq 640 "$(mode_of "$REPO/.claude/operator-owned-paths")" 'operator ownership ledger is group-readable'
eq 640 "$(mode_of "$REPO/.claude/codex-managed-paths")" 'Codex ownership ledger is group-readable'

ordinary_record="$(awk -F '|' -v target="$REPO/generated/deep/ordinary.txt" '$2 == target {x=$0} END {print x}' "$MV_LOG")"
IFS='|' read -r staged published staged_mode staged_gid staged_dir target_dir <<EOF
$ordinary_record
EOF
eq 660 "$staged_mode" 'ordinary staging inode has final mode before rename'
eq "$shared_gid" "$staged_gid" 'ordinary staging inode has final group before rename'
eq "$target_dir" "$staged_dir" 'plain publication stages beside its target'
has "$(basename "$staged")" '.swarm-publish.' 'plain publication uses private staging name'

echo '=== ordinary content refresh preserves runtime write access ==='
printf 'ordinary v2\n' > "$SWARM_HOME/templates/plainmeta/ordinary.txt"
apply sync > "$TMP/update.out"; rc=$?
eq 0 "$rc" 'Codex content refresh succeeds'
eq 660 "$(mode_of "$REPO/generated/deep/ordinary.txt")" 'content refresh does not strip ordinary group write'
eq "$shared_gid" "$(gid_of "$REPO/generated/deep/ordinary.txt")" 'content refresh retains shared gid'

echo '=== check/dry-run detect metadata-only drift without mutation ==='
chmod 600 "$REPO/AGENTS.md" "$REPO/.claude/settings.json" \
  "$REPO/.claude/operator-owned-paths" "$REPO/.claude/codex-managed-paths" "$REPO/.gitignore" \
  "$REPO/.git/hooks/pre-commit"
set +e
CHECK_OUT="$(apply check 2>&1)"; check_rc=$?
set -e
eq 0 "$check_rc" 'metadata-only check completes as a report'
has "$CHECK_OUT" 'METADATA:  AGENTS.md' 'refresh metadata drift is reported'
has "$CHECK_OUT" 'METADATA:  .claude/settings.json' 'settings metadata drift is reported'
has "$CHECK_OUT" 'METADATA:  .claude/operator-owned-paths' 'operator ledger metadata drift is reported'
has "$CHECK_OUT" 'METADATA:  .claude/codex-managed-paths' 'Codex ledger metadata drift is reported'
has "$CHECK_OUT" 'METADATA:  .gitignore' 'generated gitignore metadata drift is reported'
has "$CHECK_OUT" 'METADATA:  .git/hooks/pre-commit' 'managed Git-hook metadata drift is reported'
eq 600 "$(mode_of "$REPO/AGENTS.md")" 'check does not repair refresh metadata'

SWARM_DRY_RUN=1 apply sync > "$TMP/dry.out"; dry_rc=$?; unset SWARM_DRY_RUN
eq 0 "$dry_rc" 'metadata repair dry-run succeeds'
eq 600 "$(mode_of "$REPO/.claude/settings.json")" 'dry-run does not repair settings metadata'
apply sync > "$TMP/repair.out"; repair_rc=$?
eq 0 "$repair_rc" 'live sync repairs all metadata-only drift'
eq 640 "$(mode_of "$REPO/AGENTS.md")" 'refresh metadata repaired'
eq 640 "$(mode_of "$REPO/.claude/settings.json")" 'settings metadata repaired'
eq 640 "$(mode_of "$REPO/.claude/operator-owned-paths")" 'operator ledger metadata repaired'
eq 640 "$(mode_of "$REPO/.claude/codex-managed-paths")" 'Codex ledger metadata repaired'
eq 660 "$(mode_of "$REPO/.gitignore")" 'gitignore metadata repaired to ordinary runtime access'
eq 750 "$(mode_of "$REPO/.git/hooks/pre-commit")" 'managed Git-hook metadata repaired with execute parity'

echo '=== ownership authorities refuse writable and aliased ledgers ==='
printf 'forged doctrine\n' > "$REPO/AGENTS.md"
chmod 660 "$REPO/.claude/codex-managed-paths"
set +e
FORGED_OUT="$(apply sync 2>&1)"; forged_rc=$?
set -e
if [ "$forged_rc" -ne 0 ]; then pass 'group-writable Codex ledger is refused'; else fail 'group-writable Codex ledger is refused'; fi
has "$FORGED_OUT" 'single-link non-writable authority file' 'writable-ledger refusal explains the authority invariant'
eq 'forged doctrine' "$(cat "$REPO/AGENTS.md")" 'untrusted ledger grants no managed overwrite authority'
chmod 640 "$REPO/.claude/codex-managed-paths"
apply sync >/dev/null

cp "$REPO/.claude/codex-managed-paths" "$TMP/codex-ledger-alias"
rm "$REPO/.claude/codex-managed-paths"
ln "$TMP/codex-ledger-alias" "$REPO/.claude/codex-managed-paths"
printf 'hardlink forged doctrine\n' > "$REPO/AGENTS.md"
set +e
HARDLINK_OUT="$(apply sync 2>&1)"; hardlink_rc=$?
set -e
if [ "$hardlink_rc" -ne 0 ]; then pass 'hard-linked Codex ledger is refused'; else fail 'hard-linked Codex ledger is refused'; fi
has "$HARDLINK_OUT" 'single-link non-writable authority file' 'hard-link refusal explains the authority invariant'
eq 'hardlink forged doctrine' "$(cat "$REPO/AGENTS.md")" 'hard-link alias grants no managed overwrite authority'
rm "$REPO/.claude/codex-managed-paths"
cp "$TMP/codex-ledger-alias" "$REPO/.claude/codex-managed-paths"
chgrp "$shared_gid" "$REPO/.claude/codex-managed-paths" 2>/dev/null || true
chmod 640 "$REPO/.claude/codex-managed-paths"
apply sync >/dev/null

chmod 660 "$REPO/.claude/operator-owned-paths"
SWARM_OO_PREFIXES=' stale/'; SWARM_OO_FILES='stale.txt'
set +e
_swarm_load_oo_from_list "$REPO"; oo_rc=$?
set -e
if [ "$oo_rc" -ne 0 ]; then pass 'group-writable operator ledger is refused'; else fail 'group-writable operator ledger is refused'; fi
eq '' "$SWARM_OO_PREFIXES$SWARM_OO_FILES" 'untrusted operator ledger leaves the exemption set empty'
chmod 640 "$REPO/.claude/operator-owned-paths"
printf 'products/\n../escape\n' > "$REPO/.claude/operator-owned-paths"
set +e
_swarm_load_oo_from_list "$REPO"; malformed_oo_rc=$?
set -e
if [ "$malformed_oo_rc" -ne 0 ]; then pass 'malformed operator ledger is refused'; else fail 'malformed operator ledger is refused'; fi
eq '' "$SWARM_OO_PREFIXES$SWARM_OO_FILES" 'malformed ledger publishes no partial trusted exemption set'
apply sync >/dev/null

if chmod +a 'everyone deny write' "$REPO/AGENTS.md" 2>/dev/null; then
  set +e
  ACL_CHECK_OUT="$(apply check 2>&1)"; acl_check_rc=$?
  set -e
  eq 0 "$acl_check_rc" 'Codex ACL metadata check completes'
  has "$ACL_CHECK_OUT" 'METADATA:  AGENTS.md' 'Codex target ACL is metadata drift'
  apply sync >/dev/null
  if _swarm_file_acl_is_safe "$REPO/AGENTS.md"; then pass 'Codex live sync strips target ACL'; else fail 'Codex live sync strips target ACL'; fi

  chmod +a 'everyone deny write' "$REPO/.claude/codex-managed-paths"
  set +e
  ACL_AUTH_OUT="$(apply sync 2>&1)"; acl_auth_rc=$?
  set -e
  if [ "$acl_auth_rc" -ne 0 ]; then pass 'ACL-bearing Codex authority ledger is refused'; else fail 'ACL-bearing Codex authority ledger is refused'; fi
  has "$ACL_AUTH_OUT" 'single-link non-writable authority file' 'ACL authority refusal is explicit'
  chmod -N "$REPO/.claude/codex-managed-paths"

  chmod +a 'everyone deny write' "$REPO/.claude/operator-owned-paths"
  set +e
  _swarm_load_oo_from_list "$REPO"; acl_oo_rc=$?
  set -e
  if [ "$acl_oo_rc" -ne 0 ]; then pass 'ACL-bearing operator ledger is refused'; else fail 'ACL-bearing operator ledger is refused'; fi
  eq '' "$SWARM_OO_PREFIXES$SWARM_OO_FILES" 'ACL operator ledger publishes no exemptions'
  chmod -N "$REPO/.claude/operator-owned-paths"
else
  pass 'ACL-specific assertions skipped on host without chmod +a'
fi

echo '=== failed publication removes only parents created by that attempt ==='
FAIL_REPO="$TMP/fail-repo"; mkdir "$FAIL_REPO"; chgrp "$shared_gid" "$FAIL_REPO" 2>/dev/null || true; chmod 2770 "$FAIL_REPO"
FAIL_TARGET="$FAIL_REPO/new/deep/file.txt"
SWARM_APPLY_REPO="$FAIL_REPO"; SWARM_APPLY_ENGINE=codex; export MV_FAIL_TARGET="$FAIL_TARGET"
set +e
_swarm_publish_plain "$SWARM_HOME/templates/plainmeta/ordinary.txt" "$FAIL_TARGET" 'new/deep/file.txt'
failed_publish_rc=$?
set -e
unset MV_FAIL_TARGET
if [ "$failed_publish_rc" -ne 0 ]; then pass 'injected publication failure is surfaced'; else fail 'injected publication failure is surfaced'; fi
if [ ! -e "$FAIL_REPO/new" ]; then pass 'failed publication reverses its newly created parent chain'; else fail 'failed publication reverses its newly created parent chain'; fi

echo '=== Claude preserves established safe shared metadata ==='
CLAUDE_GENERATED_REPO="$TMP/claude-generated"; mkdir "$CLAUDE_GENERATED_REPO"
SWARM_APPLY_REPO="$CLAUDE_GENERATED_REPO"; SWARM_APPLY_MODE=init; SWARM_APPLY_ENGINE=claude
SWARM_RESULT_CHANGED=0; SWARM_RESULT_DRIFT=0; SWARM_RESULT_FATAL=0
manifest_apply_seed_text 'npm test' '.claude/test-cmd' > /dev/null
manifest_apply_gitignore '.worktrees/' '.gitignore' > /dev/null
eq 644 "$(mode_of "$CLAUDE_GENERATED_REPO/.claude/test-cmd")" 'fresh Claude seed-text retains historical 0644 mode'
eq 644 "$(mode_of "$CLAUDE_GENERATED_REPO/.gitignore")" 'fresh Claude gitignore retains historical 0644 mode'

CLAUDE_TARGET="$TMP/claude-shared.txt"
printf 'old\n' > "$CLAUDE_TARGET"; chmod 664 "$CLAUDE_TARGET"
claude_gid="$(gid_of "$CLAUDE_TARGET")"
SWARM_APPLY_REPO="$TMP"; SWARM_APPLY_ENGINE=claude; SWARM_RESULT_CHANGED=0; SWARM_RESULT_FATAL=0
_swarm_copy "$SWARM_HOME/templates/plainmeta/ordinary.txt" "$CLAUDE_TARGET" 'updated' > /dev/null
eq 664 "$(mode_of "$CLAUDE_TARGET")" 'Claude plain refresh preserves safe 0664 mode'
eq "$claude_gid" "$(gid_of "$CLAUDE_TARGET")" 'Claude plain refresh preserves established group'

echo "manifest-plain-metadata: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
