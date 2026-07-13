#!/usr/bin/env bash
# test-swarm-engine-dispatch.sh — pins the ENGINE column (swarm.conf field 7)
# and the engine-aware adversarial-review dispatcher.
#
# What this proves:
#   1. swarm_conf_parse_line: empty/absent engine -> 'claude' (legacy rows are
#      byte-identical in behavior); 'codex' -> codex; junk -> refused row + loud
#      warning (a typo must not silently boot the wrong runtime); extra
#      columns beyond ENGINE still cannot corrupt named fields.
#   2. bin/adversarial-review.sh routes by engine: claude-engine repo ->
#      codex-review.sh; codex-engine repo -> claude-review.sh; unregistered
#      repos retain the Claude default or accept an explicit engine, while
#      duplicate identity fails closed and SWARM_HOME cannot spoof it.
#
# Pure bash + git. Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
pass(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
assert_eq(){ if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected=$1 got=$2)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/engine-dispatch.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=../bin/swarm-lib.sh
. "$ROOT/bin/swarm-lib.sh"

echo "=== 1) parser: ENGINE field ==="
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 |"
assert_eq "claude" "$SWARM_CONF_F_ENGINE" "legacy 6-col row defaults to claude"
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222"
assert_eq "claude" "$SWARM_CONF_F_ENGINE" "5-col row defaults to claude"
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | | codex"
assert_eq "codex" "$SWARM_CONF_F_ENGINE" "engine codex parsed"
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | max-a | claude"
assert_eq "claude" "$SWARM_CONF_F_ENGINE" "explicit claude parsed"
assert_eq "max-a" "$SWARM_CONF_F_ACCOUNT" "account survives alongside engine"
warn_file="$TMP/engine.warn"
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | | codeX" 2>"$warn_file"; junk_rc=$?
warn="$(cat "$warn_file")"
assert_eq "1" "$junk_rc" "junk engine row is rejected"
assert_eq "" "$SWARM_CONF_F_ENGINE" "junk engine cannot fall back to a different runtime"
case "$warn" in *"unknown ENGINE"*) pass "junk engine warns loudly" ;; *) fail "junk engine warns loudly" ;; esac
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | | codex | future-col"
assert_eq "codex" "$SWARM_CONF_F_ENGINE" "extra trailing column cannot corrupt ENGINE"

echo ""
echo "=== 2) adversarial-review.sh dispatch ==="
# Sandboxed bin: real dispatcher + resolver, STUB review lanes that name themselves.
mkdir -p "$TMP/home/bin"
cp "$ROOT/bin/adversarial-review.sh" "$ROOT/bin/resolve-swarm-engine.py" "$TMP/home/bin/"
printf '#!/usr/bin/env bash\necho LANE:codex-review "$@"\n' > "$TMP/home/bin/codex-review.sh"
printf '#!/usr/bin/env bash\necho LANE:claude-review "$@"\n' > "$TMP/home/bin/claude-review.sh"
chmod +x "$TMP/home/bin/"*.sh
chmod +x "$TMP/home/bin/resolve-swarm-engine.py"

mkdir -p "$TMP/repo-claude" "$TMP/repo-codex" "$TMP/repo-unlisted"
for r in repo-claude repo-codex repo-unlisted; do git init -q "$TMP/$r"; done
cat > "$TMP/home/swarm.conf" <<EOF
alpha | $TMP/repo-claude | BOT_A | 111 | 222 |
beta  | $TMP/repo-codex  | BOT_B | 333 | 444 | | codex
EOF

out="$(cd "$TMP/repo-claude" && SWARM_HOME="$TMP/home" bash "$TMP/home/bin/adversarial-review.sh" --check)"
case "$out" in *"LANE:codex-review --check"*) pass "claude engine -> codex-review lane" ;; *) fail "claude engine -> codex-review lane (got: $out)" ;; esac

out="$(cd "$TMP/repo-codex" && SWARM_HOME="$TMP/home" bash "$TMP/home/bin/adversarial-review.sh" --check)"
case "$out" in *"LANE:claude-review --check"*) pass "codex engine -> claude-review lane" ;; *) fail "codex engine -> claude-review lane (got: $out)" ;; esac

