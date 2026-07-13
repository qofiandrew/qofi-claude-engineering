#!/usr/bin/env bash
# test-swarm-usage-poll.sh — regression tests for bin/swarm-usage-poll.sh, the
# ROTATION TRIGGER: poll the active Max account's usage and decide whether it is
# nearing its 5h / weekly cap.
#
# WHAT THIS PROTECTS (the trigger's threshold logic — the decision a rotation
# hangs off):
#   1. OK (exit 0) when both windows are comfortably under the threshold.
#   2. NEAR-LIMIT (exit 10) when EITHER window crosses the threshold — 5h or weekly.
#   3. AT-LIMIT (exit 20) when either window is at/over 100%.
#   4. UNKNOWN (exit 3) on a failed probe / missing file / unparseable payload —
#      a probe failure must NEVER read as NEAR/AT (it would trip a needless
#      credential swap). Fail-safe is silence.
#   5. The probe is SWAPPABLE: SWARM_USAGE_PROBE (a command) and SWARM_USAGE_FILE
#      (a file) are both honored; probe takes precedence. NO real endpoint / no
#      real credential is ever touched — every test feeds a synthetic payload.
#   6. Threshold is tunable + validated (bad threshold = config error, exit 2).
#   7. Alias keys + absent windows behave (absent window == plenty left).
#
# These tests perform NO network calls and read NO real credentials — usage is
# always a synthetic JSON blob via the documented swappable seam.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-usage-poll.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="$ROOT/bin/swarm-usage-poll.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/usage-poll.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# poll_with PAYLOAD [VAR=VALUE ...] — run the poller with PAYLOAD delivered via
# the SWARM_USAGE_PROBE seam (the payload is written to a temp file and the probe
# `cat`s it, so arbitrary JSON survives without quoting games). Any trailing
# VAR=VALUE pairs are exported into the run's environment. Captures stdout in
# $OUT, exit in $rc. No real endpoint, no credentials.
poll_with() {
  local payload="$1"; shift
  printf '%s' "$payload" > "$TMP/payload.json"
  OUT="$(
    export SWARM_USAGE_PROBE="cat '$TMP/payload.json'"
    while [ $# -gt 0 ]; do export "$1"; shift; done
    bash "$POLL" 2>&1
  )"; rc=$?
}

# ---------------------------------------------------------------------------
echo "=== 1) OK: both windows under threshold -> exit 0 ==="
poll_with '{"five_hour":{"used_pct":40},"weekly":{"used_pct":30}}'
assert_eq 0 "$rc" "40%/30% under default 95% -> OK (exit 0)"
if printf '%s' "$OUT" | grep -q 'OK'; then ok "labels OK"; else bad "should label OK"; fi

# ---------------------------------------------------------------------------
echo "=== 2) NEAR: 5h window crosses threshold -> exit 10 ==="
poll_with '{"five_hour":{"used_pct":98,"reset_hint":"resets 11pm"},"weekly":{"used_pct":20}}'
assert_eq 10 "$rc" "5h=98% >= 95% -> NEAR-LIMIT (exit 10)"
if printf '%s' "$OUT" | grep -qi 'NEAR'; then ok "labels NEAR-LIMIT"; else bad "should label NEAR-LIMIT"; fi

echo "=== 2b) NEAR: WEEKLY window crosses threshold even when 5h is low -> exit 10 ==="
poll_with '{"five_hour":{"used_pct":10},"weekly":{"used_pct":97}}'
assert_eq 10 "$rc" "weekly=97% >= 95% -> NEAR-LIMIT (exit 10), 5h low"

echo "=== 2c) boundary: exactly at threshold counts as NEAR ==="
poll_with '{"five_hour":{"used_pct":95},"weekly":{"used_pct":0}}'
assert_eq 10 "$rc" "5h=95% == threshold -> NEAR (>= is inclusive)"

echo "=== 2d) just under threshold stays OK ==="
poll_with '{"five_hour":{"used_pct":94},"weekly":{"used_pct":94}}'
assert_eq 0 "$rc" "94%/94% just under 95% -> OK"

# ---------------------------------------------------------------------------
echo "=== 3) AT: a window at/over 100% -> exit 20 ==="
poll_with '{"five_hour":{"used_pct":100},"weekly":{"used_pct":50}}'
assert_eq 20 "$rc" "5h=100% -> AT-LIMIT (exit 20)"
poll_with '{"weekly":{"used_pct":105}}'
assert_eq 20 "$rc" "weekly=105% -> AT-LIMIT (exit 20)"

