#!/usr/bin/env bash
# test-conf-parse-arity.sh — regression tests for the swarm.conf column-arity
# bug and its fix (the shared swarm_conf_parse_line helper in swarm-lib.sh).
#
# THE BUG (class): swarm.conf rows are positional, pipe-delimited
#     name | repo | tokvar | channel | guild_id
# but several readers did their own `IFS='|' read -r name repo tokvar channel`
# with a FIXED arity SHORTER than the file's column count. Bash's last `read`
# variable absorbs every trailing field INCLUDING the delimiter, so once the
# 5th (guild_id) column landed:
#
#   - swarm-attention: `channel` became "<channel> | <guild_id>" → failed its
#     all-digits validation → `raise`/`clear` exited 1. The attention flag was
#     dead for every swarm with a guild_id (reserve-backend-2, qofi-ios-app).
#   - swarm-typing: the typing URL became
#     "/channels/<channel> | <guild_id>/typing" → typing indicators broken.
#
# THE FIX: parse a row in ONE place (swarm_conf_parse_line) that splits into
# the full known arity PLUS a trailing `_rest` catch-all, so the last *named*
# field can never swallow an unknown future column.
#
# These tests pin BOTH the concrete fix (channel is clean today) AND the
# class-level guarantee (a future 6th column does not corrupt guild_id, and no
# reader has regressed to a fixed-arity conf read).
#
# Run from $SWARM_HOME:
#     bash tests/test-conf-parse-arity.sh
#
# Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../bin/swarm-lib.sh
. "$ROOT/bin/swarm-lib.sh"

PASS=0
FAIL=0
FAILURES=""

assert_eq() {  # expected got label
  local expected="$1" got="$2" label="$3"
  if [ "$expected" = "$got" ]; then
    printf '  PASS  [%s] %s\n' "$expected" "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  expected=[%s] got=[%s]  %s\n' "$expected" "$got" "$label" >&2
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}
  - $label  (expected=[$expected], got=[$got])"
  fi
}

