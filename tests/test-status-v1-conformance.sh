#!/usr/bin/env bash
# test-status-v1-conformance.sh — byte-for-byte conformance of bin/swarm-status-emit.py
# against the FROZEN swarm-status/v1 contract.
#
# Source of truth for the wire shape:
#   ../ios-swarm-status-widget/docs/contracts/swarm-status-v1.md
#   (frozen 2026-05-23, version v1)
#
# Why this exists: the emit logic produces what the receiver validates. Drift
# either silently corrupts the widget or causes 400s on every tick. The seven
# §8 schema examples (8.1–8.7) cover the cases we know matter — this file
# pins each to a regression test. Two specific bugs were fixed alongside this
# test landing; both have dedicated assertions:
#
#   - down → needs_attention=false  (was incorrectly true alone)
#   - compound reason format ` · `   (was dropping the watcher contribution)
#
# Plus the new field:
#   - guild_id populated → string; blank → null
#   - channel + guild_id always serialized as STRINGS (snowflakes exceed
#     JS safe-integer range; receiver would reject numeric form via §6)
#
# Run from $SWARM_HOME:
#     bash tests/test-status-v1-conformance.sh
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure (details on
# stderr). bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EMIT="$SCRIPT_DIR/../bin/swarm-status-emit.py"

if [ ! -r "$EMIT" ]; then
  echo "test: cannot read $EMIT" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=""

# emit NAME CHAN GUILD STATE AGE RESET CTO
#   Returns the emitted JSON line on stdout.
emit() {
  python3 "$EMIT" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# assert LABEL JSON PYTHON_EXPR EXPECTED
#   PYTHON_EXPR is a Python expression evaluated against the parsed object
#   bound as `o`. EXPECTED is the literal-string form of the expected value
#   (use repr-form for strings, e.g. "True", "False", "None", "'cto'").
assert_expr() {
  local label="$1" json="$2" expr="$3" expected="$4" actual
  actual="$(printf '%s' "$json" | python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
print(repr($expr))
" 2>&1)"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    return 0
  fi
  FAIL=$((FAIL + 1))
  FAILURES="$FAILURES
  $label
    expr:     $expr
    expected: $expected
    actual:   $actual
    json:     $json"
  return 1
}

# assert_type LABEL JSON KEY TYPENAME
#   Checks the JSON-typed shape of a field. TYPENAME is one of:
#   str, int, bool, NoneType.
assert_type() {
  local label="$1" json="$2" key="$3" tname="$4" actual
  actual="$(printf '%s' "$json" | python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
print(type(o.get('$key')).__name__)
")"
  if [ "$actual" = "$tname" ]; then
    PASS=$((PASS + 1))
    return 0
  fi
  FAIL=$((FAIL + 1))
  FAILURES="$FAILURES
  $label
    key:      $key
    expected: type=$tname
    actual:   type=$actual
    json:     $json"
  return 1
}

# -----------------------------------------------------------------------------
# §8.1 — All-clear: state=working, no CTO, full guild_id.
# Expectation: needs_attention=false; both attention fields null; channel and
# guild_id strings; last_activity_age_seconds is an int.
# -----------------------------------------------------------------------------
phase81() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "working" "3" "" "")"
  assert_expr "§8.1 needs_attention=false"        "$j" "o['needs_attention']"   "False"
  assert_expr "§8.1 attention_source=null"        "$j" "o['attention_source']"  "None"
  assert_expr "§8.1 attention_reason=null"        "$j" "o['attention_reason']"  "None"
  assert_expr "§8.1 state=working"                "$j" "o['state']"             "'working'"
  assert_type "§8.1 channel is str"               "$j" "channel"                "str"
  assert_type "§8.1 guild_id is str"              "$j" "guild_id"               "str"
  assert_expr "§8.1 guild_id literal"             "$j" "o['guild_id']"          "'1507070014971314287'"
  assert_type "§8.1 last_activity_age_seconds=int" "$j" "last_activity_age_seconds" "int"
  assert_expr "§8.1 limit_reset_hint=null"        "$j" "o['limit_reset_hint']"  "None"
}

