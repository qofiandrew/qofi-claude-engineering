#!/usr/bin/env bash
# test-swarm-rotate-tick.sh — regression tests for bin/swarm-rotate-tick.sh, the
# ROTATION ORCHESTRATOR: poll the active account's usage and ROUTE to a rotation
# only when the verdict warrants it. Plus the launchd plist template for the
# periodic tick.
#
# CRITICAL SAFETY PROPERTY OF THIS TEST FILE. It NEVER polls a real usage
# endpoint, NEVER swaps a real credential, NEVER restarts a real fleet, NEVER
# loads a launchd job, and makes NO network calls. Every external dependency the
# orchestrator touches is delivered through its injectable command seams, each
# pointed at a STUB:
#   - SWARM_POLL_CMD           -> a stub that EXITS with a chosen verdict code
#                                 (0/10/20/3/2) so we drive every routing branch.
#   - SWARM_ROTATE_CMD         -> a stub that RECORDS its invocation (+ flags +
#                                 the SWARM_ACTIVE_ACCOUNT it inherited) to a
#                                 witness file and exits with a chosen code. It
#                                 also answers `--next` with a fixed account so
#                                 the orchestrator can compute the post-rotate
#                                 active WITHOUT running the real actuator.
#   - SWARM_ACCOUNT_STATE_CMD  -> a stub that answers `get` from a state file and
#                                 records `set <acct>` to the witness + state file.
# The real swarm-usage-poll.sh and swarm-rotate.sh are NEVER executed.
#
# WHAT THIS PROTECTS:
#   1. ROUTING TABLE: 10 NEAR -> rotate; 20 AT -> rotate; 0 OK -> no rotate;
#      3 UNKNOWN -> no rotate; 2 config-error -> no rotate (logged). Only NEAR/AT
#      ever invoke the actuator.
#   2. STATE get-BEFORE / set-AFTER: on a successful rotate the orchestrator reads
#      the active account before and writes the new active after. A
#      failed/refused rotate writes NOTHING.
#   3. ACTIVE-ACCOUNT is fed to the actuator: the rotate stub witnesses the
#      SWARM_ACTIVE_ACCOUNT it inherited (proves the get result is exported).
#   4. ACTUATOR OUTCOMES map: rotate exit 0 -> tick 0 (+state set); rotate exit 3
#      (clean-boundary refusal) -> tick 3 (no state set); other rotate failure ->
#      tick 4 (no state set).
#   5. --dry-run: invokes the poll (read-only) but NOTHING that mutates — no
#      actuator call, no state set. Logs the plan.
#   6. NEAR never --force; AT --force only when SWARM_TICK_AT_FORCE=1.
#   7. LAUNCHD: the rotate-tick plist template renders to a WELL-FORMED plist with
#      the right Label + StartInterval (cadence), with NO placeholder surviving,
#      and the test NEVER runs `launchctl load`.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-rotate-tick.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TICK="$ROOT/bin/swarm-rotate-tick.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-rotate-tick.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── Stubs ─────────────────────────────────────────────────────────────────────
# Each stub is a real SCRIPT (not an inline command) so the witness wiring
# survives the layers of quoting the orchestrator puts it through (it invokes
# each seam via `sh -c "<cmd> ...args">`).
mkdir -p "$TMP/stubs"
WITNESS="$TMP/witness.log"
STATE_FILE="$TMP/active-account"   # the account-state stub's backing store
: > "$WITNESS"

# poll stub: exits with whatever code $TMP/poll.rc holds (the verdict under test).
# Prints a recognizable line so we can assert the orchestrator logs the poll out.
cat > "$TMP/stubs/poll.sh" <<EOF
#!/usr/bin/env bash
echo "stub-poll verdict line"
exit "\$(cat "$TMP/poll.rc" 2>/dev/null || echo 0)"
EOF

# rotate stub: answers --next with a fixed account ($TMP/next.acct, default
# 'max-NEXT'); otherwise records the invocation (with --force if present) AND the
# inherited SWARM_ACTIVE_ACCOUNT, then exits with $TMP/rotate.rc (default 0).
cat > "$TMP/stubs/rotate.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--next" ]; then
  cat "$TMP/next.acct" 2>/dev/null || echo "max-NEXT"
  exit 0
