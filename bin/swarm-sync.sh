#!/usr/bin/env bash
# swarm-sync.sh — bring each registered swarm repo up to current doctrine +
# enforcement state by re-applying the manifest at $SWARM_HOME/templates/
# manifest.tsv. Same manifest, same per-class semantics, as swarm-init and
# swarm-onboard — first-stamp / upgrade / onboard cannot diverge.
#
# What this DOES touch (the full manifest):
#   refresh   doctrine docs (CLAUDE.md, TEAM_LEAD.md, ESCALATION.md) and
#             .claude/hooks/* (test-gate, docs-check, permission-gate, dod-affirm)
#   settings  .claude/settings.json — structured-merge swarm hook
#             registrations; foreign hook entries preserved verbatim
#   git-hook  .git/hooks/pre-commit — refresh only if absent or existing
#             has SWARM-MANAGED marker; foreign pre-commits left alone
#             (warning printed)
#   gitignore .gitignore — append .claude/worktrees/ idempotently
#
# What this INTENTIONALLY does NOT touch:
#   - PROJECT_SPEC.md    (per-repo content, owned by the CTO in that repo)
#   - docs/adr/ADR.template.md  (seeded once by init)
#   - .claude/test-cmd   (seeded once by init; operator edits to real cmd)
#   - anything else in the repo
#
# Usage:
#   swarm-sync.sh                          # sync every repo in swarm.conf
#   swarm-sync.sh <name>                   # sync just one named swarm
#   swarm-sync.sh /path/to/repo            # sync an ad-hoc path (e.g.
#                                          # SWARM_HOME itself; not in conf)
#   swarm-sync.sh ... --check              # dry-run drift report; no writes
#   swarm-sync.sh ... --force              # proceed despite dirty working tree
#
# Idempotent: an artifact that already matches the manifest is left alone;
# a repo with no changes gets no commit (no empty commits).
#
# Dirty-tree safety: if `git status --porcelain` is non-empty before sync,
# the repo is REFUSED (not stashed, not committed-over). Pass --force to
# override per-run; the operator owns that risk.
#
# Branch handling: sync stays on whichever branch the repo is currently on
# and prints that branch name prominently in the per-repo header AND in the
# commit summary, so an operator can never be surprised by a commit landing
# on a feature branch. Refuses to sync from detached HEAD.
#
# CRITICAL — SYNC ≠ LIVE: this updates on-disk doctrine + hooks + settings.
# A *running* lead has already read its CLAUDE.md / TEAM_LEAD.md / ESCALATION.md
# into context and Claude Code has loaded its settings.json at session start —
# changes do not reach a running session until that swarm is restarted
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
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

# ---------------------------------------------------------------------------
# CLI parse — positional [name|path], plus --check / --force.
# ---------------------------------------------------------------------------
CHECK=0
FORCE_DIRTY=0
POSITIONAL=""
for arg in "$@"; do
  case "$arg" in
    --check|-n) CHECK=1 ;;
    --force)    FORCE_DIRTY=1 ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
    --*)
      echo "swarm-sync: unknown flag: $arg" >&2; exit 1 ;;
    *)
      if [ -z "$POSITIONAL" ]; then
        POSITIONAL="$arg"
      else
        echo "swarm-sync: too many positional args ('$POSITIONAL' and '$arg')" >&2
        exit 1
      fi
      ;;
  esac
done

[ "$CHECK" -eq 1 ] && echo "swarm-sync: dry-run (--check) — no files will be written, no commits made"

# Short sha of the SWARM_HOME repo so per-repo commits point at the exact
# template revision propagated. Fall back to "unknown" if SWARM_HOME isn't
# a git tree (it should be) — sync itself is still useful.
TPL_SHA="$(git -C "$SWARM_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"

CHANGED_NAMES=""
CHECKED_ANY=0
ANY_DRIFT=0
ANY_FATAL=0

