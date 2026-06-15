#!/usr/bin/env bash
# test-account-paths-sole-constructor.sh — REPO-WIDE backstop (tightening #1).
#
# swarm_account_resolve (bin/swarm-lib.sh) is the SINGLE allowed constructor of a
# Claude config/projects/access path ($HOME/.claude*, .claude-accounts/*,
# .claude/projects, .claude/channels). Any OTHER bin/ script that hand-builds one
# bypasses per-account resolution → under multi-account it reads the WRONG
# account's transcripts → the WORKING rail (repo_activity) disarms → a live swarm
# is silently killed. The manual sweep found ~9 sites; this assert is the net
# that guarantees there isn't a 10th (now or in a future edit).
#
# It is a STATIC grep over bin/*.sh: strip comments, then any remaining
# construction of those paths in a file OTHER than swarm-lib.sh is a failure.
#
# Run from $SWARM_HOME:  bash tests/test-account-paths-sole-constructor.sh
# Exit 0 = the resolver is the sole constructor. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# The path shapes only the resolver may construct.
PAT='\$HOME/\.claude|~/\.claude|\.claude-accounts|\.claude/projects|\.claude/channels'

# Strip comments before matching (line numbers preserved by blanking, not
# deleting): first blank a FULL-LINE comment (optional indent then '#'); then
# strip an INLINE ' #...' comment (a space before the hash — so it never eats a
# `${VAR#pattern}` expansion, which has no space). A surviving PAT hit is real
# code, not documentation.
STRIP='s/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//'
offenders=""
for f in bin/*.sh; do
  case "$f" in */swarm-lib.sh) continue ;; esac   # the sole legitimate constructor
  hits="$(sed -E "$STRIP" "$f" | grep -nE "$PAT" || true)"
  [ -n "$hits" ] && offenders="${offenders}
--- $f ---
$hits"
done

PASS=0; FAIL=0
if [ -z "$offenders" ]; then
  echo "  ok   no bin/ script outside swarm-lib.sh constructs a .claude path (resolver is sole constructor)"
  PASS=$((PASS+1))
else
  echo "  FAIL — a .claude path is hand-constructed OUTSIDE swarm_account_resolve:" >&2
  printf '%s\n' "$offenders" | sed 's/^/    /' >&2
  echo "    → route it through swarm_account_resolve (swarm-lib.sh); a bare path is a WORKING-rail landmine." >&2
  FAIL=$((FAIL+1))
fi

# Positive control: the resolver DOES construct them (so the pattern is live and
# this test can't pass vacuously if the resolver were gutted/renamed).
# grep -c (reads all input) not grep -q (closes the pipe early → SIGPIPEs sed →
# pipefail reports the pipeline non-zero even on a match).
lib_paths="$(sed -E "$STRIP" bin/swarm-lib.sh | grep -cE "$PAT" || true)"
if grep -q 'swarm_account_resolve()' bin/swarm-lib.sh && [ "${lib_paths:-0}" -gt 0 ]; then
  echo "  ok   swarm_account_resolve present and constructs the account paths"
  PASS=$((PASS+1))
else
  echo "  FAIL — swarm_account_resolve missing or no longer constructs the paths (test would be vacuous)" >&2
  FAIL=$((FAIL+1))
fi

echo ""
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
