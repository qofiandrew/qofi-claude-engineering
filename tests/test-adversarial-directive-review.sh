#!/usr/bin/env bash
# Engine routing contract for CPO directive review. Reviewers are trusted stubs
# inside a copied swarm home; the production dispatcher has no injection seam.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/directive-dispatch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
has(){ if printf '%s' "$2" | grep -qF -- "$1"; then pass "$3"; else fail "$3 (missing [$1])"; fi; }
absent(){ if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3 (unexpected [$1])"; else pass "$3"; fi; }
eq(){ if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected=$1 got=$2)"; fi; }

SWARM="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$SWARM/bin" "$REPO/.claude/bin"
cp "$ROOT/bin/adversarial-directive-review.sh" "$ROOT/bin/resolve-swarm-engine.py" "$SWARM/bin/"
DISPATCH="$SWARM/bin/adversarial-directive-review.sh"
DRAFT="$REPO/draft.md"
printf '[cto-1] build the bounded queue\n' > "$DRAFT"

cat > "$SWARM/bin/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${OPENAI_API_KEY:-}" ] && { echo 'CODEX ADVISORY-DOWN'; exit 3; }
printf 'CODEX-ROUTE:%s\n' "$*"
for arg in "$@"; do [ -f "$arg" ] && /bin/cat "$arg"; done
exit 0
EOF
cat > "$SWARM/bin/claude-review.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${ANTHROPIC_API_KEY:-}" ] && { echo 'CLAUDE ADVISORY-DOWN'; exit 3; }
printf 'CLAUDE-FABLE-ROUTE:%s\n' "$*"
for arg in "$@"; do [ -f "$arg" ] && /bin/cat "$arg"; done
exit 0
EOF
chmod +x "$SWARM/bin/"*.sh "$SWARM/bin/resolve-swarm-engine.py"

# A malicious/stale repo wrapper must never become a host command again.
cat > "$REPO/.claude/bin/codex-directive-review.sh" <<'EOF'
#!/usr/bin/env bash
echo 'MUTABLE-REPO-WRAPPER-RAN'
exit 99
EOF
chmod +x "$REPO/.claude/bin/codex-directive-review.sh"

write_conf(){
  printf 'cpo | %s | TOKEN | 111 | 222 | default | %s\n' "$REPO" "$1" > "$SWARM/swarm.conf"
  chmod 600 "$SWARM/swarm.conf"
}

echo "=== registered engine identity is authoritative ==="
write_conf claude
out="$(cd "$REPO" && bash "$DISPATCH" --check 2>&1)"; rc=$?
eq 0 "$rc" "registered repo derives its engine without an override"
has "CODEX-ROUTE" "$out" "derived Claude primary selects Codex"
out="$(cd "$REPO" && bash "$DISPATCH" --engine codex "$DRAFT" 2>&1)"; rc=$?
eq 3 "$rc" "caller engine mismatch is advisory-down"
has "does not match registered engine" "$out" "mismatch reason is explicit"

echo "=== Claude primary routes only to trusted host Codex ==="
out="$(cd "$REPO" && bash "$DISPATCH" --engine claude "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "Claude route succeeds"
has "CODEX-ROUTE" "$out" "Claude primary selects Codex"
has "build the bounded queue" "$out" "file is forwarded"
absent "MUTABLE-REPO-WRAPPER-RAN" "$out" "repo-stamped wrapper is never executed"

PRELOAD_MARKER="$TMP/dispatcher-preload-ran"
/usr/bin/python3 -I -B - "$REPO/sitecustomize.py" "$PRELOAD_MARKER" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    f"open({sys.argv[2]!r}, 'w').write('ran')\n",
    encoding="utf-8",
)
PY
rm -f "$PRELOAD_MARKER"
out="$(cd "$REPO" && PYTHONPATH="$REPO" bash "$DISPATCH" --engine claude "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "dispatcher works with hostile PYTHONPATH"
[ -e "$PRELOAD_MARKER" ] && fail "dispatcher imported repo sitecustomize" || pass "dispatcher Python is isolated from repo sitecustomize"
rm -f "$REPO/sitecustomize.py"

echo "=== Codex primary routes only to trusted host Claude/Fable ==="
write_conf codex
out="$(cd "$REPO" && bash "$DISPATCH" --engine codex "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "Codex route succeeds"
has "CLAUDE-FABLE-ROUTE" "$out" "Codex primary selects Claude/Fable"
out="$(cd "$REPO" && ANTHROPIC_API_KEY=sk-meter bash "$DISPATCH" --engine codex "$DRAFT" 2>&1)"; rc=$?
eq 3 "$rc" "reviewer money-path refusal propagates"
has "ADVISORY-DOWN" "$out" "failure remains loud and advisory"

echo "=== unregistered defaults/overrides; ambiguous identity fails closed ==="
printf 'other | %s/other | T | 1 | 2 | default | claude\n' "$TMP" > "$SWARM/swarm.conf"
chmod 600 "$SWARM/swarm.conf"
out="$(cd "$REPO" && bash "$DISPATCH" "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "unregistered repo preserves the historical Claude default"
has "CODEX-ROUTE" "$out" "unregistered Claude default selects Codex"
out="$(cd "$REPO" && bash "$DISPATCH" --engine codex "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "unregistered repo accepts explicit Codex primary"
has "CLAUDE-FABLE-ROUTE" "$out" "unregistered Codex override selects Claude/Fable"
write_conf claude
printf 'dupe | %s | T2 | 3 | 4 | default | claude\n' "$REPO" >> "$SWARM/swarm.conf"
out="$(cd "$REPO" && bash "$DISPATCH" "$DRAFT" 2>&1)"; rc=$?
eq 3 "$rc" "duplicate canonical repo rows are advisory-down"
out="$(cd "$REPO" && bash "$DISPATCH" --engine claude "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "explicit registered engine disambiguates a shared physical repo"
has "CODEX-ROUTE" "$out" "shared-repo Claude author still selects Codex"

printf 'codex-shared | %s | T3 | 5 | 6 | default | codex\n' "$REPO" >> "$SWARM/swarm.conf"
out="$(cd "$REPO" && bash "$DISPATCH" --engine codex "$DRAFT" 2>&1)"; rc=$?
eq 0 "$rc" "shared-repo Codex author selects its registered lane explicitly"
has "CLAUDE-FABLE-ROUTE" "$out" "shared-repo Codex author selects Claude/Fable"
out="$(cd "$REPO" && bash "$DISPATCH" --engine other "$DRAFT" 2>&1)"; rc=$?
eq 2 "$rc" "invalid explicit shared-repo engine remains a usage error"

printf 'adversarial-directive-review: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
