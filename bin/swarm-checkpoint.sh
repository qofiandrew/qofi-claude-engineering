#!/usr/bin/env bash
# swarm-checkpoint.sh — the SWARM_CHECKPOINT_CMD adapter: commit + branch-push
# ONE swarm repo's working tree so an imminent rotation costs minutes, not work.
#
# WHY THIS EXISTS. swarm-rotate.sh's step 1/3 is CHECKPOINT, run once per repo
# BEFORE the credential swap + fleet relaunch. A rotation = fleet restart = RAM
# state loss: in-process teammates are RAM-only and do NOT survive a relaunch;
# the lead rebuilds from DISK (stamped doctrine + COMMITTED branches). So the
# only work a rotation loses is what is NOT on disk. This script saves that work.
# It is the concrete hook the operator wires:
#     export SWARM_CHECKPOINT_CMD='/path/to/bin/swarm-checkpoint.sh "$1"'
# swarm-rotate invokes the hook as `sh -c "$hook" _ "<repo>"`, so the repo path
# arrives as $1 — and equivalently here as our own $1.
#
# THE SAFETY ENVELOPE (this is the whole point — read before editing):
#   * Operates on the repo at $1 (or $SWARM_CHECKPOINT_REPO). One repo per call.
#   * Commits any uncommitted work, then pushes the swarm's OWN current branch —
#     a worktree-<name>/feature/dev branch. That is the crash-safety cadence the
#     doctrine already endorses (ADR-0012): teammates push their worktree branch,
#     the CTO pushes dev; unpushed RAM-only work dies with the session.
#   * NEVER main/master (operator-only, reached only via an operator-approved PR).
#     If HEAD is a protected branch we REFUSE LOUDLY and skip that repo — we do
#     not commit onto it, do not push it. (Mirrors permission-gate's main floor.)
#   * NEVER --force, NEVER a destructive/broad push. A checkpoint only ever
#     fast-forwards its own branch; if the remote rejects (non-ff), that's a real
#     signal, not something to force past.
#   * IDEMPOTENT: a clean tree is a NO-OP commit-wise (exit 0). We still push the
#     branch (cheap, and it makes the remote catch up to any local-only commits),
#     but an already-up-to-date push is itself a no-op. Re-running changes nothing.
#
# INJECTABLE SEAMS (so tests push to a LOCAL bare repo, never a real remote, and
# operators can retarget without editing this file):
#   SWARM_CHECKPOINT_REMOTE   git remote NAME or URL to push to. Default: origin.
#   SWARM_CHECKPOINT_BRANCH   branch to commit/push. Default: the repo's CURRENT
#                             branch (HEAD). Set this to force a specific branch
#                             (still subject to the protected-branch refusal).
#   SWARM_CHECKPOINT_PUSH     1 (default) push after committing; 0 commit only
#                             (e.g. a host with no reachable remote — local commit
#                             still saves the work to disk, which is the floor).
#   SWARM_CHECKPOINT_MSG      commit message. Default includes a timestamp + the
#                             branch so the log reads as a rotation checkpoint.
#   SWARM_CHECKPOINT_PROTECTED  extra space/comma-separated branch names to treat
#                             as protected (refuse), on top of main/master/dev.
#                             ('dev' is protected for COMMITTING onto here — a
#                             checkpoint must land on the swarm's OWN branch, not
#                             stack surprise commits onto shared staging.)
#
# Usage:
#   swarm-checkpoint.sh <repo-path>     # checkpoint that repo (commit + push)
#   swarm-checkpoint.sh                 # repo from $SWARM_CHECKPOINT_REPO
#   swarm-checkpoint.sh -h | --help
#
# Exit codes:
#   0 — checkpointed (committed and/or pushed), OR clean-tree no-op, OR a clean
#       SKIP (protected branch / detached HEAD) — see SWARM_CHECKPOINT_STRICT.
#   2 — usage error (no repo given, repo missing, not a git work tree).
#   3 — REFUSED: HEAD is a protected branch (main/master/dev/...). By default this
#       is a LOUD exit 3 so a rotation does not silently proceed having saved
#       nothing for this repo. Set SWARM_CHECKPOINT_STRICT=0 to make it a clean
#       skip (exit 0) instead — useful when some fleet repos legitimately sit on
#       a protected branch and you don't want them to abort the rotation.
#   4 — commit failed (e.g. a pre-commit hook rejected the work).
#   5 — push failed (e.g. non-fast-forward, unreachable remote). The work IS
#       committed locally; only the publish failed.
#
# Bash 3.2-safe (macOS default). Never logs a secret (it handles none).

set -uo pipefail

PROG="swarm-checkpoint"

usage() { sed -n '1,55p' "$0"; exit "${1:-0}"; }

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --*)       echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"; else
        echo "$PROG: unexpected extra arg: $1" >&2; usage 2
      fi
      shift ;;
  esac
done

REPO="${REPO:-${SWARM_CHECKPOINT_REPO:-}}"
if [ -z "$REPO" ]; then
  echo "$PROG: no repo given. Pass a path or set SWARM_CHECKPOINT_REPO." >&2
  echo "  (swarm-rotate.sh wires this as SWARM_CHECKPOINT_CMD='swarm-checkpoint.sh \"\$1\"')" >&2
  exit 2
fi
if [ ! -d "$REPO" ]; then
  echo "$PROG: repo path is not a directory: $REPO" >&2
  exit 2
fi
# A git work tree (plain .git dir OR a linked worktree's .git file).
if [ ! -e "$REPO/.git" ] && ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$PROG: not a git work tree: $REPO — skipping (nothing to checkpoint)." >&2
  exit 2
fi

