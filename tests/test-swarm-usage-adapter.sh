#!/usr/bin/env bash
# test-swarm-usage-adapter.sh — regression tests for
# bin/swarm-usage-adapter-ccusage.sh, the ADAPTER that turns ccusage's token
# accounting into the swarm-usage-poll PROBE SCHEMA (the rotation TRIGGER's
# input). swarm-usage-poll.sh itself is UNCHANGED; this exercises the adapter and
# the adapter piped THROUGH the poll script end-to-end.
#
# CRITICAL SAFETY PROPERTY OF THIS TEST FILE. It makes NO network calls, runs NO
# real ccusage, reads NO real credential, and never rotates anything. ccusage is
# delivered ENTIRELY through the adapter's injectable SWARM_CCUSAGE_CMD seam,
# pointed at a STUB script that prints a synthetic fixture for the requested
# subcommand. These tests therefore PASS with real ccusage ABSENT (it is not
# installed in this environment).
#
# WHAT THIS PROTECTS:
#   1. SCHEMA: the adapter emits the contract
#        {"five_hour":{"used_pct":N},"weekly":{"used_pct":N},"account":"…"}
#      that swarm-usage-poll.sh parses.
#   2. MATH: used_pct = tokens_used_in_window / token_budget * 100, an HONEST
#      documented estimate (NOT the authoritative Max cap %, which is not exposed).
#   3. ACCOUNT: echoed from ccusage if present, else SWARM_USAGE_ACCOUNT/unknown.
#   4. END-TO-END regions reachable through swarm-usage-poll.sh: OK / NEAR / AT.
#   5. FAIL-SAFE: ccusage absent, budgets unset/invalid, or unparseable output ->
#      adapter prints NOTHING and exits non-zero -> poll resolves UNKNOWN (exit 3)
#      and NEVER trips a rotation on a fabricated number.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-usage-adapter.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$ROOT/bin/swarm-usage-adapter-ccusage.sh"
POLL="$ROOT/bin/swarm-usage-poll.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2] in [$1])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2] in [$1])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/usage-adapter.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── The ccusage STUB ──────────────────────────────────────────────────────────
# A real script that dispatches on the ccusage subcommand the adapter passes:
#   "<stub> blocks --active --json"  -> prints $TMP/blocks.json
#   "<stub> weekly --json"           -> prints $TMP/weekly.json
# Each fixture file is written per-test below. If a fixture file is missing the
# stub exits non-zero with NO stdout — this models ccusage being unavailable for
# that window. No network, no real ccusage.
STUB="$TMP/ccusage-stub.sh"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -uo pipefail
case "\${1:-}" in
  blocks) f="$TMP/blocks.json" ;;
  weekly) f="$TMP/weekly.json" ;;
  *)      exit 2 ;;
esac
[ -f "\$f" ] || exit 3
cat "\$f"
EOF
chmod +x "$STUB"
STUB_CMD="bash $STUB"

# Helpers to (re)write the per-window fixtures.
set_blocks() { printf '%s' "$1" > "$TMP/blocks.json"; }
set_weekly() { printf '%s' "$1" > "$TMP/weekly.json"; }
clear_blocks() { rm -f "$TMP/blocks.json"; }
clear_weekly() { rm -f "$TMP/weekly.json"; }

# A realistic active-block fixture parameterised by 5h totalTokens.
blocks_fixture() {
  cat <<JSON
{"blocks":[
  {"id":"prev","isActive":false,"isGap":false,"totalTokens":1,"tokenCounts":{"inputTokens":1,"outputTokens":0,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}},
  {"id":"active","isActive":true,"isGap":false,"totalTokens":$1,"startTime":"2026-06-14T22:00:00.000Z","endTime":"2026-06-15T03:00:00.000Z","tokenCounts":{"inputTokens":100,"outputTokens":200,"cacheCreationInputTokens":300,"cacheReadInputTokens":400}}
]}
JSON
}

# A realistic weekly fixture: two week buckets; the CURRENT week (latest period)
# carries $1 totalTokens, an older week carries a large value we must NOT pick.
weekly_fixture() {
  cat <<JSON
{"totals":{"totalTokens":999999999},"weekly":[
  {"agent":"all","period":"2026-06-01","totalTokens":9000000000,"inputTokens":1,"outputTokens":1},
  {"agent":"all","period":"2026-06-08","totalTokens":$1,"inputTokens":1,"outputTokens":1}
]}
JSON
}

