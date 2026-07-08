#!/usr/bin/env bash
# canon-check.sh — TaskCompleted hook: external-canon-mode validation gate.
#
# In LOCAL-canon mode (.claude/canon-mode absent or != 'external') this hook
# is a guaranteed no-op (exit 0) — ordinary swarms are untouched.
#
# In EXTERNAL-canon mode it fails task completion (exit 2) when:
#   1. docs/CANON_SYNC.md is missing;
#   2. CANON_SYNC.md lacks sync metadata (Canon repo / Canon commit /
#      Last implementation-behavior commit reviewed against canon /
#      Current implementation repo commit at sync-doc update — real values,
#      no template placeholders);
#   3. a src module (top-level dir under src/) has no doc pack at
#      docs/modules/<module>/ with the 7 required files (LIFECYCLE optional);
#   4. a CODE_MAP.md / TEST_MAP.md backtick-quoted repo path doesn't exist;
#   5. an INVARIANTS.md entry (- INV-…) carries neither 'tests:' nor 'gap:';
#   6. an OPEN_GAPS.md entry tagged [adr-required] has no matching GAP id in
#      docs/GAP_LEDGER.md;
#   7. docs/MODULE_INDEX.md / docs/TRACEABILITY_LEDGER.md / docs/GAP_LEDGER.md
#      are missing.
#
# Doctrine: CLAUDE.md §External canon sync / §Scoped module documentation.
# Wired in settings.json under hooks.TaskCompleted.

set -uo pipefail
EVENT="$(cat)"   # capture stdin payload — need its `cwd` to resolve the tree

# --- QOFI quality-hook runtime control (see test-gate.sh for the rationale) -
__qofi_hook="canon-check"
__qofi_disabled() {
  case "${QOFI_HOOK_PROFILE:-default}" in
    minimal|fast|off) return 0 ;;
  esac
  local _l="${QOFI_DISABLED_HOOKS:-}"; _l="${_l//,/ }"
  local _h
  for _h in $_l; do
    { [ "$_h" = "$__qofi_hook" ] || [ "$_h" = "all" ]; } && return 0
  done
  return 1
}
if __qofi_disabled; then
  echo "${__qofi_hook}: SKIPPED — disabled (QOFI_HOOK_PROFILE=${QOFI_HOOK_PROFILE:-default}, QOFI_DISABLED_HOOKS='${QOFI_DISABLED_HOOKS:-}')" >&2
  exit 0
fi
# --- end QOFI quality-hook runtime control ---------------------------------

# Worktree-topology resolution — validate the tree the agent actually works in,
# resolved from the hook payload's `cwd` field (the invoking session's working
# directory), NOT from `git rev-parse` on the process's inherited CWD nor
# $CLAUDE_PROJECT_DIR. A hook subprocess does not inherit the teammate's worktree
# CWD, so the old resolution validated the WRONG tree — a teammate whose own tree
# had broken/absent canon packs could FALSE-PASS by validating the lead's clean
# main tree. Extract cwd with python3 (repo idiom — permission-gate.sh does the
# same; no jq dep). See tests/test-hooks-worktree-resolution.sh.
PAYLOAD_CWD="$(printf '%s' "$EVENT" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")
' 2>/dev/null)"

# FAIL-CLOSED on ANY unresolvable topology (no/unparseable/non-string cwd, cwd not
# a git tree, or python3 absent → PAYLOAD_CWD empty). Unlike dod-affirm/test-gate,
# canon-check has NO CI referee backstop — the canon repo is never checked out on
# CI runners, so this gate can ONLY ever run locally — and canon consistency is
# this repo's spine. A gate with no backstop gets no fail-open corner, not even a
# degenerate one: it BLOCKS (exit 2) with the cause named rather than pass a task
# whose canon it could not validate. When cwd DOES resolve, the full external-canon
# validation below runs at its strict exit-2-on-error posture against THAT tree.
if [ -z "$PAYLOAD_CWD" ] || ! ROOT="$(git -C "$PAYLOAD_CWD" rev-parse --show-toplevel 2>/dev/null)"; then
  {
    echo "canon-check: BLOCKED — could not resolve the work tree from the payload cwd (cwd='${PAYLOAD_CWD}')."
    echo "canon-check is a local gate with NO CI backstop, so it fail-CLOSES rather than"
    echo "pass a task whose external-canon it could not validate. Ensure the TaskCompleted"
    echo "payload carries a valid cwd inside a git work tree, then complete the task again."
  } >&2
  exit 2
