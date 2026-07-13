#!/usr/bin/env bash
# test-conf-rewrite-account.sh — swarm_conf_set_account (Phase 3, tightening #2).
#
# swarm_conf_set_account CONF NAME ACCOUNT atomically rewrites field 6 (ACCOUNT)
# of one swarm.conf row, the durable persistence of a failover swap (ADR-0018).
# These tests pin the ARITY safety the rewrite must hold across legacy widths:
#   - the account lands in field 6 on 4-, 5-, and 6-column rows (short rows are
#     PADDED so positions don't shift);
#   - the target row's OTHER fields (name/repo/tok/channel/guild) are preserved;
#   - comments, blank lines, and every NON-target row are preserved verbatim;
#   - an empty ACCOUNT restores the default (drops field 6, ≤5-col verbatim);
#   - a name that matches no row leaves the conf untouched (return 1).
#
# Run from $SWARM_HOME:  bash tests/test-conf-rewrite-account.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../bin/swarm-lib.sh
. "$ROOT/bin/swarm-lib.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/conf-rewrite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Read the (trimmed) account field (6) of the row named $2 in conf $1.
acct_of() { awk -F'|' -v n="$2" '
  /^[[:space:]]*(#|$)/ { next }
  { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v==n) { a=$6; gsub(/^[ \t]+|[ \t]+$/,"",a); print a; exit } }
' "$1"; }
# Read trimmed field N of the row named $2.
field_of() { awk -F'|' -v n="$2" -v f="$3" '
  /^[[:space:]]*(#|$)/ { next }
  { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v==n) { a=$f; gsub(/^[ \t]+|[ \t]+$/,"",a); print a; exit } }
' "$1"; }

# ---------------------------------------------------------------------------
# Fixture: a 4-col, a 5-col, and a 6-col row, with a comment + blank line and a
# trailing comment so we can prove ALL surrounding content survives a rewrite.
# ---------------------------------------------------------------------------
make_conf() {
  cat > "$1" <<'EOF'
# swarm.conf fixture — name | repo | tok | channel | guild | account
four | /r/four | BOT_FOUR | 111
five | /r/five | BOT_FIVE | 222 | 555

six  | /r/six  | BOT_SIX  | 333 | 666 | oldacct
codex | /r/codex | BOT_CODEX | 444 | 777 | oldacct | codex
explicit | /r/explicit | BOT_EXPLICIT | 555 | 888 | oldacct | claude | premium-a
# trailing comment
EOF
}

# ---------------------------------------------------------------------------
# 1) Rewrite a 6-column row: field 6 replaced, all else preserved.
# ---------------------------------------------------------------------------
echo "=== 6-col row: replace existing account ==="
# Keep one deliberately redundant separator: macOS TMPDIR commonly ends in
# `/`, and the strict atomic lock publisher must not regress historical Claude
# callers merely because they construct an equivalent path spelling.
CONF="$TMP//c6.conf"; make_conf "$CONF"
ORIG="$(cat "$CONF")"
swarm_conf_set_account "$CONF" "six" "maxb"; rc=$?
assert_eq 0 "$rc" "rewrite of existing 6-col row returns 0"
assert_eq "maxb"     "$(acct_of "$CONF" six)"  "six.account replaced -> maxb"
assert_eq "/r/six"   "$(field_of "$CONF" six 2)" "six.repo preserved"
assert_eq "BOT_SIX"  "$(field_of "$CONF" six 3)" "six.tokvar preserved"
assert_eq "333"      "$(field_of "$CONF" six 4)" "six.channel preserved"
assert_eq "666"      "$(field_of "$CONF" six 5)" "six.guild preserved"
# Other rows + comments + blank line untouched.
assert_eq "$(printf '%s' "$ORIG" | grep -c '^#')" "$(grep -c '^#' "$CONF")" "comment lines count unchanged"
assert_eq ""         "$(acct_of "$CONF" four)" "four (untouched row) still has no account"
assert_eq "555"      "$(field_of "$CONF" five 5)" "five (untouched row) guild preserved"

# ---------------------------------------------------------------------------
# 2) Rewrite a 5-column row (no account yet): account appended into field 6.
# ---------------------------------------------------------------------------
echo "=== 5-col row: append account into field 6 ==="
CONF="$TMP/c5.conf"; make_conf "$CONF"
swarm_conf_set_account "$CONF" "five" "maxa"; rc=$?
assert_eq 0 "$rc" "rewrite of 5-col row returns 0"
assert_eq "maxa"     "$(acct_of "$CONF" five)"  "five.account set -> maxa (field 6)"
assert_eq "/r/five"  "$(field_of "$CONF" five 2)" "five.repo preserved"
assert_eq "222"      "$(field_of "$CONF" five 4)" "five.channel preserved"
assert_eq "555"      "$(field_of "$CONF" five 5)" "five.guild preserved (NOT clobbered by the new field 6)"

# ---------------------------------------------------------------------------
# 3) Rewrite a 4-column row (no guild, no account): padded so account lands in 6.
# ---------------------------------------------------------------------------
echo "=== 4-col row: pad guild, account lands in field 6 ==="
CONF="$TMP/c4.conf"; make_conf "$CONF"
swarm_conf_set_account "$CONF" "four" "maxc"; rc=$?
assert_eq 0 "$rc" "rewrite of 4-col row returns 0"
assert_eq "maxc"     "$(acct_of "$CONF" four)"  "four.account set -> maxc (field 6, not field 5)"
assert_eq ""         "$(field_of "$CONF" four 5)" "four.guild is empty (padded), NOT the account"
assert_eq "/r/four"  "$(field_of "$CONF" four 2)" "four.repo preserved"
assert_eq "BOT_FOUR" "$(field_of "$CONF" four 3)" "four.tokvar preserved"
assert_eq "111"      "$(field_of "$CONF" four 4)" "four.channel preserved"

# ---------------------------------------------------------------------------
# 4) Empty account restores the default: 6-col row loses field 6; 4/5-col verbatim.
# ---------------------------------------------------------------------------
echo "=== empty account restores default (drops field 6) ==="
CONF="$TMP/creset.conf"; make_conf "$CONF"
swarm_conf_set_account "$CONF" "six" ""; rc=$?
assert_eq 0 "$rc" "reset (empty account) on a 6-col row returns 0"
assert_eq ""        "$(acct_of "$CONF" six)" "six.account dropped -> default (empty)"
assert_eq "666"     "$(field_of "$CONF" six 5)" "six.guild still field 5 after dropping account"
# A row that is ALREADY default (4-col) is left verbatim by an empty-account write.
BEFORE4="$(grep '^four' "$CONF")"
swarm_conf_set_account "$CONF" "four" ""
assert_eq "$BEFORE4" "$(grep '^four' "$CONF")" "empty-account write on an already-default row is a verbatim no-op"

# ---------------------------------------------------------------------------
# 5) Unknown name: conf untouched, return 1.
# ---------------------------------------------------------------------------
echo "=== unknown name: no change, return 1 ==="
CONF="$TMP/cmiss.conf"; make_conf "$CONF"
BEFORE="$(cat "$CONF")"
swarm_conf_set_account "$CONF" "nope" "maxa"; rc=$?
assert_eq 1 "$rc" "unknown name returns 1"
assert_eq "$BEFORE" "$(cat "$CONF")" "conf is byte-for-byte unchanged on a missed name"
# No stray temp files left behind.
assert_eq "0" "$(find "$TMP" -name '*.conf.tmp.*' | wc -l | tr -d ' ')" "no leftover .tmp files"

# ---------------------------------------------------------------------------
# 6) The rewritten row still round-trips through swarm_conf_parse_line cleanly.
# ---------------------------------------------------------------------------
echo "=== rewritten row re-parses with the right account ==="
CONF="$TMP/cparse.conf"; make_conf "$CONF"
swarm_conf_set_account "$CONF" "four" "primary-2"
while IFS= read -r _l; do
  swarm_conf_parse_line "$_l" || continue
  if [ "$SWARM_CONF_F_NAME" = "four" ]; then
    assert_eq "primary-2" "$SWARM_CONF_F_ACCOUNT" "parser reads the rewritten account on 'four'"
    assert_eq "/r/four"   "$SWARM_CONF_F_REPO"    "parser reads the preserved repo on 'four'"
    assert_eq ""          "$SWARM_CONF_F_GUILD"   "parser reads the padded-empty guild on 'four'"
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

# ---------------------------------------------------------------------------
# 7) Clearing ACCOUNT on engine-aware rows preserves the empty field-6 slot;
#    ENGINE and CODEX_AUTH_POOL must never shift left.
# ---------------------------------------------------------------------------
echo "=== empty account preserves ENGINE + CODEX_AUTH_POOL ==="
CONF="$TMP/cengine.conf"; make_conf "$CONF"
swarm_conf_set_account "$CONF" "codex" ""
assert_eq ""       "$(field_of "$CONF" codex 6)" "Codex row keeps an empty ACCOUNT field"
assert_eq "codex"  "$(field_of "$CONF" codex 7)" "Codex ENGINE remains in field 7"
swarm_conf_set_account "$CONF" "explicit" ""
assert_eq ""        "$(field_of "$CONF" explicit 6)" "explicit-Claude row keeps an empty ACCOUNT field"
assert_eq "claude"  "$(field_of "$CONF" explicit 7)" "explicit Claude ENGINE remains in field 7"
assert_eq "premium-a" "$(field_of "$CONF" explicit 8)" "CODEX_AUTH_POOL remains in field 8"
while IFS= read -r _l; do
  swarm_conf_parse_line "$_l" || continue
  case "$SWARM_CONF_F_NAME" in
    codex) assert_eq "codex" "$SWARM_CONF_F_ENGINE" "parser still dispatches cleared Codex row to Codex" ;;
    explicit) assert_eq "claude" "$SWARM_CONF_F_ENGINE" "parser still dispatches explicit Claude row to Claude" ;;
  esac
