#!/usr/bin/env bash
# Focused contract tests for the first-class Codex repository surfaces.
# Repo-local Codex command hooks are deliberately neutralized: current Codex
# runs trusted hooks outside the tool sandbox, so an editable repo cannot be a
# trusted host-code source.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-template.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (missing: $needle)"; fi
}

init_repo() {
  local type="$1" repo="$2" engine="${3:-codex}" out status
  out="$WORK/init-$type-$engine.out"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Codex Template Test"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit --allow-empty -q -m init
  SWARM_HOME="$ROOT" "$ROOT/bin/swarm-init.sh" "$repo" --type "$type" --engine "$engine" >"$out" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "$type/$engine manifest stamps successfully"
  else
    bad "$type/$engine manifest stamps successfully (exit $status)"
    sed 's/^/    /' "$out"
  fi
}

ENG="$WORK/engineering"
CPO="$WORK/cpo"
CPO_CLAUDE="$WORK/cpo-claude"

echo "=== real manifest stamping ==="
init_repo engineering-cto "$ENG"
init_repo cpo "$CPO"
init_repo cpo "$CPO_CLAUDE" claude

if cmp -s "$ROOT/templates/_base/AGENTS.md" "$CPO_CLAUDE/AGENTS.md"; then
  ok "fresh Claude CPO preserves historical base AGENTS bytes"
else
  bad "fresh Claude CPO preserves historical base AGENTS bytes"
fi
if [ ! -e "$CPO_CLAUDE/.codex" ] && [ ! -e "$CPO_CLAUDE/.agents" ]; then
  ok "fresh Claude CPO receives no Codex-only policy surfaces"
else
  bad "fresh Claude CPO receives no Codex-only policy surfaces"
fi
if [ ! -e "$CPO_CLAUDE/.claude/bin/codex-directive-review.sh" ]; then
  ok "fresh Claude CPO does not stamp a mutable host reviewer"
else
  bad "fresh Claude CPO does not stamp a mutable host reviewer"
fi
contains "fresh Claude CPO doctrine routes engine-derived trusted host dispatcher" "$CPO_CLAUDE/CLAUDE.md" \
  '$SWARM_HOME/bin/adversarial-directive-review.sh --engine claude [FILE]'

for repo_type in "engineering:$ENG" "cpo:$CPO"; do
  type="${repo_type%%:*}"
  repo="${repo_type#*:}"
  for file in AGENTS.md .codex/hooks.json .codex/rules/qofi-hard-floor.rules; do
    if [ -f "$repo/$file" ]; then ok "$type stamps $file"; else bad "$type stamps $file"; fi
  done
  if find "$repo/.codex/hooks" -type f -print -quit 2>/dev/null | grep -q .; then
    bad "$type stamps no executable Codex hook scripts"
  else
    ok "$type stamps no executable Codex hook scripts"
  fi
done

if cmp -s <(cat "$ROOT/templates/engineering-cto/AGENTS.md" "$ROOT/templates/_base/CLAUDE.md" "$ROOT/templates/_base/SWARM_BEHAVIOR.md") "$ENG/AGENTS.md"; then
  ok "engineering manifest composes its AGENTS routing with the shared doctrine trace"
else
  bad "engineering manifest composes its AGENTS routing with the shared doctrine trace"
fi
if cmp -s <(cat "$ROOT/templates/cpo/AGENTS.md" "$ROOT/templates/_base/CLAUDE.md" "$ROOT/templates/_base/SWARM_BEHAVIOR.md") "$CPO/AGENTS.md"; then
  ok "cpo manifest composes its AGENTS routing with the shared doctrine trace"
else
  bad "cpo manifest composes its AGENTS routing with the shared doctrine trace"
fi

echo ""
echo "=== safe doctrine and enforcement routing ==="
for needle in CLAUDE.md ESCALATION.md TEAM_LEAD.md PROJECT_SPEC.md .claude/test-cmd .agents/skills "empty hook set" "outside the" "permission profile"; do
  contains "engineering AGENTS routes $needle" "$ENG/AGENTS.md" "$needle"
done
for needle in CLAUDE.md CONVERSATION.md EVALUATION.md SURFACING.md MEMORY.md READINESS_BAR.md ESCALATION.md CPO_BUS_PROTOCOL.md "empty hook set" "outside the"; do
  contains "cpo AGENTS routes $needle" "$CPO/AGENTS.md" "$needle"
done
contains "cpo AGENTS explicitly excludes engineering lead doctrine" "$CPO/AGENTS.md" 'has no `TEAM_LEAD.md`'
contains "cpo AGENTS documents the enforced Sol medium worker route" "$CPO/AGENTS.md" \
  'primary CPO worker to `gpt-5.6-sol` at `medium`'
contains "engineering AGENTS requires direct test execution" "$ENG/AGENTS.md" 'Run `.claude/test-cmd`'
contains "engineering AGENTS names harness completion boundary" "$ENG/AGENTS.md" 'harness stop boundary'
contains "engineering AGENTS rejects repo hook trust" "$ENG/AGENTS.md" 'should trust repo command hooks'
contains "cpo AGENTS rejects repo hook trust" "$CPO/AGENTS.md" 'repo-local command hooks'
contains "engineering AGENTS routes only the terminal Fable reviewer" "$ENG/AGENTS.md" \
  '`fable_reviewer.adversarial_review`'
