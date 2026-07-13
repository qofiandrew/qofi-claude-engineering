#!/usr/bin/env bash
# Host-side manifest selection and path containment. Repository marker files are
# untrusted inputs; no mode or engine may use them to select sources/targets
# outside the trusted template tree and canonical target repository.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/manifest-containment.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
absent() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok "$2"; else bad "$2"; fi; }

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/templates/safe" "$HOME_DIR/templates/engineering-cto"
: > "$HOME_DIR/swarm.conf"
printf 'alpha\n' > "$HOME_DIR/templates/safe/a"
printf 'beta\n' > "$HOME_DIR/templates/safe/b"
printf 'compose | safe/a+safe/b | DOC.md\n' > "$HOME_DIR/templates/safe/manifest.tsv"
printf 'refresh | safe/a | DOC.md\n' > "$HOME_DIR/templates/engineering-cto/manifest.tsv"

run_apply() { # repo mode engine [dry-run]
  local repo="$1" mode="$2" engine="$3" dry="${4:-0}"
  set +e
  APPLY_OUT="$(SWARM_HOME="$HOME_DIR" SWARM_APPLY_ENGINE_OVERRIDE="$engine" SWARM_DRY_RUN="$dry" bash -c '
    . "$1/bin/swarm-lib.sh"
    manifest_apply "$2" "$3"
    rc=$?
    printf "__RESULT__ rc=%s fatal=%s changed=%s drift=%s\n" \
      "$rc" "${SWARM_RESULT_FATAL:-unset}" "${SWARM_RESULT_CHANGED:-unset}" \
      "${SWARM_RESULT_DRIFT:-unset}"
    exit "$rc"
  ' _ "$ROOT" "$repo" "$mode" 2>&1)"
  APPLY_RC=$?
  set -e
}

echo "=== safe installation-local archetypes remain usable ==="
SAFE_REPO="$TMP/safe-repo"
mkdir -p "$SAFE_REPO/.claude"
printf 'safe\n' > "$SAFE_REPO/.claude/swarm-type"
run_apply "$SAFE_REPO" init claude
eq 0 "$APPLY_RC" "safe normalized custom manifest applies"
eq "$(printf 'alpha\nbeta')" "$(cat "$SAFE_REPO/DOC.md")" "safe compose remains byte-correct"

echo ""
echo "=== traversal type markers fail before every mode/engine write ==="
for engine in claude codex; do
  for mode in init sync check onboard; do
    CASE="$TMP/type-$engine-$mode"
    REPO="$CASE/repo"
    mkdir -p "$REPO/.claude" "$REPO/eviltype"
    printf '../../repo/eviltype\n' > "$REPO/.claude/swarm-type"
    printf 'controlled payload\n' > "$REPO/eviltype/payload"
    printf 'compose | ../../repo/eviltype/payload | ../outside.txt\n' > "$REPO/eviltype/manifest.tsv"
    printf 'outside sentinel\n' > "$CASE/outside.txt"
    dry=0; [ "$mode" = onboard ] && dry=1
    run_apply "$REPO" "$mode" "$engine" "$dry"
    if [ "$APPLY_RC" -ne 0 ]; then
      ok "$engine/$mode refuses traversal type marker"
    else
      bad "$engine/$mode refuses traversal type marker"
    fi
    has "$APPLY_OUT" "unsafe swarm type marker" "$engine/$mode names unsafe type selection"
    eq "outside sentinel" "$(cat "$CASE/outside.txt")" "$engine/$mode cannot overwrite escaped target"
  done
done

echo ""
echo "=== profile markers are known, type-scoped names ==="
PROFILE_REPO="$TMP/profile-repo"
mkdir -p "$PROFILE_REPO/.claude"
printf 'engineering-cto\n' > "$PROFILE_REPO/.claude/swarm-type"
printf '../../../../outside\n' > "$PROFILE_REPO/.claude/swarm-profile"
run_apply "$PROFILE_REPO" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "traversal profile marker is refused"; else bad "traversal profile marker is refused"; fi
has "$APPLY_OUT" "unknown or invalid swarm profile" "profile refusal is explicit"
absent "$PROFILE_REPO/DOC.md" "invalid profile fails before ordinary manifest writes"

UNKNOWN_PROFILE_REPO="$TMP/unknown-profile-repo"
mkdir -p "$UNKNOWN_PROFILE_REPO/.claude"
printf 'engineering-cto\n' > "$UNKNOWN_PROFILE_REPO/.claude/swarm-type"
printf 'not-a-profile\n' > "$UNKNOWN_PROFILE_REPO/.claude/swarm-profile"
run_apply "$UNKNOWN_PROFILE_REPO" check codex
if [ "$APPLY_RC" -ne 0 ]; then ok "unknown profile label is refused centrally"; else bad "unknown profile label is refused centrally"; fi

