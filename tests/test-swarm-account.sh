#!/usr/bin/env bash
# test-swarm-account.sh — bin/swarm-account.sh, the per-swarm FAILOVER actuator.
#
# SAFETY PROPERTY OF THIS FILE: it NEVER auth-probes a real credential, NEVER
# checkpoints/pushes a real repo, NEVER restarts a real swarm. Every external
# effect is delivered through swarm-account's injectable seams, each pointed at a
# stub that records to a witness file and returns a knob-controlled exit code:
#   SWARM_ACCOUNT_AUTHCHECK_CMD -> records "authcheck:<acct>", exits $AUTH_RC
#   SWARM_CHECKPOINT_CMD        -> records "checkpoint:<repo>", exits $CKPT_RC
#   SWARM_RESTART_CMD           -> records "restart:<name>:<flags>", exits $RESTART_RC
# HOME is redirected to a fixture so the resolver's $HOME/.claude-accounts/<label>
# provisioning check reads test dirs, never the operator's real accounts.
#
# WHAT THIS PROTECTS:
#   1. Validation order: bad name (1), bad label (2), unprovisioned target (3).
#   2. Auth-probe gate: auth-fail -> exit 4 NO swap; capped -> exit 7 NO swap;
#      uncertain -> exit 5 NO swap. The conf is untouched in all three.
#   3. Happy swap: checkpoint THEN field-rewrite THEN restart, in that order;
#      conf field 6 becomes the target; exit 0.
#   4. Clean-boundary REVERT: restart refuses (exit 2) -> field reverted, exit 6.
#   5. Restart other-failure: field STAYS, exit 9.
#   6. Checkpoint failure: exit 8 no swap; --force overrides.
#   7. Already-on-target: no-op exit 0, nothing fired.
#   8. Snapshot + --reset: first swap snapshots the default split; --reset
#      restores it churn-free.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-account.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── Fixture SWARM_HOME ────────────────────────────────────────────────────────
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates"        "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-account.sh" "$FAKE_SH/bin/swarm-account.sh"
chmod +x "$FAKE_SH/bin/swarm-account.sh"
ACCOUNT_BIN="$FAKE_SH/bin/swarm-account.sh"
CONF="$FAKE_SH/swarm.conf"

mkdir -p "$TMP/repo-alpha" "$TMP/repo-beta"

# ── Fixture HOME with a PROVISIONED account 'maxa' (config dir present) ────────
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude-accounts/maxa"          # maxa is provisioned
# (maxb intentionally NOT created -> unprovisioned)

# ── Stub seams ────────────────────────────────────────────────────────────────
WITNESS="$TMP/witness.log"
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/authcheck.sh" <<EOF
#!/usr/bin/env bash
printf 'authcheck:%s\n' "\${1:-}" >> "$WITNESS"
exit "\$(cat "$TMP/auth.rc" 2>/dev/null || echo 0)"
EOF
cat > "$TMP/stubs/checkpoint.sh" <<EOF
#!/usr/bin/env bash
printf 'checkpoint:%s\n' "\${1:-}" >> "$WITNESS"
exit "\$(cat "$TMP/ckpt.rc" 2>/dev/null || echo 0)"
EOF
cat > "$TMP/stubs/restart.sh" <<EOF
#!/usr/bin/env bash
printf 'restart:%s:%s\n' "\${1:-}" "\${2:-}" >> "$WITNESS"
exit "\$(cat "$TMP/restart.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$TMP"/stubs/*.sh
Q='"$1"'

