#!/usr/bin/env bash
# swarm-init.sh — scaffold a repo with the Claude swarm operating system.
# Usage: swarm-init.sh /path/to/repo [--force]
#
# Source of truth is $SWARM_HOME/templates (default ~/claude-swarm/templates),
# whose contents are enumerated in templates/manifest.tsv. swarm-init,
# swarm-sync, and swarm-onboard all consume that single manifest via
# manifest_apply in swarm-lib.sh, so the three commands cannot diverge on
# what "fully stamped" means.
#
# init-mode policy:
#   - refresh-class artifacts (CLAUDE.md, TEAM_LEAD.md, ESCALATION.md,
#     .claude/hooks/*) — written/overwritten unconditionally.
#   - seed-class (PROJECT_SPEC.md, docs/adr/ADR.template.md, .claude/test-cmd)
#     — copied only if absent. --force re-seeds.
#   - settings.json — copy if absent, structured-merge if one exists.
#   - .git/hooks/pre-commit — install if absent or existing has SWARM-MANAGED
#     marker; else warn and leave it alone.
#   - .gitignore — append .claude/worktrees/ idempotently.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-init: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

REPO="${1:-}"
FORCE=0
[ "${2:-}" = "--force" ] && FORCE=1

[ -z "$REPO" ]  && { echo "usage: swarm-init.sh /path/to/repo [--force]" >&2; exit 1; }
[ -d "$REPO" ]  || { echo "swarm-init: $REPO is not a directory" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

echo "Scaffolding swarm files into $REPO"

[ "$FORCE" -eq 1 ] && export SWARM_FORCE_SEED=1 || unset SWARM_FORCE_SEED

manifest_apply "$REPO" init
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "swarm-init: aborted — manifest_apply failed (rc=$rc)" >&2
  exit "$rc"
fi

cat <<'EOF'

Done. The lead launched against this repo will hold the design conversation
with you over Discord; when you say 'go build,' it authors PROJECT_SPEC.md
and the one-way-door ADRs from the conversation, confirms with you, then
decomposes and spawns. The stamped PROJECT_SPEC.md is a placeholder until
then — see TEAM_LEAD.md.
EOF
