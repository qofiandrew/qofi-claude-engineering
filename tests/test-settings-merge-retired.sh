#!/usr/bin/env bash
# test-settings-merge-retired.sh — pins the settings-merge semantics that let
# doctrine EVOLVE permission rules in already-stamped repos:
#
#   1. permissions.deny UNION — new template deny rules merge into an existing
#      settings.json (previously only allow was unioned; a deny added to the
#      template never reached stamped repos).
#   2. RETIRED-rule removal — exact-match rules listed in
#      templates/settings-retired.conf are REMOVED from the target's
#      allow+deny during merge (the one subtractive step; without it the
#      blanket force-push denies could never be lifted from stamped repos).
#   3. Foreign (operator-added) rules not in the retired list are preserved.
#   4. Idempotent: a second merge is a no-op (rc=3).
#
# Pure bash + python3. Exit 0 = all assertions pass. bash 3.2-safe.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/bin/swarm-lib.sh" 2>/dev/null || true
command -v settings_merge_swarm >/dev/null 2>&1 || type settings_merge_swarm >/dev/null 2>&1 || {
  echo "FATAL: settings_merge_swarm not loadable from bin/swarm-lib.sh" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/settings-merge.XXXXXX)")" 2>/dev/null || WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SWARM_HOME="$WORK/home"
mkdir -p "$SWARM_HOME/templates"

cat > "$SWARM_HOME/templates/settings-retired.conf" <<'EOF'
# retired rules under test
Bash(git push *--force*)
Bash(git push *--force-with-lease*)
Bash(git push *-f *)
EOF

# Template: the post-split example (subset).
cat > "$WORK/template.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git push origin worktree-*:*)",
      "Bash(git push --force-with-lease origin worktree-*:*)"
    ],
    "deny": [
      "Bash(git push origin main*)",
      "Bash(git push *--force* dev)"
    ]
  }
}
EOF

# Target: a stamped repo carrying the old blanket denies + an operator rule.
cat > "$WORK/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git push origin worktree-*:*)",
      "Bash(operator-custom-tool *)"
    ],
    "deny": [
      "Bash(git push origin main*)",
      "Bash(git push *--force*)",
      "Bash(git push *--force-with-lease*)",
      "Bash(git push *-f *)",
      "Bash(operator-custom-deny *)"
    ]
  }
}
EOF

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

settings_merge_swarm "$WORK/settings.json" "$WORK/template.json"; rc=$?
[ "$rc" -eq 0 ] && ok "merge applied (rc=0)" || bad "merge rc=$rc (want 0)"

has() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
lst=d["permissions"][sys.argv[2]]
sys.exit(0 if sys.argv[3] in lst else 1)' "$WORK/settings.json" "$2" "$3"; }

check() { # check <yes|no> <allow|deny> <rule> <label>
  if [ "$1" = yes ]; then
    has x "$2" "$3" && ok "$4" || bad "$4"
  else
    has x "$2" "$3" && bad "$4" || ok "$4"
  fi
}

echo "=== retired rules removed from deny ==="
check no  deny 'Bash(git push *--force*)'            "blanket *--force* deny removed"
check no  deny 'Bash(git push *--force-with-lease*)' "blanket force-with-lease deny removed"
check no  deny 'Bash(git push *-f *)'                "blanket -f deny removed"

echo "=== template deny rules now union in ==="
check yes deny 'Bash(git push *--force* dev)'        "new per-target deny merged"
check yes deny 'Bash(git push origin main*)'         "existing main deny kept"

echo "=== allow union + preservation ==="
check yes allow 'Bash(git push --force-with-lease origin worktree-*:*)' "worktree force allow merged"
check yes allow 'Bash(operator-custom-tool *)'       "operator allow preserved"
check yes deny  'Bash(operator-custom-deny *)'       "operator deny preserved"

echo "=== idempotency ==="
settings_merge_swarm "$WORK/settings.json" "$WORK/template.json"; rc=$?
[ "$rc" -eq 3 ] && ok "second merge is a no-op (rc=3)" || bad "second merge rc=$rc (want 3)"

echo ""
printf 'settings-merge-retired: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