REMOTE="${SWARM_CHECKPOINT_REMOTE:-origin}"
DO_PUSH="${SWARM_CHECKPOINT_PUSH:-1}"
STRICT="${SWARM_CHECKPOINT_STRICT:-1}"

# Resolve the branch to checkpoint: explicit override, else current HEAD.
BRANCH="${SWARM_CHECKPOINT_BRANCH:-}"
if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null || true)"
fi
if [ -z "$BRANCH" ]; then
  # Detached HEAD: there is no branch to push a checkpoint to. Refuse-or-skip
  # like a protected branch — we will not create a branch behind the operator's
  # back. Honors STRICT for the exit code.
  echo "$PROG: REFUSED — $REPO is in DETACHED HEAD (no branch to checkpoint)." >&2
  echo "  A checkpoint pushes the swarm's OWN branch; it will not invent one. Checkout a branch." >&2
  [ "$STRICT" = "1" ] && exit 3
  echo "$PROG: SWARM_CHECKPOINT_STRICT=0 — skipping $REPO cleanly (exit 0)." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Protected-branch refusal. main/master are operator-only (ADR-0012); dev is
# shared staging — a checkpoint must land on the swarm's OWN branch, never stack
# surprise commits onto either. Operators can extend the set.
# ---------------------------------------------------------------------------
PROTECTED_DEFAULT="main master dev"
PROTECTED_EXTRA="$(printf '%s' "${SWARM_CHECKPOINT_PROTECTED:-}" | tr ',' ' ')"
is_protected() {
  local b
  for b in $PROTECTED_DEFAULT $PROTECTED_EXTRA; do
    [ "$b" = "$1" ] && return 0
  done
  return 1
}
if is_protected "$BRANCH"; then
  {
    echo "$PROG: REFUSED — $REPO is on protected branch '$BRANCH'."
    echo "  A rotation checkpoint NEVER commits/pushes a protected branch (main/master/dev are"
    echo "  operator-/PR-owned). The swarm should be on its own worktree-<name>/feature branch."
  } >&2
  if [ "$STRICT" = "1" ]; then
    exit 3
  fi
  echo "$PROG: SWARM_CHECKPOINT_STRICT=0 — skipping $REPO cleanly (exit 0), nothing saved for it." >&2
  exit 0
fi

echo "$PROG: $REPO  (branch: $BRANCH, remote: $REMOTE)"

# ---------------------------------------------------------------------------
# COMMIT — stage everything tracked+untracked, commit if there's anything to
# commit. A clean tree is a no-op (idempotent), NOT an error.
# ---------------------------------------------------------------------------
PORCELAIN="$(git -C "$REPO" status --porcelain 2>/dev/null)"
if [ -n "$PORCELAIN" ]; then
  STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  MSG="${SWARM_CHECKPOINT_MSG:-checkpoint: pre-rotation save on $BRANCH @ $STAMP

Auto-saved by swarm-checkpoint.sh before a fleet rotation (= restart = RAM-state
loss). Commits the working tree so the relaunch costs minutes, not work.}"
  # Stage all changes (incl. untracked) in the work tree, then commit.
  if ! git -C "$REPO" add -A 2>/dev/null; then
    echo "$PROG: 'git add -A' failed in $REPO" >&2
    exit 4
  fi
  # Re-check the index: `add -A` of only-ignored noise could leave nothing staged.
  if [ -z "$(git -C "$REPO" diff --cached --name-only 2>/dev/null)" ]; then
    echo "  nothing staged after add (only ignored paths?) — no commit"
  elif git -C "$REPO" commit --no-verify -m "$MSG" >/dev/null 2>&1; then
    # --no-verify: a checkpoint is a SAVE, not a gated merge. We must not let a
    # repo's pre-commit hook (test-gate etc.) block crash-safety right before a
    # restart that would otherwise LOSE the work. The work still flows through
    # the normal gate when the teammate later integrates the branch.
    SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo "  committed: $SHA on $BRANCH"
  else
    echo "$PROG: commit FAILED in $REPO (branch $BRANCH)" >&2
    exit 4
  fi
else
  echo "  clean working tree — nothing to commit (no-op)"
fi

# ---------------------------------------------------------------------------
# PUSH — publish the swarm's own branch to the remote. NEVER --force, never a
# protected branch (we already refused those), never broad/destructive. An
# already-up-to-date push is a no-op (idempotent).
# ---------------------------------------------------------------------------
if [ "$DO_PUSH" != "1" ]; then
  echo "  SWARM_CHECKPOINT_PUSH=$DO_PUSH — committed only, not pushing."
  exit 0
fi

# Does the remote even exist? If REMOTE looks like a configured remote NAME and
# isn't configured, that's a real misconfig for a push-enabled checkpoint.
if ! printf '%s' "$REMOTE" | grep -q '[:/]'; then
  if ! git -C "$REPO" remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "$PROG: remote '$REMOTE' is not configured in $REPO — committed locally, NOT pushed." >&2
    echo "  Set SWARM_CHECKPOINT_REMOTE to a configured remote, or SWARM_CHECKPOINT_PUSH=0 to commit-only." >&2
    exit 5
  fi
fi

# Push exactly this one branch by explicit src:dst refspec so nothing else (no
# tags, no other branches, no protected ref) can ride along. -u sets upstream so
# subsequent pushes/pulls track it. No --force, ever.
if git -C "$REPO" push -u "$REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "  pushed: $BRANCH -> $REMOTE"
  exit 0
fi
echo "$PROG: push FAILED — $BRANCH -> $REMOTE (non-fast-forward or unreachable remote)." >&2
echo "  Work IS committed locally; only the publish failed. NOT force-pushing (that would" >&2
echo "  destroy remote history). Resolve the remote divergence by hand." >&2
exit 5
