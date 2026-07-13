#!/usr/bin/env bash
# swarm-onboard.sh — inject the swarm operating system into a pre-existing
# real codebase (the kind that already has its own code, history, and
# possibly its own .claude/, CLAUDE.md, or pre-commit hook).
#
# Different from swarm-init / swarm-add:
#   - swarm-init is for greenfield: scaffold a repo we're about to build in.
#   - swarm-add registers a swarm in swarm.conf (creates Discord bot, etc.)
#     and ALSO runs swarm-init to stamp the repo.
#   - swarm-onboard is for a real codebase the operator wants to bring
#     under the swarm. It STOPS at doctrine + enforcement. It does NOT add
#     the repo to swarm.conf (use swarm-add separately when ready to spin
#     up a Discord-facing swarm), and it does NOT fake a docs-mirror-code
#     skeleton (real codebases have their own structure; the CTO bootstraps
#     modules/<module>.md from the real code as a first task).
#
# CONFLICT POLICY: refuse-and-report by DEFAULT.
#   Onboard does a PREFLIGHT pass (no writes) against the manifest. Every
#   refresh-class artifact that exists but differs from the template, and
#   every foreign .git/hooks/pre-commit, is a COLLISION. The preflight
#   prints a per-file report. If ANY collisions remain after applying the
#   per-concern force flags (--force-docs / --force-hooks / --force-precommit
#   / --force), the script REFUSES to write anything and exits 2.
#
#   When the preflight is clean, the live pass runs and a single commit
#   captures all changes. If the live pass itself fails partway through,
#   the script rolls the repo back to its starting state.
#
#   settings.json is structured-merged (additive, dedup-by-command) and
#   does not generate a collision — that operation is always safe.
#   .gitignore is appended-to idempotently; same.
#
# Usage:
#   swarm-onboard.sh /path/to/repo [flags...]
#
# Flags:
#   --force-docs        overwrite managed doctrine (and Codex AGENTS.md) on collision
#   --force-hooks       overwrite managed .claude/.codex hooks on collision
#   --force-precommit   overwrite foreign .git/hooks/pre-commit
#   --force             all three of the above (escape hatch)
#   --force-dirty       proceed even if working tree is dirty (NOT recommended)
#   --check             preflight only — report, never write or commit
#   --engine <name>     repository runtime surfaces: claude (default) or codex
#   -h, --help          this help
#
# NOT exposed as a flag (intentional):
#   PROJECT_SPEC.md / .claude/test-cmd / docs/adr/ADR.template.md are seed-
#   class. If present, onboard leaves them alone, full stop. The operator
#   doesn't need a flag to "force-seed" these on a real codebase that
#   already has its own.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-onboard: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

usage() { sed -n '1,55p' "$0"; exit "${1:-0}"; }

REPO=""
FORCE_DOCS=0
FORCE_HOOKS=0
FORCE_PRECOMMIT=0
FORCE_DIRTY=0
CHECK_ONLY=0
ENGINE="claude"

while [ $# -gt 0 ]; do
  case "$1" in
    --force-docs)      FORCE_DOCS=1; shift ;;
    --force-hooks)     FORCE_HOOKS=1; shift ;;
    --force-precommit) FORCE_PRECOMMIT=1; shift ;;
    --force)           FORCE_DOCS=1; FORCE_HOOKS=1; FORCE_PRECOMMIT=1; shift ;;
    --force-dirty)     FORCE_DIRTY=1; shift ;;
    --check|-n)        CHECK_ONLY=1; shift ;;
    --engine)          [ $# -ge 2 ] || { echo "swarm-onboard: --engine requires a value" >&2; usage 1; }; ENGINE="$2"; shift 2 ;;
    --engine=*)        ENGINE="${1#--engine=}"; shift ;;
    -h|--help)         usage 0 ;;
    --*)               echo "swarm-onboard: unknown flag: $1" >&2; usage 1 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"; else
        echo "swarm-onboard: too many positional args ('$REPO' and '$1')" >&2; usage 1
      fi
      shift
      ;;
  esac
done
case "$ENGINE" in claude|codex) ;; *) echo "swarm-onboard: --engine must be claude or codex" >&2; exit 1 ;; esac
export SWARM_APPLY_ENGINE_OVERRIDE="$ENGINE"

