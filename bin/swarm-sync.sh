#!/usr/bin/env bash
# swarm-sync.sh — re-stamp doctrine/policy files from $SWARM_HOME/templates
# into each repo registered in $SWARM_HOME/swarm.conf, and commit the change
# inside each affected repo.
#
# Policy docs ONLY (the operating contract, refreshed every run by design —
# matches swarm-init.sh's "always refresh" set):
#     CLAUDE.md  ESCALATION.md  TEAM_LEAD.md
#
# Things this script INTENTIONALLY does NOT touch:
#   - PROJECT_SPEC.md      (per-repo content, owned by the CTO in that repo)
#   - .claude/             (hooks, settings, test-cmd — swarm-init's job)
#   - .git/hooks/          (pre-commit — swarm-init's job)
#   - .gitignore           (swarm-init's job)
#   - anything else        (project content)
#
# Usage:
#   swarm-sync.sh            # sync all repos in swarm.conf
#   swarm-sync.sh <name>     # sync just one swarm by name
#
# Idempotent: a file that already matches the template is left alone; a repo
# whose three docs are already in sync gets no commit (no empty commits).
#
# CRITICAL — SYNC ≠ LIVE: this updates the on-disk doctrine. A *running* lead
# has already read its CLAUDE.md / TEAM_LEAD.md / ESCALATION.md into context;
# new content does not reach the lead until that swarm is restarted
# (swarm-up.sh down && swarm-up.sh up). The end-of-run reminder lists which
# swarms need that. This script never restarts sessions and never pushes.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-sync: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
TPL="$SWARM_HOME/templates"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

DOCS="CLAUDE.md ESCALATION.md TEAM_LEAD.md"

# Verify each template doc exists up-front; refuse to run a half-baked sync.
for d in $DOCS; do
  [ -f "$TPL/$d" ] || { echo "swarm-sync: missing template $TPL/$d — aborting" >&2; exit 1; }
done

# Short sha of the SWARM_HOME repo so the commit message points at the exact
# template revision that was propagated. If SWARM_HOME isn't a git tree (it
# should be), fall back to "unknown" rather than failing — the sync itself is
# still useful.
TPL_SHA="$(git -C "$SWARM_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# CLI: optional <name> filter.
FILTER="${1:-}"

# Repos whose docs changed (we'll list these in the restart reminder).
CHANGED_NAMES=""
CHECKED_ANY=0

sync_repo() {  # name repo
  local name="$1" repo="$2"
  local rel
  echo ""
  echo "swarm '$name' ($repo)"

  if [ ! -d "$repo" ]; then
    echo "  WARN: repo path missing — skipping" >&2
    return 0
  fi
  if [ ! -d "$repo/.git" ]; then
    echo "  WARN: not a git working tree — skipping" >&2
    return 0
  fi

  local changed_here=0
  for d in $DOCS; do
    if [ ! -e "$repo/$d" ]; then
      cp "$TPL/$d" "$repo/$d"
      echo "  created: $d"
      changed_here=1
    elif cmp -s "$TPL/$d" "$repo/$d"; then
      echo "  unchanged: $d"
    else
      cp "$TPL/$d" "$repo/$d"
      echo "  updated: $d"
      changed_here=1
    fi
  done

  if [ "$changed_here" -eq 0 ]; then
    echo "  no change"
    return 0
  fi

  # Stage and commit ONLY the three docs in the target repo. Belt-and-braces:
  # if for some reason none of the three are actually staged after `git add`
  # (e.g. they were already committed by another process between cp and add),
  # skip the commit rather than create an empty one.
  ( cd "$repo" && git add -- $DOCS )
  local staged
  staged="$(cd "$repo" && git diff --cached --name-only -- $DOCS)"
  if [ -z "$staged" ]; then
    echo "  no staged changes — skipping commit"
    return 0
  fi

  if ( cd "$repo" && git commit -m "sync doctrine from templates @ $TPL_SHA" >/dev/null ); then
    local sha
    sha="$(cd "$repo" && git rev-parse --short HEAD)"
    echo "  committed: $sha — sync doctrine from templates @ $TPL_SHA"
    CHANGED_NAMES="$CHANGED_NAMES $name"
  else
    echo "  WARN: commit failed in $repo (pre-commit hook? merge in progress?) — files are written; resolve and commit by hand" >&2
  fi
}

# Stream the conf the same way swarm-up.sh / swarm-watch.sh do.
while IFS='|' read -r name repo tokvar channel; do
  name="$(echo "${name:-}"   | xargs)"
  repo="$(echo "${repo:-}"   | xargs)"
  [ -z "$name" ] && continue
  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi
  CHECKED_ANY=1
  sync_repo "$name" "$repo"
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$CHECKED_ANY" -eq 0 ]; then
  if [ -n "$FILTER" ]; then
    echo "swarm-sync: no swarm named '$FILTER' in $CONF" >&2
    exit 1
  else
    echo "swarm-sync: no swarms in $CONF — nothing to do"
    exit 0
  fi
fi

# Restart reminder. Compute which of the changed swarms also has a live tmux
# session — those are the ones an operator must cycle to load new doctrine
# into the lead's context and register settings/hook changes.
echo ""
echo "===================================================================="
echo "SYNC ≠ LIVE."
echo ""
echo "The new doctrine is on disk in each repo, but a running lead has"
echo "already read its CLAUDE.md / TEAM_LEAD.md / ESCALATION.md into its"
echo "context. It will keep operating on the OLD policy until its tmux"
echo "session is cycled. Restart each affected swarm explicitly:"
echo ""
echo "    bin/swarm-up.sh down"
echo "    bin/swarm-up.sh up"
echo ""

if [ -z "$CHANGED_NAMES" ]; then
  echo "(No repos changed in this run — no restart needed.)"
else
  echo "Affected swarms (docs changed in this run):"
  for n in $CHANGED_NAMES; do
    sess="${PREFIX}-${n}"
    if command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
      echo "  - $n  (tmux session $sess is RUNNING — restart required to pick up new doctrine)"
    else
      echo "  - $n  (no live tmux session; next swarm-up will pick up the new doctrine)"
    fi
  done
fi
echo "===================================================================="