MARKER_LINK_REPO="$TMP/marker-link-repo"
mkdir -p "$MARKER_LINK_REPO/.claude"
printf 'engineering-cto\n' > "$TMP/outside-type-marker"
ln -s "$TMP/outside-type-marker" "$MARKER_LINK_REPO/.claude/swarm-type"
set +e
DIRECT_MARKER_OUT="$(SWARM_HOME="$HOME_DIR" bash -c '. "$1/bin/swarm-lib.sh"; swarm_type_of "$2"' _ "$ROOT" "$MARKER_LINK_REPO" 2>&1)"
DIRECT_MARKER_RC=$?
set -e
eq 2 "$DIRECT_MARKER_RC" "type resolver rejects its symlink before reading it"
has "$DIRECT_MARKER_OUT" "unsafe .claude/swarm-type marker" "direct resolver reports unsafe marker object"
run_apply "$MARKER_LINK_REPO" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "symlinked type marker is refused before resolution"; else bad "symlinked type marker is refused before resolution"; fi
has "$APPLY_OUT" "unsafe .claude/swarm-type marker" "marker-object refusal is explicit"
absent "$MARKER_LINK_REPO/DOC.md" "symlinked marker cannot select a manifest"

echo ""
echo "=== complete manifest preflight rejects source and target escape ==="
BAD_SOURCE_REPO="$TMP/bad-source-repo"
mkdir -p "$HOME_DIR/templates/bad-source" "$BAD_SOURCE_REPO/.claude"
printf 'bad-source\n' > "$BAD_SOURCE_REPO/.claude/swarm-type"
cat > "$HOME_DIR/templates/bad-source/manifest.tsv" <<'MANIFEST'
refresh | safe/a | first.txt
compose | safe/a+../outside-source | second.txt
MANIFEST
run_apply "$BAD_SOURCE_REPO" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "compose component traversal is refused"; else bad "compose component traversal is refused"; fi
has "$APPLY_OUT" "unsafe or missing compose source path" "source refusal identifies the bad compose component"
absent "$BAD_SOURCE_REPO/first.txt" "complete validation prevents partial earlier writes"

BAD_TARGET_REPO="$TMP/bad-target/repo"
mkdir -p "$HOME_DIR/templates/bad-target" "$BAD_TARGET_REPO/.claude"
printf 'bad-target\n' > "$BAD_TARGET_REPO/.claude/swarm-type"
printf 'compose | safe/a+safe/b | ../outside.txt\n' > "$HOME_DIR/templates/bad-target/manifest.tsv"
printf 'outside sentinel\n' > "$TMP/bad-target/outside.txt"
run_apply "$BAD_TARGET_REPO" init codex
if [ "$APPLY_RC" -ne 0 ]; then ok "relative target escape is refused"; else bad "relative target escape is refused"; fi
has "$APPLY_OUT" "unsafe manifest target path" "target refusal is explicit"
eq "outside sentinel" "$(cat "$TMP/bad-target/outside.txt")" "escaped target stays byte-unchanged"

echo ""
echo "=== symlinked source/target parents cannot cross containment ==="
EXTERNAL_SOURCE="$TMP/external-source"
mkdir -p "$EXTERNAL_SOURCE" "$HOME_DIR/templates/source-link" "$TMP/source-link-repo/.claude"
printf 'outside source\n' > "$EXTERNAL_SOURCE/payload"
ln -s "$EXTERNAL_SOURCE" "$HOME_DIR/templates/source-link/linked"
printf 'source-link\n' > "$TMP/source-link-repo/.claude/swarm-type"
printf 'refresh | source-link/linked/payload | copied.txt\n' > "$HOME_DIR/templates/source-link/manifest.tsv"
run_apply "$TMP/source-link-repo" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "template source symlink escape is refused"; else bad "template source symlink escape is refused"; fi
absent "$TMP/source-link-repo/copied.txt" "outside source is never copied"

