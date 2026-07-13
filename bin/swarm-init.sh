#!/usr/bin/env bash
# swarm-init.sh — scaffold a repo with the Claude swarm operating system.
# Usage: swarm-init.sh /path/to/repo [--type <name>] [--profile <name>] [--engine claude|codex] [--force]
#
# Source of truth is $SWARM_HOME/templates (default ~/claude-swarm/templates),
# whose contents are enumerated in templates/<type>/manifest.tsv — the per-
# archetype manifest dispatched to by swarm_type_of() (default 'engineering-
# cto'). swarm-init, swarm-sync, and swarm-onboard all consume the manifest
# for the target's archetype via manifest_apply in swarm-lib.sh, so the three
# commands cannot diverge on what "fully stamped" means.
#
# --type <name> applies the selected archetype through an in-memory override,
# then stamps .claude/swarm-type only AFTER the manifest adoption preflight
# and apply succeed. The name
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
ENGINE="claude"
ENGINE_EXPLICIT=0
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
    --engine)
      [ $# -ge 2 ] || { echo "swarm-init: --engine requires a value" >&2; exit 1; }
      ENGINE="$2"; ENGINE_EXPLICIT=1; shift 2 ;;
    --engine=*)
      ENGINE="${1#--engine=}"; ENGINE_EXPLICIT=1; shift ;;
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

[ -z "$REPO" ]  && { echo "usage: swarm-init.sh /path/to/repo [--type <name>] [--profile <name>] [--engine claude|codex] [--force]" >&2; exit 1; }
[ -d "$REPO" ]  || { echo "swarm-init: $REPO is not a directory" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"
case "$ENGINE" in
  claude|codex) ;;
  *) echo "swarm-init: --engine must be claude or codex (got: $ENGINE)" >&2; exit 1 ;;
esac

# A configured repository's surface is repository-scoped, even though engine
# selection is row-scoped.  In particular, one Codex row makes AGENTS.md and
# the managed-surface ledger authoritative for every Claude sibling sharing
# that physical repository.  A bare direct swarm-init historically defaulted
# to Claude and could therefore rewrite a configured Codex AGENTS.md while
# leaving its Codex ledger behind.  Resolve the effective engine under the same
# cooperative config lock used by sync.  swarm-add always passes --engine after
# doing its own locked shared-repo resolution, so it does not re-enter the lock.
INIT_CONFIG_LOCK_HELD=0
cleanup_swarm_init() {
  if [ "$INIT_CONFIG_LOCK_HELD" -eq 1 ]; then
    swarm_conf_lock_release
    INIT_CONFIG_LOCK_HELD=0
  fi
}
trap cleanup_swarm_init EXIT

if [ "$ENGINE_EXPLICIT" -eq 0 ]; then
  CONF="$SWARM_HOME/swarm.conf"
  if ! swarm_conf_lock_acquire "$CONF"; then
    echo "swarm-init: REFUSED — lifecycle mutation in progress; repo surfaces were not initialized" >&2
    exit 2
  fi
  INIT_CONFIG_LOCK_HELD=1
  _init_matches=0
  _init_codex=0
  while IFS= read -r _init_line || [ -n "$_init_line" ]; do
    _init_trimmed="$(_swarm_trim "$_init_line")"
    case "$_init_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_init_line"; then
      echo "swarm-init: REFUSED — malformed swarm.conf prevents configured engine resolution" >&2
      exit 2
    fi
    _init_configured="$SWARM_CONF_F_REPO"
    [ -d "$_init_configured" ] || continue
    _init_canonical="$(cd "$_init_configured" 2>/dev/null && pwd -P)" || {
      echo "swarm-init: REFUSED — configured repository cannot be canonicalized: $_init_configured" >&2
      exit 2
    }
    if [ "$SWARM_CONF_F_ENGINE" = "codex" ] && [ "$_init_canonical" != "$_init_configured" ]; then
      echo "swarm-init: REFUSED — Codex row '$SWARM_CONF_F_NAME' uses a noncanonical repo alias: $_init_configured" >&2
      exit 2
    fi
    [ "$_init_canonical" = "$REPO" ] || continue
    _init_matches=$((_init_matches + 1))
    [ "$SWARM_CONF_F_ENGINE" = "codex" ] && _init_codex=1
  done < "$CONF"
  if [ "$_init_matches" -gt 0 ]; then
    if [ "$_init_codex" -eq 1 ]; then ENGINE="codex"; else ENGINE="claude"; fi
    echo "swarm-init: configured repo surface resolved to $ENGINE"
  else
    swarm_conf_lock_release
    INIT_CONFIG_LOCK_HELD=0
  fi
