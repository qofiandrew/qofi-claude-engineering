#!/usr/bin/env bash
# test-provision-tokens.sh — regression tests for bin/swarm-provision-tokens.sh,
# the 1Password -> per-machine tokens.env provisioner.
#
# DEFAULT FLOW is a manual SILENT prompt (read -s): for each swarm in THIS
# machine's swarm.conf the operator pastes the token copied from 1Password.
# These tests drive that by PIPING values on stdin (one line per prompt, in
# swarm.conf order) — the same bytes a paste+Enter would deliver. An OPTIONAL
# automation path (SWARM_VAULT_FETCH) is also covered.
#
# WHAT THIS PROTECTS (the security-critical invariants of the secrets model):
#   1. SUBSET: tokens.env contains exactly the TOKEN_VAR_NAMEs in this
#      machine's swarm.conf — the per-machine least-privilege boundary.
#   2. NO LEAK: pasted secret VALUES never appear on stdout/stderr.
#   3. PERMS: tokens.env is chmod 600.
#   4. ATOMIC: a missing/empty value mid-run leaves an existing tokens.env intact.
#   5. DRY-RUN: lists names, prompts for nothing, writes nothing.
#   6. GIT-TRACKED REFUSAL: refuses if tokens.env is git-tracked.
#   7. --status: also provisions the shared SWARM_STATUS_SECRET/ENDPOINT.
#   8. OPTIONAL auto path: SWARM_VAULT_FETCH still fetches non-interactively.
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
assert_eq()        { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_file_has()  { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
assert_file_lacks(){ if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# Build a minimal fake SWARM_HOME (templates/ + swarm.conf satisfy the guard).
# Reads the swarm.conf body from stdin.
make_home() {
  local h; h="$(mktemp -d "${TMPDIR:-/tmp}/prov-home.XXXXXX")"
  mkdir -p "$h/templates"
  cat > "$h/swarm.conf"
  echo "$h"
}

# ---------------------------------------------------------------------------
echo "=== 1+2+3) manual paste: subset, no-leak, perms ==="
H="$(make_home <<'EOF'
acme   | /p/acme   | BOT_ACME   | 111222333444555666 | 999
beacon | /p/beacon | BOT_BEACON | 222333444555666777 | 999
# a comment row is ignored
EOF
)"
# Pipe the two pasted tokens in swarm.conf order (acme, beacon). SWARM_VAULT_FETCH
# is NOT set, so the script takes the manual-prompt path and reads them from stdin.
OUT="$(printf 'tok-ACME-secret\ntok-BEACON-secret\n' | SWARM_HOME="$H" bash "$PROVISION" 2>&1)"; rc=$?
assert_eq 0 "$rc" "provision exits 0"
TOK="$H/tokens.env"
assert_file_has  "$TOK" 'export BOT_ACME="tok-ACME-secret"'     "BOT_ACME provisioned from paste"
assert_file_has  "$TOK" 'export BOT_BEACON="tok-BEACON-secret"' "BOT_BEACON provisioned from paste"
assert_file_lacks "$TOK" 'BOT_OTHER'                            "no stray vars (subset is exact)"
perms="$(stat -f '%Lp' "$TOK" 2>/dev/null)"
assert_eq 600 "$perms" "tokens.env is chmod 600"
# NO-LEAK: the pasted secret values must not appear in the script's output.
if printf '%s' "$OUT" | grep -q 'tok-ACME-secret\|tok-BEACON-secret'; then bad "no-leak: pasted value leaked to stdout/stderr"; else ok "no-leak: pasted values absent from output"; fi
# var NAMES in the prompt are fine:
if printf '%s' "$OUT" | grep -q 'BOT_ACME'; then ok "var names shown in prompts"; else bad "var names should appear in prompts"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 4) atomic: an empty paste mid-run leaves existing tokens.env intact ==="
H="$(make_home <<'EOF'
acme   | /p/acme   | BOT_ACME   | 111 | 999
beacon | /p/beacon | BOT_BEACON | 222 | 999
EOF
)"
printf 'export SENTINEL="do-not-clobber"\n' > "$H/tokens.env"; chmod 600 "$H/tokens.env"
# First paste OK, second paste EMPTY (operator hit Enter with nothing) -> abort.
OUT="$(printf 'tok-ACME\n\n' | SWARM_HOME="$H" bash "$PROVISION" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "provision fails on an empty paste"; else bad "provision should fail on an empty paste"; fi
assert_file_has  "$H/tokens.env" 'SENTINEL="do-not-clobber"' "existing tokens.env left UNTOUCHED on failure"
assert_file_lacks "$H/tokens.env" 'BOT_ACME'                 "no partial write of the earlier paste"
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 5) --dry-run: names only, no prompt, no write ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
# Feed nothing on stdin; --dry-run must not attempt a read.
OUT="$(SWARM_HOME="$H" bash "$PROVISION" --dry-run </dev/null 2>&1)"; rc=$?
assert_eq 0 "$rc" "--dry-run exits 0 with no stdin (never prompts)"
if printf '%s' "$OUT" | grep -q 'BOT_ACME'; then ok "--dry-run lists the var name"; else bad "--dry-run should list var names"; fi
if [ -f "$H/tokens.env" ]; then bad "--dry-run must not write tokens.env"; else ok "--dry-run wrote nothing"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 6) refuse when tokens.env is git-tracked ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
( cd "$H" && git init -q && : > tokens.env && git add -f tokens.env ) >/dev/null 2>&1
OUT="$(printf 'tok\n' | SWARM_HOME="$H" bash "$PROVISION" 2>&1)"; rc=$?
assert_eq 2 "$rc" "provision exits 2 (FATAL) when tokens.env is git-tracked"
if printf '%s' "$OUT" | grep -qi 'tracked by git'; then ok "explains the git-tracked refusal"; else bad "should explain git-tracked refusal"; fi
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 7) --status prompts for the shared SWARM_STATUS_SECRET/ENDPOINT ==="
H="$(make_home <<'EOF'
acme | /p/acme | BOT_ACME | 111 | 999
EOF
)"
# Order: BOT_ACME, then SWARM_STATUS_SECRET, then SWARM_STATUS_ENDPOINT.
printf 'tok-ACME\nstatus-sekret\nhttps://ingest.example/ingest\n' | \
  SWARM_HOME="$H" bash "$PROVISION" --status >/dev/null 2>&1
