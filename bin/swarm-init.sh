#!/usr/bin/env bash
# swarm-init.sh — scaffold a repo with the Claude swarm operating system.
# Usage: swarm-init.sh /path/to/repo [--force]
#
# Source of truth is $SWARM_HOME/templates (default ~/claude-swarm/templates),
# which must contain the artifacts you downloaded:
#   CLAUDE.md  ESCALATION.md  TEAM_LEAD.md  PROJECT_SPEC.template.md
#   ADR.template.md  settings.example.json
#   hooks/{test-gate.sh,docs-check.sh,permission-gate.sh,dod-affirm.sh}
#   git-hooks/pre-commit
#
# It writes into the target repo:
#   CLAUDE.md, ESCALATION.md, TEAM_LEAD.md      (root — refreshed every run; they're policy)
#   PROJECT_SPEC.md                              (from template; never clobbered)
#   docs/adr/ADR.template.md
#   .claude/hooks/{test-gate.sh,docs-check.sh,permission-gate.sh,dod-affirm.sh}
#   .claude/settings.json                        (copied, or jq-merged if one exists)
#   .claude/test-cmd                             (placeholder; edit to your test command)
#   .git/hooks/pre-commit                        (docs-touch + anti-secret gate,
#                                                 only installed if the marker
#                                                 line matches or no pre-commit exists)

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
cp "$TPL/hooks/dod-affirm.sh"      "$REPO/.claude/hooks/dod-affirm.sh"
echo "  wrote: .claude/hooks/{test-gate.sh,docs-check.sh,permission-gate.sh,dod-affirm.sh}"

# Git pre-commit hook — docs-touch + anti-secret. Only install if (a) no
# pre-commit exists yet, or (b) the existing one carries our SWARM-MANAGED
# marker line (i.e., it's our own from a previous swarm-init run). NEVER
# clobber a user-authored pre-commit; warn instead so they can merge by hand.
if [ -d "$REPO/.git" ]; then
  PRECOMMIT="$REPO/.git/hooks/pre-commit"
  MARKER='# SWARM-MANAGED pre-commit'
  if [ ! -e "$PRECOMMIT" ]; then
    cp "$TPL/git-hooks/pre-commit" "$PRECOMMIT"
    chmod +x "$PRECOMMIT"
    echo "  wrote: .git/hooks/pre-commit  (docs-touch + anti-secret gate)"
  elif head -n 5 "$PRECOMMIT" | grep -qF "$MARKER"; then
    cp "$TPL/git-hooks/pre-commit" "$PRECOMMIT"
    chmod +x "$PRECOMMIT"
    echo "  updated: .git/hooks/pre-commit  (existing was swarm-managed)"
  else
    echo "  NOTE: kept existing .git/hooks/pre-commit (no SWARM-MANAGED marker);"
    echo "        review $TPL/git-hooks/pre-commit and merge by hand if you want"
    echo "        the docs-touch + anti-secret gate active."
  fi
else
  echo "  skip: .git/hooks/pre-commit  ($REPO is not a git working tree)"
fi

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

# .gitignore: ensure .claude/worktrees/ is excluded. Each teammate's
# isolated git worktree is created here on demand by the CTO before spawn
# (see TEAM_LEAD.md §Integration branch & merge ownership). If this dir
# is tracked, the docs-check.sh TeammateIdle hook misclassifies the
# untracked worktree contents as "source changed, no docs touch" and
# blocks teammate idle. Add the line idempotently — create .gitignore if
# absent, append only if the line is missing.
GI="$REPO/.gitignore"
LINE='.claude/worktrees/'
if [ ! -e "$GI" ]; then
  {
    echo "# Per-teammate git worktrees (CTO provisions before spawn;"
    echo "# never tracked in the integration tree)."
    echo "$LINE"
  } > "$GI"
  echo "  wrote: .gitignore  (created with .claude/worktrees/ entry)"
elif grep -qxF "$LINE" "$GI"; then
  echo "  skip (already gitignored): .claude/worktrees/"
else
  {
    echo ""
    echo "# Per-teammate git worktrees (CTO provisions before spawn;"
    echo "# never tracked in the integration tree)."
    echo "$LINE"
  } >> "$GI"
  echo "  appended: .gitignore  (.claude/worktrees/ entry)"
fi

echo "Done. The lead launched against this repo will hold the design conversation with you over Discord; when you say 'go build,' it authors PROJECT_SPEC.md and the one-way-door ADRs from the conversation, confirms with you, then decomposes and spawns. The stamped PROJECT_SPEC.md is a placeholder until then — see TEAM_LEAD.md."
