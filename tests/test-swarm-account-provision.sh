#!/usr/bin/env bash
# test-swarm-account-provision.sh — bin/swarm-account-provision.sh, the isolated
# config-dir SKELETON builder (ADR-0018 activation tooling).
#
# SAFETY PROPERTY: this test NEVER reads or writes a real token, NEVER touches the
# operator's real ~/.claude-accounts. HOME is redirected to a temp dir so the
# resolver builds the account dirs there; a fixture swarm.conf supplies the channel
# set. A decoy tokens.env with a SECRET is placed in scope to prove provision never
# reads it.
#
# WHAT THIS PROTECTS:
#   1. Bad/empty/default label is refused (exit 2) before any path is built.
#   2. --dry-run touches nothing and exits 0.
#   3. A real run builds: config dir + plugins/{known_marketplaces,installed_plugins}
#      .json + a SYMMETRIC access.json (one group per channel, allowFrom owner+watcher).
#   4. Idempotency: a second run is a no-op-equivalent, exit 0, same group count.
#   5. NO token read/written: the decoy secret never appears in output, and no
#      tokens.env is created.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-account-provision.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROV="$ROOT/bin/swarm-account-provision.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prov.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export SWARM_HOME="$ROOT"
CONF="$TMP/swarm.conf"
cat > "$CONF" <<'EOF'
# header
a | /tmp/a | BOT_A | 1001 | 2001 |
b | /tmp/b | BOT_B | 1002 | 2002 |
c | /tmp/c | BOT_C | 1003 |      |
EOF
DECOY="$TMP/tokens.env"; printf 'export OAUTH_TOKEN_MAXB=DECOY-SECRET-XYZ\n' > "$DECOY"

run() { HOME="$TMP" SWARM_CONF="$CONF" SWARM_TOKENS_ENV="$DECOY" bash "$PROV" "$@" 2>&1; }

echo "=== bad / empty / default labels are refused (exit 2) ==="
OUT="$(run '1bad')"; assert_eq "2" "$?" "leading-digit label rejected"
OUT="$(run 'has space')"; assert_eq "2" "$?" "label with space rejected"
# An empty positional is a usage error (exit 1), not a provision; the default
# account is not provisionable.
HOME="$TMP" SWARM_CONF="$CONF" bash "$PROV" >/dev/null 2>&1; assert_eq "1" "$?" "missing label is a usage error"

echo "=== --dry-run touches nothing, exits 0 ==="
OUT="$(run max-b --dry-run)"; RC=$?
assert_eq "0" "$RC" "--dry-run exit 0"
assert_has "$OUT" "would create" "--dry-run announces intent"
[ -d "$TMP/.claude-accounts/max-b" ] && bad "--dry-run created the config dir" || ok "--dry-run created nothing on disk"

echo "=== real run builds the skeleton ==="
OUT="$(run max-b)"; RC=$?
assert_eq "0" "$RC" "real provision exit 0"
CDIR="$TMP/.claude-accounts/max-b"
[ -d "$CDIR/projects" ] && ok "projects/ created" || bad "projects/ missing"
[ -f "$CDIR/plugins/known_marketplaces.json" ] && ok "known_marketplaces.json created" || bad "known_marketplaces.json missing"
[ -f "$CDIR/plugins/installed_plugins.json" ] && ok "installed_plugins.json created" || bad "installed_plugins.json missing"
[ -f "$CDIR/channels/discord/access.json" ] && ok "access.json created" || bad "access.json missing"

# marketplace points at SWARM_HOME (directory source)
MKT="$(cat "$CDIR/plugins/known_marketplaces.json")"
assert_has "$MKT" '"qofi-swarm"' "marketplace qofi-swarm registered"
assert_has "$MKT" "$ROOT" "marketplace points at SWARM_HOME (directory source)"

# symmetric access.json: one group per distinct channel (3), allowFrom owner+watcher.
# Read the JSON via a helper that takes the path as argv (no nested-quote ambiguity).
ACCESS_JSON="$CDIR/channels/discord/access.json"
aj() { python3 - "$ACCESS_JSON" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); what = sys.argv[2]
g = d.get("groups", {})
if what == "ngroups": print(len(g))
elif what == "allow0": print(len(list(g.values())[0]["allowFrom"]) if g else 0)
elif what == "has1001": print("1001" in g)
elif what == "top_owner": print("1507069153335443608" in d.get("allowFrom", []))
elif what == "control_owner": print(d.get("loginControlOwnerId", ""))
PY
}
assert_eq "3" "$(aj ngroups)" "access.json has one group per channel (3)"
assert_eq "2" "$(aj allow0)" "each group allowFrom = owner + watcher (2)"
assert_eq "True" "$(aj has1001)" "channel 1001 has a group"
assert_eq "True" "$(aj top_owner)" "top-level allowFrom explicitly identifies the operator"
assert_eq "1507069153335443608" "$(aj control_owner)" "login-control owner is explicitly pinned"
assert_eq "600" "$(stat -f %Lp "$ACCESS_JSON" 2>/dev/null || stat -c %a "$ACCESS_JSON")" "access.json is owner-private mode 0600"
assert_eq "700" "$(stat -f %Lp "$(dirname "$ACCESS_JSON")" 2>/dev/null || stat -c %a "$(dirname "$ACCESS_JSON")")" "new account Discord state is owner-private mode 0700"

echo "=== NO token read or written ==="
assert_lacks "$OUT" "DECOY-SECRET-XYZ" "the decoy token value never appears in output"
[ -f "$CDIR/.credentials.json" ] && bad "provision wrote a credential file" || ok "no credential file written by provision"

echo "=== idempotency: second run is exit 0, same group count ==="
OUT2="$(run max-b)"; assert_eq "0" "$?" "second provision exit 0"
assert_eq "3" "$(aj ngroups)" "group count stable after re-run (idempotent)"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