# run_adapter — run the adapter with the stub wired + given budgets/extra env.
# Captures $OUT (stdout only), $ERR (stderr), $rc.
run_adapter() {
  local errf="$TMP/err.$$"
  OUT="$(
    export SWARM_CCUSAGE_CMD="$STUB_CMD"
    while [ $# -gt 0 ]; do export "$1"; shift; done
    bash "$ADAPTER" 2>"$errf"
  )"; rc=$?
  ERR="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"
}

# poll_via_adapter — pipe the adapter as swarm-usage-poll.sh's PROBE, end-to-end.
# Captures poll stdout in $OUT, exit in $rc. This is the real wiring an operator
# would use: SWARM_USAGE_PROBE='bash bin/swarm-usage-adapter-ccusage.sh'.
poll_via_adapter() {
  OUT="$(
    export SWARM_CCUSAGE_CMD="$STUB_CMD"
    export SWARM_USAGE_PROBE="bash '$ADAPTER'"
    while [ $# -gt 0 ]; do export "$1"; shift; done
    bash "$POLL" 2>&1
  )"; rc=$?
}

# ---------------------------------------------------------------------------
echo "=== 1) SCHEMA + MATH: adapter emits the probe schema with correct used_pct ==="
set_blocks "$(blocks_fixture 50000000)"     # 50M of 200M budget = 25%
set_weekly "$(weekly_fixture 200000000)"    # 200M of 2,000M budget = 10%
run_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 0 "$rc" "adapter exits 0 with valid ccusage output + budgets"
assert_has "$OUT" '"five_hour"' "emits five_hour window"
assert_has "$OUT" '"weekly"'    "emits weekly window"
assert_has "$OUT" '"used_pct": 25.0' "5h used_pct = 50M/200M = 25.0"
assert_has "$OUT" '"used_pct": 10.0' "weekly used_pct = 200M/2000M = 10.0"
# The emitted payload must be valid JSON the poll schema parser accepts.
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["five_hour"]["used_pct"]==25.0; assert d["weekly"]["used_pct"]==10.0' \
  && ok "payload is valid JSON with expected used_pct values" \
  || bad "payload failed JSON/value assertion"

echo "=== 1b) weekly picks the CURRENT (latest period) bucket, not an older big one ==="
# Older bucket is 9,000M (would be 450%); current is 200M (10%). Must read 10%.
assert_lacks "$OUT" '450' "did NOT use the stale 9000M bucket"

# ---------------------------------------------------------------------------
echo "=== 2) ACCOUNT: ccusage has none here -> SWARM_USAGE_ACCOUNT / unknown ==="
set_blocks "$(blocks_fixture 10000000)"
run_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_USAGE_ACCOUNT=max-a
assert_has "$OUT" '"account": "max-a"' "account stamped from SWARM_USAGE_ACCOUNT"
run_adapter SWARM_5H_TOKEN_BUDGET=200000000
assert_has "$OUT" '"account": "unknown"' "account defaults to unknown when unconfigured"

# ---------------------------------------------------------------------------
echo "=== 3) END-TO-END through swarm-usage-poll.sh: OK / NEAR / AT reachable ==="
# OK: 5h 30% (60M/200M), weekly 10% — both under default 85% threshold.
set_blocks "$(blocks_fixture 60000000)"
set_weekly "$(weekly_fixture 200000000)"
poll_via_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 0 "$rc" "30%/10% via adapter -> poll OK (exit 0)"
assert_has "$OUT" 'OK' "poll labels OK"

# NEAR: 5h 90% (180M/200M) crosses default 85% threshold.
set_blocks "$(blocks_fixture 180000000)"
set_weekly "$(weekly_fixture 100000000)"
poll_via_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 10 "$rc" "5h 90% via adapter -> poll NEAR-LIMIT (exit 10)"
assert_has "$OUT" 'NEAR' "poll labels NEAR-LIMIT"

# AT: weekly at/over 100% (2,000M/2,000M) -> AT-LIMIT even with low 5h.
set_blocks "$(blocks_fixture 10000000)"
set_weekly "$(weekly_fixture 2000000000)"
poll_via_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 20 "$rc" "weekly 100% via adapter -> poll AT-LIMIT (exit 20)"
assert_has "$OUT" 'AT' "poll labels AT-LIMIT"