fi

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
export SWARM_APPLY_ENGINE_OVERRIDE="$ENGINE"

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

# Validate existing markers before manifest_apply. No mkdir or marker write is
# allowed ahead of the Codex adoption preflight: a foreign `.codex/**` or
# `.agents/skills/**` target must leave init with no partial marker state.
EXISTING_TYPE=""
if [ -n "$TYPE" ]; then
  if [ -L "$REPO/.claude/swarm-type" ] || \
     { [ -e "$REPO/.claude/swarm-type" ] && [ ! -f "$REPO/.claude/swarm-type" ]; }; then
    echo "swarm-init: REFUSED — .claude/swarm-type is not a regular file" >&2
    exit 1
  fi
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
fi

EXISTING_PROFILE=""
if [ -n "$PROFILE" ]; then
  if [ -L "$REPO/.claude/swarm-profile" ] || \
     { [ -e "$REPO/.claude/swarm-profile" ] && [ ! -f "$REPO/.claude/swarm-profile" ]; }; then
    echo "swarm-init: REFUSED — .claude/swarm-profile is not a regular file" >&2
    exit 1
  fi
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
fi

[ "$FORCE" -eq 1 ] && export SWARM_FORCE_SEED=1 || unset SWARM_FORCE_SEED

# Resolve a requested type/profile without writing their marker first. The
# manifest layer performs the full Codex adoption preflight before its first
# write, using these explicit selections for manifest/profile dispatch.
if [ -n "$TYPE" ]; then
  export SWARM_APPLY_TYPE_OVERRIDE="$TYPE"
else
  unset SWARM_APPLY_TYPE_OVERRIDE
fi
if [ -n "$PROFILE" ]; then
  export SWARM_APPLY_PROFILE_OVERRIDE_SET=1
  export SWARM_APPLY_PROFILE_OVERRIDE="$PROFILE"
else
  unset SWARM_APPLY_PROFILE_OVERRIDE_SET SWARM_APPLY_PROFILE_OVERRIDE
fi

manifest_apply "$REPO" init
rc=$?
unset SWARM_APPLY_TYPE_OVERRIDE SWARM_APPLY_PROFILE_OVERRIDE_SET SWARM_APPLY_PROFILE_OVERRIDE SWARM_APPLY_ENGINE_OVERRIDE
if [ "$rc" -ne 0 ]; then
  echo "swarm-init: aborted — manifest_apply failed (rc=$rc)" >&2
  exit "$rc"
fi

# Markers are committed only after a successful adoption+apply. Publish through
# the manifest layer's engine-aware atomic writer: on a prepared Codex checkout
# a raw mktemp+rename here would reintroduce the operator-primary gid and mode
# 0600 after the manifest had just repaired the shared runtime boundary.
_stamp_init_marker() {
  local basename="$1" value="$2" current="$3" tmp
  [ "$current" != "$value" ] || return 0
  tmp="$(mktemp -t "swarm-init-${basename}.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$tmp" || \
     ! _swarm_publish_plain "$tmp" "$REPO/.claude/$basename" ".claude/$basename"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  echo "  stamped: .claude/$basename = $value"
}
if [ -n "$TYPE" ] && ! _stamp_init_marker swarm-type "$TYPE" "$EXISTING_TYPE"; then
  echo "swarm-init: manifest applied but failed to stamp .claude/swarm-type" >&2
  exit 1
fi
if [ -n "$PROFILE" ] && ! _stamp_init_marker swarm-profile "$PROFILE" "$EXISTING_PROFILE"; then
  echo "swarm-init: manifest applied but failed to stamp .claude/swarm-profile" >&2
  exit 1
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
