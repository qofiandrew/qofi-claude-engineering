#!/usr/bin/env bash
# test-swarm-credswap.sh — regression tests for bin/swarm-credswap-keychain.sh,
# the macOS-Keychain credential-swap adapter behind swarm-rotate's
# SWARM_CREDSWAP_CMD seam. This is the HIGHEST-RISK hook, so the tests are about
# one thing above all: FAIL-SAFE REVERSIBILITY.
#
# CRITICAL SAFETY PROPERTIES OF THIS TEST FILE (SYNTHETIC-FIXTURE discipline,
# mirroring swarm-doctor.sh / test-swarm-rotate.sh):
#   - It NEVER reads, writes, prints, or logs a REAL credential value.
#   - It NEVER references the real `claude` service name as a WRITE target: the
#     synthetic service name "swarm-credswap-TEST-$$" is used everywhere, and we
#     assert the adapter, run against it, never names "Claude Code-credentials".
#   - Two layers:
#       (A) LOGIC LEVEL — a MOCK keychain (a flat backing file) injected via
#           SWARM_KEYCHAIN_CMD. Deterministic; lets us INJECT a verify failure
#           and assert the backup is RESTORED. Always runs.
#       (B) REAL `security` LEVEL — same flows against the actual login keychain
#           under the synthetic test-only service, with guaranteed cleanup. This
#           block DEGRADES GRACEFULLY: if `security` add/find/delete are blocked
#           in the sandbox it SKIPS (reported honestly), it does not fail.
#
# WHAT THIS PROTECTS:
#   1. HAPPY PATH: backup -> install -> verify(pass) -> active slot holds NEXT.
#   2. VERIFY-FAILURE REVERSIBILITY: install a bad blob, verify fails -> the
#      PRIOR value is RESTORED to the slot and exit is non-zero (4).
#   3. INSTALL-FAILURE REVERSIBILITY: install fails -> prior value RESTORED (3).
#   4. EMPTY-SLOT REVERSIBILITY: no prior item, verify fails -> the slot is left
#      EMPTY again (restore = delete what we installed).
#   5. REFUSALS (no keychain change): no account; no blob source; empty blob; no
#      auth-verify available -> exit 2, slot untouched.
#   6. NO-LEAK: the synthetic secret value never appears on stdout/stderr.
#   7. SEAM CONTRACT: works when called the way swarm-rotate calls it
#      (SWARM_ROTATE_TO_ACCOUNT exported + account in $1), blob via stdin.
#   8. NEVER-TOUCH-REAL: the adapter's output never names the live claude service
#      as a write target while running against the synthetic service.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-credswap.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDSWAP="$ROOT/bin/swarm-credswap-keychain.sh"

PASS=0; FAIL=0; SKIP=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
skip() { printf '  SKIP  %s\n' "$1"; SKIP=$((SKIP+1)); }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-credswap-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A clearly synthetic, test-only service name (NEVER the real claude service).
TEST_SERVICE="swarm-credswap-TEST-$$"
TEST_ACCOUNT="synthetic-acct"
# Synthetic secret values — NOT real credentials. The whole point of the no-leak
# assertions is that even these throwaway markers must not appear in output.
PRIOR_BLOB="SYNTH-PRIOR-do-not-leak-$$"
NEXT_BLOB="SYNTH-NEXT-do-not-leak-$$"