# acct_of CONF NAME -> trimmed field 6
acct_of() { awk -F'|' -v n="$2" '
  /^[[:space:]]*(#|$)/ { next }
  { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v==n) { a=$6; gsub(/^[ \t]+|[ \t]+$/,"",a); print a; exit } }
' "$1"; }

# Reset the fixture conf + knobs before each case.
reset_conf() {
  cat > "$CONF" <<EOF
# name | repo | tok | channel | guild | account
alpha | $TMP/repo-alpha | BOT_ALPHA | 111 | 999 |
onmaxa | $TMP/repo-beta | BOT_BETA | 222 | 999 | maxa
EOF
  rm -f "$FAKE_SH/.swarm-accounts-default"
  echo 0 > "$TMP/auth.rc"; echo 0 > "$TMP/ckpt.rc"; echo 0 > "$TMP/restart.rc"
  : > "$WITNESS"
}

# run_acct ARGS... — invoke swarm-account.sh with the fixture env. Captures OUT/rc/W.
run_acct() {
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export HOME="$FAKE_HOME"
    export SWARM_ACCOUNT_AUTHCHECK_CMD="$TMP/stubs/authcheck.sh $Q"
    export SWARM_CHECKPOINT_CMD="$TMP/stubs/checkpoint.sh"
    export SWARM_RESTART_CMD="$TMP/stubs/restart.sh"
    export SWARM_TOKENS_ENV="$TMP/none.env"   # no vault file; token comes from env below
    export OAUTH_TOKEN_MAXA="tok-maxa-SECRET"
    bash "$ACCOUNT_BIN" "$@" 2>&1
  )"; rc=$?
  W="$(cat "$WITNESS")"
}

# ---------------------------------------------------------------------------
echo "=== 1) validation: bad name / bad label / unprovisioned ==="
reset_conf
run_acct nope maxa
assert_eq 1 "$rc" "unknown swarm name -> exit 1"
assert_eq "" "$W" "nothing fired for an unknown name"

reset_conf
run_acct alpha "bad/slash"
assert_eq 2 "$rc" "invalid target label -> exit 2"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha account untouched after a bad label"

reset_conf
run_acct alpha maxb        # maxb config dir does not exist
assert_eq 3 "$rc" "unprovisioned target (no config dir) -> exit 3"
assert_has "$OUT" "not provisioned" "explains the provisioning gap"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha untouched when target unprovisioned"

# ---------------------------------------------------------------------------
echo "=== 1b) provisioned config dir but NO vault token -> exit 3 ==="
reset_conf
OUT="$(
  export SWARM_HOME="$FAKE_SH" HOME="$FAKE_HOME"
  export SWARM_ACCOUNT_AUTHCHECK_CMD="$TMP/stubs/authcheck.sh $Q"
  export SWARM_CHECKPOINT_CMD="$TMP/stubs/checkpoint.sh" SWARM_RESTART_CMD="$TMP/stubs/restart.sh"
  export SWARM_TOKENS_ENV="$TMP/none.env"
  # OAUTH_TOKEN_MAXA intentionally UNSET
  bash "$ACCOUNT_BIN" alpha maxa 2>&1
)"; rc=$?
assert_eq 3 "$rc" "provisioned dir but missing token -> exit 3"
assert_has "$OUT" "no token in vault" "names the missing vault var"

# ---------------------------------------------------------------------------
echo "=== 2) auth-probe gate: fail(4) / capped(7) / uncertain(5) — never swaps ==="
reset_conf; echo 1 > "$TMP/auth.rc"; run_acct alpha maxa
assert_eq 4 "$rc" "auth-FAIL -> exit 4"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha NOT swapped on auth-fail"
assert_lacks "$W" "restart:" "no restart fired on auth-fail"
assert_lacks "$W" "checkpoint:" "no checkpoint fired on auth-fail (probe gates first)"

reset_conf; echo 75 > "$TMP/auth.rc"; run_acct alpha maxa
assert_eq 7 "$rc" "authed-but-CAPPED -> exit 7 (router tries next)"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha NOT swapped onto a capped account"

reset_conf; echo 2 > "$TMP/auth.rc"; run_acct alpha maxa
assert_eq 5 "$rc" "probe UNCERTAIN -> exit 5 (fail-safe, no swap)"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha NOT swapped on an uncertain probe"

