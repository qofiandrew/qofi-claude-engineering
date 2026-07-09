#!/usr/bin/env bash
# swarm-canon-enable.sh — switch an engineering-cto swarm repo into
# EXTERNAL-CANON source-of-truth mode (see docs/CANON-MODES.md).
#
# What it does (all seeds are write-if-absent; never clobbers repo content):
#   1. writes .claude/canon-mode = external   (the mode marker)
#   2. seeds  .claude/canon-binding.md        (repo-specific canon binding;
#      appended to the composed CLAUDE.md by manifest_apply_compose)
#   3. seeds  docs/CANON_SYNC.md              (binding + sync-point metadata)
#   4. seeds  docs/MODULE_INDEX.md, docs/TRACEABILITY_LEDGER.md,
#             docs/GAP_LEDGER.md
#   5. seeds  docs/modules/<module>/{README,CANON_MAP,INTERFACES,INVARIANTS,
#             OPEN_GAPS,TEST_MAP,CODE_MAP}.md per module (LIFECYCLE.md is the
#             optional pack member — add it by hand where a module has a
#             stateful lifecycle, from templates/engineering-cto/canon/module/)
#
# It does NOT recompose CLAUDE.md itself — run bin/swarm-sync.sh (or
# swarm-init) afterwards so the external-canon overlay + binding are composed
# in through the normal manifest pipeline.
#
# Usage:
#   swarm-canon-enable.sh <repo-path> --canon <canon-repo-path> \
#       [--product-path <path-within-canon-repo>] \
#       [--modules "m1 m2 ..."]        # default: top-level dirs under src/
#
# Ordinary (local-canon) swarms never run this; absent marker == local mode.

set -euo pipefail

SWARM_HOME="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SWARM_HOME/templates/engineering-cto/canon"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

REPO="${1:-}"; [ -n "$REPO" ] || usage
shift
CANON="" PRODUCT_PATH="" MODULES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --canon)        CANON="${2:?--canon requires a value}"; shift 2 ;;
    --product-path) PRODUCT_PATH="${2:?--product-path requires a value}"; shift 2 ;;
    --modules)      MODULES="${2:?--modules requires a value}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[ -d "$REPO" ]  || { echo "ERROR: repo not found: $REPO" >&2; exit 1; }
[ -n "$CANON" ] || { echo "ERROR: --canon <canon-repo-path> is required" >&2; exit 1; }
[ -d "$CANON" ] || { echo "ERROR: canon repo not found: $CANON" >&2; exit 1; }
[ -f "$TPL/CANON_SYNC.template.md" ] || { echo "ERROR: canon templates missing under $TPL" >&2; exit 1; }

REPO="$(cd "$REPO" && pwd)"
CANON="$(cd "$CANON" && pwd)"
CANON_ROOT="$CANON"
# If --product-path was not given but the canon path itself is nested inside a
# git repo, split it into repo root + product path for the metadata.
if [ -z "$PRODUCT_PATH" ]; then
  if CANON_GIT_ROOT="$(git -C "$CANON" rev-parse --show-toplevel 2>/dev/null)" \
     && [ "$CANON_GIT_ROOT" != "$CANON" ]; then
    CANON_ROOT="$CANON_GIT_ROOT"
    PRODUCT_PATH="${CANON#"$CANON_GIT_ROOT"/}"
  else
    PRODUCT_PATH="."
  fi
fi

CANON_COMMIT="$(git -C "$CANON_ROOT" rev-parse HEAD 2>/dev/null || echo '<unknown>')"
IMPL_COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo '<unknown>')"
TODAY="$(date +%Y-%m-%d)"

if [ -z "$MODULES" ]; then
  if [ -d "$REPO/src" ]; then
    MODULES="$(cd "$REPO/src" && find . -maxdepth 1 -mindepth 1 -type d | sed 's|^\./||' | sort | tr '\n' ' ')"
  fi
fi

seed() { # seed <target> <<< content-on-stdin : write-if-absent
  local tgt="$1"
  if [ -e "$tgt" ]; then echo "  exists (kept): ${tgt#"$REPO"/}"; cat >/dev/null; return 0; fi
  mkdir -p "$(dirname "$tgt")"
  cat > "$tgt"
  echo "  seeded:        ${tgt#"$REPO"/}"
}

echo "==> enabling external-canon mode: $REPO"
echo "    canon repo:   $CANON_ROOT"
echo "    product path: $PRODUCT_PATH"

# 1. mode marker (refresh semantics — the marker IS the mode)
mkdir -p "$REPO/.claude"
printf 'external\n' > "$REPO/.claude/canon-mode"
echo "  wrote:         .claude/canon-mode = external"

# 2. repo-specific canon binding (composed into CLAUDE.md as the final source)
seed "$REPO/.claude/canon-binding.md" <<EOF

## Canon binding (this repo)

- **Canon / spec repo:** \`$CANON_ROOT\`
  (product path: \`$PRODUCT_PATH\`)
- **Implementation repo:** \`$REPO\`

**Normativity:** the canon repo's ADRs / decision records, requirements
ledger, and live technical architecture are **normative product canon**. This
implementation repo's module docs (\`docs/modules/<module>/\`) are **scoped
projections** of that canon, and code/tests are executable reality that never
legalizes a canon violation. Sync point + log: \`docs/CANON_SYNC.md\`.
EOF

# 3. CANON_SYNC.md from template, placeholders filled
tmp_sync="$(mktemp -t canon-sync.XXXXXX)"
trap 'rm -f "${tmp_sync:-}"' EXIT INT TERM
sed -e "s|<absolute-or-relative-path-to-canon-repo>|$CANON_ROOT|" \
    -e "s|<path-within-canon-repo, e.g. products/<product>>|$PRODUCT_PATH|" \
    -e "s|<this repo's path>|$REPO|" \
    -e "s|<canon-repo commit hash this implementation is synced against>|$CANON_COMMIT|" \
    -e "s|<last code/behavior commit reviewed against that canon commit>|$IMPL_COMMIT|" \
    -e "s|<implementation repo HEAD when this doc was last updated>|$IMPL_COMMIT|" \
    -e "s|<YYYY-MM-DD>|$TODAY|" \
    "$TPL/CANON_SYNC.template.md" > "$tmp_sync"
seed "$REPO/docs/CANON_SYNC.md" < "$tmp_sync"
rm -f "$tmp_sync"

# 4. root ledgers
seed "$REPO/docs/MODULE_INDEX.md"        < "$TPL/MODULE_INDEX.template.md"
seed "$REPO/docs/TRACEABILITY_LEDGER.md" < "$TPL/TRACEABILITY_LEDGER.template.md"
seed "$REPO/docs/GAP_LEDGER.md"          < "$TPL/GAP_LEDGER.template.md"

# 5. per-module packs (LIFECYCLE deliberately not auto-seeded — optional member)
for m in $MODULES; do
  for f in README CANON_MAP INTERFACES INVARIANTS OPEN_GAPS TEST_MAP CODE_MAP; do
    sed "s|<module>|$m|g" "$TPL/module/$f.template.md" \
      | seed "$REPO/docs/modules/$m/$f.md"
  done
done
[ -n "$MODULES" ] || echo "  NOTE: no src/ modules detected and none passed via --modules; seed packs by hand."

echo "==> done. Next steps:"
echo "    1. run bin/swarm-sync.sh for this swarm so CLAUDE.md recomposes with"
echo "       the external-canon overlay + canon binding;"
echo "    2. fill in the seeded packs (CANON_MAP citations, INVARIANTS, maps);"
echo "    3. the canon-check TaskCompleted gate now enforces the pack contract."
