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

# --- Work-tree resolution: ASSIGNED tree, fail-closed -----------------------
# Resolve the tree this gate must act on. In worktree topology (TEAM_LEAD.md
# section *Worktree isolation*) each teammate is ASSIGNED
# .claude/worktrees/<name>/ on branch worktree-<name>. The harness can RE-HOME
# a session into a tree that is NOT its assignment (seen live 2026-07-08:
# gates checked a sibling tree — false-blocking clean agents against a
# sibling red tree AND fail-OPEN passing while the real assigned tree held an
# unverified completion). So for a teammate event the payload cwd is a hint,
# never the authority:
#   * teammate_name present (TaskCompleted payloads carry it) -> act on the
#     teammate ASSIGNED tree: the optional .claude/worktree-assignments.tsv
#     override (name<TAB>path, relative to the main root; "." = main tree)
#     else the .claude/worktrees/<name> convention. The main root is reachable
#     from ANY sibling tree via git rev-parse --git-common-dir, else
#     $CLAUDE_PROJECT_DIR.
#   * no teammate_name (solo/lead event) -> the payload cwd toplevel.
#   * anything unresolvable -> BLOCK (cannot-verify), NEVER pass or skip: a
#     gate that cannot locate the assigned tree must not pass on a sibling
#     clean tree. Operator ruling 2026-07-08 — supersedes the earlier
#     fail-soft posture for unresolvable topology on this hook.
# One python3 pass (repo idiom, no jq; single-quote-free for the bash 3.2 -c
# form). Emits STATUS|ROOT|MISMATCH|NAME with STATUS one of
# OK|PARSE_FAILED|NO_TREE|NO_ASSIGNMENT; empty output = python3 absent.
RES="$(printf '%s' "$EVENT" | python3 -c 'import sys, json, os, subprocess

def toplevel(p):
    if not p or not os.path.isdir(p):
        return ""
    try:
        r = subprocess.run(["git", "-C", p, "rev-parse", "--show-toplevel"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    except Exception:
        return ""
    return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""

def emit(status, root="", mismatch="0", name=""):
    print("%s|%s|%s|%s" % (status, root, mismatch, name))
    sys.exit(0)

try:
    e = json.loads(sys.stdin.read())
except Exception:
    emit("PARSE_FAILED")
if not isinstance(e, dict):
    emit("PARSE_FAILED")
cwd = e.get("cwd") if isinstance(e.get("cwd"), str) else ""
name = (e.get("teammate_name") if isinstance(e.get("teammate_name"), str) else "").strip()
cwd_root = toplevel(cwd)

if not name:                     # solo/lead event: no assignment to enforce
    if cwd_root:
        emit("OK", cwd_root)
    emit("NO_TREE")

# Teammate event: resolve the ASSIGNED tree; never trust cwd (the harness can
# re-home a session into a sibling tree, and gating there is wrong-tree). Any
# sibling tree still shares the main repo, so the main root is reachable via
# --git-common-dir even from a wrongly-homed cwd; CLAUDE_PROJECT_DIR (set at
# launch to the lead project dir) is the fallback.
main_root = ""
if cwd_root:
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-common-dir"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        if r.returncode == 0:
            gd = r.stdout.decode("utf-8", "replace").strip()
            if gd:
                if not os.path.isabs(gd):
                    gd = os.path.join(cwd, gd)
                main_root = os.path.dirname(os.path.realpath(gd))
    except Exception:
        pass
if not main_root:
    main_root = os.environ.get("CLAUDE_PROJECT_DIR", "")

assigned = ""
if main_root:
    # Optional override table .claude/worktree-assignments.tsv: one row per
    # teammate, name<TAB>path (path relative to the main root; "." maps a
    # named agent to the main tree, a conscious visible exception). An
    # unreadable table means cannot-verify; never guess past a corrupt record.
    tsv = os.path.join(main_root, ".claude", "worktree-assignments.tsv")
    if os.path.exists(tsv):
        try:
            with open(tsv, encoding="utf-8") as fh:
                for line in fh:
                    line = line.split("#", 1)[0].rstrip("\n")
                    if not line.strip():
                        continue
                    parts = line.split("\t", 1) if "\t" in line else line.split(None, 1)
                    if len(parts) == 2 and parts[0].strip() == name:
                        p = parts[1].strip()
                        assigned = p if os.path.isabs(p) else os.path.normpath(os.path.join(main_root, p))
                        break
        except Exception:
            emit("NO_ASSIGNMENT", name=name)
    if not assigned:
        conv = os.path.join(main_root, ".claude", "worktrees", name)
        if os.path.isdir(conv):
            assigned = conv
if not assigned:
    emit("NO_ASSIGNMENT", name=name)
aroot = toplevel(assigned)
if not aroot:
    emit("NO_ASSIGNMENT", name=name)
mismatch = "1" if (cwd_root and os.path.realpath(cwd_root) != os.path.realpath(aroot)) else "0"
emit("OK", aroot, mismatch, name)' 2>/dev/null)"
STATUS="${RES%%|*}"; _r1="${RES#*|}"; ROOT="${_r1%%|*}"
_r2="${_r1#*|}"; TREE_MISMATCH="${_r2%%|*}"; TM_NAME="${_r2#*|}"
case "$STATUS" in
  OK) : ;;
  PARSE_FAILED)
    {
      echo "canon-check: BLOCKED — could not parse the TaskCompleted payload, so the work"
      echo "tree this gate must verify could not be resolved. Re-run the task."
    } >&2
    exit 2 ;;
  NO_ASSIGNMENT)
    {
      echo "canon-check: BLOCKED — cannot verify: no assigned worktree resolvable for teammate [$TM_NAME]."
      echo "Provisioning gap (TEAM_LEAD.md section *Worktree isolation*): expected .claude/worktrees/$TM_NAME/,"
      echo "or a .claude/worktree-assignments.tsv row [$TM_NAME<TAB><path>] (path [.] maps to the main tree)."
      echo "A gate never passes on wrong-tree ambiguity — provision/record the worktree, then re-run."
    } >&2
    exit 2 ;;
  *)
    {
      echo "canon-check: BLOCKED — cannot verify: no work tree resolvable from the payload (no CI backstop exists for canon)."
      echo "A gate never passes on a tree it cannot locate. Re-run from the assigned tree."
    } >&2
    exit 2 ;;
esac
if [ "$TREE_MISMATCH" = "1" ]; then
  echo "canon-check: NOTE — session cwd is not the assigned tree of teammate [$TM_NAME] (harness re-homing); acting on the ASSIGNED tree: $ROOT" >&2
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