# ===========================================================================
# (A) LOGIC LEVEL — a MOCK keychain injected via SWARM_KEYCHAIN_CMD.
# ===========================================================================
# The mock backs a single generic-password item with a flat file: line 1 holds
# the stored value (absent file == no item). It implements just the subcommands
# the adapter uses: find-generic-password (-w prints value), add-generic-password
# (-U upsert; value from stdin via `-w -`), delete-generic-password. A control
# file lets a test force find/add to FAIL, to exercise the install-failure path.
MOCK="$TMP/mock-security.sh"
MOCK_STORE="$TMP/mock-store"          # the item's value lives here (or absent)
MOCK_FAIL_ADD="$TMP/mock-fail-add"    # if present, add-generic-password fails
cat > "$MOCK" <<MOCKEOF
#!/usr/bin/env bash
# Mock 'security' — faithful to the REAL macOS semantics the adapter relies on:
#   * find-generic-password -w   prints the stored value + a trailing newline
#                                (real 'security' appends \n); exit 44 if absent.
#   * add-generic-password   -w  with NO value arg reads the password from stdin
#                                AS A PROMPT+RETYPE: two lines, must MATCH. We read
#                                both and store line 1 (matching real behavior).
#   * delete-generic-password    removes the item.
# Backing store: \$MOCK_STORE. A \$MOCK_FAIL_ADD control file forces add to fail
# (to exercise the install-failure rollback path).
set -u
store="\${MOCK_STORE:?}"
fail_add="\${MOCK_FAIL_ADD:-/nonexistent}"
sub="\${1:-}"; shift || true
# A bare -w means different things per subcommand (faithful to real 'security'):
# on FIND it requests the value be PRINTED; on ADD it requests the value be READ
# from the prompt (stdin). The adapter never passes a value AFTER -w (that would be
# argv exposure), so -w is always bare here. We key the behavior off the SUBcommand.
has_w=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -w) has_w=1; shift ;;
    -U) shift ;;
    -s|-a) shift 2 ;;
    *) shift ;;
  esac
done
case "\$sub" in
  find-generic-password)
    [ -f "\$store" ] || exit 44          # not found
    if [ "\$has_w" -eq 1 ]; then
      # find -w: print value + trailing newline (real 'security' does).
      printf '%s\n' "\$(cat "\$store")"
    fi
    exit 0 ;;
  add-generic-password)
    # One-shot injected failure: the FIRST add after the flag is set fails, then
    # the flag is consumed so the subsequent RESTORE add can succeed (proving the
    # rollback re-installs the prior value -> exit 3, not the unknown-state 6).
    if [ -f "\$fail_add" ]; then rm -f "\$fail_add"; exit 45; fi
    # Prompt+retype: read two lines from stdin; they must MATCH (as real does).
    IFS= read -r line1 || line1=""
    IFS= read -r line2 || line2=""
    if [ "\$line1" != "\$line2" ]; then exit 46; fi   # mismatch -> fail
    printf '%s' "\$line1" > "\$store"
    exit 0 ;;
  delete-generic-password)
    rm -f "\$store"; exit 0 ;;
  *) exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCK"

# run_logic — invoke the adapter against the MOCK keychain. Args:
#   \$1 = authcheck command ('true' passes, 'false' fails)
#   \$2.. = extra args to the adapter (the account handle, flags)
# Blob source: SWARM_CREDSWAP_BLOB_FETCH echoes NEXT_BLOB for any account.
# Captures \$OUT and \$rc.
run_logic() {
  local _auth="$1"; shift
  OUT="$(
    export MOCK_STORE MOCK_FAIL_ADD
    export SWARM_KEYCHAIN_CMD="$MOCK"
    export SWARM_CREDSWAP_SERVICE="$TEST_SERVICE"
    export SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT"
    export SWARM_CREDSWAP_AUTHCHECK_CMD="$_auth"
    export SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}"
    bash "$CREDSWAP" "$@" 2>&1
  )"; rc=$?
}
seed_prior() { printf '%s' "$PRIOR_BLOB" > "$MOCK_STORE"; }   # slot has a prior item
clear_slot() { rm -f "$MOCK_STORE"; }                          # slot empty
slot_value() { [ -f "$MOCK_STORE" ] && cat "$MOCK_STORE" || printf '<EMPTY>'; }

echo "=== (A) LOGIC LEVEL — mock keychain via SWARM_KEYCHAIN_CMD ==="

