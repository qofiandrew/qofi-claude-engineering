#!/usr/bin/env bash
# test-swarm-account-resolve.sh — the multi-account resolver (Phase 1).
#
# swarm_account_resolve LABEL is the SINGLE SOURCE OF TRUTH that maps an account
# label to its config dir / projects dir / access.json / vault token-var. These
# tests pin:
#   - the EMPTY label = today's behavior, BYTE-FOR-BYTE (the inert default), so a
#     no-label fleet is provably unchanged;
#   - a <label> → isolated config dir + OAUTH_TOKEN_<UPPER> (dash→underscore);
#   - a malformed label is REJECTED (exit 2) BEFORE any path is built — a bad
#     label must never name a directory.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account-resolve.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../bin/swarm-lib.sh
. "$ROOT/bin/swarm-lib.sh"

PASS=0; FAIL=0; FAILURES=""
assert_eq() {  # expected got label
  if [ "$1" = "$2" ]; then printf '  PASS  [%s] %s\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  expected=[%s] got=[%s]  %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1))
    FAILURES="${FAILURES}
  - $3 (expected=[$1] got=[$2])"; fi
}

# ---------------------------------------------------------------------------
# 1) EMPTY label = the default account = today's behavior, BYTE-FOR-BYTE.
#    The expected values are the literal paths the consumers hardcode today
#    ($HOME/.claude, .../projects, .../channels/discord/access.json) — so this
#    asserts the inert-default guarantee at the resolver.
# ---------------------------------------------------------------------------
echo "=== empty label → default account (byte-identical to today; overrides UNSET) ==="
unset CLAUDE_PROJECTS_DIR SWARM_ACCESS_FILE 2>/dev/null || true
swarm_account_resolve ""; rc=$?
assert_eq 0 "$rc" "empty label resolves (rc 0)"
assert_eq "$HOME/.claude"                                "$SWARM_ACCT_CONFIG_DIR"   "default CONFIG_DIR = \$HOME/.claude"
assert_eq "$HOME/.claude/projects"                       "$SWARM_ACCT_PROJECTS_DIR" "default PROJECTS = \$HOME/.claude/projects"
assert_eq "$HOME/.claude/channels/discord/access.json"   "$SWARM_ACCT_ACCESS_FILE"  "default ACCESS = \$HOME/.claude/channels/discord/access.json"
assert_eq ""                                             "$SWARM_ACCT_TOKEN_VAR"    "default TOKEN_VAR empty (keychain auth, no token export)"

# No-arg call resolves the default too (defensive: a caller may omit the arg).
swarm_account_resolve; rc=$?
assert_eq 0 "$rc" "no-arg call resolves (rc 0)"
assert_eq "$HOME/.claude" "$SWARM_ACCT_CONFIG_DIR" "no-arg → default CONFIG_DIR"

# ---------------------------------------------------------------------------
# 1b) The DEFAULT account PRESERVES the env overrides consumers honor today —
#     CLAUDE_PROJECTS_DIR (WORKING-rail) and SWARM_ACCESS_FILE. Dropping these
#     would point the WORKING-rail check at the real ~/.claude even when a test
#     fixture redirected it → a live swarm silently looks stale.
# ---------------------------------------------------------------------------
echo "=== default honors CLAUDE_PROJECTS_DIR + SWARM_ACCESS_FILE overrides ==="
CLAUDE_PROJECTS_DIR="/tmp/fixture-projects"; swarm_account_resolve ""; unset CLAUDE_PROJECTS_DIR
assert_eq "/tmp/fixture-projects"   "$SWARM_ACCT_PROJECTS_DIR" "empty label honors CLAUDE_PROJECTS_DIR override"
SWARM_ACCESS_FILE="/tmp/fixture-access.json"; swarm_account_resolve ""; unset SWARM_ACCESS_FILE
assert_eq "/tmp/fixture-access.json" "$SWARM_ACCT_ACCESS_FILE"  "empty label honors SWARM_ACCESS_FILE override"

echo "=== labeled account ignores the default-only overrides ==="
CLAUDE_PROJECTS_DIR="/tmp/fixture-projects"; SWARM_ACCESS_FILE="/tmp/fixture-access.json"
swarm_account_resolve "maxa"
unset CLAUDE_PROJECTS_DIR SWARM_ACCESS_FILE
assert_eq "$HOME/.claude-accounts/maxa/projects"                     "$SWARM_ACCT_PROJECTS_DIR" "labeled PROJECTS ignores CLAUDE_PROJECTS_DIR"
assert_eq "$HOME/.claude-accounts/maxa/channels/discord/access.json" "$SWARM_ACCT_ACCESS_FILE"  "labeled ACCESS ignores SWARM_ACCESS_FILE"

# ---------------------------------------------------------------------------
# 2) A <label> → isolated config dir + OAUTH_TOKEN_<UPPER>.
# ---------------------------------------------------------------------------
echo "=== labeled account → isolated dir + token var ==="
swarm_account_resolve "maxa"; rc=$?
assert_eq 0 "$rc" "label 'maxa' resolves (rc 0)"
assert_eq "$HOME/.claude-accounts/maxa"                              "$SWARM_ACCT_CONFIG_DIR"   "CONFIG_DIR under .claude-accounts/<label>"
assert_eq "$HOME/.claude-accounts/maxa/projects"                     "$SWARM_ACCT_PROJECTS_DIR" "PROJECTS under the account dir"
assert_eq "$HOME/.claude-accounts/maxa/channels/discord/access.json" "$SWARM_ACCT_ACCESS_FILE"  "ACCESS under the account dir"
assert_eq "OAUTH_TOKEN_MAXA"                                         "$SWARM_ACCT_TOKEN_VAR"    "TOKEN_VAR = OAUTH_TOKEN_<UPPER>"

# Dash and lowercase: 'max-b' → OAUTH_TOKEN_MAX_B (upper + dash→underscore).
echo "=== label normalization (lowercase + dash→underscore) ==="
swarm_account_resolve "max-b"
assert_eq "$HOME/.claude-accounts/max-b" "$SWARM_ACCT_CONFIG_DIR" "dash kept in the DIR (filesystem-legal)"
assert_eq "OAUTH_TOKEN_MAX_B"            "$SWARM_ACCT_TOKEN_VAR"  "dash→underscore + upper in the VAR name"
swarm_account_resolve "Primary_2"
assert_eq "OAUTH_TOKEN_PRIMARY_2"        "$SWARM_ACCT_TOKEN_VAR"  "mixed-case + underscore label → OAUTH_TOKEN_PRIMARY_2"

# ---------------------------------------------------------------------------
# 3) Malformed labels are REJECTED (rc 2) — and must not have built a path.
# ---------------------------------------------------------------------------
echo "=== malformed labels rejected before any path is built ==="
for bad in "1leading" "bad/slash" "../escape" "has space" "semi;colon" '$inject' "dot.dot"; do
  # Seed a sentinel so we can prove the resolver did NOT overwrite the globals.
  SWARM_ACCT_CONFIG_DIR="__UNSET__"
  swarm_account_resolve "$bad" 2>/dev/null; rc=$?
  assert_eq 2 "$rc" "malformed label '$bad' → rc 2 (rejected)"
  assert_eq "__UNSET__" "$SWARM_ACCT_CONFIG_DIR" "malformed label '$bad' built NO path (globals untouched)"
done

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
