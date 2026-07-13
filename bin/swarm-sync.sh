#!/usr/bin/env bash
# swarm-sync.sh — bring each registered swarm repo up to current doctrine +
# enforcement state by re-applying the manifest at $SWARM_HOME/templates/
# manifest.tsv. Same manifest, same per-class semantics, as swarm-init and
# swarm-onboard — first-stamp / upgrade / onboard cannot diverge.
#
# What this DOES touch (the full manifest):
#   refresh   AGENTS.md — the historical Claude pointer comes byte-for-byte
#             from templates/_base/AGENTS.md; Codex rows use their archetype
#             source and ownership ledger
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
#   swarm-sync.sh /path/to/repo --engine codex  # explicit ad-hoc Codex surfaces
#   swarm-sync.sh ... --check              # dry-run drift report; no writes
#   swarm-sync.sh ... --force              # proceed despite dirty working tree
#
# Idempotent: an artifact that already matches the manifest is left alone;
# a repo with no changes gets no commit (no empty commits).
#
# Dirty-tree safety: sync-managed dirt is refused (not stashed or committed
# over) unless `--force` is explicit. Dirt wholly beneath stamped
# operator-owned paths may coexist with sync; the managed-only commit pathset
# leaves that work, including pre-staged entries, untouched.
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
cleanup_swarm_sync() {
  while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
}
trap cleanup_swarm_sync EXIT

# ---------------------------------------------------------------------------
# CLI parse — positional [name|path], plus --check / --force.
# ---------------------------------------------------------------------------
CHECK=0
FORCE_DIRTY=0
POSITIONAL=""
ADHOC_ENGINE="claude"
ENGINE_EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check|-n) CHECK=1; shift ;;
    --force)    FORCE_DIRTY=1; shift ;;
    --engine)
      [ $# -ge 2 ] || { echo "swarm-sync: --engine requires claude or codex" >&2; exit 1; }
      ADHOC_ENGINE="$2"; ENGINE_EXPLICIT=1; shift 2 ;;
    --engine=*) ADHOC_ENGINE="${1#--engine=}"; ENGINE_EXPLICIT=1; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
    --*)
      echo "swarm-sync: unknown flag: $1" >&2; exit 1 ;;
    *)
      if [ -z "$POSITIONAL" ]; then
        POSITIONAL="$1"
      else
        echo "swarm-sync: too many positional args ('$POSITIONAL' and '$1')" >&2
        exit 1
      fi
      shift
      ;;
  esac
done
case "$ADHOC_ENGINE" in claude|codex) ;; *) echo "swarm-sync: --engine must be claude or codex" >&2; exit 1 ;; esac

[ "$CHECK" -eq 1 ] && echo "swarm-sync: dry-run (--check) — no files will be written, no commits made"

# Short sha of the SWARM_HOME repo so per-repo commits point at the exact
# template revision propagated. Fall back to "unknown" if SWARM_HOME isn't
# a git tree (it should be) — sync itself is still useful.
TPL_SHA="$(git -C "$SWARM_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"

CHANGED_NAMES=""
CHECKED_ANY=0
ANY_DRIFT=0
ANY_FATAL=0

swarm_sync_effective_engine() {  # canonical-repo
  local _target="$1" _line _configured _canonical _matches=0 _codex=0
  SWARM_SYNC_EFFECTIVE_ENGINE=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_line"; then return 2; fi
    _configured="$SWARM_CONF_F_REPO"
    [ -d "$_configured" ] || continue
    _canonical="$(cd "$_configured" 2>/dev/null && pwd -P)" || return 2
    if [ "$SWARM_CONF_F_ENGINE" = "codex" ] && [ "$_canonical" != "$_configured" ]; then
      echo "swarm-sync: REFUSED — Codex row '$SWARM_CONF_F_NAME' uses a noncanonical repo alias: $_configured" >&2
      return 2
    fi
    [ "$_canonical" = "$_target" ] || continue
    _matches=$((_matches + 1))
    [ "$SWARM_CONF_F_ENGINE" = "codex" ] && _codex=1
  done < "$CONF"
  [ "$_matches" -gt 0 ] || return 1
  if [ "$_codex" -eq 1 ]; then SWARM_SYNC_EFFECTIVE_ENGINE="codex"; else SWARM_SYNC_EFFECTIVE_ENGINE="claude"; fi
  return 0
}