assert_rc() {  # expected_rc got_rc label
  assert_eq "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# 1) Current 5-column schema — every field lands where it should, trimmed.
# ---------------------------------------------------------------------------
echo "=== 5-column row (current schema) ==="
swarm_conf_parse_line "acme | /Users/me/code/acme | BOT_ACME | 111222333444555666 | 999888777666555444"
rc=$?
assert_rc 0 "$rc"                                   "parse returns 0 for a data row"
assert_eq "acme"                "$SWARM_CONF_F_NAME"    "name"
assert_eq "/Users/me/code/acme" "$SWARM_CONF_F_REPO"    "repo"
assert_eq "BOT_ACME"            "$SWARM_CONF_F_TOKVAR"  "tokvar"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "channel is JUST the channel (the bug)"
assert_eq "999888777666555444" "$SWARM_CONF_F_GUILD"   "guild_id"

# ---------------------------------------------------------------------------
# 2) THE FUTURE-COLUMN GUARANTEE — a 6th column (e.g. a future 'type') must
#    NOT corrupt guild_id. This is what protects the next column we add.
# ---------------------------------------------------------------------------
echo "=== 6-column row (a hypothetical future column) ==="
swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666 | 999888777666555444 | engineering-cto"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "channel uncorrupted by a 6th column"
assert_eq "999888777666555444" "$SWARM_CONF_F_GUILD"   "guild_id uncorrupted by a 6th column (lands in _rest)"

# ---------------------------------------------------------------------------
# 3) Legacy 4-column row (no guild_id yet) — back-compat: channel still clean,
#    guild empty.
# ---------------------------------------------------------------------------
echo "=== 4-column row (pre-guild_id, back-compat) ==="
swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "channel clean with no 5th column"
assert_eq ""                   "$SWARM_CONF_F_GUILD"   "guild empty when absent"

# ---------------------------------------------------------------------------
# 4) Whitespace handling — fields are trimmed regardless of padding.
# ---------------------------------------------------------------------------
echo "=== whitespace tolerance ==="
swarm_conf_parse_line "   acme   |/p|BOT_ACME|   111222333444555666   |999"
assert_eq "acme"               "$SWARM_CONF_F_NAME"    "leading/trailing spaces trimmed (name)"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "spaces trimmed (channel)"

# ---------------------------------------------------------------------------
# 5) Comment / blank lines — parse returns non-zero so callers `continue`.
# ---------------------------------------------------------------------------
echo "=== comment / blank lines ==="
swarm_conf_parse_line "# this is a comment"; assert_rc 1 "$?" "comment line → return 1"
swarm_conf_parse_line "   # indented comment"; assert_rc 1 "$?" "indented comment → return 1"
swarm_conf_parse_line ""; assert_rc 1 "$?" "blank line → return 1"
swarm_conf_parse_line "    "; assert_rc 1 "$?" "whitespace-only line → return 1"

# ---------------------------------------------------------------------------
# 6) THE LIVE CONFIG — every real row in swarm.conf must yield a clean,
#    all-digits-or-empty channel and guild (no embedded '|'). This is the
#    exact invariant the bug violated for the two existing swarms; it asserts
#    against the live file without hardcoding snowflake IDs.
# ---------------------------------------------------------------------------
echo "=== live swarm.conf rows ==="
CONF="$ROOT/swarm.conf"
if [ -f "$CONF" ]; then
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    nm="$SWARM_CONF_F_NAME"
    case "$SWARM_CONF_F_CHANNEL" in
      *'|'*|*' '*) clean_chan=0 ;;
      *) clean_chan=1 ;;
    esac
    assert_eq 1 "$clean_chan" "live row '$nm': channel has no embedded '|' or space"
    echo "$SWARM_CONF_F_CHANNEL" | grep -qE '^[0-9]+$' && digit_chan=1 || digit_chan=0
    assert_eq 1 "$digit_chan" "live row '$nm': channel is all-digits"
    case "$SWARM_CONF_F_GUILD" in
      *'|'*) clean_guild=0 ;;
      *) clean_guild=1 ;;
    esac
    assert_eq 1 "$clean_guild" "live row '$nm': guild has no embedded '|'"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
else
  echo "  (skip: $CONF not present)"
fi

# ---------------------------------------------------------------------------
# 7) STRUCTURAL GUARD — every swarm.conf reader uses the shared helper, and
#    none has regressed to a fixed-arity `IFS='|' read` of the conf fields.
#    This is what catches a FUTURE reader (or a future column) reintroducing
#    the bug. swarm-restart/swarm-aliases parse by awk index / name+catch-all
#    (inherently arity-robust) and are intentionally exempt from the "uses
#    helper" check, but must still never use the fragile fixed-arity pattern.
# ---------------------------------------------------------------------------
echo "=== structural: readers use the shared helper, none use fixed-arity ==="
for f in swarm-up swarm-sync swarm-typing swarm-watch swarm-attention; do
  if grep -q "swarm_conf_parse_line" "$ROOT/bin/$f.sh"; then uses=1; else uses=0; fi
  assert_eq 1 "$uses" "bin/$f.sh routes conf parsing through swarm_conf_parse_line"
done

# Forbid the exact fragile arities the bug came from, in ANY bin script other
# than the lib that legitimately defines the canonical read.
fragile=0
fragile_hits="$(grep -rnE "IFS='\\|'[[:space:]]+read -r (name repo tokvar channel|n r t c)" "$ROOT/bin" 2>/dev/null \
  | grep -v 'swarm-lib.sh' || true)"
[ -n "$fragile_hits" ] && fragile=1
if [ "$fragile" -eq 1 ]; then
  printf '  fixed-arity conf reads still present:\n%s\n' "$fragile_hits" >&2
fi
assert_eq 0 "$fragile" "no bin script uses a fixed-arity 4-var conf read"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