# §8.1 second swarm — ready (idle waiting). state=ready, age=412, no CTO.
phase81_ready() {
  local j; j="$(emit "ios-swarm-status-widget" "1507882161535975654" "1507070014971314287" "ready" "412" "" "")"
  assert_expr "§8.1-ready needs_attention=false"  "$j" "o['needs_attention']"   "False"
  assert_expr "§8.1-ready state=ready"            "$j" "o['state']"             "'ready'"
  assert_expr "§8.1-ready attention_source=null"  "$j" "o['attention_source']"  "None"
  assert_expr "§8.1-ready attention_reason=null"  "$j" "o['attention_reason']"  "None"
}

# -----------------------------------------------------------------------------
# §8.2 — Stalled (watcher attention). No CTO flag.
# Expectation: needs_attention=true; source="watcher"; reason="stalled"
# (non-empty single-line — per §5 the literal text isn't normative, but the
# null/source pairing is).
# -----------------------------------------------------------------------------
phase82() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "stalled" "187" "" "")"
  assert_expr "§8.2 needs_attention=true"      "$j" "o['needs_attention']"   "True"
  assert_expr "§8.2 attention_source=watcher"  "$j" "o['attention_source']"  "'watcher'"
  assert_expr "§8.2 attention_reason=stalled"  "$j" "o['attention_reason']"  "'stalled'"
  assert_expr "§8.2 state=stalled"             "$j" "o['state']"             "'stalled'"
}

# -----------------------------------------------------------------------------
# §8.3 — CTO open escalation while ready (override case).
# state=ready (would normally be needs_attention=false); CTO flag set →
# needs_attention=true, source="cto", reason= cto reason verbatim.
# -----------------------------------------------------------------------------
phase83() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "ready" "22" "" "cto escalation open")"
  assert_expr "§8.3 needs_attention=true"     "$j" "o['needs_attention']"   "True"
  assert_expr "§8.3 attention_source=cto"     "$j" "o['attention_source']"  "'cto'"
  assert_expr "§8.3 attention_reason=cto"     "$j" "o['attention_reason']"  "'cto escalation open'"
  assert_expr "§8.3 state stays ready"        "$j" "o['state']"             "'ready'"
}

# -----------------------------------------------------------------------------
# §8.4 — Paused on limit with reset hint.
# Reason wording is contract-significant — schema example matches verbatim:
#   "paused on usage limit (resets in 2h 15m)"
# -----------------------------------------------------------------------------
phase84() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "paused-limit" "9" "in 2h 15m" "")"
  assert_expr "§8.4 needs_attention=true"      "$j" "o['needs_attention']"   "True"
  assert_expr "§8.4 attention_source=watcher"  "$j" "o['attention_source']"  "'watcher'"
  assert_expr "§8.4 attention_reason verbatim" "$j" "o['attention_reason']"  "'paused on usage limit (resets in 2h 15m)'"
  assert_expr "§8.4 limit_reset_hint=in 2h 15m" "$j" "o['limit_reset_hint']" "'in 2h 15m'"
  assert_expr "§8.4 state=paused-limit"        "$j" "o['state']"             "'paused-limit'"
}

# §8.4 sub-case — paused-limit WITHOUT a parseable reset hint.
# Schema §3 says limit_reset_hint MAY be null in this case; reason still must
# be non-empty single-line. We emit "paused on usage limit" without parens.
phase84_no_reset() {
  local j; j="$(emit "x" "100" "200" "paused-limit" "9" "" "")"
  assert_expr "§8.4-noreset needs_attention=true"   "$j" "o['needs_attention']"   "True"
  assert_expr "§8.4-noreset attention_source=watcher" "$j" "o['attention_source']" "'watcher'"
  assert_expr "§8.4-noreset attention_reason"        "$j" "o['attention_reason']" "'paused on usage limit'"
  assert_expr "§8.4-noreset limit_reset_hint=null"   "$j" "o['limit_reset_hint']" "None"
}

# -----------------------------------------------------------------------------
# §8.5 — Down swarm, no CTO. THE REGRESSION TEST for the down bug.
# Pre-fix behavior: needs_attention=true, source="watcher", reason="down".
# Post-fix behavior (per §5 + example 8.5): needs_attention=false, both
# attention fields null. Down-without-CTO is GREY-quiet, not red-alarming.
# -----------------------------------------------------------------------------
phase85_down_no_cto() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "down" "" "" "")"
  assert_expr "§8.5 [BUG-FIX] down alone needs_attention=false" "$j" "o['needs_attention']"  "False"
  assert_expr "§8.5 [BUG-FIX] down alone attention_source=null" "$j" "o['attention_source']" "None"
  assert_expr "§8.5 [BUG-FIX] down alone attention_reason=null" "$j" "o['attention_reason']" "None"
  assert_expr "§8.5 state stays down"                           "$j" "o['state']"            "'down'"
  assert_expr "§8.5 last_activity_age_seconds=null when blank"  "$j" "o['last_activity_age_seconds']" "None"
}