assert_file_has "$H/tokens.env" 'export SWARM_STATUS_SECRET="status-sekret"'                  "--status provisions SWARM_STATUS_SECRET"
assert_file_has "$H/tokens.env" 'export SWARM_STATUS_ENDPOINT="https://ingest.example/ingest"' "--status provisions SWARM_STATUS_ENDPOINT"
assert_file_has "$H/tokens.env" 'export BOT_ACME='                                            "--status still provisions bot tokens"
rm -rf "$H"

# ---------------------------------------------------------------------------
echo "=== 8) OPTIONAL automation path: SWARM_VAULT_FETCH fetches non-interactively ==="
H="$(make_home <<'EOF'
acme   | /p/acme   | BOT_ACME   | 111 | 999
beacon | /p/beacon | BOT_BEACON | 222 | 999
EOF
)"
# No stdin needed — the fetch template supplies values. '{}' -> the var name.
OUT="$(SWARM_HOME="$H" SWARM_VAULT_FETCH='printf %s MOCK-{}' bash "$PROVISION" </dev/null 2>&1)"; rc=$?
assert_eq 0 "$rc" "auto path exits 0"
assert_file_has "$H/tokens.env" 'export BOT_ACME="MOCK-BOT_ACME"'     "auto path provisions BOT_ACME"
assert_file_has "$H/tokens.env" 'export BOT_BEACON="MOCK-BOT_BEACON"' "auto path provisions BOT_BEACON"
if printf '%s' "$OUT" | grep -q 'MOCK-BOT_'; then bad "auto path: value leaked to output"; else ok "auto path: values absent from output"; fi
rm -rf "$H"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