contains "engineering AGENTS preserves unavailable as review-pending" "$ENG/AGENTS.md" \
  '`review-unavailable` means'
contains "engineering doctrine routes plugin v1 through production normalizer" "$ENG/TEAM_LEAD.md" \
  '$SWARM_HOME/bin/qofi-review-normalize.py run'
contains "engineering doctrine refuses fabricated legacy diff provenance" "$ENG/TEAM_LEAD.md" \
  '`provenance_status: unavailable-legacy-plugin`'
contains "Claude worker doctrine routes plugin v1 through production normalizer" "$ENG/CLAUDE.md" \
  '$SWARM_HOME/bin/qofi-review-normalize.py run'
contains "Claude worker doctrine documents exact private result-set location" "$ENG/CLAUDE.md" \
  '`~/.claude/qofi-review-result-sets/<repository-key>/`'
contains "cpo AGENTS routes only the terminal Fable reviewer" "$CPO/AGENTS.md" \
  '`fable_reviewer.adversarial_review`'
contains "cpo AGENTS forbids recursive reviewer capability" "$CPO/AGENTS.md" \
  'recursive agent path'

echo ""
echo "=== Codex command hooks are neutralized ==="
if python3 - "$ENG/.codex/hooks.json" "$CPO/.codex/hooks.json" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    assert json.load(open(path, encoding="utf-8")) == {"hooks": {}}
PY
then
  ok "both archetypes stamp the empty hook neutralizer"
else
  bad "both archetypes stamp the empty hook neutralizer"
fi
if ! rg -n 'dangerously-bypass-hook-trust|SessionStart|PreToolUse|PermissionRequest|stop-gate\.sh' \
  "$ENG/.codex/hooks.json" "$CPO/.codex/hooks.json" >/dev/null 2>&1; then
  ok "stamped Codex configuration contains no command-hook trust path"
else
  bad "stamped Codex configuration contains no command-hook trust path"
fi

echo ""
echo "=== Codex skill discovery shims route without body duplication ==="
EXPECTED_SKILLS="at-scale-ops data-migrations dead-code-scan perf-budgets review-checklist-python-uv review-checklist-swift-ios review-checklist-ts-node ts-node-stack"
COUNT="$(find "$ENG/.agents/skills" -name SKILL.md -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$COUNT" = "8" ]; then ok "all eight Codex skill shims stamped"; else bad "all eight Codex skill shims stamped (got $COUNT)"; fi
for name in $EXPECTED_SKILLS; do
  shim="$ENG/.agents/skills/$name/SKILL.md"
  body="$ENG/.claude/skills/$name/SKILL.md"
  if [ -f "$shim" ] && [ -f "$body" ]; then ok "$name shim and canonical body both exist"; else bad "$name shim and canonical body both exist"; continue; fi
  contains "$name shim routes to canonical body" "$shim" ".claude/skills/$name/SKILL.md"
  declared="$(sed -n 's/^name: //p' "$shim" | head -n 1)"
  if [ "$declared" = "$name" ]; then ok "$name shim frontmatter matches directory"; else bad "$name shim frontmatter matches directory"; fi
  size="$(wc -c < "$shim" | tr -d ' ')"
  if [ "$size" -lt 1600 ]; then ok "$name shim stays lightweight"; else bad "$name shim stays lightweight ($size bytes)"; fi
done
if [ ! -e "$CPO/.agents/skills" ]; then ok "cpo does not receive engineering skills"; else bad "cpo does not receive engineering skills"; fi
if cmp -s "$ENG/.codex/rules/qofi-hard-floor.rules" "$CPO/.codex/rules/qofi-hard-floor.rules"; then
  ok "both archetypes stamp the same manual-interactive execpolicy floor"
else
  bad "both archetypes stamp the same manual-interactive execpolicy floor"
fi

echo ""
echo "=== project execpolicy hard floor (manual interactive defense in depth) ==="
if ! command -v codex >/dev/null 2>&1; then
  ok "codex CLI unavailable; execpolicy checks skipped"
else
  ok "codex CLI is available for execpolicy checks"
  RULES="$ENG/.codex/rules/qofi-hard-floor.rules"
  policy_forbidden() {
    local desc="$1" output status
    shift
    output="$(codex execpolicy check --rules "$RULES" -- "$@" 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ] && printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin).get("decision") == "forbidden"' 2>/dev/null; then
      ok "$desc"
    else
      bad "$desc (exit $status, output: $output)"
    fi
  }
  policy_unmatched() {
    local desc="$1" output status
    shift
    output="$(codex execpolicy check --rules "$RULES" -- "$@" 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ] && printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "decision" not in d and d.get("matchedRules") == []' 2>/dev/null; then
      ok "$desc"
    else
      bad "$desc (exit $status, output: $output)"
    fi
  }

  policy_forbidden "execpolicy forbids sudo prefix" sudo true
  policy_forbidden "execpolicy forbids recursive/forced rm prefix" rm -rf build
  policy_forbidden "execpolicy forbids common protected push" git push origin main
  policy_forbidden "execpolicy forbids common force-push to shared dev" git push --force upstream dev
  policy_forbidden "execpolicy forbids package publication" npm publish
  policy_unmatched "execpolicy does not invent a decision for git status" git status
  policy_unmatched "execpolicy leaves an explicit feature push to normal policy" git push origin feature/codex
fi

echo ""
echo "codex-template-integration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