# -----------------------------------------------------------------------------
# §8.6 — Down swarm WITH CTO escalation. Edge case: state stays "down" but
# CTO override flips needs_attention=true, source="cto", reason=cto only
# (NO compound — "down" is not a watcher-attention state, so there's no
# watcher contribution to concatenate).
# -----------------------------------------------------------------------------
phase86_down_with_cto() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "down" "" "" "cto escalation open")"
  assert_expr "§8.6 down+cto needs_attention=true"  "$j" "o['needs_attention']"   "True"
  assert_expr "§8.6 down+cto attention_source=cto"  "$j" "o['attention_source']"  "'cto'"
  assert_expr "§8.6 down+cto attention_reason=cto only (no compound)" \
                                                    "$j" "o['attention_reason']"  "'cto escalation open'"
  assert_expr "§8.6 state stays down"               "$j" "o['state']"             "'down'"
}

# -----------------------------------------------------------------------------
# §8.7 — Compound reason (watcher state AND CTO escalation). THE REGRESSION
# TEST for the dropped-watcher-contribution bug.
# Pre-fix: emit dropped the watcher reason and emitted only the cto reason.
# Post-fix: source="cto" (CTO precedence) AND reason = watcher_reason +
# " · " + cto_reason. Exact separator is " · " (U+00B7 with spaces on both
# sides) — the schema example 8.7 byte-for-byte.
# -----------------------------------------------------------------------------
phase87_compound() {
  local j; j="$(emit "reserve-backend-2" "1507159618453770291" "1507070014971314287" "stalled" "240" "" "cto escalation open")"
  assert_expr "§8.7 [BUG-FIX] compound needs_attention=true"  "$j" "o['needs_attention']"  "True"
  assert_expr "§8.7 [BUG-FIX] compound attention_source=cto"  "$j" "o['attention_source']" "'cto'"
  assert_expr "§8.7 [BUG-FIX] compound reason watcher·cto" \
                                                              "$j" "o['attention_reason']" "'stalled · cto escalation open'"
  assert_expr "§8.7 state stays stalled"                      "$j" "o['state']"            "'stalled'"
}

# Compound sub-case: silent + cto. Same shape, different watcher reason.
phase87_compound_silent() {
  local j; j="$(emit "x" "100" "200" "silent" "1200" "" "blocked on review")"
  assert_expr "§8.7-silent compound source=cto" "$j" "o['attention_source']" "'cto'"
  assert_expr "§8.7-silent compound reason"     "$j" "o['attention_reason']" "'silent · blocked on review'"
}

# Compound sub-case: paused-limit + cto. Watcher reason here is the longer
# "paused on usage limit (resets ...)" string — confirms the separator
# splices correctly with multi-word watcher contributions.
phase87_compound_paused_with_reset() {
  local j; j="$(emit "x" "100" "200" "paused-limit" "9" "in 2h 15m" "blocked on review")"
  assert_expr "§8.7-paused compound source=cto" "$j" "o['attention_source']" "'cto'"
  assert_expr "§8.7-paused compound reason" \
    "$j" "o['attention_reason']" \
    "'paused on usage limit (resets in 2h 15m) · blocked on review'"
}

# -----------------------------------------------------------------------------
# §3 — Required fields + types. Snowflakes MUST be strings; receiver §6
# rejects numeric form. Schema also requires guild_id to accept null/absent
# during the transition window.
# -----------------------------------------------------------------------------
phase_guild_null() {
  local j; j="$(emit "x" "100" "" "ready" "5" "" "")"
  assert_expr "guild_id=null when blank input" "$j" "o['guild_id']" "None"
  assert_type "channel still str even when guild_id is null" "$j" "channel" "str"
}

phase_snowflakes_are_strings() {
  local j; j="$(emit "x" "1507159618453770291" "1507070014971314287" "working" "1" "" "")"
  assert_type "channel is str (not int)"  "$j" "channel"  "str"
  assert_type "guild_id is str (not int)" "$j" "guild_id" "str"
  assert_expr "channel value preserved"  "$j" "o['channel']"  "'1507159618453770291'"
  assert_expr "guild_id value preserved" "$j" "o['guild_id']" "'1507070014971314287'"
}

