#!/usr/bin/env bash
# swarm-new.sh — front-end for new-swarm standup. Automates the GitHub
# half (create remote, push initial commit) and then execs swarm-add.sh
# for the Discord-portal walkthrough.
#
# swarm-new owns:
#   - fresh local repo at ~/qofirepos/<name> with an empty initial commit
#   - a new GitHub repo at github.com/qofiandrew/<name>
#   - 'origin' set to the github-company SSH alias
#   - first push (origin/main tracking)
#
# swarm-add (existing) owns everything else: Discord app/bot creation
# walkthrough, MESSAGE CONTENT INTENT toggle, OAuth invite, channel ID
# capture, silent token paste, swarm.conf row, swarm-init stamping,
# enabledPlugins verify, access.json.
#
# Usage:
#   swarm-new.sh <name> [--public] [--type <name>]
#
#   <name>     short, no spaces, [a-zA-Z][a-zA-Z0-9_-]*  (becomes both
#              the GitHub repo name and, via swarm-add, the tmux session
#              "swarm-<name>")
#
# Flags:
#   --public        create the GitHub repo as public (default: private)
#   --type <name>   stamp the swarm as a specific archetype (engineering-cto /
#                   cpo / company-brain). Default is engineering-cto when
#                   omitted; no marker is written (back-compat). Threaded to
#                   swarm-add → swarm-init for the actual stamp.
#   --profile <name>
#                   engineering-cto-only profile overlay (frontend / backend;
#                   ADR-0013), threaded to swarm-add → swarm-init. Stamps
#                   .claude/swarm-profile and composes a stack-specific overlay
#                   onto CLAUDE.md. v1 'backend' is label-only. Omit for none.
#   --bot-user-id <id>
#                   the new swarm's Discord bot user id (== Application ID),
#                   threaded to swarm-add for cto-watcher bus registration
#                   (engineering-cto only). Usually omitted on greenfield —
#                   the app doesn't exist yet, so swarm-add's walkthrough
#                   prompts for it. Pass it only if the Discord app was
#                   pre-created.
#   -h, --help      this help
#
# Greenfield only — creates a brand-new repo at ~/qofirepos/<name>.
# Wrapping an existing local directory is intentionally out of scope.
#
# CWD-independent — uses absolute paths and 'git -C <repo>' throughout;
# safe to invoke from anywhere.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-new: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the lib for swarm_type_is_known (used to validate --type before
# any GitHub side-effects).
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

usage() {
  sed -n '1,48p' "$0"
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing — positional [name] + flags in any order.
# --type takes a value (next arg, or --type=<val>); convert to a
# while/shift loop so that two-arg form works.
# ---------------------------------------------------------------------------
NAME=""
VISIBILITY="--private"
TYPE=""
PROFILE=""
BOT_USER_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --public)   VISIBILITY="--public"; shift ;;
    --private)  VISIBILITY="--private"; shift ;;
    --type)
      [ $# -ge 2 ] || { echo "swarm-new: --type requires a value" >&2; usage 1; }
      TYPE="$2"; shift 2 ;;
    --type=*)
      TYPE="${1#--type=}"; shift ;;
    --profile)
      [ $# -ge 2 ] || { echo "swarm-new: --profile requires a value" >&2; usage 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#--profile=}"; shift ;;
    --bot-user-id)
      [ $# -ge 2 ] || { echo "swarm-new: --bot-user-id requires a value" >&2; usage 1; }
      BOT_USER_ID="$2"; shift 2 ;;
    --bot-user-id=*)
      BOT_USER_ID="${1#--bot-user-id=}"; shift ;;
    -h|--help)  usage 0 ;;
    --*)        echo "swarm-new: unknown flag: $1" >&2; usage 1 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"; else
        echo "swarm-new: too many positional args (got '$1' after name)" >&2; usage 1
      fi
      shift ;;
  esac
done

[ -z "$NAME" ] && { echo "swarm-new: missing <name>" >&2; usage 1; }

if [ -n "$TYPE" ]; then
  if ! swarm_type_is_known "$TYPE"; then
    {
      echo "swarm-new: unknown --type '$TYPE'"
      echo "  known types:"
      swarm_known_types | sed 's/^/    /'
    } >&2
    exit 1
  fi