# ---------------------------------------------------------------------------
# sync_repo NAME REPO — apply the manifest to one repo, then commit.
# ---------------------------------------------------------------------------
sync_repo() {
  local name="$1" repo="$2" engine="${3:-claude}" configured="${4:-0}"
  local config_lock_held=0

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
    #
    # OPERATOR-OWNED-AWARE (ADR-0018 follow-up): a tree dirty ONLY under
    # operator-owned paths (products/, stress-test-log/, …) is SAFE to sync.
    # manifest_apply SKIPS operator-owned targets in sync mode and the commit
    # set (swarm_manifest_targets_relative) EXCLUDES them, so those dirty files
    # are provably never written, staged, or committed by this run. The CPO
    # continuously writes product specs, so its tree is near-always dirty under
    # products/ — refusing there silently strands it on stale doctrine. We
    # refuse ONLY when a SYNC-MANAGED path (doctrine / hooks / settings /
    # gitignore / anything the manifest writes) is dirty. --force still overrides.
    if [ "$CHECK" -eq 0 ]; then
      local porcelain
      porcelain="$(git -C "$repo" status --porcelain 2>/dev/null)"
      if [ -n "$porcelain" ]; then
        if [ "$FORCE_DIRTY" -eq 1 ]; then
          echo "  WARN: working tree is dirty — proceeding anyway (--force)"
        else
          # Classify the dirt against the repo's stamped operator-owned set
          # (.claude/operator-owned-paths), reusing the canonical-prefix matcher.
          # foreign = the dirty paths that are NOT operator-owned (sync-managed).
          _swarm_load_oo_from_list "$repo"
          local foreign
          foreign="$(swarm_dirty_classify_oo "$repo")"
          if [ -z "$foreign" ]; then
            echo "  NOTE: working tree is dirty but ONLY under operator-owned paths"
            echo "        (products/ etc.) — sync skips these and will not commit them; proceeding."
          else
            {
              echo "  REFUSED: working tree has uncommitted SYNC-MANAGED changes."
              echo "           Commit or stash, then re-run. To override, pass --force."
              echo "           Sync-managed dirty paths (operator-owned dirt is fine, these are not):"
              printf '%s\n' "$foreign" | head -5 | sed 's/^/             /'
            } >&2
            return 0
          fi
        fi
      fi
    fi
  fi

  # Apply the manifest. Either MODE=sync (writes) or MODE=check (read-only).
  local mode
  if [ "$CHECK" -eq 1 ]; then mode="check"; else mode="sync"; fi

  if [ "$configured" -eq 1 ]; then
    if ! swarm_conf_lock_acquire "$CONF"; then
      echo "  REFUSED: lifecycle mutation in progress; repo surfaces were not synced" >&2
      ANY_FATAL=1
      return 0
    fi
    config_lock_held=1
    if ! swarm_sync_effective_engine "$repo"; then
      echo "  REFUSED: configured repo identity/engine changed before manifest apply" >&2
      swarm_conf_lock_release
      config_lock_held=0
      ANY_FATAL=1
      return 0
    fi
    engine="$SWARM_SYNC_EFFECTIVE_ENGINE"
    echo "  effective repo surface: $engine"
  fi
  SWARM_APPLY_ENGINE_OVERRIDE="$engine" manifest_apply "$repo" "$mode"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$config_lock_held" -eq 1 ]; then
      swarm_conf_lock_release
      config_lock_held=0
    fi
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
    if [ "$config_lock_held" -eq 1 ]; then
      swarm_conf_lock_release
      config_lock_held=0
    fi
    return 0
  fi

  # Live sync: if nothing changed on disk, no commit.
  if [ "${SWARM_RESULT_CHANGED:-0}" -eq 0 ]; then
    echo "  no change"
    if [ "$config_lock_held" -eq 1 ]; then
      swarm_conf_lock_release
      config_lock_held=0
    fi
    return 0
  fi

  # Stage and commit ONLY paths we actually touched. Belt-and-braces: stage
  # every manifest target that exists (untouched files are unchanged in
  # working tree and add-with-no-diff is a no-op).
  local staged_any=0
  local target_paths=()
  local mf_files
  mf_files="$(swarm_manifest_targets_relative)"
  if [ -n "$mf_files" ]; then
    # `git add` ignores not-in-worktree paths only if the path doesn't
    # exist; manifest targets that exist are added unconditionally. The
    # commit only includes paths that are actually different from HEAD.
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -e "$repo/$p" ] || continue
      if git -C "$repo" add -- "$p" 2>/dev/null; then
        staged_any=1
        target_paths[${#target_paths[@]}]="$p"
      else
        echo "  ERROR: could not stage managed sync target '$p'" >&2
        if [ "$config_lock_held" -eq 1 ]; then
          swarm_conf_lock_release
          config_lock_held=0
        fi
        ANY_FATAL=1
        return 0
      fi
    done <<EOF
$mf_files
EOF
  fi

  local staged
  if [ "$staged_any" -eq 1 ]; then
    staged="$(git -C "$repo" diff --cached --name-only -- "${target_paths[@]}" 2>/dev/null)"
  else
    staged=""
  fi
  if [ -z "$staged" ]; then
    echo "  no staged changes — skipping commit"
    if [ "$config_lock_held" -eq 1 ]; then
      swarm_conf_lock_release
      config_lock_held=0
    fi
    return 0
  fi

  # `--only` is load-bearing: the index may already contain operator-owned
  # work that dirty-tree classification intentionally permits. Commit exactly
  # the managed pathset and leave every unrelated staged entry intact.
  if git -C "$repo" commit --only \
       -m "sync swarm system from manifest @ $TPL_SHA (branch: $branch)" \
       -- "${target_paths[@]}" >/dev/null; then
    local sha
    sha="$(cd "$repo" && git rev-parse --short HEAD)"
    echo "  committed: $sha on branch $branch — sync swarm system @ $TPL_SHA"
    CHANGED_NAMES="$CHANGED_NAMES $name"
  else
    echo "  WARN: commit failed in $repo (pre-commit hook? merge in progress?) — files are written; resolve and commit by hand" >&2
  fi
  # Configured repos retain the lifecycle lease through manifest application,
  # engine-specific target derivation, staging, and commit. A concurrent
  # add/migration therefore cannot splice a different engine surface into this
  # commit or leave half of that surface dirty.
  if [ "$config_lock_held" -eq 1 ]; then
    swarm_conf_lock_release
    config_lock_held=0
  fi
}

# swarm_manifest_targets_relative — print one target-path per line, for
# `git add`. Avoids re-parsing the manifest in every caller.
#
# Skips operator-owned: sync NEVER writes those, so they must never be
# auto-staged either — if the operator has dirty edits to their
# product-vision.md and we're force-syncing past the dirty-tree refusal,
# we must not sweep their edits into the sync commit. Always includes the
# .claude/operator-owned-paths and .claude/codex-managed-paths ledgers
# (auto-stamped by manifest_apply itself, outside the manifest walk) so their
# updates land in the sync commit.
swarm_manifest_targets_relative() {
  local out=""
  _collect() {
    # Operator-owned content is outside sync's commit, and git-hook targets
    # live beneath .git rather than in the tracked worktree. `git add` may
    # report success for the latter, but passing them to `git commit --only`
    # makes the whole managed commit fail with an unmatched pathspec.
    case "$1" in operator-owned|git-hook) return 0 ;; esac
    # Claude retains the historical AGENTS.md pointer bytes even
    # though AGENTS.md is also a Codex-owned surface for Codex rows. Skip the
    # remaining Codex-only targets, but stage Claude's managed pointer.
    _swarm_is_codex_managed_target "$3" && \
      [ "${SWARM_APPLY_ENGINE:-claude}" != "codex" ] && \
      [ "$3" != "AGENTS.md" ] && return 0
    out="${out}${3}
"
  }
  manifest_walk _collect >/dev/null || return $?
  out="${out}.claude/operator-owned-paths
"
  if [ "${SWARM_APPLY_ENGINE:-claude}" = "codex" ]; then
    out="${out}.claude/codex-managed-paths
"
  fi
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
  AD_HOC="$(cd "$POSITIONAL" 2>/dev/null && pwd -P)" || { echo "swarm-sync: not a directory: $POSITIONAL" >&2; exit 1; }
  # A path is not an authority bypass. Serialize even a currently ad-hoc repo
  # against registration, then derive all matching physical rows under that
  # lease. Configuration wins over `--engine`; malformed config fails closed.
  if ! swarm_conf_lock_acquire "$CONF"; then
    echo "swarm-sync: REFUSED — lifecycle mutation in progress; path sync did not start" >&2
    exit 2
  fi
  _path_configured=0
  swarm_sync_effective_engine "$AD_HOC"
  _derive_rc=$?
  case "$_derive_rc" in
    0)
      _path_configured=1
      if [ "$ENGINE_EXPLICIT" -eq 1 ]; then
        echo "swarm-sync: --engine is not allowed for a configured repository path; field 7 is authoritative" >&2
        swarm_conf_lock_release
        exit 2
      fi
      ADHOC_ENGINE="$SWARM_SYNC_EFFECTIVE_ENGINE"
      ;;
    1) ;;
    *)
      echo "swarm-sync: REFUSED — malformed or unsafe swarm.conf prevents authoritative path-engine resolution" >&2
      swarm_conf_lock_release
      exit 2
      ;;
  esac
  CHECKED_ANY=1
  sync_repo "$(basename "$AD_HOC")" "$AD_HOC" "$ADHOC_ENGINE" "$_path_configured"
  swarm_conf_lock_release