# ---------------------------------------------------------------------------
echo "=== 4) UNKNOWN: probe failure / unparseable / empty -> exit 3 (fail-safe) ==="
# Probe exits non-zero (no stdout).
OUT="$(SWARM_USAGE_PROBE='exit 7' bash "$POLL" 2>&1)"; rc=$?
assert_eq 3 "$rc" "probe exits non-zero -> UNKNOWN (exit 3), NOT NEAR/AT"
# Probe prints garbage.
poll_with 'this is not json'
assert_eq 3 "$rc" "unparseable payload -> UNKNOWN (exit 3)"
# Missing usage file, no probe.
OUT="$(SWARM_USAGE_FILE="$TMP/does-not-exist.json" bash "$POLL" 2>&1)"; rc=$?
assert_eq 3 "$rc" "missing usage file + no probe -> UNKNOWN (exit 3)"
# Empty object is a valid object with no windows -> treated as 0% -> OK, NOT unknown.
poll_with '{}'
assert_eq 0 "$rc" "empty object {} -> OK (no windows == plenty left), not UNKNOWN"

# ---------------------------------------------------------------------------
echo "=== 5) swappable seam: SWARM_USAGE_FILE is read when no probe is set ==="
echo '{"five_hour":{"used_pct":95}}' > "$TMP/usage.json"
OUT="$(SWARM_USAGE_FILE="$TMP/usage.json" bash "$POLL" 2>&1)"; rc=$?
assert_eq 10 "$rc" "file payload 95% -> NEAR (file seam honored)"
# Probe takes precedence over file: file says 95 (NEAR) but probe says 10 (OK).
OUT="$(SWARM_USAGE_FILE="$TMP/usage.json" SWARM_USAGE_PROBE="printf '%s' '{\"five_hour\":{\"used_pct\":10}}'" bash "$POLL" 2>&1)"; rc=$?
assert_eq 0 "$rc" "probe overrides file (probe=10% OK wins over file=95%)"

# ---------------------------------------------------------------------------
echo "=== 6) tunable + validated threshold ==="
# Lower the bar to 50: 60% now trips NEAR.
poll_with '{"five_hour":{"used_pct":60}}' SWARM_ROTATE_THRESHOLD_PCT=50
assert_eq 10 "$rc" "threshold 50, 5h=60% -> NEAR"
# Raise the bar to 99: 90% is now OK.
poll_with '{"five_hour":{"used_pct":90}}' SWARM_ROTATE_THRESHOLD_PCT=99
assert_eq 0 "$rc" "threshold 99, 5h=90% -> OK"
# Bad threshold -> config error (exit 2).
poll_with '{"five_hour":{"used_pct":90}}' SWARM_ROTATE_THRESHOLD_PCT=abc
assert_eq 2 "$rc" "non-numeric threshold -> config error (exit 2)"
poll_with '{"five_hour":{"used_pct":90}}' SWARM_ROTATE_THRESHOLD_PCT=0
assert_eq 2 "$rc" "threshold 0 (out of range) -> config error (exit 2)"

# ---------------------------------------------------------------------------
echo "=== 7) alias keys + absent windows ==="
# Alias: 5h / weekly + pct/percent variants.
poll_with '{"5h":{"pct":98},"week":{"percent":10}}'
assert_eq 10 "$rc" "alias keys (5h.pct / week.percent) parse -> NEAR"
# Scalar form: bare percent under the *_pct key.
poll_with '{"five_hour_pct":96}'
assert_eq 10 "$rc" "scalar five_hour_pct=96 -> NEAR"
# Only weekly present; 5h absent -> treated as 0, weekly drives.
poll_with '{"weekly":{"used_pct":30}}'
assert_eq 0 "$rc" "only weekly present (30%), 5h absent -> OK"

# ---------------------------------------------------------------------------
echo "=== 8) --quiet emits no stdout; --json emits a JSON line ==="
OUT="$(SWARM_USAGE_PROBE="printf '%s' '{\"five_hour\":{\"used_pct\":98}}'" bash "$POLL" --quiet 2>/dev/null)"; rc=$?
assert_eq 10 "$rc" "--quiet keeps the exit code"
if [ -z "$OUT" ]; then ok "--quiet prints nothing"; else bad "--quiet should print nothing (got [$OUT])"; fi
OUT="$(SWARM_USAGE_PROBE="printf '%s' '{\"five_hour\":{\"used_pct\":98},\"account\":\"max-b\"}'" bash "$POLL" --json 2>/dev/null)"; rc=$?
if printf '%s' "$OUT" | grep -q '"verdict": *"NEAR"'; then ok "--json includes verdict"; else bad "--json should include verdict NEAR (got [$OUT])"; fi
if printf '%s' "$OUT" | grep -q '"account": *"max-b"'; then ok "--json echoes account"; else bad "--json should echo account"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
