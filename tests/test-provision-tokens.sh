#!/usr/bin/env bash
# test-provision-tokens.sh — regression tests for bin/swarm-provision-tokens.sh,
# the vault -> per-machine tokens.env provisioner.
#
# WHAT THIS PROTECTS (the security-critical invariants of the secrets model):
#   1. SUBSET: tokens.env contains exactly the TOKEN_VAR_NAMEs in this
#      machine's swarm.conf — the per-machine least-privilege boundary.
#   2. NO LEAK: secret VALUES never appear on the script's stdout/stderr.
#   3. PERMS: tokens.env is chmod 600.
#   4. ATOMIC: a mid-run vault failure leaves an existing tokens.env untouched.
#   5. DRY-RUN: lists names, makes no vault calls, writes nothing.
#   6. GIT-TRACKED REFUSAL: refuses to provision if tokens.env is git-tracked.
#   7. --status: also provisions the shared SWARM_STATUS_SECRET/ENDPOINT.
#
# A mock vault (printf / tiny script) stands in for the real fetch command, so
# the test is hermetic and never touches a real secret store.
#
# Run from $SWARM_HOME:  bash tests/test-provision-tokens.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROVISION="$ROOT/bin/swarm-provision-tokens.sh"

PASS=0; FAIL=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
assert_file_lacks(){ if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# Build a minimal fake SWARM_HOME (templates/ + swarm.conf satisfy the guard).
make_home() {  # -> echoes a fresh temp SWARM_HOME with the given conf body on stdin
  local h; h="$(mktemp -d "${TMPDIR:-/tmp}/prov-home.XXXXXX")"
  mkdir -p "$h/templates"
  cat > "$h/swarm.conf"
  echo "$h"
}

# ---------------------------------------------------------------------------
echo "=== 1+2+3) subset, no-leak, perms ==="
H="$(make_home <<'EOF'
acme   | /p/acme   | BOT_ACME   | 111222333444555666 | 999
beacon | /p/beacon | BOT_BEACON | 222333444555666777 | 999
# a comment row is ignored
EOF
)"
OUT="$(SWARM_HOME="$H" SWARM_VAULT_FETCH='printf %s MOCK-{}' bash "$PROVISION" 2>&1)"; rc=$?
assert_eq 0 "$rc" "provision exits 0"
TOK="$H/tokens.env"
assert_file_has  "$TOK" 'export BOT_ACME="MOCK-BOT_ACME"'     "BOT_ACME provisioned"
assert_file_has  "$TOK" 'export BOT_BEACON="MOCK-BOT_BEACON"' "BOT_BEACON provisioned"
assert_file_lacks "$TOK" 'BOT_OTHER'                          "no stray vars (subset is exact)"
perms="$(stat -f '%Lp' "$TOK" 2>/dev/null)"
assert_eq 600 "$perms" "tokens.env is chmod 600"
# NO-LEAK: the secret value must not appear in the script's output.
if printf '%s' "$OUT" | grep -q 'MOCK-BOT_'; then bad "no-leak: secret value leaked to stdout/stderr"; else ok "no-leak: secret values absent from output"; fi
# but the var NAMES are fine to print:
if printf '%s' "$OUT" | grep -q 'BOT_ACME'; then ok "var names reported in output"; else bad "var names should be reported"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 4) atomic: mid-run vault failure leaves existing tokens.env intact ==="
H="$(make_home <<'EOF'
acme   | /p/acme   | BOT_ACME   | 111 | 999
beacon | /p/beacon | BOT_BEACON | 222 | 999
EOF
)"
printf 'export SENTINEL="do-not-clobber"\n' > "$H/tokens.env"; chmod 600 "$H/tokens.env"
cat > "$H/mockfetch.sh" <<'EOF'
#!/bin/sh
case "$1" in
  BOT_BEACON) exit 1 ;;          # simulate a vault miss mid-run
  *) printf %s "MOCK-$1" ;;
esac
EOF
chmod +x "$H/mockfetch.sh"
OUT="$(SWARM_HOME="$H" SWARM_VAULT_FETCH="$H/mockfetch.sh {}" bash "$PROVISION" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "provision fails when a fetch fails"; else bad "provision should fail when a fetch fails"; fi
assert_file_has  "$H/tokens.env" 'SENTINEL="do-not-clobber"' "existing tokens.env left UNTOUCHED on failure"
assert_file_lacks "$H/tokens.env" 'BOT_ACME'                 "no partial write of earlier-fetched token"
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 5) --dry-run: names only, no fetch, no write ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
# SWARM_VAULT_FETCH set to a command that WOULD fail if ever called.
OUT="$(SWARM_HOME="$H" SWARM_VAULT_FETCH='false' bash "$PROVISION" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "--dry-run exits 0 even with a failing fetch (never calls it)"
if printf '%s' "$OUT" | grep -q 'BOT_ACME'; then ok "--dry-run lists the var name"; else bad "--dry-run should list var names"; fi
if [ -f "$H/tokens.env" ]; then bad "--dry-run must not write tokens.env"; else ok "--dry-run wrote nothing"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 6) refuse when tokens.env is git-tracked ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
( cd "$H" && git init -q && git add templates 2>/dev/null; : > tokens.env && git add -f tokens.env ) >/dev/null 2>&1
OUT="$(SWARM_HOME="$H" SWARM_VAULT_FETCH='printf %s MOCK-{}' bash "$PROVISION" 2>&1)"; rc=$?
assert_eq 2 "$rc" "provision exits 2 (FATAL) when tokens.env is git-tracked"
if printf '%s' "$OUT" | grep -qi 'tracked by git'; then ok "explains the git-tracked refusal"; else bad "should explain git-tracked refusal"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 7) --status pulls the shared SWARM_STATUS_SECRET/ENDPOINT ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
SWARM_HOME="$H" SWARM_VAULT_FETCH='printf %s MOCK-{}' bash "$PROVISION" --status >/dev/null 2>&1
assert_file_has "$H/tokens.env" 'export SWARM_STATUS_SECRET="MOCK-SWARM_STATUS_SECRET"'     "--status provisions SWARM_STATUS_SECRET"
assert_file_has "$H/tokens.env" 'export SWARM_STATUS_ENDPOINT="MOCK-SWARM_STATUS_ENDPOINT"' "--status provisions SWARM_STATUS_ENDPOINT"
assert_file_has "$H/tokens.env" 'export BOT_ACME='                                          "--status still provisions bot tokens"
rm -rf "$H"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