# ---------------------------------------------------------------------------
# sync_repo NAME REPO — apply the manifest to one repo, then commit.
# ---------------------------------------------------------------------------
sync_repo() {
  local name="$1" repo="$2"

  echo ""
  echo "swarm '$name' ($repo)"

  if [ ! -d "$repo" ]; then
    echo "  WARN: repo path missing — skipping" >&2
    return 0
  fi
  # Allow non-git dirs (e.g., SWARM_HOME audit before it became a git tree)
  # only for --check; otherwise commits aren't possible and the sync isn't
  # useful.
  local is_git=0
  if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
    is_git=1
  fi
  if [ "$is_git" -eq 0 ] && [ "$CHECK" -eq 0 ]; then
    echo "  WARN: not a git working tree — skipping (use --check for a drift-only view)" >&2
    return 0
  fi

  local branch=""
  if [ "$is_git" -eq 1 ]; then
    branch="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
      echo "  REFUSED: detached HEAD — checkout a branch before sync" >&2
      return 0
    fi
    echo "  on branch: $branch"

    # Dirty-tree refusal (skip for --check, since check never writes anyway).
    if [ "$CHECK" -eq 0 ]; then
      local porcelain
      porcelain="$(git -C "$repo" status --porcelain 2>/dev/null)"
      if [ -n "$porcelain" ]; then
        if [ "$FORCE_DIRTY" -eq 1 ]; then
          echo "  WARN: working tree is dirty — proceeding anyway (--force)"
        else
          {
            echo "  REFUSED: working tree is dirty (uncommitted changes)."
            echo "           Commit or stash, then re-run. To override, pass --force."
            echo "           First few dirty paths:"
            printf '%s\n' "$porcelain" | head -5 | sed 's/^/             /'
          } >&2
          return 0
        fi
      fi
    fi
  fi

  # Apply the manifest. Either MODE=sync (writes) or MODE=check (read-only).
  local mode
  if [ "$CHECK" -eq 1 ]; then mode="check"; else mode="sync"; fi

  manifest_apply "$repo" "$mode"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ERROR: manifest_apply failed for $name (rc=$rc)" >&2
    ANY_FATAL=1
    return 0
  fi

  if [ "$mode" = "check" ]; then
    if [ "${SWARM_RESULT_DRIFT:-0}" -eq 1 ]; then
      ANY_DRIFT=1
    else
      echo "  (in sync)"
    fi
    return 0
  fi

  # Live sync: if nothing changed on disk, no commit.
  if [ "${SWARM_RESULT_CHANGED:-0}" -eq 0 ]; then
    echo "  no change"
    return 0
  fi

  # Stage and commit ONLY paths we actually touched. Belt-and-braces: stage
  # every manifest target that exists (untouched files are unchanged in
  # working tree and add-with-no-diff is a no-op).
  local staged_any=0
  local mf_files
  mf_files="$(swarm_manifest_targets_relative)"
  if [ -n "$mf_files" ]; then
    # `git add` ignores not-in-worktree paths only if the path doesn't
    # exist; manifest targets that exist are added unconditionally. The
    # commit only includes paths that are actually different from HEAD.
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -e "$repo/$p" ] || continue
      ( cd "$repo" && git add -- "$p" 2>/dev/null ) && staged_any=1
    done <<EOF
$mf_files
EOF
  fi

  local staged
  staged="$(cd "$repo" && git diff --cached --name-only 2>/dev/null)"
  if [ -z "$staged" ]; then
    echo "  no staged changes — skipping commit"
    return 0
  fi

  if ( cd "$repo" && git commit -m "sync swarm system from manifest @ $TPL_SHA (branch: $branch)" >/dev/null ); then
    local sha
    sha="$(cd "$repo" && git rev-parse --short HEAD)"
    echo "  committed: $sha on branch $branch — sync swarm system @ $TPL_SHA"
    CHANGED_NAMES="$CHANGED_NAMES $name"
  else
    echo "  WARN: commit failed in $repo (pre-commit hook? merge in progress?) — files are written; resolve and commit by hand" >&2
  fi
}