fi

# Fail-fast flag-level --profile check (ADR-0013), before any GitHub
# side-effects. The authoritative refusal lives in swarm-init (reached via
# swarm-add); this catches the obvious cases before we create a remote.
if [ -n "$PROFILE" ]; then
  if [ "${TYPE:-engineering-cto}" != "engineering-cto" ]; then
    echo "swarm-new: --profile is only valid for engineering-cto swarms (got --type '$TYPE')" >&2
    exit 1
  fi
  if ! swarm_profile_is_known "$PROFILE"; then
    {
      echo "swarm-new: unknown --profile '$PROFILE'"
      echo "  known profiles:"
      swarm_known_profiles | sed 's/^/    /'
    } >&2
    exit 1
  fi
fi

# Name validation mirrors swarm-add's rule. Check it BEFORE touching
# GitHub so we never create a remote we'd then refuse to register.
echo "$NAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$' || {
  echo "swarm-new: name must match [a-zA-Z][a-zA-Z0-9_-]* (got: $NAME)" >&2
  exit 1
}

GH_OWNER="qofiandrew"
SSH_ALIAS="github-company"
REPO_PARENT="$HOME/qofirepos"
REPO="$REPO_PARENT/$NAME"
REMOTE_URL="git@${SSH_ALIAS}:${GH_OWNER}/${NAME}.git"

# ---------------------------------------------------------------------------
# Preflight — all side-effect-free. Any failure here aborts before we
# touch disk or GitHub.
# ---------------------------------------------------------------------------
echo "swarm-new: preflight"

if ! command -v gh >/dev/null 2>&1; then
  echo "swarm-new: gh CLI not on PATH — install with 'brew install gh' and re-run." >&2
  exit 1
fi

GH_STATUS="$(gh auth status 2>&1)" || {
  echo "swarm-new: gh not authenticated — run 'gh auth login' and re-run." >&2
  echo "$GH_STATUS" >&2
  exit 1
}

# Two-accounts footgun: this host has multiple gh logins. The
# github-company SSH alias resolves to qofiandrew, so the active gh
# account must match — otherwise gh repo create would land it under
# the wrong owner.
ACTIVE_USER="$(gh api user --jq .login 2>/dev/null)" || {
  echo "swarm-new: could not query active gh user — run 'gh auth status'." >&2
  exit 1
}
if [ "$ACTIVE_USER" != "$GH_OWNER" ]; then
  echo "swarm-new: active gh account is '$ACTIVE_USER', expected '$GH_OWNER'." >&2
  echo "          switch with:  gh auth switch -u $GH_OWNER" >&2
  exit 1
fi

# SSH alias presence — without it the push would either fail or
# silently route through plain github.com, breaking the remote
# convention the rest of the repos use.
if ! grep -qE "^Host[[:space:]]+${SSH_ALIAS}([[:space:]]|\$)" "$HOME/.ssh/config" 2>/dev/null; then
  echo "swarm-new: no 'Host $SSH_ALIAS' entry in ~/.ssh/config — add the alias and re-run." >&2
  exit 1
fi

# Target dir must not exist — greenfield only.
if [ -e "$REPO" ]; then
  echo "swarm-new: target path already exists: $REPO" >&2
  echo "          this script is greenfield-only; pick a different name or remove the path." >&2
  exit 1
fi

mkdir -p "$REPO_PARENT" || {
  echo "swarm-new: could not create parent dir $REPO_PARENT" >&2
  exit 1
}

echo "  name:    $NAME"
echo "  repo:    $REPO"
echo "  remote:  $REMOTE_URL ($VISIBILITY on github.com/$GH_OWNER)"
echo "  account: $ACTIVE_USER"

# ---------------------------------------------------------------------------
# PHASE 1 — local repo init (BEFORE touching GitHub).
#
# Doing this first means any local failure happens while GitHub is
# untouched, so there's no orphaned-remote cleanup to do on the
# failure path.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-new: initialising local repo at $REPO"

mkdir "$REPO" || { echo "swarm-new: mkdir $REPO failed" >&2; exit 1; }

