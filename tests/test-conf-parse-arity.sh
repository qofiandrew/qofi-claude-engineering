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
assert_eq ""                    "$SWARM_CONF_F_ACCOUNT" "account empty in a 5-column (no ACCOUNT) row"
assert_eq "claude"              "$SWARM_CONF_F_ENGINE" "legacy blank engine resolves to Claude"
assert_eq "default"             "$SWARM_CONF_F_CODEX_AUTH_POOL" "legacy blank field 8 resolves to default pool"

# ---------------------------------------------------------------------------
# 2) ACCOUNT is field 6 — a 6-column row populates SWARM_CONF_F_ACCOUNT and
#    leaves guild_id (field 5) clean. ENGINE is field 7, CODEX_AUTH_POOL is
#    field 8, and the FUTURE-COLUMN GUARANTEE sits at field 9.
# ---------------------------------------------------------------------------
echo "=== 6-column row (ACCOUNT is field 6) ==="
swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666 | 999888777666555444 | max-a"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "channel uncorrupted by the ACCOUNT column"
assert_eq "999888777666555444" "$SWARM_CONF_F_GUILD"   "guild_id uncorrupted by the ACCOUNT column"
assert_eq "max-a"              "$SWARM_CONF_F_ACCOUNT" "ACCOUNT captured from field 6"

echo "=== 7/8/9-column rows (ENGINE, CODEX_AUTH_POOL, future catch-all) ==="
swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666 | 999888777666555444 | max-a | codex"
assert_eq "max-a"              "$SWARM_CONF_F_ACCOUNT" "ACCOUNT uncorrupted by ENGINE field 7"
assert_eq "codex"              "$SWARM_CONF_F_ENGINE" "ENGINE captured from field 7"
assert_eq "default"            "$SWARM_CONF_F_CODEX_AUTH_POOL" "missing field 8 resolves to default pool"

swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666 | 999888777666555444 | max-a | codex | premium_a"
assert_eq "max-a"              "$SWARM_CONF_F_ACCOUNT" "ACCOUNT remains distinct from field 8"
assert_eq "premium_a"          "$SWARM_CONF_F_CODEX_AUTH_POOL" "CODEX_AUTH_POOL captured from field 8"

swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666 | 999888777666555444 | max-a | codex | premium_a | future-v1"
assert_eq "premium_a"          "$SWARM_CONF_F_CODEX_AUTH_POOL" "field 9 cannot corrupt CODEX_AUTH_POOL"
assert_eq "999888777666555444" "$SWARM_CONF_F_GUILD" "guild remains clean with field 9"

swarm_conf_parse_line "acme | /p | BOT_ACME | 1 | | | codex | ../escape" >/dev/null 2>&1
assert_rc 1 "$?" "unsafe CODEX_AUTH_POOL makes the row fail closed"

# ---------------------------------------------------------------------------
# 3) Legacy 4-column row (no guild_id yet) — back-compat: channel still clean,
#    guild empty.
# ---------------------------------------------------------------------------
echo "=== 4-column row (pre-guild_id, back-compat) ==="
swarm_conf_parse_line "acme | /p | BOT_ACME | 111222333444555666"
assert_eq "111222333444555666" "$SWARM_CONF_F_CHANNEL" "channel clean with no 5th column"
assert_eq ""                   "$SWARM_CONF_F_GUILD"   "guild empty when absent"
assert_eq ""                   "$SWARM_CONF_F_ACCOUNT" "account empty in a 4-column row"

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
    case "$SWARM_CONF_F_ACCOUNT" in
      *'|'*) clean_acct=0 ;;
      *) clean_acct=1 ;;
    esac
    assert_eq 1 "$clean_acct" "live row '$nm': ACCOUNT has no embedded '|'"
    case "$SWARM_CONF_F_CODEX_AUTH_POOL" in
      [!a-z]*|*[!a-z0-9_-]*) clean_pool=0 ;;
      *) clean_pool=1 ;;
    esac
    assert_eq 1 "$clean_pool" "live row '$nm': CODEX_AUTH_POOL is canonical/default"
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
echo "=== INJ-1: a non-identifier TOKEN_VAR_NAME (field 3) is REJECTED (blanked) ==="
# Field 3 is later deref'd by NAME via ${!tokvar} and spliced into the pane env
# line; a value that is not a legal shell identifier is an injection sink that
# would defeat F1 token isolation (ADR-0018). The parser must blank it — and the
# check itself must NOT evaluate the value. Payloads are SINGLE-quoted here so the
# TEST shell does not expand them; only the parser sees the literal string.
SENTINEL="${TMPDIR:-/tmp}/inj1-sentinel.$$"
rm -f "$SENTINEL"
swarm_conf_parse_line 'evil | /r/e | BOT_X[$(touch '"$SENTINEL"')] | 111 | 999' 2>/dev/null
assert_eq "" "$SWARM_CONF_F_TOKVAR" "array-subscript NAME[\$(...)] token-var is blanked"
if [ -e "$SENTINEL" ]; then sent=EXECUTED; else sent=inert; fi
assert_eq "inert" "$sent" "validating the token-var did NOT execute the \$(...) payload"
rm -f "$SENTINEL"
swarm_conf_parse_line 'evil2 | /r/e | BOT_X"; touch '"$SENTINEL"'; x=" | 111 | 999' 2>/dev/null
assert_eq "" "$SWARM_CONF_F_TOKVAR" "quote-break token-var is blanked"
if [ -e "$SENTINEL" ]; then sent=EXECUTED; else sent=inert; fi
assert_eq "inert" "$sent" "the quote-break payload did NOT execute"
rm -f "$SENTINEL"
swarm_conf_parse_line 'e3 | /r/e | 1BADVAR | 111 | 999' 2>/dev/null
assert_eq "" "$SWARM_CONF_F_TOKVAR" "leading-digit token-var is blanked"
swarm_conf_parse_line 'e4 | /r/e | BOT-DASH | 111 | 999' 2>/dev/null
assert_eq "" "$SWARM_CONF_F_TOKVAR" "dash (non-identifier) token-var is blanked"
# Legitimate identifiers are preserved unchanged (no false positives).
swarm_conf_parse_line 'good | /r/g | BOT_QOFI_PRODUCT | 111 | 999' 2>/dev/null
assert_eq "BOT_QOFI_PRODUCT" "$SWARM_CONF_F_TOKVAR" "a valid identifier token-var is preserved"
swarm_conf_parse_line 'good2 | /r/g | _UNDERSCORE_OK | 111 | 999' 2>/dev/null
assert_eq "_UNDERSCORE_OK" "$SWARM_CONF_F_TOKVAR" "leading-underscore identifier is preserved"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  exit 1
fi
exit 0