# swarm_manifest_targets_relative — print one target-path per line, for
# `git add`. Avoids re-parsing the manifest in every caller.
#
# Skips operator-owned: sync NEVER writes those, so they must never be
# auto-staged either — if the operator has dirty edits to their
# product-vision.md and we're force-syncing past the dirty-tree refusal,
# we must not sweep their edits into the sync commit. Always includes the
# .claude/operator-owned-paths list (auto-stamped by manifest_apply itself,
# outside the manifest walk) so its updates land in the sync commit.
swarm_manifest_targets_relative() {
  local out=""
  _collect() {
    case "$1" in operator-owned) return 0 ;; esac
    out="${out}${3}
"
  }
  manifest_walk _collect >/dev/null || return $?
  out="${out}.claude/operator-owned-paths
"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Mode selection: ad-hoc path vs. swarm.conf walk.
#
# Swarm names per swarm-add validation are [a-zA-Z][a-zA-Z0-9_-]* — no
# slashes, no dots. So a positional containing '/' or starting with '.' is
# unambiguously a path, not a name.
# ---------------------------------------------------------------------------
is_path=0
case "$POSITIONAL" in
  */*|./*|/*|.) is_path=1 ;;
esac

if [ -n "$POSITIONAL" ] && [ "$is_path" -eq 1 ]; then
  AD_HOC="$(cd "$POSITIONAL" 2>/dev/null && pwd)" || { echo "swarm-sync: not a directory: $POSITIONAL" >&2; exit 1; }
  CHECKED_ANY=1
  sync_repo "$(basename "$AD_HOC")" "$AD_HOC"
else
  # Either no arg (sync all in conf) or a swarm name filter.
  FILTER="${POSITIONAL:-}"
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    name="$SWARM_CONF_F_NAME"
    repo="$SWARM_CONF_F_REPO"
    [ -z "$name" ] && continue
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
      continue
    fi
    CHECKED_ANY=1
    sync_repo "$name" "$repo"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
fi

if [ "$CHECKED_ANY" -eq 0 ]; then
  if [ -n "$POSITIONAL" ]; then
    echo "swarm-sync: no swarm named '$POSITIONAL' in $CONF" >&2
    exit 1
  else
    echo "swarm-sync: no swarms in $CONF — nothing to do"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Summary + SYNC ≠ LIVE reminder.
# ---------------------------------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  echo ""
  echo "===================================================================="
  if [ "$ANY_DRIFT" -eq 1 ]; then
    echo "Drift detected. Re-run without --check to apply the manifest."
  else
    echo "All checked repos are in sync with the manifest."
  fi
  echo "===================================================================="
  [ "$ANY_FATAL" -eq 1 ] && exit 2
  exit 0
fi

echo ""
echo "===================================================================="
echo "SYNC ≠ LIVE."
echo ""
echo "Swarm files on disk match the manifest. But a running lead has"
echo "already read its CLAUDE.md / TEAM_LEAD.md / ESCALATION.md into its"
echo "context AND Claude Code loaded its settings.json + hooks at session"
echo "start. Live sessions continue on the OLD policy until cycled:"
echo ""
echo "    bin/swarm-up.sh down"
echo "    bin/swarm-up.sh up"
echo ""

if [ -z "$CHANGED_NAMES" ]; then
  echo "(No repos changed in this run — no restart needed.)"
else
  echo "Affected swarms (manifest changes committed in this run):"
  for n in $CHANGED_NAMES; do
    sess="${PREFIX}-${n}"
    if command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
      echo "  - $n  (tmux session $sess is RUNNING — restart required)"
    else
      echo "  - $n  (no live tmux session; next swarm-up will pick up the new state)"
    fi
  done
fi
echo "===================================================================="

[ "$ANY_FATAL" -eq 1 ] && exit 2
exit 0
