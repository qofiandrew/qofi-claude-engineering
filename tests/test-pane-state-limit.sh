#!/usr/bin/env bash
# test-pane-state-limit.sh — regression tests for pane_state()'s limit detection
# in bin/swarm-lib.sh (the "paused-limit" rc=2 signal that swarm-limit-detect.sh
# turns into the rotation AT verdict).
#
# WHY THIS EXISTS. pane_state greps the WHOLE pane capture for limit substrings.
# The old set matched bare "usage limit", which also appears in Claude Code's
# GLOBAL informational notice ("▎ Through <date>, you can use up to 50% of your
# weekly usage limit on Fable 5") and in the leads' own conversation about rate
# limits — so EVERY pane read as paused-limit and the rotation tick's real
# signal was a permanent false AT. This pins the robust behavior:
#   - a genuine cap-HIT banner ("usage limit reached", "5-hour limit reached")
#     -> rc=2 (paused-limit),
#   - the benign allowance notice ("you can use up to N%") -> NOT rc=2,
#   - casual conversation mentioning "usage limit"/"rate limit" -> NOT rc=2,
#   - a real cap line still WINS when a benign notice is also on screen,
#   - working / at-prompt / unknown are unaffected.
#
# No real tmux: a stub tmux returns a chosen capture via $MOCK_CAP.
#
# Run from $SWARM_HOME:  bash tests/test-pane-state-limit.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pane-state-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Stub tmux: capture-pane prints $MOCK_CAP; command -v must find it (it's on PATH).
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in capture-pane) printf '%s\n' "${MOCK_CAP:-}"; exit 0 ;; *) exit 0 ;; esac
EOF
chmod +x "$STUB/tmux"

# ps CAPTURE [ENVLINE] -> sets $RC and $DETAIL from pane_state against the stub.
ps() {
  local cap="$1"; shift
  local out
  out="$(
    export SWARM_HOME="$ROOT"
    export MOCK_CAP="$cap"
    "$@" bash -c '. "'"$ROOT"'/bin/swarm-lib.sh"; pane_state sess "'"$STUB"'/tmux"; printf "%s\t%s" "$?" "$SWARM_PANE_STATE_DETAIL"'
  )"
  RC="${out%%	*}"; DETAIL="${out#*	}"
}

FABLE='▎ Through July 12, you can use up to 50% of your weekly usage limit on Fable 5.
❯
  ← for agents'
CAP_REACHED='Claude usage limit reached · resets 3pm
❯'
CAP_5H='5-hour limit reached · resets at 11pm'
BOTH='▎ you can use up to 50% of your weekly usage limit on Fable 5.
Claude usage limit reached · resets 3pm'
CONVO='we should handle the usage limit gracefully when the 5-hour limit is near
❯
  ← for agents'
CONVO_RATE='the rate limit handling needs a retry loop
❯
  ← for agents'
IDLE='❯
  ⏵⏵ auto mode on · ← for agents'
WORKING='✻ Baking… (esc to interrupt)'

echo "=== the false positive: the global Fable allowance notice is NOT a cap ==="
ps "$FABLE"
assert_eq 1 "$RC" "Fable 'you can use up to' notice -> at-prompt (rc=1), NOT paused-limit"

echo "=== genuine cap-HIT banners DO fire (rc=2) ==="
ps "$CAP_REACHED"
assert_eq 2 "$RC" "'usage limit reached' -> paused-limit (rc=2)"
assert_has "$DETAIL" "usage limit reached" "detail carries the cap line"
ps "$CAP_5H"
assert_eq 2 "$RC" "'5-hour limit reached' -> paused-limit (rc=2)"

echo "=== a real cap WINS even when the benign notice is also on screen ==="
ps "$BOTH"
assert_eq 2 "$RC" "benign notice does not shadow a real cap (rc=2)"
assert_has "$DETAIL" "usage limit reached" "detail is the REAL cap line, not the notice"

echo "=== conversation mentions are NOT caps (robust against the leads' own text) ==="
ps "$CONVO"
assert_eq 1 "$RC" "'...the usage limit...the 5-hour limit is near' in prose -> NOT a cap"
ps "$CONVO_RATE"
assert_eq 1 "$RC" "'rate limit' in prose (not 'rate limit exceeded') -> NOT a cap"

echo "=== other states unaffected ==="
ps "$IDLE";    assert_eq 1 "$RC" "idle prompt -> at-prompt (rc=1)"
ps "$WORKING"; assert_eq 0 "$RC" "working footer -> working (rc=0)"

echo "=== overrides still work ==="
ps "$CONVO" env SWARM_LIMIT_PATTERNS='usage limit'
assert_eq 2 "$RC" "operator can broaden via SWARM_LIMIT_PATTERNS (bare 'usage limit' matches prose)"
ps "$CAP_REACHED
  ← for agents" env SWARM_LIMIT_EXCLUDE_PATTERNS='usage limit reached'
assert_eq 1 "$RC" "operator can suppress a phrasing via SWARM_LIMIT_EXCLUDE_PATTERNS (cap line dropped -> falls through to the idle footer)"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