fi
cd "$ROOT" 2>/dev/null || { echo "canon-check: BLOCKED — cannot cd to resolved tree ($ROOT)." >&2; exit 2; }

# Mode gate: anything but an explicit 'external' marker is local mode → no-op.
MARKER="$ROOT/.claude/canon-mode"
[ -f "$MARKER" ] || exit 0
MODE="$(head -n 1 "$MARKER" 2>/dev/null | tr -d '[:space:]')"
[ "$MODE" = "external" ] || exit 0

ERRORS=""
err() { ERRORS="${ERRORS}  - $1
"; }

# 1+2. CANON_SYNC.md exists and carries real sync metadata.
SYNC="docs/CANON_SYNC.md"
if [ ! -s "$SYNC" ]; then
  err "$SYNC missing — external-canon mode requires the sync contract (see CLAUDE.md §External canon sync; seed via swarm-canon-enable.sh)"
else
  # The three commit fields are DISTINCT (see CANON_SYNC.template.md):
  # canon commit synced against; last implementation-BEHAVIOR commit reviewed
  # against it; current repo commit when the sync doc was last updated
  # (docs-only/restamp commits legitimately advance only the last one).
  for field in "Canon repo:" "Canon commit:" \
               "Last implementation-behavior commit reviewed against canon:" \
               "Current implementation repo commit at sync-doc update:"; do
    line="$(grep -F "$field" "$SYNC" | head -n 1)"
    if [ -z "$line" ]; then
      err "$SYNC lacks '$field' sync metadata"
    elif printf '%s' "$line" | grep -q '<[a-zA-Z].*>'; then
      err "$SYNC '$field' still carries a template placeholder — fill in the real value"
    else
      # A label with an EMPTY value is a false claim, not metadata: strip the
      # label and markdown dressing; something real must remain.
      val="$(printf '%s' "${line#*"$field"}" | tr -d ' \t`*_-')"
      [ -n "$val" ] || err "$SYNC '$field' has an empty value — fill in the real value"
    fi
  done
fi

# 7. Root ledgers exist.
for f in docs/MODULE_INDEX.md docs/TRACEABILITY_LEDGER.md docs/GAP_LEDGER.md; do
  [ -s "$f" ] || err "$f missing — required in external-canon mode"
done

# Path-existence checker for CODE_MAP/TEST_MAP: every backtick-quoted
# repo-relative path (src/…, tests/…, test/…) must exist, AND the map must
# cite at least one such path — a map with none (paths omitted or written
# without backticks) is invisible to this check and therefore refused, not
# waved through. Trailing globs are not supported — maps cite real paths.
check_map_paths() {
  local map="$1"
  local p found=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    found=1
    [ -e "$p" ] || err "$map references missing path: $p"
  done < <(grep -o '`\(src\|tests\|test\)/[^`]*`' "$map" 2>/dev/null | tr -d '\`' | sort -u)
  [ "$found" -eq 1 ] || err "$map cites no backtick-quoted src/tests path — maps must cite real paths in backticks"
}

# 3–6. Per-module doc packs for every LEAF src module (modules live nested under
#       engine dirs, src/<engine>/<module>/, per the ENGINE_MAP org — the doc
#       packs stay keyed by module basename at docs/modules/<module>/).
if [ -d src ]; then
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    pack="docs/modules/$m"
    if [ ! -d "$pack" ]; then
      err "src module '$m' has no doc pack at $pack/ (seed via swarm-canon-enable.sh)"
      continue
    fi
    for f in README.md CANON_MAP.md INTERFACES.md INVARIANTS.md OPEN_GAPS.md TEST_MAP.md CODE_MAP.md; do
      [ -s "$pack/$f" ] || err "$pack/$f missing or empty"
    done
    [ -s "$pack/CODE_MAP.md" ] && check_map_paths "$pack/CODE_MAP.md"
    [ -s "$pack/TEST_MAP.md" ] && check_map_paths "$pack/TEST_MAP.md"
    # 5. INVARIANTS coverage: every '- INV…' entry has tests: (with existing
    # backticked paths) or gap: (with a GAP id recorded in this pack's
    # OPEN_GAPS.md). A dangling reference is a false claim, not coverage.
    if [ -s "$pack/INVARIANTS.md" ]; then
      while IFS= read -r line; do
        case "$line" in
          *"tests:"*)
            tpaths="$(printf '%s' "${line#*tests:}" | grep -o '`[^`]*`' | tr -d '\`')"
            if [ -z "$tpaths" ]; then
              err "$pack/INVARIANTS.md 'tests:' entry cites no backtick-quoted path: ${line%%|*}"
            else
              for tp in $tpaths; do
                [ -e "$tp" ] || err "$pack/INVARIANTS.md 'tests:' path missing: $tp"
              done
            fi ;;
          *"gap:"*)
            gid="$(printf '%s' "$line" | grep -o 'GAP-[A-Za-z0-9_-]*' | head -n 1)"
            if [ -z "$gid" ]; then
              err "$pack/INVARIANTS.md 'gap:' entry names no GAP-<id>: ${line%%|*}"
            elif ! grep -q "$gid" "$pack/OPEN_GAPS.md" 2>/dev/null; then
              err "$pack/INVARIANTS.md gap $gid is not recorded in $pack/OPEN_GAPS.md"
            fi ;;
          *) err "$pack/INVARIANTS.md entry lacks 'tests:' or 'gap:': ${line%%|*}" ;;
        esac
      done < <(grep '^- INV' "$pack/INVARIANTS.md" 2>/dev/null)
    fi
    # 6. [adr-required] gaps must be in the root GAP_LEDGER.
    if [ -s "$pack/OPEN_GAPS.md" ] && [ -s docs/GAP_LEDGER.md ]; then
      while IFS= read -r line; do
        gid="$(printf '%s' "$line" | grep -o 'GAP-[A-Za-z0-9_-]*' | head -n 1)"
        if [ -z "$gid" ]; then
          err "$pack/OPEN_GAPS.md [adr-required] entry has no GAP-<id>: ${line%%:*}"
        elif ! grep -q "$gid" docs/GAP_LEDGER.md; then
          err "$pack/OPEN_GAPS.md gap $gid is [adr-required] but absent from docs/GAP_LEDGER.md"
        fi
      done < <(grep '^\- GAP.*\[adr-required\]' "$pack/OPEN_GAPS.md" 2>/dev/null)
    fi
  done < <(find src -mindepth 1 -type d 2>/dev/null | while IFS= read -r d; do ls "$d"/*.ts >/dev/null 2>&1 && basename "$d"; done | sort -u)
fi

if [ -n "$ERRORS" ]; then
  {
    echo "canon-check: BLOCKED — external-canon validation failed."
    printf '%s' "$ERRORS"
    echo "Doctrine: CLAUDE.md §External canon sync / §Scoped module documentation."
    echo "Fix the items above (drift routes upstream via OPEN_GAPS → GAP_LEDGER →"
    echo "canon patch; it is never absorbed silently), then complete the task."
  } >&2
  exit 2
fi

echo "canon-check: PASS — external-canon packs, maps, invariants, gap routing, and sync metadata all consistent." >&2
exit 0
