#!/usr/bin/env bash
# Pure regression for the generic + per-Codex operator-view aliases.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-aliases-codex.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/swarm.conf" <<'CONF'
claude-row | /tmp/claude | BOT_CLAUDE | 111
codex-row | /tmp/codex | BOT_CODEX | 222 | | | codex
CONF

PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1" >&2; FAIL=$((FAIL + 1)); }
has() {
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi
}
lacks() {
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi
}

OUT="$(SWARM_HOME="$TMP" bash -c '
  shopt -s expand_aliases
  source "$1"
  alias swarm-view
  alias swarm-view-codex-row
  alias swarm-claude-row
  alias swarm-codex-row
  alias swarm-view-claude-row 2>/dev/null || true
' _ "$ROOT/bin/swarm-aliases.sh")"

has "$OUT" "swarm-view.sh" "generic swarm-view alias targets the supported view"
has "$OUT" "swarm-view-codex-row=" "Codex row receives a per-swarm view alias"
has "$OUT" "swarm-view.sh codex-row" "per-Codex alias carries the configured name"
has "$OUT" "swarm-attach.sh claude-row" "existing Claude attach alias is unchanged"
has "$OUT" "swarm-codex-row='" "traditional Codex alias remains available"
has "$(printf '%s\n' "$OUT" | grep 'swarm-codex-row=')" "swarm-attach.sh codex-row" "traditional Codex alias preserves attach-or-launch"
lacks "$(printf '%s\n' "$OUT" | grep 'swarm-codex-row=')" "swarm-view.sh" "traditional Codex alias delegates view dispatch to attach helper"
lacks "$OUT" "swarm-view-claude-row=" "Claude rows do not receive a misleading Codex view alias"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
