#!/usr/bin/env bash
# test-doctrine-compose.sh — byte-identity guard for the doctrine compose pipeline.
#
# Two layers:
#
#   1. ROUND-TRIP: compose(engineering-cto fragments) ≡ frozen fixtures.
#      Protects future fragment edits from silently drifting the composed
#      output. If a fragment loses its trailing newline, gets reordered,
#      or has whitespace mangled by an editor, this catches it before any
#      sync touches a live swarm.
#
#   2. LIVE-SWARM DRIFT (informational): runs manifest_check against the
#      configured live swarms and reports their drift state. ONLY consulted
#      after the operator has approved syncing the reordered doctrine.
#      Before that approval, DRIFT against live is the EXPECTED state (the
#      reorder is what's being landed); after sync, DRIFT must return to
#      zero permanently.
#
# Always self-checks the trailing-newline invariant on every non-final
# compose source — same assertion _compose_to_tmp makes at apply time,
# pulled into the test so a fragment violation surfaces during CI/dev
# rather than at sync time.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0
note() { printf '  %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }
pass() { printf '  ok   %s\n' "$*"; }

echo "==> Round-trip: compose(engineering-cto fragments) ≡ frozen fixtures"

compose_check() {
  local label="$1" fixture="$2"; shift 2
  local tmp
  tmp="$(mktemp -t swarm-test-compose.XXXXXX)" || { fail "$label: mktemp"; return; }
  : > "$tmp"
  local n=$# i=0
  for src in "$@"; do
    i=$((i+1))
    local p="templates/$src"
    if [ ! -f "$p" ]; then
      fail "$label: source missing — $src"
      rm -f "$tmp"; return
    fi
    if [ "$i" -lt "$n" ]; then
      local last
      last="$(tail -c 1 "$p" | xxd -p)"
      if [ "$last" != "0a" ]; then
        fail "$label: source '$src' lacks trailing newline (last byte 0x$last) — invariant violation"
        rm -f "$tmp"; return
      fi
    fi
    cat "$p" >> "$tmp"
  done
  if [ ! -f "$fixture" ]; then
    fail "$label: fixture missing — $fixture"
    rm -f "$tmp"; return
  fi
  if cmp -s "$tmp" "$fixture"; then
    pass "$label composed == $fixture"
  else
    fail "$label composed != $fixture"
    diff "$tmp" "$fixture" | head -20
  fi
  rm -f "$tmp"
}

compose_check "CLAUDE.md" "tests/fixtures/CLAUDE.engineering-cto.expected.md" \
  engineering-cto/CLAUDE.preamble.md _base/CLAUDE.md _base/SWARM_BEHAVIOR.md engineering-cto/CLAUDE.md

# Profile overlay (ADR-0013): the 'frontend' profile appends a 4th compose
# source after engineering-cto/CLAUDE.md, which makes engineering-cto/CLAUDE.md
# a NON-final source — so this also self-checks its trailing-newline invariant.
# (NOTE: this re-implements cat, like every check above; the REAL
# manifest_apply_compose injection is exercised separately by
# test-swarm-profile-dispatch.sh, which asserts byte-identity to this same
# fixture through the live pipeline.)
compose_check "CLAUDE.md (frontend profile)" "tests/fixtures/CLAUDE.engineering-cto.frontend.expected.md" \
  engineering-cto/CLAUDE.preamble.md _base/CLAUDE.md _base/SWARM_BEHAVIOR.md engineering-cto/CLAUDE.md engineering-cto/profiles/frontend/CLAUDE.md

compose_check "ESCALATION.md" "tests/fixtures/ESCALATION.engineering-cto.expected.md" \
  engineering-cto/ESCALATION.preamble.md _base/ESCALATION.md engineering-cto/ESCALATION.md

# The permission-gate hook also composes (since the cpo archetype landed and
# pushed the prelude/policy/tail split into _base + per-archetype). Round-trip
# byte-identity for both archetypes' composed hooks.
compose_check "engineering-cto permission-gate.sh" "tests/fixtures/permission-gate.engineering-cto.expected.sh" \
  _base/hooks/permission-gate-prelude.sh engineering-cto/hooks/permission-gate-policy.sh _base/hooks/permission-gate-tail.sh

echo ""
echo "==> Round-trip: compose(cpo fragments) ≡ frozen fixtures"

compose_check "cpo CLAUDE.md" "tests/fixtures/CLAUDE.cpo.expected.md" \
  cpo/CLAUDE.preamble.md _base/CLAUDE.md _base/SWARM_BEHAVIOR.md cpo/CLAUDE.md

compose_check "cpo ESCALATION.md" "tests/fixtures/ESCALATION.cpo.expected.md" \
  cpo/ESCALATION.preamble.md _base/ESCALATION.md cpo/ESCALATION.md

compose_check "cpo permission-gate.sh" "tests/fixtures/permission-gate.cpo.expected.sh" \
  _base/hooks/permission-gate-prelude.sh cpo/hooks/permission-gate-policy.sh _base/hooks/permission-gate-tail.sh

echo ""
echo "==> Runtime doctrine parity: CLAUDE.md and AGENTS.md share one ordered fragment trace"

shared_trace_from_manifest() { # manifest target
  local manifest="$1" target="$2"
  awk -F'|' -v target="$target" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      behavior=$1; sources=$2; output=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", behavior)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", sources)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", output)
      if (behavior != "compose" || output != target) next
      n=split(sources, parts, "+")
      for (i=1; i<=n; i++) if (parts[i] ~ /^_base\/(CLAUDE|SWARM_BEHAVIOR)\.md$/) print parts[i]
    }
  ' "$manifest"
}