fi
_flags="\$*"
printf 'rotate:flags=[%s]:active=[%s]\n' "\$_flags" "\${SWARM_ACTIVE_ACCOUNT:-}" >> "$WITNESS"
exit "\$(cat "$TMP/rotate.rc" 2>/dev/null || echo 0)"
EOF

# account-state stub: `get` echoes the state file; `set <acct>` records it to the
# witness and writes the state file. Mirrors Phase-3's get|set contract.
cat > "$TMP/stubs/state.sh" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  get) cat "$STATE_FILE" 2>/dev/null || true ;;
  set) printf 'state-set:%s\n' "\${2:-}" >> "$WITNESS"; printf '%s' "\${2:-}" > "$STATE_FILE" ;;
  *)   echo "stub-state: unknown subcmd '\${1:-}'" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP"/stubs/*.sh

# Defaults for the per-run knobs.
echo 0          > "$TMP/poll.rc"     # poll verdict (overridden per test)
echo 0          > "$TMP/rotate.rc"   # actuator outcome (overridden per test)
echo "max-NEXT" > "$TMP/next.acct"   # what --next returns
printf 'max-CUR' > "$STATE_FILE"     # the stored active-before account

# run_tick ARGS...  — invoke the orchestrator with all three seams stubbed.
# Pre-set these OPTIONAL vars before the call to drive a test:
#   T_POLL_RC    -> poll verdict code           (default 0)
#   T_ROTATE_RC  -> actuator exit code          (default 0)
#   T_NEXT       -> account the rotate --next returns (default 'max-NEXT')
#   T_ACTIVE     -> stored active-before account (default 'max-CUR'; '' = empty)
#   T_AT_FORCE   -> SWARM_TICK_AT_FORCE value    (default unset)
# Captures stdout+stderr in $OUT, exit in $rc, and resets the witness each run.
reset_tt() { T_POLL_RC=0; T_ROTATE_RC=0; T_NEXT='max-NEXT'; T_ACTIVE='max-CUR'; T_AT_FORCE=''; }
reset_tt
run_tick() {
  printf '%s' "$T_POLL_RC"   > "$TMP/poll.rc"
  printf '%s' "$T_ROTATE_RC" > "$TMP/rotate.rc"
  printf '%s' "$T_NEXT"      > "$TMP/next.acct"
  printf '%s' "$T_ACTIVE"    > "$STATE_FILE"
  : > "$WITNESS"
  OUT="$(
    export SWARM_POLL_CMD="$TMP/stubs/poll.sh"
    export SWARM_ROTATE_CMD="$TMP/stubs/rotate.sh"
    export SWARM_ACCOUNT_STATE_CMD="$TMP/stubs/state.sh"
    [ -n "$T_AT_FORCE" ] && export SWARM_TICK_AT_FORCE="$T_AT_FORCE"
    bash "$TICK" "$@" 2>&1
  )"; rc=$?
  W="$(cat "$WITNESS")"
  reset_tt
}

# ---------------------------------------------------------------------------
echo "=== 1) ROUTING: OK(0) and UNKNOWN(3) do NOT rotate ==="
T_POLL_RC=0; run_tick
assert_eq 0 "$rc" "OK verdict -> tick exit 0"
assert_lacks "$W" "rotate:" "OK -> actuator NOT invoked"
assert_lacks "$W" "state-set:" "OK -> no state write"

T_POLL_RC=3; run_tick
assert_eq 0 "$rc" "UNKNOWN verdict -> tick exit 0 (fail-safe)"
assert_lacks "$W" "rotate:" "UNKNOWN -> actuator NOT invoked (probe failure never rotates)"
assert_lacks "$W" "state-set:" "UNKNOWN -> no state write"

# ---------------------------------------------------------------------------
echo "=== 2) ROUTING: config-error(2) does NOT rotate, but is logged + exit 2 ==="
T_POLL_RC=2; run_tick
assert_eq 2 "$rc" "config-error verdict -> tick exit 2"
assert_lacks "$W" "rotate:" "config-error -> actuator NOT invoked"
assert_lacks "$W" "state-set:" "config-error -> no state write"
assert_has "$OUT" "CONFIG ERROR" "config-error is logged"