# ---------------------------------------------------------------------------
echo "=== 3) happy swap: checkpoint -> rewrite -> restart, in order; exit 0 ==="
reset_conf; run_acct alpha maxa
assert_eq 0 "$rc" "clean swap -> exit 0"
assert_eq "maxa" "$(acct_of "$CONF" alpha)" "alpha.account rewritten -> maxa"
assert_has "$W" "checkpoint:$TMP/repo-alpha" "checkpoint ran for alpha's repo"
assert_has "$W" "restart:alpha:" "restart ran for alpha"
assert_lacks "$OUT" "tok-maxa-SECRET" "the token value never appears in output"
# Order: checkpoint precedes restart.
cp_line="$(printf '%s\n' "$W" | grep -n '^checkpoint:' | head -n1 | cut -d: -f1)"
rs_line="$(printf '%s\n' "$W" | grep -n '^restart:'    | head -n1 | cut -d: -f1)"
if [ -n "$cp_line" ] && [ -n "$rs_line" ] && [ "$cp_line" -lt "$rs_line" ]; then
  ok "ORDER: checkpoint < restart"
else bad "ORDER wrong (checkpoint=$cp_line restart=$rs_line)"; fi

# ---------------------------------------------------------------------------
echo "=== 3b) already on target -> no-op exit 0, nothing fired ==="
reset_conf; run_acct onmaxa maxa
assert_eq 0 "$rc" "already-on-target -> exit 0"
assert_has "$OUT" "already on account" "says it's a no-op"
assert_eq "" "$W" "no authcheck/checkpoint/restart fired for a no-op"

# ---------------------------------------------------------------------------
echo "=== 4) clean-boundary REFUSAL (restart exit 2) -> field REVERTED, exit 6 ==="
reset_conf; echo 2 > "$TMP/restart.rc"; run_acct alpha maxa
assert_eq 6 "$rc" "restart refused -> exit 6"
assert_eq "" "$(acct_of "$CONF" alpha)" "field REVERTED to default after a clean-boundary refusal"
assert_has "$OUT" "REVERTED" "explains the revert"

# ---------------------------------------------------------------------------
echo "=== 5) restart other-failure (exit 5) -> field STAYS, exit 9 ==="
reset_conf; echo 5 > "$TMP/restart.rc"; run_acct alpha maxa
assert_eq 9 "$rc" "restart failed (non-refusal) -> exit 9"
assert_eq "maxa" "$(acct_of "$CONF" alpha)" "field STAYS rewritten when restart fails for another reason"

# ---------------------------------------------------------------------------
echo "=== 6) checkpoint failure: exit 8 (no swap); --force overrides ==="
reset_conf; echo 1 > "$TMP/ckpt.rc"; run_acct alpha maxa
assert_eq 8 "$rc" "checkpoint failure without --force -> exit 8"
assert_eq "" "$(acct_of "$CONF" alpha)" "no swap when checkpoint fails"
assert_lacks "$W" "restart:" "no restart when checkpoint fails"

reset_conf; echo 1 > "$TMP/ckpt.rc"; run_acct alpha maxa --force
assert_eq 0 "$rc" "checkpoint failure WITH --force -> proceeds (exit 0)"
assert_eq "maxa" "$(acct_of "$CONF" alpha)" "--force swaps despite checkpoint failure"
assert_has "$W" "restart:alpha:--force" "--force is passed through to restart"

# ---------------------------------------------------------------------------
echo "=== 7) snapshot + --reset restores the default split (churn-free) ==="
reset_conf
run_acct alpha maxa                                  # first swap captures snapshot
assert_eq 0 "$rc" "swap for snapshot setup -> exit 0"
[ -f "$FAKE_SH/.swarm-accounts-default" ] && ok "default-split snapshot captured on first swap" || bad "snapshot file not created"
assert_eq "maxa" "$(acct_of "$CONF" alpha)" "alpha is on maxa before reset"
run_acct --reset
assert_eq 0 "$rc" "--reset -> exit 0"
assert_eq "" "$(acct_of "$CONF" alpha)" "alpha restored to default (empty) by --reset"
assert_eq "maxa" "$(acct_of "$CONF" onmaxa)" "onmaxa (originally maxa) restored to maxa, not churned"
# Second --reset with nothing drifted is churn-free.
run_acct --reset
assert_has "$OUT" "nothing to reset" "a second --reset is churn-free"

# ---------------------------------------------------------------------------
echo "=== 7b) --reset with no snapshot -> no-op exit 0 ==="
reset_conf   # removes the snapshot
run_acct --reset
assert_eq 0 "$rc" "--reset with no snapshot -> exit 0"
assert_has "$OUT" "never failed over" "honestly reports there is nothing to reset"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
