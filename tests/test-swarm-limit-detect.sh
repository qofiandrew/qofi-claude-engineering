#!/usr/bin/env bash
# test-swarm-limit-detect.sh — regression tests for bin/swarm-limit-detect.sh,
# the REAL rate-limit detector that turns an observed usage-limit pane message
# (pane_state rc=2 — the same signal swarm-watch.sh trusts) into the poller's
# AT-LIMIT verdict, keeping the burn-proxy poller as the NEAR early warning.
#
# SYNTHETIC-FIXTURE discipline:
#   - A throwaway SWARM_HOME with a synthetic swarm.conf (no real fleet).
#   - Pane observation is injected via SWARM_PANE_STATE_CMD (a stub returning a
#     chosen pane_state rc + limit line) — no real tmux, no live sessions.
#   - The delegated proxy poller is injected via SWARM_POLL_CMD_INNER — a stub
#     that exits a chosen verdict — so no real usage endpoint is touched.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-limit-detect.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECT="$ROOT/bin/swarm-limit-detect.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

# Synthetic SWARM_HOME: just a swarm.conf with two fake swarms + a templates dir
# (some siblings check for it; the detector only needs swarm.conf).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-limit-detect-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/templates"
cat > "$FAKE_HOME/swarm.conf" <<'CONF'
# name | repo | tokvar | channel | guild
alpha | ~/repos/alpha | ALPHA_TOK | 111 | 999
beta  | ~/repos/beta  | BETA_TOK  | 222 | 999
CONF

run() {  # PANE_STUB OR_POLL_FLAG... -> OUT, rc. PANE_STUB sees session in $1.
  local stub="$1"; shift
  OUT="$(SWARM_HOME="$FAKE_HOME" SWARM_PANE_STATE_CMD="$stub" \
         SWARM_POLL_CMD_INNER="$PROXY" bash "$DETECT" "$@" 2>&1)"; rc=$?
}

# Default delegated proxy stub: exits whatever $PROXY_RC holds (so we can assert
# the verdict is passed through in --or-poll). Default OK(0).
PROXY="$TMP/proxy.sh"
cat > "$PROXY" <<'EOF'
#!/usr/bin/env bash
echo "stub-proxy verdict"
exit "${PROXY_RC:-0}"
EOF
chmod +x "$PROXY"

echo "=== swarm-limit-detect — REAL-signal mode ==="

echo "--- a live pane shows a usage limit (rc=2) -> AT-LIMIT (exit 20) ---"
# beta's pane is paused-limit; alpha is at-prompt.
run 'case "$1" in *beta*) printf "5-hour limit reached · resets at 11pm\n"; exit 2;; *) exit 1;; esac'
assert_eq 20 "$rc" "observed real limit -> AT (exit 20)"
assert_has "$OUT" "AT-LIMIT (REAL signal)" "labels it as the REAL signal"
assert_has "$OUT" "beta" "names the swarm whose pane is capped"
assert_has "$OUT" "5-hour limit reached" "echoes the matched limit line"

echo "--- no live pane shows a limit (all at-prompt rc=1) -> OK (exit 0) ---"
run 'exit 1'
assert_eq 0 "$rc" "no real limit, panes readable -> OK (exit 0)"
assert_has "$OUT" "no live swarm pane" "explains: not capped"

echo "--- working panes (rc=0) but none capped -> OK (exit 0) ---"
run 'exit 0'
assert_eq 0 "$rc" "working panes, none capped -> OK (exit 0)"

echo "--- cannot observe (all uncertain rc=4) -> UNKNOWN (exit 3), no AT claimed ---"
run 'exit 4'
assert_eq 3 "$rc" "no observable pane -> UNKNOWN (exit 3)"
assert_has "$OUT" "Yielding" "yields rather than asserting not-capped"

echo "--- one capped pane is enough even if others are fine ---"
run 'case "$1" in *alpha*) exit 0;; *beta*) printf "rate limit\n"; exit 2;; esac'
assert_eq 20 "$rc" "any one capped pane -> AT (single-account fleet is capped)"

echo "=== --or-poll combiner: real signal is the hard stop, else delegate ==="

echo "--- real AT short-circuits BEFORE the proxy is consulted ---"
PROXY_RC=10 run 'case "$1" in *beta*) printf "Claude usage limit reached\n"; exit 2;; *) exit 1;; esac' --or-poll
# even though the proxy would say NEAR(10), the real AT wins:
assert_eq 20 "$rc" "real AT short-circuits to 20 (proxy not consulted)"
assert_has "$OUT" "REAL signal" "reports the real signal won"

echo "--- no real limit -> delegate to proxy; proxy NEAR(10) passes through ---"
PROXY_RC=10 run 'exit 1' --or-poll
assert_eq 10 "$rc" "no real cap -> delegates, proxy NEAR(10) passes through"
assert_has "$OUT" "delegating to burn-proxy" "announces delegation to the proxy"
assert_has "$OUT" "stub-proxy verdict" "the proxy's own output is surfaced"

echo "--- no real limit -> delegate; proxy OK(0) passes through ---"
PROXY_RC=0 run 'exit 1' --or-poll
assert_eq 0 "$rc" "delegated proxy OK(0) passes through"

echo "--- unobservable real signal -> still delegate to proxy (don't fabricate AT) ---"
PROXY_RC=0 run 'exit 4' --or-poll
assert_eq 0 "$rc" "unobservable real -> delegate, do NOT claim AT"
assert_has "$OUT" "delegating" "delegates when it cannot see the real signal"

echo "--- --json emits a machine-readable line for the real signal ---"
run 'case "$1" in *beta*) printf "usage limit reached\n"; exit 2;; *) exit 1;; esac' --json
assert_has "$OUT" '"verdict": "AT"' "json reports verdict AT"
assert_has "$OUT" '"swarm": "beta"' "json names the capped swarm"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'Failures:%s\n' "$FAILURES" >&2; exit 1; fi
exit 0