# -----------------------------------------------------------------------------
# §3/§6 — attention_reason must NOT contain embedded newlines (one-line
# constraint for notification rendering). The emit's defensive guard strips
# them even if a CTO reason somehow contained them.
# -----------------------------------------------------------------------------
phase_no_embedded_newlines() {
  local cto_dirty
  cto_dirty="$(printf 'first line\nsecond line')"
  local j; j="$(emit "x" "100" "200" "stalled" "60" "" "$cto_dirty")"
  assert_expr "newline-stripped from compound reason" \
    "$j" "'\n' not in (o['attention_reason'] or '')" "True"
  assert_expr "newline-stripped from cto-only reason" \
    "$(emit "x" "100" "200" "ready" "5" "" "$cto_dirty")" \
    "'\n' not in (o['attention_reason'] or '')" "True"
}

# -----------------------------------------------------------------------------
# §3 — last_activity_age_seconds null when transcript is absent (state often
# "starting" or "down"). Receiver §3 calls this out explicitly.
# -----------------------------------------------------------------------------
phase_age_null_when_blank() {
  local j; j="$(emit "x" "100" "200" "starting" "" "" "")"
  assert_expr "last_activity_age_seconds=null when age blank" \
    "$j" "o['last_activity_age_seconds']" "None"
  assert_expr "starting alone needs_attention=false" \
    "$j" "o['needs_attention']" "False"
}

# -----------------------------------------------------------------------------
# §6 — needs_attention⇔attention_source pairing invariants. Build a fuzz of
# the four cells (cto×watcher-state) and assert the pairing rules hold.
# -----------------------------------------------------------------------------
phase_pairing_invariants() {
  # cell A: no cto, ready  → needs=false, source=null, reason=null
  local j
  j="$(emit "x" "100" "200" "ready" "5" "" "")"
  assert_expr "pair[A] needs=false" "$j" "o['needs_attention']"   "False"
  assert_expr "pair[A] src=null"    "$j" "o['attention_source']"  "None"
  assert_expr "pair[A] reason=null" "$j" "o['attention_reason']"  "None"

  # cell B: no cto, stalled → needs=true, source=watcher, reason="stalled"
  j="$(emit "x" "100" "200" "stalled" "60" "" "")"
  assert_expr "pair[B] needs=true"     "$j" "o['needs_attention']"  "True"
  assert_expr "pair[B] src=watcher"    "$j" "o['attention_source']" "'watcher'"
  assert_expr "pair[B] reason=stalled" "$j" "o['attention_reason']" "'stalled'"

  # cell C: cto, ready → needs=true, source=cto, reason=cto only
  j="$(emit "x" "100" "200" "ready" "5" "" "ESCALATE")"
  assert_expr "pair[C] needs=true"     "$j" "o['needs_attention']"  "True"
  assert_expr "pair[C] src=cto"        "$j" "o['attention_source']" "'cto'"
  assert_expr "pair[C] reason=cto"     "$j" "o['attention_reason']" "'ESCALATE'"

  # cell D: cto, stalled → needs=true, source=cto, reason=compound
  j="$(emit "x" "100" "200" "stalled" "60" "" "ESCALATE")"
  assert_expr "pair[D] needs=true"        "$j" "o['needs_attention']"  "True"
  assert_expr "pair[D] src=cto"           "$j" "o['attention_source']" "'cto'"
  assert_expr "pair[D] reason=compound"   "$j" "o['attention_reason']" "'stalled · ESCALATE'"
}

# -----------------------------------------------------------------------------
# Run all phases. Each is independent.
# -----------------------------------------------------------------------------
phase81
phase81_ready
phase82
phase83
phase84
phase84_no_reset
phase85_down_no_cto
phase86_down_with_cto
phase87_compound
phase87_compound_silent
phase87_compound_paused_with_reset
phase_guild_null
phase_snowflakes_are_strings
phase_no_embedded_newlines
phase_age_null_when_blank
phase_pairing_invariants

echo ""
echo "===================================================================="
echo "swarm-status/v1 conformance: $PASS pass, $FAIL fail"
echo "===================================================================="

if [ "$FAIL" -gt 0 ]; then
  printf '\nFAILURES:%s\n' "$FAILURES" >&2
  exit 1
fi
exit 0