# ---------------------------------------------------------------------------
echo "=== 4) FAIL-SAFE: every failure mode -> adapter non-zero, NO stdout, poll UNKNOWN ==="

echo "--- 4a) ccusage unavailable (stub returns nothing) -> non-zero, empty stdout ---"
clear_blocks; clear_weekly      # stub now exits non-zero with no output
run_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 1 "$rc" "ccusage produces nothing -> adapter exits non-zero"
if [ -z "$OUT" ]; then ok "adapter prints NOTHING to stdout on ccusage failure"; else bad "adapter must print nothing (got [$OUT])"; fi
# Same condition, end-to-end: poll must resolve UNKNOWN (exit 3), never NEAR/AT.
poll_via_adapter SWARM_5H_TOKEN_BUDGET=200000000 SWARM_WEEKLY_TOKEN_BUDGET=2000000000
assert_eq 3 "$rc" "ccusage failure end-to-end -> poll UNKNOWN (exit 3), NOT a rotation"
assert_has "$OUT" 'UNKNOWN' "poll labels UNKNOWN on probe failure"

echo "--- 4b) budgets unset -> adapter refuses (no defensible denominator) ---"
set_blocks "$(blocks_fixture 50000000)"
run_adapter         # no SWARM_*_TOKEN_BUDGET at all
assert_eq 1 "$rc" "no budget set -> adapter exits non-zero"
if [ -z "$OUT" ]; then ok "no budget -> nothing on stdout"; else bad "no budget should print nothing (got [$OUT])"; fi
assert_has "$ERR" "budget" "stderr explains the missing budget"

echo "--- 4c) invalid budget (non-integer) -> adapter refuses ---"
run_adapter SWARM_5H_TOKEN_BUDGET=lots
assert_eq 1 "$rc" "non-integer budget -> adapter exits non-zero"
if [ -z "$OUT" ]; then ok "invalid budget -> nothing on stdout"; else bad "invalid budget should print nothing (got [$OUT])"; fi

echo "--- 4d) unparseable ccusage output -> adapter refuses ---"
set_blocks 'this is not json'
run_adapter SWARM_5H_TOKEN_BUDGET=200000000
assert_eq 1 "$rc" "unparseable ccusage JSON -> adapter exits non-zero"
if [ -z "$OUT" ]; then ok "unparseable output -> nothing on stdout"; else bad "unparseable should print nothing (got [$OUT])"; fi

echo "--- 4e) ccusage genuinely ABSENT (no stub, no ccusage, force npx-only path) ---"
# Unset SWARM_CCUSAGE_CMD AND make ccusage/npx invisible by emptying PATH so the
# resolver finds neither -> must fail-safe (the real state of this host: ccusage
# is NOT installed). We keep python3 reachable via absolute interpreter path,
# but the adapter resolves ccusage purely via PATH lookups.
OUT="$(env -i HOME="$HOME" PATH="/nonexistent" \
        SWARM_5H_TOKEN_BUDGET=200000000 \
        /bin/bash "$ADAPTER" 2>/dev/null)"; rc=$?
assert_eq 1 "$rc" "ccusage + npx both absent -> adapter exits non-zero"
if [ -z "$OUT" ]; then ok "ccusage absent -> nothing on stdout (poll would resolve UNKNOWN)"; else bad "ccusage absent should print nothing (got [$OUT])"; fi

# ---------------------------------------------------------------------------
echo "=== 5) single-window mode: only a 5h budget set -> only five_hour emitted ==="
set_blocks "$(blocks_fixture 100000000)"   # 100M/200M = 50%
clear_weekly
run_adapter SWARM_5H_TOKEN_BUDGET=200000000   # no weekly budget -> weekly not requested
assert_eq 0 "$rc" "only 5h budget -> adapter still succeeds"
assert_has "$OUT" '"five_hour"' "emits five_hour"
assert_lacks "$OUT" '"weekly"'  "omits weekly when no weekly budget configured"
assert_has "$OUT" '"used_pct": 50.0' "5h used_pct = 100M/200M = 50.0"

# ---------------------------------------------------------------------------
echo "=== 6) honest-estimate disclosure is carried in the payload ==="
set_blocks "$(blocks_fixture 50000000)"
run_adapter SWARM_5H_TOKEN_BUDGET=200000000
assert_has "$OUT" 'NOT authoritative Max cap' "payload labels used_pct as an estimate, not the real cap"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