else
  if [ "$ENGINE_EXPLICIT" -eq 1 ]; then
    echo "swarm-sync: --engine is only valid with an ad-hoc repository path; configured rows use field 7" >&2
    exit 1
  fi
  # Either no arg (sync all in conf) or a swarm name filter.
  FILTER="${POSITIONAL:-}"
  _seen_repos="$(mktemp "${TMPDIR:-/tmp}/swarm-sync-seen.XXXXXX")" || exit 1
  : > "$_seen_repos"
  while IFS= read -r _line || [ -n "$_line" ]; do
    swarm_conf_parse_line "$_line" || continue
    name="$SWARM_CONF_F_NAME"
    repo="$SWARM_CONF_F_REPO"
    [ -z "$name" ] && continue
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
      continue
    fi
    [ -d "$repo" ] || { CHECKED_ANY=1; sync_repo "$name" "$repo" "$SWARM_CONF_F_ENGINE" 1; continue; }
    repo="$(cd "$repo" 2>/dev/null && pwd -P)" || continue
    if grep -Fqx -- "$repo" "$_seen_repos"; then
      continue
    fi
    printf '%s\n' "$repo" >> "$_seen_repos"
    if ! swarm_sync_effective_engine "$repo"; then
      echo "swarm-sync: could not derive one safe effective engine for $repo" >&2
      ANY_FATAL=1
      continue
    fi
    engine="$SWARM_SYNC_EFFECTIVE_ENGINE"
    CHECKED_ANY=1
    sync_repo "$name" "$repo" "$engine" 1
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  rm -f "$_seen_repos"
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