git -C "$REPO" init -q || {
  echo "swarm-new: git init failed in $REPO" >&2
  exit 1
}

# Empty initial commit — gives us a HEAD to push without colliding with
# any files swarm-init will later stamp into the repo.
git -C "$REPO" commit --allow-empty -m "Initial commit" -q || {
  echo "swarm-new: empty initial commit failed in $REPO" >&2
  exit 1
}

# Force-rename to 'main' so we don't depend on the host's
# init.defaultBranch setting.
git -C "$REPO" branch -M main || {
  echo "swarm-new: 'git branch -M main' failed in $REPO" >&2
  exit 1
}

echo "  local repo on branch 'main' with empty initial commit"

# ---------------------------------------------------------------------------
# PHASE 2 — create the GitHub remote.
#
# This is the first step that creates anything outside the local FS.
# Done now (after local init) so the orphan window is just this step
# plus the push that follows.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-new: creating GitHub repo $GH_OWNER/$NAME ($VISIBILITY)"

GH_OUT="$(gh repo create "$GH_OWNER/$NAME" "$VISIBILITY" 2>&1)"
GH_RC=$?
if [ "$GH_RC" -ne 0 ]; then
  echo "swarm-new: 'gh repo create' failed (rc=$GH_RC):" >&2
  echo "$GH_OUT" >&2
  echo "          GitHub side is untouched; remove the local dir for a clean retry:" >&2
  echo "          rm -rf $REPO" >&2
  exit 1
fi
echo "  GitHub repo created: https://github.com/$GH_OWNER/$NAME"

# ---------------------------------------------------------------------------
# PHASE 3 — wire the remote and push.
#
# From here on, GitHub exists. If anything fails before the push lands,
# print a precise remediation so the operator knows exactly how to
# recover (retry the push, or delete the empty remote).
# ---------------------------------------------------------------------------
print_orphan_remediation() {
  cat >&2 <<EOF

swarm-new: !! GitHub repo '$GH_OWNER/$NAME' was created but the initial
              push did not complete. Pick one to recover:

   retry the push:
       git -C $REPO push -u origin main

   OR delete the empty remote and start over:
       gh repo delete $GH_OWNER/$NAME --yes
       rm -rf $REPO

EOF
}

if ! git -C "$REPO" remote add origin "$REMOTE_URL"; then
  echo "swarm-new: 'git remote add origin' failed" >&2
  print_orphan_remediation
  exit 1
fi

echo ""
echo "swarm-new: pushing initial commit to origin/main"

if ! git -C "$REPO" push -u origin main; then
  echo "swarm-new: 'git push' failed" >&2
  print_orphan_remediation
  exit 1
fi

# Final sanity check — confirm upstream tracking is actually set.
if ! git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  echo "swarm-new: push reported success but upstream is not set; investigate." >&2
  print_orphan_remediation
  exit 1
fi

# ---------------------------------------------------------------------------
# PHASE 4 — hand off to swarm-add for the Discord half.
#
# swarm-add picks up from its Phase 0: it'll prompt for channel ID
# (Phase 2), walk the Discord portal (Phase 1), capture the token
# silently (Phase 3), write tokens.env + swarm.conf, run swarm-init,
# verify enabledPlugins, and stamp access.json.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-new: GitHub side complete."
echo "  repo:    $REPO"
echo "  remote:  $REMOTE_URL"
echo "  branch:  main (tracking origin/main)"
echo ""
echo "swarm-new: handing off to swarm-add for the Discord walkthrough"
echo ""

# Thread --type (→ swarm-init), --profile (→ swarm-init, ADR-0013), and
# --bot-user-id (→ cto-watcher bus registration) through to swarm-add. Build
# the arg list dynamically so the bare two-arg form still works when all are
# absent.
ADD_ARGS=("$NAME" "$REPO")
[ -n "$TYPE" ]        && ADD_ARGS+=(--type "$TYPE")
[ -n "$PROFILE" ]     && ADD_ARGS+=(--profile "$PROFILE")
[ -n "$BOT_USER_ID" ] && ADD_ARGS+=(--bot-user-id "$BOT_USER_ID")
exec "$SCRIPT_DIR/swarm-add.sh" "${ADD_ARGS[@]}"
