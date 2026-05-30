#!/usr/bin/env bash
# test-launchd-template-substitution.sh — regression tests for the launchd
# plist TEMPLATE substitution (bin/swarm-launchd-install.sh).
#
# WHAT THIS PROTECTS. launchd doesn't expand $VARS/~ in plist paths, so the
# committed plists are TEMPLATES with @@SWARM_HOME@@ / @@HOME@@ / @@TMUX_BIN@@
# placeholders, rendered per machine. This pins:
#   - every placeholder is substituted (none survives — an un-substituted path
#     would silently break the agent on a differently-named account),
#   - the values land in the right fields,
#   - the rendered output is a valid plist (plutil -lint).
# It renders with DELIBERATELY FAKE $HOME and tmux paths to prove the result
# is username/host-agnostic, not accidentally tied to this machine.
#
# Run from $SWARM_HOME:  bash tests/test-launchd-template-substitution.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
assert_eq() { # expected got label
  if [ "$1" = "$2" ]; then printf '  PASS  %s\n' "$3"; PASS=$((PASS+1))
  else printf '  FAIL  expected=[%s] got=[%s]  %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (expected=[$1] got=[$2])"; fi
}
assert_contains() { # haystack-file needle label
  if grep -qF -- "$2" "$1"; then printf '  PASS  %s\n' "$3"; PASS=$((PASS+1))
  else printf '  FAIL  missing [%s] in %s  %s\n' "$2" "$1" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (missing [$2])"; fi
}
assert_absent() { # file pattern label
  if grep -q -- "$2" "$1"; then printf '  FAIL  unexpected [%s] in %s  %s\n' "$2" "$1" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (found [$2])"
  else printf '  PASS  %s\n' "$3"; PASS=$((PASS+1)); fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/launchd-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Deliberately fake, distinctive values — NOT this machine's real ones.
FAKE_HOME="/Users/somebodyelse"
FAKE_TMUX="/some/other/prefix/bin/tmux"

echo "=== render templates with fake HOME + tmux (proves host-agnostic) ==="
HOME="$FAKE_HOME" SWARM_TMUX_BIN="$FAKE_TMUX" SWARM_HOME="$ROOT" \
  bash "$ROOT/bin/swarm-launchd-install.sh" --render-only "$TMP" >/dev/null 2>"$TMP/err"
rc=$?
assert_eq 0 "$rc" "swarm-launchd-install --render-only exits 0"
[ "$rc" -ne 0 ] && cat "$TMP/err" >&2

# Derive the expected plist set from the ACTIVE templates (launchd/*.plist.template),
# mirroring swarm-launchd-install.sh's own glob. A template renamed to
# *.plist.template.disabled (e.g. swarm-watch, whose heartbeat is intentionally
# off — see "launchd: disable swarm-watch heartbeat") is excluded by the glob,
# so this test tracks whatever is actually active instead of hardcoding a fixed
# set that drifts the moment a template is enabled/disabled.
shopt -s nullglob 2>/dev/null || true
EXPECTED_BASES=""   # space-separated; plist basenames never contain spaces
for tmpl in "$ROOT"/launchd/*.plist.template; do
  b="$(basename "$tmpl")"; EXPECTED_BASES="$EXPECTED_BASES ${b%.template}"
done
assert_eq "1" "$([ -n "$EXPECTED_BASES" ] && echo 1 || echo 0)" "at least one active *.plist.template in launchd/"

for base in $EXPECTED_BASES; do
  out="$TMP/$base"
  if [ ! -f "$out" ]; then
    assert_eq "exists" "MISSING" "$base rendered"
    continue
  fi
  assert_eq "exists" "exists" "$base rendered"
  # THE load-bearing assertion: no placeholder survives.
  assert_absent "$out" "@@" "$base: no @@ placeholder survives"
  # SWARM_HOME substituted into the script path. The script name is the plist
  # label minus the com.qofi. prefix and .plist suffix (swarm-watch/swarm-typing).
  script_name="${base#com.qofi.}"; script_name="${script_name%.plist}"
  assert_contains "$out" "$ROOT/bin/${script_name}.sh" "$base: script path uses \$SWARM_HOME"
  assert_contains "$out" "<string>$ROOT</string>" "$base: SWARM_HOME env value substituted"
  # HOME substituted into log + projects paths (fake value, not real machine).
  assert_contains "$out" "$FAKE_HOME/.config/swarm/" "$base: log path uses \$HOME"
  assert_contains "$out" "$FAKE_HOME/.claude/projects" "$base: CLAUDE_PROJECTS_DIR uses \$HOME"
  # tmux path substituted.
  assert_contains "$out" "<string>$FAKE_TMUX</string>" "$base: SWARM_TMUX_BIN substituted"
  # Valid plist.
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$out" >/dev/null 2>&1; then assert_eq 0 0 "$base: plutil -lint passes"
    else assert_eq 0 1 "$base: plutil -lint passes"; fi
  fi
done

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
