#!/usr/bin/env bash
# swarm-init.sh — scaffold a repo with the Claude swarm operating system.
# Usage: swarm-init.sh /path/to/repo [--force]
#
# Source of truth is $SWARM_HOME/templates (default ~/claude-swarm/templates),
# which must contain the artifacts you downloaded:
#   CLAUDE.md  ESCALATION.md  TEAM_LEAD.md  PROJECT_SPEC.template.md
#   ADR.template.md  settings.example.json  hooks/test-gate.sh  hooks/docs-check.sh
#
# It writes into the target repo:
#   CLAUDE.md, ESCALATION.md, TEAM_LEAD.md      (root — refreshed every run; they're policy)
#   PROJECT_SPEC.md                              (from template; never clobbered)
#   docs/adr/ADR.template.md
#   .claude/hooks/{test-gate.sh,docs-check.sh}
#   .claude/settings.json                        (copied, or jq-merged if one exists)
#   .claude/test-cmd                             (placeholder; edit to your test command)

set -euo pipefail

SWARM_HOME="${SWARM_HOME:-$HOME/claude-swarm}"
TPL="$SWARM_HOME/templates"

REPO="${1:-}"
FORCE=0
[ "${2:-}" = "--force" ] && FORCE=1

[ -z "$REPO" ]  && { echo "usage: swarm-init.sh /path/to/repo [--force]" >&2; exit 1; }
[ -d "$REPO" ]  || { echo "swarm-init: $REPO is not a directory" >&2; exit 1; }
[ -d "$TPL" ]   || { echo "swarm-init: templates not found at $TPL (set SWARM_HOME)" >&2; exit 1; }

echo "Scaffolding swarm files into $REPO"

# Policy docs — always refresh (they encode the operating contract, not content).
for f in CLAUDE.md ESCALATION.md TEAM_LEAD.md; do
  cp "$TPL/$f" "$REPO/$f"; echo "  wrote: $f"
done

# Spec — seed from template, but never overwrite a real spec.
if [ ! -e "$REPO/PROJECT_SPEC.md" ] || [ "$FORCE" -eq 1 ]; then
  cp "$TPL/PROJECT_SPEC.template.md" "$REPO/PROJECT_SPEC.md"; echo "  wrote: PROJECT_SPEC.md"
else
  echo "  skip (exists): PROJECT_SPEC.md"
fi

# ADR template.
mkdir -p "$REPO/docs/adr"
cp "$TPL/ADR.template.md" "$REPO/docs/adr/ADR.template.md"; echo "  wrote: docs/adr/ADR.template.md"

# Hooks (invoked via 'bash' in settings, so no +x needed).
mkdir -p "$REPO/.claude/hooks"
cp "$TPL/hooks/test-gate.sh"       "$REPO/.claude/hooks/test-gate.sh"
cp "$TPL/hooks/docs-check.sh"      "$REPO/.claude/hooks/docs-check.sh"
cp "$TPL/hooks/permission-gate.sh" "$REPO/.claude/hooks/permission-gate.sh"
echo "  wrote: .claude/hooks/{test-gate.sh,docs-check.sh,permission-gate.sh}"

# Settings — copy if absent; recursive-merge with jq if one exists; else leave a .new.
SET="$REPO/.claude/settings.json"
if [ ! -e "$SET" ]; then
  cp "$TPL/settings.example.json" "$SET"; echo "  wrote: .claude/settings.json"
elif command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq -s '.[0] * .[1]' "$SET" "$TPL/settings.example.json" > "$tmp" && mv "$tmp" "$SET"
  echo "  merged: .claude/settings.json (jq; arrays replaced — verify hooks block)"
else
  cp "$TPL/settings.example.json" "$SET.new"
  echo "  NOTE: kept existing settings.json; review $SET.new and merge by hand (no jq found)"
fi

# Test-command placeholder.
if [ ! -e "$REPO/.claude/test-cmd" ] || [ "$FORCE" -eq 1 ]; then
  echo "npm test --silent" > "$REPO/.claude/test-cmd"
  echo "  wrote: .claude/test-cmd  (edit to your repo's real test command)"
else
  echo "  skip (exists): .claude/test-cmd"
fi

echo "Done. The lead launched against this repo will hold the design conversation with you over Discord; when you say 'go build,' it authors PROJECT_SPEC.md and the one-way-door ADRs from the conversation, confirms with you, then decomposes and spawns. The stamped PROJECT_SPEC.md is a placeholder until then — see TEAM_LEAD.md."