# ---------------------------------------------------------------------------
echo "=== 3) ROUTING: NEAR(10) rotates at clean boundary (no --force) ==="
T_POLL_RC=10; run_tick
assert_eq 0 "$rc" "NEAR + actuator success -> tick exit 0"
assert_has "$W" "rotate:flags=[]" "NEAR -> actuator invoked WITHOUT --force"
assert_lacks "$W" "--force" "NEAR never forces"

# ---------------------------------------------------------------------------
echo "=== 4) ROUTING: AT(20) rotates; forces only with SWARM_TICK_AT_FORCE=1 ==="
T_POLL_RC=20; run_tick
assert_eq 0 "$rc" "AT (default, no opt-in) -> tick exit 0"
assert_has "$W" "rotate:flags=[]" "AT default -> actuator invoked WITHOUT --force"

T_POLL_RC=20; T_AT_FORCE=1; run_tick
assert_eq 0 "$rc" "AT + SWARM_TICK_AT_FORCE=1 -> tick exit 0"
assert_has "$W" "rotate:flags=[--force]" "AT + opt-in -> actuator invoked WITH --force"

# ---------------------------------------------------------------------------
echo "=== 5) STATE: get-BEFORE exported to actuator; set-AFTER on success ==="
T_POLL_RC=10; T_ACTIVE='max-CUR'; T_NEXT='max-NEXT'; run_tick
assert_eq 0 "$rc" "successful rotate -> tick exit 0"
assert_has "$W" "active=[max-CUR]" "actuator inherited SWARM_ACTIVE_ACCOUNT from the state GET (before)"
assert_has "$W" "state-set:max-NEXT" "new active persisted via state SET (after) = the --next account"
# Order: the actuator runs before the state SET (we set only after a clean success).
rot_line="$(grep -n '^rotate:'    "$WITNESS" | head -n1 | cut -d: -f1)"
set_line="$(grep -n '^state-set:' "$WITNESS" | head -n1 | cut -d: -f1)"
if [ -n "$rot_line" ] && [ -n "$set_line" ] && [ "$rot_line" -lt "$set_line" ]; then
  ok "ORDER: rotate (actuator) precedes state SET"
else
  bad "ORDER wrong (rotate=$rot_line set=$set_line)"
fi

# ---------------------------------------------------------------------------
echo "=== 6) ACTUATOR OUTCOMES: refusal(3) and failure(other) leave state alone ==="
# Actuator REFUSES at the clean-boundary guard (exit 3) -> tick 3, no state set.
T_POLL_RC=10; T_ROTATE_RC=3; run_tick
assert_eq 3 "$rc" "actuator clean-boundary refusal (3) -> tick exit 3"
assert_has "$W" "rotate:" "refusal: actuator WAS invoked"
assert_lacks "$W" "state-set:" "refusal: NO state write (active unchanged)"
assert_has "$OUT" "REFUSED at the clean-boundary guard" "refusal is explained"

# Actuator FAILS otherwise (e.g. exit 5 credswap failure) -> tick 4, no state set.
T_POLL_RC=10; T_ROTATE_RC=5; run_tick
assert_eq 4 "$rc" "actuator failure (5) -> tick exit 4"
assert_lacks "$W" "state-set:" "failure: NO state write (active unchanged)"
assert_has "$OUT" "actuator FAILED" "failure is explained"

# ---------------------------------------------------------------------------
echo "=== 7) --dry-run: polls (read-only) but invokes NOTHING live ==="
# NEAR verdict + dry-run: must NOT call the actuator and must NOT write state.
T_POLL_RC=10; run_tick --dry-run
assert_eq 0 "$rc" "--dry-run exits 0"
assert_has "$OUT" "DRY-RUN" "dry-run announces itself"
assert_has "$OUT" "WOULD rotate" "dry-run logs the plan it would take"
assert_lacks "$W" "rotate:" "--dry-run does NOT invoke the actuator (nothing live)"
assert_lacks "$W" "state-set:" "--dry-run does NOT write the account-state store"

# AT verdict + dry-run: still nothing live.
T_POLL_RC=20; run_tick --dry-run
assert_eq 0 "$rc" "--dry-run (AT) exits 0"
assert_lacks "$W" "rotate:" "--dry-run (AT) invokes nothing live"
assert_lacks "$W" "state-set:" "--dry-run (AT) writes no state"