out="$(cd "$TMP/repo-unlisted" && SWARM_HOME="$TMP/home" bash "$TMP/home/bin/adversarial-review.sh" --check)"; rc=$?
assert_eq 0 "$rc" "unlisted repo retains the historical Claude default"
case "$out" in *"LANE:codex-review --check"*) pass "unlisted default routes Claude-authored work to Codex" ;; *) fail "unlisted default lane (got: $out)" ;; esac
out="$(cd "$TMP/repo-unlisted" && bash "$TMP/home/bin/adversarial-review.sh" --engine codex --check)"; rc=$?
assert_eq 0 "$rc" "unlisted repo accepts an explicit Codex author engine"
case "$out" in *"LANE:claude-review --check"*) pass "explicit ad-hoc Codex work routes to Claude/Fable" ;; *) fail "unlisted Codex lane (got: $out)" ;; esac

out="$(cd "$TMP/repo-claude" && bash "$TMP/home/bin/adversarial-review.sh" --engine codex --check 2>&1)"; rc=$?
assert_eq 3 "$rc" "registered engine cannot be overridden"
case "$out" in *"does not match registered engine"*) pass "registered mismatch is explicit" ;; *) fail "registered mismatch is explicit (got: $out)" ;; esac

out="$(cd "$TMP/repo-codex" && SWARM_HOME= bash "$TMP/home/bin/adversarial-review.sh" --check)"
case "$out" in *"LANE:claude-review --check"*) pass "empty SWARM_HOME cannot change registered Codex identity" ;; *) fail "empty SWARM_HOME preserves registered identity (got: $out)" ;; esac

python3 - "$TMP/home/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('| codex\n', '| CODEX\n'); open(p,'w').write(s)
PY
out="$(cd "$TMP/repo-codex" && bash "$TMP/home/bin/adversarial-review.sh" --check 2>&1)"; rc=$?
assert_eq 3 "$rc" "mixed-case engine is rejected consistently with the canonical parser"
python3 - "$TMP/home/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('| CODEX\n', '| codex\n'); open(p,'w').write(s)
PY

printf 'dupe | %s | BOT_C | 555 | 666 | | codex\n' "$TMP/repo-codex" >> "$TMP/home/swarm.conf"
out="$(cd "$TMP/repo-codex" && bash "$TMP/home/bin/adversarial-review.sh" --check 2>&1)"; rc=$?
assert_eq 3 "$rc" "duplicate canonical rows fail closed"
out="$(cd "$TMP/repo-codex" && bash "$TMP/home/bin/adversarial-review.sh" --engine codex --check 2>&1)"; rc=$?
assert_eq 0 "$rc" "explicit registered engine disambiguates shared same-engine rows"
case "$out" in *"LANE:claude-review --check"*) pass "shared Codex rows retain foreign-family review" ;; *) fail "shared Codex lane (got: $out)" ;; esac

printf 'mixed | %s | BOT_D | 777 | 888 | | claude\n' "$TMP/repo-codex" >> "$TMP/home/swarm.conf"
out="$(cd "$TMP/repo-codex" && bash "$TMP/home/bin/adversarial-review.sh" --engine claude --check 2>&1)"; rc=$?
assert_eq 0 "$rc" "explicit Claude author disambiguates a mixed-engine shared repo"
case "$out" in *"LANE:codex-review --check"*) pass "shared Claude row routes to Codex" ;; *) fail "mixed Claude lane (got: $out)" ;; esac
out="$(cd "$TMP/repo-codex" && bash "$TMP/home/bin/adversarial-review.sh" --engine codex --check 2>&1)"; rc=$?
assert_eq 0 "$rc" "explicit Codex author disambiguates a mixed-engine shared repo"
case "$out" in *"LANE:claude-review --check"*) pass "shared Codex row routes to Claude/Fable" ;; *) fail "mixed Codex lane (got: $out)" ;; esac

echo ""
echo "engine-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
