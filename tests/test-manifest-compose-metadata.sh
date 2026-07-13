#!/usr/bin/env bash
# Metadata and atomic-publication contract for manifest compose targets.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d /private/tmp/qofi-compose-metadata.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM
SWARM_HOME="$TMP/swarm"; REPO="$TMP/repo"; DRY_REPO="$TMP/dry-repo"
STUB="$TMP/stub"; MV_LOG="$TMP/mv.log"
mkdir -p "$SWARM_HOME/templates/meta" "$REPO" "$DRY_REPO" "$STUB"
export SWARM_HOME MV_LOG

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
eq(){ if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected=[$1] got=[$2])"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (missing [$2])"; fi; }
mode_of(){ stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
gid_of(){ stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1" 2>/dev/null; }

printf '#!/bin/sh\nprintf pre\n' > "$SWARM_HOME/templates/meta/pre.sh"
printf 'printf post\n' > "$SWARM_HOME/templates/meta/post.sh"
printf 'manual one\n' > "$SWARM_HOME/templates/meta/manual-a.md"
printf 'manual two\n' > "$SWARM_HOME/templates/meta/manual-b.md"
chmod 644 "$SWARM_HOME/templates/meta/pre.sh" "$SWARM_HOME/templates/meta/post.sh"

# Observe the staging file at the atomic publication boundary. This wrapper
# records metadata before delegating to the real mv.
cat > "$STUB/mv" <<'SH'
#!/bin/sh
previous=""; last=""
for argument in "$@"; do
  case "$argument" in -*) continue ;; esac
  previous="$last"; last="$argument"
done
mode="$(stat -f '%Lp' "$previous" 2>/dev/null || stat -c '%a' "$previous")"
gid="$(stat -f '%g' "$previous" 2>/dev/null || stat -c '%g' "$previous")"
printf '%s|%s|%s|%s|%s|%s\n' \
  "$previous" "$last" "$mode" "$gid" "$(dirname "$previous")" "$(dirname "$last")" >> "$MV_LOG"
exec /bin/mv "$@"
SH
chmod 755 "$STUB/mv"
PATH="$STUB:$PATH"; export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/swarm-lib.sh"

reset_context(){
  SWARM_APPLY_REPO="$1"; SWARM_APPLY_MODE="$2"
  SWARM_APPLY_ENGINE="${3:-claude}"
  SWARM_RESULT_CHANGED=0; SWARM_RESULT_DRIFT=0; SWARM_RESULT_FATAL=0
  SWARM_RESULT_COLLISIONS=""
  unset SWARM_DRY_RUN SWARM_QUIET_UNCHANGED
}

assert_publication(){
  local target="$1" expected_mode="$2" expected_gid="$3" record
  record="$(awk -F '|' -v target="$target" '$2 == target { found=$0 } END { print found }' "$MV_LOG")"
  if [ -n "$record" ]; then pass "$4 publication crossed observed mv"; else fail "$4 publication crossed observed mv"; return; fi
  local staged published mode gid staged_dir target_dir
  IFS='|' read -r staged published mode gid staged_dir target_dir <<EOF
$record
EOF
  eq "$expected_mode" "$mode" "$4 staging mode is final before publication"
  eq "$expected_gid" "$gid" "$4 staging group is final before publication"
  eq "$target_dir" "$staged_dir" "$4 staging file is in the target directory"
  has "$(basename "$staged")" ".swarm-compose." "$4 uses the private compose staging name"
}

echo "=== dry-run remains read-only ==="
reset_context "$DRY_REPO" onboard; SWARM_DRY_RUN=1
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/dry.out"; rc=$?
eq 0 "$rc" "missing-target onboard preflight succeeds"
eq 1 "$SWARM_RESULT_CHANGED" "preflight reports the planned compose write"
if [ ! -e "$DRY_REPO/.claude" ]; then pass "preflight creates no target parent"; else fail "preflight creates no target parent"; fi
eq "" "$(cat "$MV_LOG" 2>/dev/null)" "preflight performs no publication"

echo "=== new hook publishes executable/readable metadata atomically ==="
mkdir -p "$REPO/.claude/hooks"
primary_gid="$(id -g)"; parent_gid="$primary_gid"
for candidate in $(id -G); do
  if [ "$candidate" != "$primary_gid" ] && chgrp "$candidate" "$REPO/.claude/hooks" 2>/dev/null; then
    parent_gid="$candidate"
    break
  fi
done
parent_gid="$(gid_of "$REPO/.claude/hooks")"
: > "$MV_LOG"
reset_context "$REPO" init
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/new-hook.out"; rc=$?
HOOK="$REPO/.claude/hooks/permission-gate.sh"
eq 0 "$rc" "new composed hook succeeds"
eq 755 "$(mode_of "$HOOK")" "new hook is owner-writable and executable/readable by runtime users"
eq "$parent_gid" "$(gid_of "$HOOK")" "new hook inherits its target-parent group"
if [ -x "$HOOK" ] && [ -r "$HOOK" ]; then pass "new hook is executable and readable"; else fail "new hook is executable and readable"; fi
assert_publication "$HOOK" 755 "$parent_gid" "new hook"
if find "$REPO/.claude/hooks" -name '.swarm-compose.*' -print -quit | grep -q .; then fail "new hook leaves no staging file"; else pass "new hook leaves no staging file"; fi

echo "=== new Codex hook derives non-executable shared metadata ==="
CODEX_REPO="$TMP/codex-repo"
mkdir -p "$CODEX_REPO/.claude/hooks"
chgrp "$parent_gid" "$CODEX_REPO/.claude/hooks" 2>/dev/null || true
codex_parent_gid="$(gid_of "$CODEX_REPO/.claude/hooks")"
: > "$MV_LOG"
reset_context "$CODEX_REPO" init codex
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/new-codex.out"; rc=$?
CODEX_HOOK="$CODEX_REPO/.claude/hooks/permission-gate.sh"
eq 0 "$rc" "new Codex composed hook succeeds"
eq 640 "$(mode_of "$CODEX_HOOK")" "non-executable sources produce a bash-invoked Codex hook"
eq "$codex_parent_gid" "$(gid_of "$CODEX_HOOK")" "new Codex hook inherits its target-parent group"
assert_publication "$CODEX_HOOK" 640 "$codex_parent_gid" "new Codex hook"

echo "=== Claude preserves safe existing metadata ==="
HOOK_CONTENT="$TMP/hook-content"
cp "$HOOK" "$HOOK_CONTENT"
chmod 600 "$HOOK"
if [ "$parent_gid" != "$primary_gid" ]; then chgrp "$primary_gid" "$HOOK"; fi
claude_safe_gid="$(gid_of "$HOOK")"
reset_context "$REPO" check claude
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/claude-check.out"; rc=$?
eq 0 "$rc" "Claude metadata check completes"
eq 0 "$SWARM_RESULT_DRIFT" "owner-readable 0600 is safe for the operator-run Claude hook"
has "$(cat "$TMP/claude-check.out")" "OK:" "Claude check accepts safe existing metadata"

: > "$MV_LOG"
reset_context "$REPO" sync claude
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/claude-sync.out"; rc=$?
eq 0 "$rc" "Claude unchanged sync succeeds"
eq 0 "$SWARM_RESULT_CHANGED" "Claude unchanged sync does not rewrite safe metadata"
eq 600 "$(mode_of "$HOOK")" "Claude retains safe existing mode"
eq "$claude_safe_gid" "$(gid_of "$HOOK")" "Claude retains safe existing group"
eq "" "$(cat "$MV_LOG")" "Claude safe metadata causes no atomic replacement"

echo "=== Claude check detects and sync repairs unsafe metadata ==="
chmod 666 "$HOOK"
reset_context "$REPO" check claude
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/claude-unsafe-check.out"; rc=$?
eq 0 "$rc" "unsafe Claude metadata check completes"
eq 1 "$SWARM_RESULT_DRIFT" "group/world-writable Claude hook is metadata drift"
has "$(cat "$TMP/claude-unsafe-check.out")" "METADATA:" "unsafe Claude metadata is explained"

: > "$MV_LOG"
reset_context "$REPO" sync claude
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/claude-repair.out"; rc=$?
eq 0 "$rc" "Claude sync repairs unsafe unchanged metadata"
eq 755 "$(mode_of "$HOOK")" "unsafe Claude hook falls back to conventional safe mode"
eq "$parent_gid" "$(gid_of "$HOOK")" "unsafe Claude hook falls back to target-parent group"
assert_publication "$HOOK" 755 "$parent_gid" "Claude metadata repair"

echo "=== Codex normalizes unchanged hook for dedicated-runtime readability ==="
chmod 600 "$HOOK"
if [ "$parent_gid" != "$primary_gid" ]; then chgrp "$primary_gid" "$HOOK"; fi
reset_context "$REPO" check codex
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/check.out"; rc=$?
eq 0 "$rc" "Codex metadata check completes"
eq 1 "$SWARM_RESULT_DRIFT" "Codex check marks private/wrong-group metadata drift"
has "$(cat "$TMP/check.out")" "METADATA:" "Codex metadata check explains the drift"
eq 600 "$(mode_of "$HOOK")" "Codex check does not mutate the drifted target"

reset_context "$REPO" sync codex; SWARM_DRY_RUN=1
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/repair-dry.out"; rc=$?
eq 0 "$rc" "Codex metadata-repair dry-run succeeds"
has "$(cat "$TMP/repair-dry.out")" "would repair metadata" "Codex metadata-repair dry-run reports its action"
eq 600 "$(mode_of "$HOOK")" "Codex metadata-repair dry-run is read-only"

: > "$MV_LOG"
reset_context "$REPO" sync codex
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/repair.out"; rc=$?
eq 0 "$rc" "unchanged-content Codex sync repairs metadata"
eq 1 "$SWARM_RESULT_CHANGED" "metadata repair is reported as a sync change"
has "$(cat "$TMP/repair.out")" "repaired metadata" "metadata repair is explicit"
if cmp -s "$HOOK" "$HOOK_CONTENT"; then pass "metadata repair preserves composed bytes"; else fail "metadata repair preserves composed bytes"; fi
eq 640 "$(mode_of "$HOOK")" "bash-invoked Codex hook becomes group-readable without exec"
eq "$parent_gid" "$(gid_of "$HOOK")" "metadata repair restores target-parent group"
assert_publication "$HOOK" 640 "$parent_gid" "Codex metadata repair"

chmod 700 "$HOOK"
if [ "$parent_gid" != "$primary_gid" ]; then chgrp "$primary_gid" "$HOOK"; fi
: > "$MV_LOG"
reset_context "$REPO" sync codex
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/codex-exec.out"; rc=$?
eq 0 "$rc" "Codex sync repairs an owner-executable hook"
eq 750 "$(mode_of "$HOOK")" "Codex carries owner execution into the runtime group contract"
eq "$parent_gid" "$(gid_of "$HOOK")" "executable Codex hook uses target-parent group"
assert_publication "$HOOK" 750 "$parent_gid" "Codex executable metadata repair"

echo "=== Claude content update preserves safe existing metadata before publication ==="
printf 'printf updated\n' > "$SWARM_HOME/templates/meta/post.sh"
: > "$MV_LOG"
reset_context "$REPO" sync claude
manifest_apply_compose 'meta/pre.sh+meta/post.sh' '.claude/hooks/permission-gate.sh' > "$TMP/update.out"; rc=$?
eq 0 "$rc" "composed hook content update succeeds"
has "$(cat "$HOOK")" "updated" "content update publishes new bytes"
eq 750 "$(mode_of "$HOOK")" "Claude content update preserves safe existing mode"
eq "$parent_gid" "$(gid_of "$HOOK")" "content update retains target-parent group"
assert_publication "$HOOK" 750 "$parent_gid" "content update"

echo "=== non-hook composition remains readable and non-writable by group/world ==="
mkdir -p "$REPO/manuals"
chgrp "$parent_gid" "$REPO/manuals" 2>/dev/null || true
manual_gid="$(gid_of "$REPO/manuals")"
: > "$MV_LOG"
reset_context "$REPO" init
manifest_apply_compose 'meta/manual-a.md+meta/manual-b.md' 'manuals/GUIDE.md' > "$TMP/manual.out"; rc=$?
MANUAL="$REPO/manuals/GUIDE.md"
eq 0 "$rc" "new non-hook composition succeeds"
eq 644 "$(mode_of "$MANUAL")" "non-hook composition is readable without group/world write"
eq "$manual_gid" "$(gid_of "$MANUAL")" "non-hook composition inherits its target-parent group"
if [ -r "$MANUAL" ]; then pass "non-hook composition is readable"; else fail "non-hook composition is readable"; fi
assert_publication "$MANUAL" 644 "$manual_gid" "non-hook composition"

echo "=== special targets are rejected without false publication ==="
ln -s "$MANUAL" "$REPO/manuals/link.md"
reset_context "$REPO" sync claude
manifest_apply_compose 'meta/manual-a.md+meta/manual-b.md' 'manuals/link.md' > "$TMP/link.out" 2>&1; rc=$?
eq 1 "$rc" "symlink compose target is rejected"
eq 1 "$SWARM_RESULT_FATAL" "symlink rejection is fatal"
if [ -L "$REPO/manuals/link.md" ]; then pass "symlink target is not replaced or followed"; else fail "symlink target is not replaced or followed"; fi

mkdir "$REPO/manuals/directory-target"
reset_context "$REPO" sync claude
manifest_apply_compose 'meta/manual-a.md+meta/manual-b.md' 'manuals/directory-target' > "$TMP/directory.out" 2>&1; rc=$?
eq 1 "$rc" "directory compose target is rejected"
eq 1 "$SWARM_RESULT_FATAL" "directory rejection is fatal"
if [ -d "$REPO/manuals/directory-target" ] && \
   [ -z "$(find "$REPO/manuals/directory-target" -mindepth 1 -print -quit)" ]; then
  pass "directory target receives no misplaced staging file"
else
  fail "directory target receives no misplaced staging file"
fi

echo "manifest-compose-metadata: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