# OK verdict + dry-run: short-circuits before any rotation logic.
T_POLL_RC=0; run_tick --dry-run
assert_eq 0 "$rc" "--dry-run (OK) exits 0"
assert_lacks "$W" "rotate:" "--dry-run (OK) invokes nothing"

# ---------------------------------------------------------------------------
echo "=== 8) empty stored active: actuator still invoked (cold-start), success persists --next ==="
T_POLL_RC=10; T_ACTIVE=''; T_NEXT='max-FIRST'; run_tick
assert_eq 0 "$rc" "empty active + NEAR -> still rotates (exit 0)"
assert_has "$W" "active=[]" "empty stored active is passed through (actuator cold-starts)"
assert_has "$W" "state-set:max-FIRST" "post-rotate active persisted from --next"

# ---------------------------------------------------------------------------
echo "=== 9) LAUNCHD: rotate-tick plist renders well-formed (NO launchctl load) ==="
# Render-only via the installer with a FAKE HOME/tmux + an explicit interval, and
# assert the rendered plist for our label is well-formed with the right cadence.
# This NEVER calls 'launchctl load' — render-only mode skips launchctl entirely.
LD_OUT="$TMP/ld"; mkdir -p "$LD_OUT"
FAKE_HOME="/Users/somebodyelse"
FAKE_TMUX="/some/other/prefix/bin/tmux"
HOME="$FAKE_HOME" SWARM_TMUX_BIN="$FAKE_TMUX" SWARM_HOME="$ROOT" SWARM_TICK_INTERVAL=180 \
  bash "$ROOT/bin/swarm-launchd-install.sh" --render-only "$LD_OUT" >/dev/null 2>"$TMP/ld.err"
ld_rc=$?
assert_eq 0 "$ld_rc" "launchd render-only exits 0"
[ "$ld_rc" -ne 0 ] && cat "$TMP/ld.err" >&2

PLIST="$LD_OUT/com.qofi.swarm-rotate-tick.plist"
if [ -f "$PLIST" ]; then
  ok "rotate-tick plist rendered"
  BODY="$(cat "$PLIST")"
  assert_has  "$BODY" "<string>com.qofi.swarm-rotate-tick</string>" "plist has the right Label"
  assert_has  "$BODY" "$ROOT/bin/swarm-rotate-tick.sh" "plist points at swarm-rotate-tick.sh (SWARM_HOME substituted)"
  assert_has  "$BODY" "<key>StartInterval</key>" "plist is PERIODIC (StartInterval present)"
  assert_has  "$BODY" "<integer>180</integer>" "StartInterval interval substituted from SWARM_TICK_INTERVAL (180)"
  assert_has  "$BODY" "$FAKE_HOME/.config/swarm/rotate-tick.log" "log path uses \$HOME"
  assert_lacks "$BODY" "@@" "no @@ placeholder survives in the rendered plist"
  # Belt-and-suspenders: a real plist linter, when available.
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then ok "plist passes plutil -lint"; else bad "plist failed plutil -lint"; fi
  fi
else
  bad "rotate-tick plist did NOT render at $PLIST"
fi

# Default interval (no SWARM_TICK_INTERVAL) renders 300.
LD_OUT2="$TMP/ld2"; mkdir -p "$LD_OUT2"
HOME="$FAKE_HOME" SWARM_TMUX_BIN="$FAKE_TMUX" SWARM_HOME="$ROOT" \
  bash "$ROOT/bin/swarm-launchd-install.sh" --render-only "$LD_OUT2" >/dev/null 2>&1
if [ -f "$LD_OUT2/com.qofi.swarm-rotate-tick.plist" ]; then
  assert_has "$(cat "$LD_OUT2/com.qofi.swarm-rotate-tick.plist")" "<integer>300</integer>" "default cadence is 300s when SWARM_TICK_INTERVAL unset"
else
  bad "default-interval render missing"
fi

# A bad interval is a config error (exit non-zero), not a malformed plist.
HOME="$FAKE_HOME" SWARM_TMUX_BIN="$FAKE_TMUX" SWARM_HOME="$ROOT" SWARM_TICK_INTERVAL=abc \
  bash "$ROOT/bin/swarm-launchd-install.sh" --render-only "$TMP/ld3" >/dev/null 2>&1
assert_eq 1 "$?" "non-numeric SWARM_TICK_INTERVAL -> installer refuses (exit 1), no plist rendered"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