echo "--- 1) happy path: backup -> install -> verify(pass) -> slot holds NEXT ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_logic 'true' max-b
assert_eq 0 "$rc" "happy path exits 0"
assert_eq "$NEXT_BLOB" "$(slot_value)" "active slot now holds the NEXT credential"
assert_has "$OUT" "step 1/3" "ran step 1 (backup)"
assert_has "$OUT" "step 2/3" "ran step 2 (install)"
assert_has "$OUT" "step 3/3" "ran step 3 (verify)"
assert_has "$OUT" "DONE" "reports DONE on success"
assert_lacks "$OUT" "$PRIOR_BLOB" "no-leak: prior secret value never printed"
assert_lacks "$OUT" "$NEXT_BLOB"  "no-leak: next secret value never printed"

echo "--- 2) VERIFY failure -> PRIOR value RESTORED, exit 4 (the key safety prop) ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_logic 'false' max-b           # auth check fails AFTER install
assert_eq 4 "$rc" "verify failure -> exit 4"
assert_eq "$PRIOR_BLOB" "$(slot_value)" "RESTORED: prior credential is back in the slot"
assert_has "$OUT" "RESTORED" "announces the rollback"
assert_lacks "$OUT" "$PRIOR_BLOB" "no-leak: prior value not printed during rollback"
assert_lacks "$OUT" "$NEXT_BLOB"  "no-leak: bad next value not printed"

echo "--- 3) INSTALL failure -> PRIOR value RESTORED, exit 3 ---"
seed_prior; : > "$MOCK_FAIL_ADD"   # one-shot: the install add fails, restore add succeeds
run_logic 'true' max-b
assert_eq 3 "$rc" "install failure -> exit 3"
assert_eq "$PRIOR_BLOB" "$(slot_value)" "RESTORED: prior credential back after a failed install"
assert_lacks "$(slot_value)" "$NEXT_BLOB" "slot does not hold the NEXT (failed) blob"
assert_has "$OUT" "rolling back" "attempts rollback on install failure"
assert_has "$OUT" "RESTORED" "reports a successful rollback (exit 3, not unknown-state 6)"
rm -f "$MOCK_FAIL_ADD"

echo "--- 4) EMPTY-SLOT reversibility: no prior item + verify fails -> slot left EMPTY ---"
clear_slot; rm -f "$MOCK_FAIL_ADD"
run_logic 'false' max-b
assert_eq 4 "$rc" "empty slot + verify failure -> exit 4"
assert_eq "<EMPTY>" "$(slot_value)" "RESTORED to empty (restore = delete what we installed)"
assert_has "$OUT" "no current item" "notes there was no prior item to back up"

echo "--- 5) REFUSALS (no keychain change): no account / no blob / empty blob / no verify ---"
# 5a no account at all
OUT="$(SWARM_KEYCHAIN_CMD="$MOCK" MOCK_STORE="$MOCK_STORE" SWARM_CREDSWAP_SERVICE="$TEST_SERVICE" \
       SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT" SWARM_CREDSWAP_AUTHCHECK_CMD='true' \
       SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}" bash "$CREDSWAP" 2>&1)"; rc=$?
assert_eq 2 "$rc" "no next-account -> REFUSED (exit 2)"
# 5b no blob source
seed_prior
OUT="$(SWARM_KEYCHAIN_CMD="$MOCK" MOCK_STORE="$MOCK_STORE" SWARM_CREDSWAP_SERVICE="$TEST_SERVICE" \
       SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT" SWARM_CREDSWAP_AUTHCHECK_CMD='true' \
       bash "$CREDSWAP" max-b 2>&1)"; rc=$?
assert_eq 2 "$rc" "no blob source -> REFUSED (exit 2)"
assert_eq "$PRIOR_BLOB" "$(slot_value)" "slot UNTOUCHED when refusing for no blob source"
# 5c empty blob
OUT="$(SWARM_KEYCHAIN_CMD="$MOCK" MOCK_STORE="$MOCK_STORE" SWARM_CREDSWAP_SERVICE="$TEST_SERVICE" \
       SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT" SWARM_CREDSWAP_AUTHCHECK_CMD='true' \
       SWARM_CREDSWAP_BLOB_FETCH='printf %s "" # {}' bash "$CREDSWAP" max-b 2>&1)"; rc=$?