TARGET_LINK_REPO="$TMP/target-link-repo"
TARGET_OUTSIDE="$TMP/target-outside"
mkdir -p "$HOME_DIR/templates/target-link" "$TARGET_LINK_REPO/.claude" "$TARGET_OUTSIDE"
printf 'target-link\n' > "$TARGET_LINK_REPO/.claude/swarm-type"
printf 'compose | safe/a+safe/b | linked/DOC.md\n' > "$HOME_DIR/templates/target-link/manifest.tsv"
ln -s "$TARGET_OUTSIDE" "$TARGET_LINK_REPO/linked"
run_apply "$TARGET_LINK_REPO" onboard codex 1
if [ "$APPLY_RC" -ne 0 ]; then ok "target parent symlink escape is refused in dry-run"; else bad "target parent symlink escape is refused in dry-run"; fi
absent "$TARGET_OUTSIDE/DOC.md" "dry-run cannot create through target symlink"
run_apply "$TARGET_LINK_REPO" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "target parent symlink escape is refused live"; else bad "target parent symlink escape is refused live"; fi
absent "$TARGET_OUTSIDE/DOC.md" "live apply cannot create through target symlink"

FINAL_LINK_REPO="$TMP/final-link-repo"
mkdir -p "$HOME_DIR/templates/final-link" "$FINAL_LINK_REPO/.claude"
printf 'final-link\n' > "$FINAL_LINK_REPO/.claude/swarm-type"
printf 'refresh | safe/a | linked-file\n' > "$HOME_DIR/templates/final-link/manifest.tsv"
printf 'outside target sentinel\n' > "$TMP/final-link-outside"
ln -s "$TMP/final-link-outside" "$FINAL_LINK_REPO/linked-file"
run_apply "$FINAL_LINK_REPO" sync claude
if [ "$APPLY_RC" -ne 0 ]; then ok "final refresh target symlink is refused"; else bad "final refresh target symlink is refused"; fi
has "$APPLY_OUT" "target is a symlink" "final-target refusal names the symlink"
eq "outside target sentinel" "$(cat "$TMP/final-link-outside")" "refresh cannot overwrite a symlink destination"

HARDLINK_REPO="$TMP/hardlink-repo"
mkdir -p "$HOME_DIR/templates/hardlink" "$HARDLINK_REPO/.claude"
printf 'hardlink\n' > "$HARDLINK_REPO/.claude/swarm-type"
printf 'refresh | safe/a | linked-file\n' > "$HOME_DIR/templates/hardlink/manifest.tsv"
printf 'outside hardlink sentinel\n' > "$TMP/hardlink-outside"
ln "$TMP/hardlink-outside" "$HARDLINK_REPO/linked-file"
run_apply "$HARDLINK_REPO" sync codex
if [ "$APPLY_RC" -ne 0 ]; then ok "final refresh target hard link is refused"; else bad "final refresh target hard link is refused"; fi
has "$APPLY_OUT" "target has 2 hard links" "hard-link refusal reports the alias count"
eq "outside hardlink sentinel" "$(cat "$TMP/hardlink-outside")" "refresh cannot truncate an outside hard-link alias"

FINAL_DIR_REPO="$TMP/final-dir-repo"
mkdir -p "$HOME_DIR/templates/final-dir" "$FINAL_DIR_REPO/.claude" "$FINAL_DIR_REPO/DOC.md"
printf 'final-dir\n' > "$FINAL_DIR_REPO/.claude/swarm-type"
printf 'compose | safe/a+safe/b | DOC.md\n' > "$HOME_DIR/templates/final-dir/manifest.tsv"
run_apply "$FINAL_DIR_REPO" init codex
if [ "$APPLY_RC" -ne 0 ]; then ok "non-regular final target is refused"; else bad "non-regular final target is refused"; fi
has "$APPLY_OUT" "target is not a regular file" "non-regular refusal is explicit"
eq 0 "$(find "$FINAL_DIR_REPO/DOC.md" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "compose cannot publish a staging child into a target directory"

GIT_POINTER_REPO="$TMP/git-pointer-repo"
mkdir -p "$HOME_DIR/templates/git-pointer" "$GIT_POINTER_REPO/.claude"
printf 'git-pointer\n' > "$GIT_POINTER_REPO/.claude/swarm-type"
printf 'git-hook | safe/a | .git/hooks/pre-commit\n' > "$HOME_DIR/templates/git-pointer/manifest.tsv"
printf 'gitdir: /tmp/example-worktree-gitdir\n' > "$GIT_POINTER_REPO/.git"
run_apply "$GIT_POINTER_REPO" check claude
if [ "$APPLY_RC" -ne 0 ]; then ok "git pointer parent fails closed"; else bad "git pointer parent fails closed"; fi
has "$APPLY_OUT" "is not a directory" "git pointer refusal explains unsupported hook parent"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