for type in engineering-cto cpo; do
  claude_trace="$(shared_trace_from_manifest "templates/$type/manifest.tsv" CLAUDE.md)"
  agents_trace="$(shared_trace_from_manifest "templates/$type/manifest.tsv" AGENTS.md)"
  expected="$(printf '%s\n' _base/CLAUDE.md _base/SWARM_BEHAVIOR.md)"
  if [ "$claude_trace" = "$expected" ] && [ "$agents_trace" = "$expected" ]; then
    pass "$type CLAUDE.md/AGENTS.md shared fragment trace is identical"
  else
    fail "$type shared doctrine trace drift (CLAUDE=[$claude_trace] AGENTS=[$agents_trace])"
  fi
done

echo ""
echo "==> Single-file refresh artifacts (no compose) ≡ frozen fixtures"
for spec in \
  "TEAM_LEAD.md=engineering-cto/TEAM_LEAD.md=tests/fixtures/TEAM_LEAD.engineering-cto.expected.md"
do
  label="${spec%%=*}"
  rest="${spec#*=}"
  src="templates/${rest%%=*}"
  fix="${rest#*=}"
  if cmp -s "$src" "$fix"; then
    pass "$label == fixture"
  else
    fail "$label != fixture"
  fi
done

echo ""
echo "==> Live-swarm coverage: BOTH swarms must have ALL THREE doctrine"
echo "    files matching the expected fixture (the proof must be complete,"
echo "    not partial — per the extended coverage decision)."
echo "    NOTE: before the post-reorder sync, CLAUDE.md and ESCALATION.md"
echo "    will report MISMATCH against the live swarms — that is the ONE"
echo "    expected reorder change. After sync, all must match."

for repo in /Users/aschettino/qofirepos/reserve-backend-2 /Users/aschettino/qofirepos/qofi-ios-app; do
  name="$(basename "$repo")"
  for f in CLAUDE.md ESCALATION.md TEAM_LEAD.md; do
    case "$f" in
      CLAUDE.md)     fix="tests/fixtures/CLAUDE.engineering-cto.expected.md" ;;
      ESCALATION.md) fix="tests/fixtures/ESCALATION.engineering-cto.expected.md" ;;
      TEAM_LEAD.md)  fix="tests/fixtures/TEAM_LEAD.engineering-cto.expected.md" ;;
    esac
    if [ ! -f "$repo/$f" ]; then
      note "$name/$f  MISSING in live swarm"
      continue
    fi
    if cmp -s "$repo/$f" "$fix"; then
      pass "$name/$f == expected fixture (in sync with reordered doctrine)"
    else
      note "$name/$f  MISMATCH (pre-sync state, expected before first sync)"
    fi
  done
done

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL ($FAIL failure(s))"
  exit 1
fi
echo "OK"