assert_eq 2 "$rc" "empty blob -> REFUSED (exit 2)"
assert_has "$OUT" "empty credential blob" "explains the empty-blob refusal"
# 5d no auth verify available: SWARM_CREDSWAP_AUTHCHECK_CMD unset, AND the real
# auth-probe helper (bin/swarm-auth-probe.sh — now the preferred default verifier)
# is NOT reachable, AND `claude` is not on PATH. To make the probe genuinely
# absent we run a COPY of the adapter from a scratch dir that has no sibling
# swarm-auth-probe.sh; the adapter discovers the probe via $(dirname "$0"), so a
# lone copy can't find it. `claude` lives in ~/.local/bin; PATH=/usr/bin:/bin
# keeps the core tools (id, mktemp, cat, ...) but excludes `claude`, so
# `command -v claude` fails deterministically. With NO verifier of any kind, the
# adapter must REFUSE rather than swap a credential it cannot then VERIFY.
LONE_DIR="$TMP/lone-bin"; mkdir -p "$LONE_DIR"
cp "$CREDSWAP" "$LONE_DIR/swarm-credswap-keychain.sh"   # copy WITHOUT the probe sibling
OUT="$(SWARM_KEYCHAIN_CMD="$MOCK" MOCK_STORE="$MOCK_STORE" SWARM_CREDSWAP_SERVICE="$TEST_SERVICE" \
       SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT" PATH="/usr/bin:/bin" \
       SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}" /bin/bash "$LONE_DIR/swarm-credswap-keychain.sh" max-b 2>&1)"; rc=$?
assert_eq 2 "$rc" "no auth-verify available (no probe, no claude) -> REFUSED (exit 2)"
assert_has "$OUT" "unverifiable swap" "refuses an unverifiable swap"

echo "=== (A2) REAL AUTH PROBE wired as the default verifier — the 3-way (b)-vs-(c) split ==="
# These tests drive the FULL chain that closes the auth-check hole: the adapter's
# VERIFY step runs bin/swarm-auth-probe.sh (the real default verifier), and the
# probe's outcome is itself driven by a SYNTHETIC probe call (SWARM_AUTH_PROBE_CMD)
# so no live `claude` and no real credential are ever involved. The point is the
# distinction the old `claude --version` default could not make:
#   (b) bad/expired credential        -> probe exit 1  -> adapter RESTORES (exit 4)
#   (c) authenticates but rate-limited -> probe exit 75 -> adapter KEEPS swap (exit 7)
AUTHPROBE="$ROOT/bin/swarm-auth-probe.sh"

# run_probe — like run_logic but the authcheck is the REAL probe, with its
# underlying probe CALL stubbed to a chosen outcome. \$1 = the synthetic probe
# command (stdout/stderr + exit that the probe classifies); \$2.. = adapter args.
run_probe() {
  local _probe_cmd="$1"; shift
  OUT="$(
    export MOCK_STORE MOCK_FAIL_ADD
    export SWARM_KEYCHAIN_CMD="$MOCK"
    export SWARM_CREDSWAP_SERVICE="$TEST_SERVICE"
    export SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT"
    export SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}"
    # The adapter's verify = the real probe; the probe's call = our synthetic stub.
    export SWARM_CREDSWAP_AUTHCHECK_CMD="$AUTHPROBE"
    export SWARM_AUTH_PROBE_CMD="$_probe_cmd"
    bash "$CREDSWAP" "$@" 2>&1
  )"; rc=$?
}

echo "--- A2.1) probe says AUTHENTICATES (good) -> swap proceeds, slot holds NEXT, exit 0 ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_probe 'printf "pong\n"; exit 0' max-b
assert_eq 0 "$rc" "good credential (probe exit 0) -> swap succeeds (exit 0)"
assert_eq "$NEXT_BLOB" "$(slot_value)" "active slot holds the NEXT credential (swap kept)"
assert_has "$OUT" "authenticates" "verify reports the credential authenticates"

