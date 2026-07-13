#!/usr/bin/env bash
# test-dod-affirm-format.sh — regression tests for the DoD-line FORMAT the
# dod-affirm.sh TaskCompleted gate accepts (issue #54(a)).
#
# The bug this pins: the commit-summary template renders each item as
#     [DoD-2] Tests: yes | n/a:<reason>
# where "|" means OR — but agents legitimately read it as a separator and
# write "yes | 42 passing, suite green". The old pattern
#     ^\[DoD-n\] Label: (yes|n/a:.+)$
# rejected every such line, false-BLOCKING completions whose affirmation was
# genuinely present. The fix accepts "yes" optionally followed by "| <detail>"
# WITHOUT weakening the gate: the leading verdict token is still mandatory,
# still anchored to the exact tag, and a missing/mangled line still BLOCKS.
#
# Pure git + bash + python3. Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/templates/engineering-cto/hooks/dod-affirm.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found: $HOOK" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dod-fmt.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
FIXED_GIT_DATE="2000-01-01T00:00:00Z"

# A minimal git repo so the payload cwd resolves to a real work tree. Every
# commit shares one timestamp to reproduce Git's one-second ordering tie.
git -C "$WORK" init -q -b dev
env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"

PASS=0; FAIL=0

# run <expected-exit> <summary-text> <label>
run() {
  local want="$1" summary="$2" label="$3" ev out rc
  ev="$(python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1], "summary": sys.argv[2]}))' "$WORK" "$summary")"
  out="$(printf '%s' "$ev" | bash "$HOOK" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  PASS  %s (exit %s)\n' "$label" "$rc"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (want exit %s, got %s)\n%s\n' "$label" "$want" "$rc" "$out"; FAIL=$((FAIL+1))
  fi
}

# Build a six-line block; $1 substitutes the Tests line, $2 the Docs line.
block() {
  printf '[DoD-1] Contract: yes\n%s\n%s\n[DoD-4] Operability: n/a:doc-only\n[DoD-5] Scale: n/a:not at-scale\n[DoD-6] No conflicts: yes\n' \
    "${1:-[DoD-2] Tests: yes}" "${2:-[DoD-3] Docs: yes}"
}

echo "=== plain forms still accepted ==="
run 0 "$(block)" "bare 'yes' + 'n/a:<reason>' block passes"

echo ""
echo "=== the #54(a) regression: 'yes | <detail>' is an affirmation, not a malformed line ==="
run 0 "$(block '[DoD-2] Tests: yes | 42 passing, suite green')" "yes | <detail> accepted"
run 0 "$(block '[DoD-2] Tests: yes|no new tests needed beyond existing')" "yes|<detail> (no spaces) accepted"
run 0 "$(block '[DoD-2] Tests: yes | n/a:<reason>')" "verbatim template tail after 'yes' accepted (verdict token is yes)"

echo ""
echo "=== gate NOT weakened ==="
run 2 "$(block '[DoD-2] Tests: no | suite red')" "'no | detail' still BLOCKS"
run 2 "$(block '[DoD-2] Tests: yessir')" "'yessir' still BLOCKS (token anchored)"
run 2 "$(block '[DoD-2] Tests: n/a')" "bare 'n/a' without reason still BLOCKS"
run 2 "$(printf '[DoD-1] Contract: yes\n[DoD-2] Tests: yes\n')" "missing lines still BLOCK"
run 2 "$(block '[DoD-2] Tests: maybe | yes')" "'maybe | yes' still BLOCKS (verdict must lead)"

echo ""
echo "=== merge-wrapper blindness: DoD lines on the feature commit under a --no-ff merge still satisfy the gate ==="
# Repro of the live false-block (2026-07-09/10): work commits carry the DoD
# block, the branch is merged --no-ff, so HEAD is a merge commit WITHOUT the
# lines. The hook must read the newest non-merge commit introduced on the
# merged side, blind to the merge wrapper but not open to stale base history.
git -C "$WORK" -c user.email=t@t -c user.name=t checkout -q -b feat-dod
env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: thing

$(block)"
git -C "$WORK" -c user.email=t@t -c user.name=t checkout -q dev
env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
  git -C "$WORK" -c user.email=t@t -c user.name=t merge -q --no-ff feat-dod -m "merge: thing"
run 0 "" "empty summary + DoD-stamped feature commit under a --no-ff merge PASSES"
# And the fix does not weaken the gate: a merge atop a feature commit that
# LACKS the lines still blocks on an empty summary.
git -C "$WORK" -c user.email=t@t -c user.name=t checkout -q -b feat-nodod
env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: unaffirmed thing"
git -C "$WORK" -c user.email=t@t -c user.name=t checkout -q dev
env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
  git -C "$WORK" -c user.email=t@t -c user.name=t merge -q --no-ff feat-nodod -m "merge: unaffirmed thing"
run 2 "" "merge atop an UNaffirmed feature commit still BLOCKS on an empty summary"

echo ""
printf 'dod-affirm-format: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
