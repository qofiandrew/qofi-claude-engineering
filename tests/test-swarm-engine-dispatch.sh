#!/usr/bin/env bash
# test-swarm-engine-dispatch.sh — pins the ENGINE column (swarm.conf field 7)
# and the engine-aware adversarial-review dispatcher.
#
# What this proves:
#   1. swarm_conf_parse_line: empty/absent engine -> 'claude' (legacy rows are
#      byte-identical in behavior); 'codex' -> codex; junk -> 'claude' + loud
#      warning (a typo must not silently boot the wrong runtime); extra
#      columns beyond ENGINE still cannot corrupt named fields.
#   2. bin/adversarial-review.sh routes by engine: claude-engine repo ->
#      codex-review.sh; codex-engine repo -> claude-review.sh; unknown repo /
#      no SWARM_HOME -> codex-review.sh (today's default lane).
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
warn="$(swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | | codeX" 2>&1 >/dev/null || true)"
assert_eq "claude" "$SWARM_CONF_F_ENGINE" "junk engine falls back to claude"
case "$warn" in *"unknown ENGINE"*) pass "junk engine warns loudly" ;; *) fail "junk engine warns loudly" ;; esac
swarm_conf_parse_line "a | /r | BOT_A | 111 | 222 | | codex | future-col"
assert_eq "codex" "$SWARM_CONF_F_ENGINE" "extra trailing column cannot corrupt ENGINE"

echo ""
echo "=== 2) adversarial-review.sh dispatch ==="
# Sandboxed bin: real dispatcher + lib, STUB review lanes that just name themselves.
mkdir -p "$TMP/home/bin"
cp "$ROOT/bin/adversarial-review.sh" "$ROOT/bin/swarm-lib.sh" "$TMP/home/bin/"
printf '#!/usr/bin/env bash\necho LANE:codex-review "$@"\n' > "$TMP/home/bin/codex-review.sh"
printf '#!/usr/bin/env bash\necho LANE:claude-review "$@"\n' > "$TMP/home/bin/claude-review.sh"
chmod +x "$TMP/home/bin/"*.sh
mkdir -p "$TMP/home/templates"   # swarm-lib sanity paths

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

out="$(cd "$TMP/repo-unlisted" && SWARM_HOME="$TMP/home" bash "$TMP/home/bin/adversarial-review.sh" --check)"
case "$out" in *"LANE:codex-review"*) pass "unlisted repo -> default codex-review lane" ;; *) fail "unlisted repo -> default codex-review lane (got: $out)" ;; esac

out="$(cd "$TMP/repo-codex" && SWARM_HOME= bash "$TMP/home/bin/adversarial-review.sh" --check)"
case "$out" in *"LANE:codex-review"*) pass "no SWARM_HOME -> default codex-review lane" ;; *) fail "no SWARM_HOME -> default codex-review lane (got: $out)" ;; esac

echo ""
echo "engine-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