echo "--- A2.2) (b) BAD/EXPIRED synthetic credential -> RESTORE path, exit 4 (the proof owed) ---"
# A deliberately-bad credential: the probe call fails to authenticate (non-zero,
# auth-error surface). The adapter MUST roll back to the prior value. This is the
# restore-on-bad-cred proof the build review owed — driven through the real probe.
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_probe 'printf "authentication_error: OAuth token has expired\n" >&2; exit 1' max-b
assert_eq 4 "$rc" "BAD credential (probe -> auth-fail) -> RESTORE path, exit 4"
assert_eq "$PRIOR_BLOB" "$(slot_value)" "RESTORED: prior credential is back in the slot (bad swap rolled back)"
assert_has "$OUT" "RESTORED" "announces the rollback on a bad credential"
assert_lacks "$OUT" "$NEXT_BLOB" "no-leak: the bad next value is not printed"

echo "--- A2.3) (b) bare non-zero probe (no message) is still treated as bad -> RESTORE, exit 4 ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_probe 'exit 9' max-b
assert_eq 4 "$rc" "non-zero probe with no signal -> fail-closed RESTORE, exit 4"
assert_eq "$PRIOR_BLOB" "$(slot_value)" "RESTORED: fail-closed rolls the slot back to prior"

echo "--- A2.4) (c) AUTHENTICATES-BUT-RATE-LIMITED -> does NOT restore, swap KEPT, exit 7 ---"
# The crux of (b)-vs-(c): the rotate target's credential is GOOD (it authenticates)
# but the account is itself capped. Restoring would thrash to the (also-capped)
# prior account, so the adapter KEEPS the swap and signals ring exhaustion (exit 7).
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_probe 'printf "Claude usage limit reached - resets at 11pm\n"; exit 0' max-b
assert_eq 7 "$rc" "authed-but-rate-limited -> ring-exhaustion signal (exit 7), NOT verify-fail (4)"
assert_eq "$NEXT_BLOB" "$(slot_value)" "NOT restored: the swap is KEPT (new credential is valid, just capped)"
assert_lacks "$OUT" "rolling back" "does NOT thrash-restore a valid-but-capped credential"
assert_has "$OUT" "RING EXHAUSTION" "surfaces ring exhaustion (rotation has nowhere fresh to go)"

echo "--- A2.5) (c) rate-limit on a NON-zero probe exit is also classified capped, not bad ---"
# A 429 can ride on a non-zero exit too; the limit signal is authoritative either
# way (the credential authenticated far enough to be told it's capped).
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_probe 'printf "rate limit\n" >&2; exit 1' max-b
assert_eq 7 "$rc" "rate-limit signal on non-zero exit -> still (c) capped, exit 7"
assert_eq "$NEXT_BLOB" "$(slot_value)" "still NOT restored on a capped (non-zero) probe"

echo "--- 6) NEVER name the real claude service as a write target ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
run_logic 'true' max-b
assert_lacks "$OUT" "Claude Code-credentials" "output never names the live claude service (using synthetic)"

echo "--- 7) SEAM CONTRACT: swarm-rotate-style invocation (env + \$1, blob via stdin) ---"
seed_prior; rm -f "$MOCK_FAIL_ADD"
# Exactly how swarm-rotate runs it: SWARM_ROTATE_TO_ACCOUNT exported + acct in $1.
OUT="$(
  export MOCK_STORE MOCK_FAIL_ADD
  export SWARM_KEYCHAIN_CMD="$MOCK"
  export SWARM_CREDSWAP_SERVICE="$TEST_SERVICE"
  export SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT"
  export SWARM_CREDSWAP_AUTHCHECK_CMD='true'
  export SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}"
  SWARM_ROTATE_TO_ACCOUNT="max-b" sh -c "$CREDSWAP \"\$1\"" _ "max-b" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "rotate-style invocation succeeds"
