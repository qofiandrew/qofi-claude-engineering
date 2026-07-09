#!/usr/bin/env bash
# swarm-init.sh — scaffold a repo with the Claude swarm operating system.
# Usage: swarm-init.sh /path/to/repo [--type <name>] [--profile <name>] [--force]
#
# Source of truth is $SWARM_HOME/templates (default ~/claude-swarm/templates),
# whose contents are enumerated in templates/<type>/manifest.tsv — the per-
# archetype manifest dispatched to by swarm_type_of() (default 'engineering-
# cto'). swarm-init, swarm-sync, and swarm-onboard all consume the manifest
# for the target's archetype via manifest_apply in swarm-lib.sh, so the three
# commands cannot diverge on what "fully stamped" means.
#
# --type <name> stamps .claude/swarm-type with the given archetype BEFORE
# manifest_apply runs, so swarm_type_of() resolves to that type. The name
# is validated against swarm_known_types (engineering-cto / cpo /
# company-brain) — unknown types are refused, never silently
# misclassified. When --type is absent NO marker is written; swarm_type_of
# falls back to the engineering-cto default, preserving back-compat for
# existing swarms stamped before per-type dispatch existed.
#
# --profile <name> (ADR-0013) stamps .claude/swarm-profile — an ORTHOGONAL
# axis layered on top of the engineering-cto archetype. It is valid ONLY for
# engineering-cto swarms (refused against any other type, against the repo's
# RESOLVED type) and validated against swarm_known_profiles (frontend /
# backend). It composes a stack-specific overlay onto CLAUDE.md only; v1
# 'backend' is label-only (no overlay). When absent NO marker is written and
# the compose is byte-identical to a pre-profile swarm. Like --type, switching
# an existing profile is refused.
#
# init-mode policy:
#   - refresh-class artifacts (CLAUDE.md, TEAM_LEAD.md, ESCALATION.md,
#     .claude/hooks/*) — written/overwritten unconditionally.
#   - seed-class (PROJECT_SPEC.md, docs/adr/ADR.template.md, .claude/test-cmd)
#     — copied only if absent. --force re-seeds.
#   - operator-owned — copied only if absent. --force does NOT re-seed
#     (operator-authored content is sacred; see swarm-lib.sh).
#   - settings.json — copy if absent, structured-merge if one exists.
#   - .git/hooks/pre-commit — install if absent or existing has SWARM-MANAGED
#     marker; else warn and leave it alone.
#   - .gitignore — append .claude/worktrees/ idempotently.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-init: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

REPO=""
TYPE=""
PROFILE=""
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1; shift ;;
    --type)
      [ $# -ge 2 ] || { echo "swarm-init: --type requires a value" >&2; exit 1; }
      TYPE="$2"; shift 2 ;;
    --type=*)
      TYPE="${1#--type=}"; shift ;;
    --profile)
      [ $# -ge 2 ] || { echo "swarm-init: --profile requires a value" >&2; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#--profile=}"; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
    --*)
      echo "swarm-init: unknown flag: $1" >&2; exit 1 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"; else
        echo "swarm-init: too many positional args ('$REPO' and '$1')" >&2
        exit 1
      fi
      shift ;;
  esac
done