done < "$CONF"

# ---------------------------------------------------------------------------
# 8) A field-8 pool update never reuses or shifts Claude ACCOUNT / ENGINE.
# ---------------------------------------------------------------------------
echo "=== CODEX_AUTH_POOL rewrite is field-8-only ==="
CONF="$TMP/cpool.conf"; make_conf "$CONF"
swarm_conf_set_codex_auth_pool "$CONF" "codex" "premium-a"; rc=$?
assert_eq 0 "$rc" "pool rewrite returns 0"
assert_eq "oldacct" "$(field_of "$CONF" codex 6)" "pool update preserves dormant ACCOUNT"
assert_eq "codex" "$(field_of "$CONF" codex 7)" "pool update preserves ENGINE"
assert_eq "premium-a" "$(field_of "$CONF" codex 8)" "pool update writes CODEX_AUTH_POOL field 8"
swarm_conf_set_codex_auth_pool "$CONF" "four" "default"; rc=$?
assert_eq 0 "$rc" "pool rewrite pads a legacy row"
assert_eq "" "$(field_of "$CONF" four 5)" "legacy pool padding preserves empty GUILD"
assert_eq "" "$(field_of "$CONF" four 6)" "legacy pool padding preserves empty ACCOUNT"
assert_eq "" "$(field_of "$CONF" four 7)" "legacy pool padding preserves empty ENGINE"
assert_eq "default" "$(field_of "$CONF" four 8)" "legacy pool lands only in field 8"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