assert_eq "$NEXT_BLOB" "$(slot_value)" "rotate-style swap installed NEXT via stdin"

# ===========================================================================
# (B) REAL `security` LEVEL — synthetic service, guaranteed cleanup, or SKIP.
# ===========================================================================
echo ""
echo "=== (B) REAL security — synthetic service '$TEST_SERVICE' (or SKIP if sandboxed) ==="

# Probe: can we add/find/delete a generic-password under the synthetic service?
real_cleanup() { security delete-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" >/dev/null 2>&1 || true; }
real_cleanup   # pre-clean any leftover from a crashed prior run
REAL_OK=0
if security add-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" -w "probe" >/dev/null 2>&1; then
  if security find-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" >/dev/null 2>&1; then
    REAL_OK=1
  fi
fi
real_cleanup

if [ "$REAL_OK" -ne 1 ]; then
  skip "real 'security' keychain writes blocked in this sandbox — logic-level (mock) tests above stand in"
else
  # Helper: read the synthetic slot's value WITH -w. This is a TEST reading a value
  # it itself wrote (a synthetic marker), to PROVE the adapter installed/restored
  # the right bytes — it is never a real credential.
  real_slot() { security find-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" -w 2>/dev/null || printf '<EMPTY>'; }
  real_seed_prior() { security add-generic-password -U -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" -w "$PRIOR_BLOB" >/dev/null 2>&1; }

  run_real() {  # AUTHCHECK ACCOUNT-ARG
    OUT="$(
      export SWARM_CREDSWAP_SERVICE="$TEST_SERVICE"
      export SWARM_CREDSWAP_ACCOUNT="$TEST_ACCOUNT"
      export SWARM_CREDSWAP_AUTHCHECK_CMD="$1"
      export SWARM_CREDSWAP_BLOB_FETCH="printf %s $NEXT_BLOB # {}"
      bash "$CREDSWAP" "$2" 2>&1
    )"; rc=$?
  }

  echo "--- B1) REAL happy path: slot ends up holding NEXT ---"
  real_seed_prior
  run_real 'true' max-b
  assert_eq 0 "$rc" "REAL happy path exits 0"
  assert_eq "$NEXT_BLOB" "$(real_slot)" "REAL: slot holds NEXT after a verified swap"
  assert_lacks "$OUT" "$PRIOR_BLOB" "REAL no-leak: prior value not printed"
  assert_lacks "$OUT" "$NEXT_BLOB"  "REAL no-leak: next value not printed"

  echo "--- B2) REAL verify failure -> PRIOR RESTORED in the real keychain ---"
  real_seed_prior
  run_real 'false' max-b
  assert_eq 4 "$rc" "REAL verify failure -> exit 4"
  assert_eq "$PRIOR_BLOB" "$(real_slot)" "REAL RESTORED: prior credential back in the real slot"
  assert_has "$OUT" "RESTORED" "REAL: announces rollback"

  echo "--- B3) REAL empty-slot reversibility: no prior + verify fails -> slot EMPTY ---"
  real_cleanup   # ensure no prior item
  run_real 'false' max-b
  assert_eq 4 "$rc" "REAL empty + verify failure -> exit 4"
  assert_eq "<EMPTY>" "$(real_slot)" "REAL RESTORED to empty (deleted what we installed)"

  # CLEANUP — the synthetic entry must not survive the test run.
  real_cleanup
  if security find-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" >/dev/null 2>&1; then
    bad "CLEANUP: synthetic keychain entry '$TEST_SERVICE' still present after the run"
  else
    ok "CLEANUP: synthetic keychain entry removed"
  fi
fi

# Final belt-and-suspenders cleanup regardless of path.
security delete-generic-password -s "$TEST_SERVICE" -a "$TEST_ACCOUNT" >/dev/null 2>&1 || true

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