[ -z "$REPO" ] && { echo "swarm-onboard: missing repo path" >&2; usage 1; }
[ -d "$REPO" ] || { echo "swarm-onboard: not a directory: $REPO" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"

# Onboard requires a real git working tree — atomicity guarantees depend on
# `git restore` to undo our writes on rollback.
if [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/.git" ]; then
  echo "swarm-onboard: $REPO is not a git working tree — onboard requires git for atomicity" >&2
  exit 1
fi

BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
  echo "swarm-onboard: detached HEAD in $REPO — checkout a branch before onboarding" >&2
  exit 1
fi

echo "Onboarding swarm system into $REPO"
echo "  branch: $BRANCH"
[ "$CHECK_ONLY" -eq 1 ] && echo "  mode: --check (preflight only; no writes, no commit)"

# Dirty-tree refusal (default).
PORCELAIN="$(git -C "$REPO" status --porcelain 2>/dev/null)"
if [ -n "$PORCELAIN" ]; then
  if [ "$FORCE_DIRTY" -eq 1 ]; then
    echo "  WARN: working tree is dirty — proceeding anyway (--force-dirty)"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    echo "  WARN: working tree is dirty (--check ignores this; live run would refuse)"
  else
    {
      echo "swarm-onboard: REFUSED — working tree is dirty (uncommitted changes)."
      echo "Commit or stash, then re-run. Atomicity (rollback on failure)"
      echo "requires a clean starting state. Override with --force-dirty (NOT"
      echo "recommended; rollback on failure may not recover operator WIP)."
      echo "First few dirty paths:"
      printf '%s\n' "$PORCELAIN" | head -5 | sed 's/^/  /'
    } >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# PREFLIGHT: dry-run apply with onboard collision policy.
#
# This is the gate: we discover every conflict BEFORE writing anything.
# The flags chosen by the operator (or their absence) determine whether each
# would-be-conflict is silently resolvable or a hard COLLISION.
# ---------------------------------------------------------------------------
echo ""
echo "PREFLIGHT (no writes):"

export SWARM_FORCE_DOCS="$FORCE_DOCS"
export SWARM_FORCE_HOOKS="$FORCE_HOOKS"
export SWARM_FORCE_PRECOMMIT="$FORCE_PRECOMMIT"
export SWARM_DRY_RUN=1
export SWARM_QUIET_UNCHANGED=1

manifest_apply "$REPO" onboard
PREFLIGHT_RC=$?

if [ "$PREFLIGHT_RC" -ne 0 ] || [ "${SWARM_RESULT_FATAL:-0}" -eq 1 ]; then
  echo ""
  echo "swarm-onboard: REFUSED — preflight encountered a fatal error (missing template?)." >&2
  exit 2
fi

if [ -n "${SWARM_RESULT_COLLISIONS:-}" ]; then
  echo ""
  echo "===================================================================="
  echo "COLLISIONS — onboard REFUSED. No files written."
  echo "===================================================================="
  echo ""
  echo "The following manifest entries collide with existing files that"
  echo "differ from the swarm template:"
  printf '%s\n' "${SWARM_RESULT_COLLISIONS}" | sed '/^$/d' | sed 's/^/  /'
  echo ""
  echo "To proceed, re-run with the appropriate per-concern flag(s):"
  echo "  --force-docs        overwrite managed doctrine (including Codex AGENTS.md)"
  echo "  --force-hooks       overwrite managed .claude/.codex hooks"
  echo "  --force-precommit   overwrite a foreign .git/hooks/pre-commit"
  echo "  --force             all of the above"
  echo ""
  echo "Or hand-merge the conflicting files yourself and re-run."
  echo "===================================================================="
  exit 2
fi

if [ "${SWARM_RESULT_CHANGED:-0}" -eq 0 ]; then
  echo ""
  echo "swarm-onboard: nothing to do — this repo is already fully stamped."
  exit 0
fi

# Stop here in --check mode. Preflight already printed the plan.
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo ""
  echo "===================================================================="
  echo "swarm-onboard --check: plan is clean. Re-run without --check to apply."
  echo "===================================================================="
  exit 0
fi

# ---------------------------------------------------------------------------
# LIVE APPLY: preflight passed, no unresolved collisions. Now write.
#
# We snapshot the pre-existing .git/hooks/pre-commit because git can't
# restore files outside the working tree. Everything else (settings.json,
# CLAUDE.md, etc.) is in the working tree and is recoverable via `git
# restore` + targeted deletion of newly-created files on rollback.
# ---------------------------------------------------------------------------

SNAPSHOT_DIR="$(mktemp -d -t swarm-onboard.XXXXXX)" || {
  echo "swarm-onboard: could not create snapshot dir" >&2; exit 2; }
PRECOMMIT_PATH="$REPO/.git/hooks/pre-commit"
PRECOMMIT_EXISTED=0
if [ -e "$PRECOMMIT_PATH" ]; then
  cp "$PRECOMMIT_PATH" "$SNAPSHOT_DIR/pre-commit"
  PRECOMMIT_EXISTED=1
fi

# Capture the set of manifest target paths so rollback can remove any we
# created. (Files that existed at HEAD are reverted via `git restore`.)
MANIFEST_TARGETS=""
_collect_targets() {
  # Skip git-hook (handled via snapshot) and gitignore (tracked file; git
  # restore handles).
  case "$1" in git-hook|gitignore) return 0 ;; esac
  _swarm_is_codex_managed_target "$3" \
    && [ "$ENGINE" != "codex" ] && [ "$3" != "AGENTS.md" ] && return 0
  MANIFEST_TARGETS="$MANIFEST_TARGETS
$3"
}
manifest_walk _collect_targets
if [ "$ENGINE" = "codex" ]; then
  MANIFEST_TARGETS="$MANIFEST_TARGETS
.claude/codex-managed-paths"
fi

rollback() {
  echo ""
  echo "swarm-onboard: ROLLING BACK to pre-onboard state..."
  # 1) Revert any tracked file we modified.
  ( cd "$REPO" && git checkout -- . 2>/dev/null || true )
  # 2) Remove untracked files we may have created (only manifest targets
  #    that aren't tracked at HEAD).
  while IFS= read -r tgt; do
    [ -z "$tgt" ] && continue
    if [ -e "$REPO/$tgt" ]; then
      if ! ( cd "$REPO" && git cat-file -e "HEAD:$tgt" 2>/dev/null ); then
        rm -f "$REPO/$tgt"
      fi
    fi
  done <<EOF
$MANIFEST_TARGETS
EOF
  # 3) Restore .git/hooks/pre-commit.
  if [ "$PRECOMMIT_EXISTED" -eq 1 ]; then
    cp "$SNAPSHOT_DIR/pre-commit" "$PRECOMMIT_PATH"
  else
    rm -f "$PRECOMMIT_PATH"
  fi
  rm -rf "$SNAPSHOT_DIR"
  echo "swarm-onboard: rollback complete. Repo is unchanged from start."
}

echo ""
echo "LIVE APPLY:"
unset SWARM_DRY_RUN
unset SWARM_QUIET_UNCHANGED

manifest_apply "$REPO" onboard
LIVE_RC=$?

if [ "$LIVE_RC" -ne 0 ] || [ "${SWARM_RESULT_FATAL:-0}" -eq 1 ]; then
  echo ""
  echo "swarm-onboard: LIVE APPLY FAILED — rolling back." >&2
  rollback
  exit 2
fi

# Defense in depth: if a collision somehow appeared in the live pass (e.g.,
# a race between preflight and live), refuse and roll back.
if [ -n "${SWARM_RESULT_COLLISIONS:-}" ]; then
  echo ""
  echo "swarm-onboard: collisions appeared in live pass (race?) — rolling back." >&2
  printf '%s\n' "$SWARM_RESULT_COLLISIONS" | sed '/^$/d' | sed 's/^/  /'
  rollback
  exit 2
fi

# ---------------------------------------------------------------------------
# COMMIT — single commit on the current branch.
# ---------------------------------------------------------------------------
TPL_SHA="$(git -C "$SWARM_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Stage manifest targets (only the ones that actually exist in the worktree
# now). .git/hooks/pre-commit is outside the worktree; git ignores it.
# operator-owned IS staged here (in onboard, the seed is part of the initial
# commit) — distinct from sync, which never stages operator-owned content.
_stage() {
  local behavior="$1" src="$2" tgt="$3"
  case "$behavior" in git-hook) return 0 ;; esac
  _swarm_is_codex_managed_target "$tgt" \
    && [ "$ENGINE" != "codex" ] && [ "$tgt" != "AGENTS.md" ] && return 0
  [ -e "$REPO/$tgt" ] || return 0
  ( cd "$REPO" && git add -- "$tgt" 2>/dev/null || true )
}
manifest_walk _stage

# Stage the auto-stamped ledgers (they live outside the manifest walk).
for _ledger in .claude/operator-owned-paths; do
  if [ -e "$REPO/$_ledger" ]; then
    ( cd "$REPO" && git add -- "$_ledger" 2>/dev/null || true )
  fi
done
if [ "$ENGINE" = "codex" ] && [ -e "$REPO/.claude/codex-managed-paths" ]; then
  ( cd "$REPO" && git add -- ".claude/codex-managed-paths" 2>/dev/null || true )
fi

STAGED="$(cd "$REPO" && git diff --cached --name-only 2>/dev/null)"
if [ -z "$STAGED" ]; then
  # All manifest writes happened to be no-ops (e.g., all files already at
  # template state, only .git/hooks/pre-commit was missing). Print and exit
  # without an empty commit.
  echo ""
  echo "swarm-onboard: no staged changes to commit (likely only .git/hooks/pre-commit changed)."
else
  if ( cd "$REPO" && git commit -m "onboard swarm system from manifest @ $TPL_SHA (branch: $BRANCH)" >/dev/null ); then
    SHA="$(cd "$REPO" && git rev-parse --short HEAD)"
    echo ""
    echo "swarm-onboard: committed $SHA on branch $BRANCH — onboard swarm system @ $TPL_SHA"
  else
    echo "swarm-onboard: WARN — commit failed (pre-commit hook?). Files are written; resolve and commit by hand." >&2
  fi
fi

rm -rf "$SNAPSHOT_DIR"

# ---------------------------------------------------------------------------
# Onboarding-comb-over CTO bootstrap note. The comb-over PROTOCOL itself
# lives in TEAM_LEAD.md §*Onboarding comb-over* — reconciling docs to
# code is judgment work, not scriptable. We just invoke it by name and
# tailor one paragraph to monorepo vs single-app shape.
#
# Monorepo detection is a HINT for this message — the comb-over's
# code-reading is authoritative if this hint guesses wrong.
# Rule: apps/ with ≥1 subdir OR packages/ present.
# ---------------------------------------------------------------------------
is_monorepo=0
if [ -d "$REPO/apps" ] && [ -n "$(find "$REPO/apps" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ]; then
  is_monorepo=1
fi
[ -d "$REPO/packages" ] && is_monorepo=1

cat <<EOF

====================================================================
Onboarded: doctrine + enforcement are in place.

NEXT STEP — the docs structure is NOT auto-generated. The CTO's
mandated first task in this repo is the ONBOARDING COMB-OVER (see
TEAM_LEAD.md §Onboarding comb-over). The comb-over reverse-engineers
modules/<module>.md from the actual code, reconciles any stale docs
to current code behavior, and surfaces doc-vs-code conflicts that
look like bugs (instead of silently documenting broken behavior —
onboarding doubles as defect discovery).
EOF

if [ "$is_monorepo" -eq 1 ]; then
  cat <<EOF

This repo looks like a MONOREPO (apps/ subdirs OR packages/ present).
The comb-over builds the MONOREPO docs layout:

  - apps/<app>/docs/ for each app — that app's modules/<module>.md
    and app-scoped ADRs.
  - docs/ at the repo root for cross-app / project-wide concerns
    (PROJECT_SPEC.md, shared ADRs, build log).
  - Shared packages documented as their own modules with contract
    surface + data-ownership rule (typically single-owner of any
    shared schema; consumed via contract, not by reaching into
    tables).

Do NOT flatten the monorepo into a single docs/ set.
EOF
else
  cat <<EOF

This repo looks like a single-app codebase. The comb-over builds
the flat docs layout: modules/<module>.md at the repo root,
docs/adr/ at the repo root.
EOF
fi

cat <<EOF

After the comb-over completes, continue at TEAM_LEAD.md §Lifecycle
step 2 (Decompose) on feature work — there is no design conversation,
the repo already exists.

swarm-onboard does NOT register this repo with the swarm. When ready
to spin up a Discord-facing swarm against it, run:

  bin/swarm-add.sh <name> $REPO <channel_id> --engine $ENGINE
====================================================================
EOF