[ -z "$REPO" ]  && { echo "usage: swarm-init.sh /path/to/repo [--type <name>] [--force]" >&2; exit 1; }
[ -d "$REPO" ]  || { echo "swarm-init: $REPO is not a directory" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"

# Validate --type early — refusing here means we never stamp a marker for
# a misspelled type and never run manifest_apply against a non-existent
# templates/<type>/manifest.tsv.
if [ -n "$TYPE" ]; then
  if ! swarm_type_is_known "$TYPE"; then
    {
      echo "swarm-init: unknown --type '$TYPE'"
      echo "  known types:"
      swarm_known_types | sed 's/^/    /'
    } >&2
    exit 1
  fi
  # Defense: refuse if the template directory doesn't exist on disk. A
  # known type in swarm_known_types whose templates/<type>/ hasn't been
  # built yet would otherwise produce a confusing "manifest not found"
  # error from deep inside manifest_walk.
  if [ ! -f "$SWARM_HOME/templates/$TYPE/manifest.tsv" ]; then
    {
      echo "swarm-init: --type '$TYPE' is known but $SWARM_HOME/templates/$TYPE/manifest.tsv does not exist."
      echo "            The archetype has not been built yet."
    } >&2
    exit 1
  fi
fi

# Validate --profile early (ADR-0013), before any marker write — refusal
# leaves no partial state, mirroring the --type validation above. A profile
# is an engineering-cto-only ORTHOGONAL axis: refuse it against any other
# archetype (checked against the repo's RESOLVED type, so an already-cpo
# repo is caught even without --type), and refuse an unknown profile.
# Validation is purely against swarm_known_profiles — a label-only profile
# (v1 'backend') legitimately has NO overlay fragment on disk, so unlike
# --type we do NOT require a templates/ path to exist.
if [ -n "$PROFILE" ]; then
  EFFECTIVE_TYPE="${TYPE:-$(swarm_type_of "$REPO")}"
  if [ "$EFFECTIVE_TYPE" != "engineering-cto" ]; then
    {
      echo "swarm-init: --profile is only valid for engineering-cto swarms"
      echo "            (resolved type: '$EFFECTIVE_TYPE'). A profile is an"
      echo "            engineering-cto overlay; it does not apply to other archetypes."
    } >&2
    exit 1
  fi
  if ! swarm_profile_is_known "$PROFILE"; then
    {
      echo "swarm-init: unknown --profile '$PROFILE'"
      echo "  known profiles:"
      swarm_known_profiles | sed 's/^/    /'
    } >&2
    exit 1
  fi
fi

echo "Scaffolding swarm files into $REPO"

# Stamp .claude/swarm-type BEFORE manifest_apply so swarm_type_of()
# inside the apply resolves to the requested type, not the default.
if [ -n "$TYPE" ]; then
  mkdir -p "$REPO/.claude"
  EXISTING_TYPE=""
  if [ -f "$REPO/.claude/swarm-type" ]; then
    EXISTING_TYPE="$(head -n1 "$REPO/.claude/swarm-type" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -n "$EXISTING_TYPE" ] && [ "$EXISTING_TYPE" != "$TYPE" ]; then
    {
      echo "swarm-init: REFUSED — $REPO/.claude/swarm-type is already '$EXISTING_TYPE'"
      echo "            but --type '$TYPE' was requested. Changing a swarm's"
      echo "            archetype is not supported (it would mix doctrines)."
      echo "            Remove the marker by hand if you really mean to switch."
    } >&2
    exit 1
  fi
  if [ "$EXISTING_TYPE" != "$TYPE" ]; then
    printf '%s\n' "$TYPE" > "$REPO/.claude/swarm-type"
    echo "  stamped: .claude/swarm-type = $TYPE"
  fi
fi

# Stamp .claude/swarm-profile BEFORE manifest_apply so swarm_profile_of()
# inside the apply resolves to the requested profile (ADR-0013). Same
# refuse-to-switch guard as the type marker: changing a swarm's profile is
# not supported (it would mix doctrine overlays). Validated above.
if [ -n "$PROFILE" ]; then
  mkdir -p "$REPO/.claude"
  EXISTING_PROFILE=""
  if [ -f "$REPO/.claude/swarm-profile" ]; then
    EXISTING_PROFILE="$(head -n1 "$REPO/.claude/swarm-profile" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -n "$EXISTING_PROFILE" ] && [ "$EXISTING_PROFILE" != "$PROFILE" ]; then
    {
      echo "swarm-init: REFUSED — $REPO/.claude/swarm-profile is already '$EXISTING_PROFILE'"
      echo "            but --profile '$PROFILE' was requested. Changing a swarm's"
      echo "            profile is not supported. Remove the marker by hand if you"
      echo "            really mean to switch."
    } >&2
    exit 1
  fi
  if [ "$EXISTING_PROFILE" != "$PROFILE" ]; then
    printf '%s\n' "$PROFILE" > "$REPO/.claude/swarm-profile"
    echo "  stamped: .claude/swarm-profile = $PROFILE"
  fi
fi

[ "$FORCE" -eq 1 ] && export SWARM_FORCE_SEED=1 || unset SWARM_FORCE_SEED

manifest_apply "$REPO" init
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "swarm-init: aborted — manifest_apply failed (rc=$rc)" >&2
  exit "$rc"
fi

RESOLVED_TYPE="$(swarm_type_of "$REPO")"
case "$RESOLVED_TYPE" in
  cpo)
    cat <<'EOF'

Done. This repo is now an operator-owned product-vision store driven by the
cpo agent. The cpo holds the conversation with you over Discord; you think
out loud about products and the cpo refines your stream into clean specs
under products/<product>/<facet>.md, with decisions captured in
products/<product>/decisions/. See CLAUDE.md (the entry doctrine) and
MEMORY.md (the write protocol) for what the cpo will and won't touch.
EOF
    ;;
  *)
    cat <<'EOF'

Done. The lead launched against this repo will hold the design conversation
with you over Discord; when you say 'go build,' it authors PROJECT_SPEC.md
and the one-way-door ADRs from the conversation, confirms with you, then
decomposes and spawns. The stamped PROJECT_SPEC.md is a placeholder until
then — see TEAM_LEAD.md.
EOF
    ;;
esac
