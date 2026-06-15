#!/usr/bin/env bash
# test-swarm-account-preflight.sh — bin/swarm-account-preflight.sh, the activation
# readiness gate (ADR-0018).
#
# SAFETY PROPERTY: never reads a real token value. The VAULT check is exercised
# with a fixture tokens.env containing a SECRET; the test asserts the secret VALUE
# never appears in preflight's output (only the variable NAME may).
#
# WHAT THIS PROTECTS:
#   1. PASS path: against the REAL repo (F1 launcher live, substrate present) with a
#      clean vault -> exit 0, "PASS" printed, no FAIL lines.
#   2. F1 refusal: against a FAKE tree whose swarm-up.sh is PRE-F1 (blanket `set -a`,
#      no scrub) -> exit 2, the scrub-missing + set-a failures fire. This is the
#      load-bearing guard: it must REFUSE to greenlight a pre-F1 launcher.
#   3. Vault token present -> FAIL (exit 2) by default; --allow-tokens -> PASS (NOTE).
#      In BOTH cases the token VALUE never appears in output (NAME-only).
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account-preflight.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREF="$ROOT/bin/swarm-account-preflight.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
echo "=== PASS path: real repo, F1 live, clean vault ==="
EMPTY_VAULT="$TMP/empty.env"; : > "$EMPTY_VAULT"
OUT="$(SWARM_HOME="$ROOT" SWARM_TOKENS_ENV="$EMPTY_VAULT" bash "$PREF" 2>&1)"; RC=$?
assert_eq "0" "$RC" "clean tree -> exit 0"
assert_has "$OUT" "PASS — safe to provision" "final PASS line printed"
assert_lacks "$OUT" "  FAIL  " "no FAIL lines on a clean tree"
assert_has "$OUT" "scrub loop present" "F1 scrub loop detected on the real launcher"
assert_has "$OUT" "scoped token derive present" "F1 scoped derive detected on the real launcher"

# ---------------------------------------------------------------------------
echo "=== F1 refusal: a PRE-F1 launcher must be REFUSED ==="
FAKE="$TMP/fake"; mkdir -p "$FAKE/templates" "$FAKE/bin"
printf 'x | /tmp/x | BOT_X | 1 | 2 |\n' > "$FAKE/swarm.conf"
# A pre-F1 launcher: blanket auto-export, NO scrub loop, token is a literal.
cat > "$FAKE/bin/swarm-up.sh" <<'EOF'
#!/usr/bin/env bash
# pre-F1 launcher (the leak): sources the whole vault and auto-exports it.
set -a
. "$TOKENS"
set +a
tmux send-keys -t "$sess" "export DISCORD_BOT_TOKEN=$SOME_TOKEN" C-m
EOF
# Substrate present so ONLY the F1 checks fail (isolates the assertion).
cat > "$FAKE/bin/swarm-lib.sh" <<'EOF'
swarm_account_resolve() { :; }
SWARM_CONF_F_ACCOUNT=""
swarm_conf_set_account() { :; }
EOF
cat > "$FAKE/bin/swarm-account.sh" <<'EOF'
# swap actuator uses swarm_account_resolve
EOF
OUT="$(SWARM_HOME="$FAKE" SWARM_TOKENS_ENV="$EMPTY_VAULT" bash "$PREF" 2>&1)"; RC=$?
assert_eq "2" "$RC" "pre-F1 launcher -> exit 2 (REFUSED)"
assert_has "$OUT" "F1 scrub loop MISSING" "refuses: scrub loop missing"
assert_has "$OUT" "live 'set -a' blanket auto-export is present" "refuses: live set -a detected"
assert_has "$OUT" "swarm_account_resolve" "substrate check still ran (resolver present)"

# ---------------------------------------------------------------------------
echo "=== VAULT: a token present FAILs by default; value NEVER printed ==="
TOKVAULT="$TMP/withtoken.env"; printf 'export OAUTH_TOKEN_MAXB=TOPSECRET-VALUE-9z\n' > "$TOKVAULT"
OUT="$(SWARM_HOME="$ROOT" SWARM_TOKENS_ENV="$TOKVAULT" bash "$PREF" 2>&1)"; RC=$?
assert_eq "2" "$RC" "token in vault (no --allow-tokens) -> exit 2"
assert_has  "$OUT" "OAUTH_TOKEN_MAXB" "the token NAME is reported"
assert_lacks "$OUT" "TOPSECRET-VALUE-9z" "the token VALUE is NEVER printed (default)"

echo "=== VAULT: --allow-tokens downgrades to NOTE, still PASS, value hidden ==="
OUT="$(SWARM_HOME="$ROOT" SWARM_TOKENS_ENV="$TOKVAULT" bash "$PREF" --allow-tokens 2>&1)"; RC=$?
assert_eq "0" "$RC" "--allow-tokens with token present -> exit 0"
assert_has  "$OUT" "NOTE" "--allow-tokens reports a NOTE, not a failure"
assert_lacks "$OUT" "TOPSECRET-VALUE-9z" "the token VALUE is NEVER printed (--allow-tokens)"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
