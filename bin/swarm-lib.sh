#!/usr/bin/env bash
# swarm-lib.sh — shared helpers, sourced by the swarm-* scripts.
#
# Sourced, not executed. Bash 3.2-safe (macOS default). Does NOT call `set` —
# the caller owns shell options. python3 is the only non-shell dependency
# (already required across the swarm scripts; see swarm-add, dod-affirm,
# permission-gate).
#
# Four concerns live here:
#
#   0. swarm_conf_parse_line()     — parse ONE swarm.conf row into the
#                                    canonical fields. The single place the
#                                    column schema/arity is defined, so every
#                                    reader shares it and a future column can
#                                    never silently corrupt an existing one.
#   1. repo_activity()             — shared "is this swarm producing work?"
#                                    signal for swarm-watch + swarm-typing.
#   2. manifest_walk / apply       — the single-source-of-truth deployer
#                                    consumed by swarm-init, swarm-sync, and
#                                    swarm-onboard. ALL three commands share
#                                    these helpers; per-mode policy is in
#                                    flags passed via env, not duplicated
#                                    logic. See templates/<type>/manifest.tsv
#                                    (per-archetype dispatch via swarm_type_of).
#   3. settings_merge_swarm()      — structured merge of swarm hook
#                                    registrations into an existing
#                                    settings.json. Additive, dedup-by-
#                                    command, atomic write. Never clobbers
#                                    foreign hook entries.

# ---------------------------------------------------------------------------
# 0) swarm.conf row parsing — ONE definition of the column schema.
# ---------------------------------------------------------------------------
#
# swarm.conf rows are positional, pipe-delimited:
#
#     name | repo | tokvar | channel | guild_id
#
# The historical bug this section exists to kill: readers did their own
# `IFS='|' read -r name repo tokvar channel` with a FIXED arity SHORTER than
# the file's column count. Bash's last `read` variable absorbs every trailing
# field INCLUDING the delimiter — so once the 5th (guild_id) column landed, a
# 4-variable reader's `channel` silently became "<channel> | <guild_id>".
# That broke swarm-attention (channel failed all-digits validation) and
# swarm-typing (typing URL carried " | <guild>"). Each future column would
# break the next reader the same way.
#
# The fix: parse a row HERE, once, splitting into the full known arity PLUS a
# trailing catch-all (`_rest`). The last *named* field can therefore never
# swallow an unknown future column — it lands in `_rest` and is ignored until
# we name it. To add a column later: add it to the read below and expose a new
# SWARM_CONF_F_* global. Readers that don't use it need no change and cannot
# be corrupted by it.
#
# Results are returned in globals (bash 3.2 has no namerefs / assoc-array
# return); a reader copies out only the fields it uses:
#
#   SWARM_CONF_F_NAME  SWARM_CONF_F_REPO  SWARM_CONF_F_TOKVAR
#   SWARM_CONF_F_CHANNEL  SWARM_CONF_F_GUILD
#
# swarm_conf_parse_line returns non-zero for a comment/blank line so callers
# can `swarm_conf_parse_line "$line" || continue`.

SWARM_CONF_F_NAME=""
SWARM_CONF_F_REPO=""
SWARM_CONF_F_TOKVAR=""
SWARM_CONF_F_CHANNEL=""
SWARM_CONF_F_GUILD=""

# _swarm_trim STRING — strip leading/trailing whitespace (pure bash, no
# subprocess; safe in the per-row hot loops swarm-typing/swarm-watch run).
_swarm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# swarm_conf_parse_line RAW_LINE
#   Populate SWARM_CONF_F_* from one raw swarm.conf line. Returns 1 (caller
#   should `continue`) for blank or comment ('#') lines, 0 otherwise.
swarm_conf_parse_line() {
  local _line="$1" _trimmed
  _trimmed="$(_swarm_trim "$_line")"
  case "$_trimmed" in
    ''|'#'*) return 1 ;;
  esac
  local _name _repo _tokvar _channel _guild _rest
  # Full known arity + `_rest` catch-all so a row with MORE columns than the
  # current schema cannot corrupt the last named field (see header).
  IFS='|' read -r _name _repo _tokvar _channel _guild _rest <<EOF
$_line
EOF
  SWARM_CONF_F_NAME="$(_swarm_trim "$_name")"
  SWARM_CONF_F_REPO="$(_swarm_trim "$_repo")"
  SWARM_CONF_F_TOKVAR="$(_swarm_trim "$_tokvar")"
  SWARM_CONF_F_CHANNEL="$(_swarm_trim "$_channel")"
  SWARM_CONF_F_GUILD="$(_swarm_trim "$_guild")"
  return 0
}

# ---------------------------------------------------------------------------
# 1) repo_activity — used by swarm-watch + swarm-typing + swarm-restart.
# ---------------------------------------------------------------------------
#
# Walks every Claude Code project dir associated with REPO_PATH — the lead's
# own dir AND every per-teammate worktree dir — recursively, including the
# subagents/ subdir where teammate transcripts live. Returns:
#
#     "<newest_age_seconds>|<active_teammate_count>"
#
# - newest_age_seconds: integer, ALWAYS NUMERIC. Real seconds-since-mtime
#   when a transcript exists; the sentinel SWARM_NO_TRANSCRIPT_AGE
#   (9999999 ≈ 115 days, larger than any plausible STALE_SECONDS) when
#   either NO jsonl exists at all (swarm just started) OR the scan
#   encountered an unrecoverable error. The function NEVER returns blank
#   — empty age would force every caller to add the same parsing branch
#   and the natural fail-mode of `[ "$age" -gt "$STALE_SECONDS" ]` would
#   silently flip to "fresh" on weird input. Fail-safe is silence; the
#   sentinel makes that automatic for any threshold-based predicate.
#   Callers that need to distinguish "no transcript yet" from "stale
#   transcript" compare `age == SWARM_NO_TRANSCRIPT_AGE` (see swarm-watch
#   and swarm-restart for the "🟡 starting" message).
# - active_teammate_count: number of distinct teammate worktree dirs whose
#   most recent jsonl is ≤ STALE_SECONDS old. 0 if none.
#
# Matching is by encoded-path prefix (Claude Code encodes a project's cwd by
# replacing every '/' and '.' with '-' and prepending '-'). Teammate worktree
# dirs match the prefix "<lead-encoded>--claude-worktrees-" so this never
# accidentally folds in a similarly-named sibling repo.
#
# Orphan-dir defense: a teammate transcript dir whose corresponding
# <repo>/.claude/worktrees/<name> no longer exists is skipped. Teardown
# (TEAM_LEAD.md §Worktree teardown) is the primary cleanup, but if it
# misses the transcript dir we still don't let stale teammate-only
# writes from a removed worktree poison the live signal.
SWARM_NO_TRANSCRIPT_AGE=9999999

repo_activity() {
  local repo="$1" projects="$2" stale="$3"
  python3 - "$repo" "$projects" "$stale" <<'PY'
import os, re, sys, time

NO_TRANSCRIPT = 9999999  # MUST match SWARM_NO_TRANSCRIPT_AGE in swarm-lib.sh.

try:
    repo, projects, stale = sys.argv[1], sys.argv[2], int(sys.argv[3])

    lead_enc = re.sub(r"[/.]", "-", repo)
    teammate_prefix = lead_enc + "--claude-worktrees-"

    now = time.time()
    newest_age = None
    teammate_newest = {}

    try:
        entries = os.listdir(projects)
    except FileNotFoundError:
        # No projects dir at all — fail-stale, never blank.
        print(f"{NO_TRANSCRIPT}|0")
        raise SystemExit(0)

    for entry in entries:
        is_lead = (entry == lead_enc)
        is_teammate = entry.startswith(teammate_prefix)
        if not (is_lead or is_teammate):
            continue
        if is_teammate:
            # Orphan check: skip teammate transcript dirs whose git
            # worktree has been torn down (see TEAM_LEAD.md §Worktree
            # teardown). Belt-and-suspenders to teardown removing the
            # transcript dir itself.
            wt_name = entry[len(teammate_prefix):]
            wt_path = os.path.join(repo, ".claude", "worktrees", wt_name)
            if not os.path.isdir(wt_path):
                continue
        try:
            walker = os.walk(os.path.join(projects, entry))
        except Exception:
            continue
        for root, _, files in walker:
            for f in files:
                if not f.endswith(".jsonl"):
                    continue
                try:
                    mt = os.path.getmtime(os.path.join(root, f))
                except OSError:
                    continue
                age = int(now - mt)
                if age < 0:
                    age = 0
                if newest_age is None or age < newest_age:
                    newest_age = age
                if is_teammate:
                    prev = teammate_newest.get(entry)
                    if prev is None or age < prev:
                        teammate_newest[entry] = age

    active = sum(1 for a in teammate_newest.values() if a <= stale)
    age_out = NO_TRANSCRIPT if newest_age is None else newest_age
    print(f"{age_out}|{active}")
except SystemExit:
    raise
except Exception as e:
    # Catastrophic path: never let the function return blank. The
    # liveness/typing predicates' fail-safe is silence; the sentinel
    # achieves that under any threshold-based check.
    sys.stderr.write(f"repo_activity: unexpected error: {e}\n")
    print(f"{NO_TRANSCRIPT}|0")
PY
}

# pane_working SESSION TMUX_BIN
#
# Inspect the live tmux pane for the Claude TUI footer that ONLY appears
# while a turn is in flight, and return tri-valued status:
#
#     0 — working  (capture succeeded AND footer contains "esc to interrupt")
#     1 — idle     (capture succeeded AND no "esc to interrupt" anywhere)
#     2 — uncertain (tmux missing, session absent, capture-pane failed,
#                    or empty output)
#
# Why footer-substring is the right signal: the spinner verb varies
# ("Caramelizing", "Thinking", "Baking", …) and past-tense recaps like
# "Crunched for 1m 28s" / "Worked for Ns" linger AFTER the turn finishes.
# Only the footer is a stable binary indicator — `… · esc to interrupt`
# while a turn is interruptible, `… · ← for agents` at the prompt.
#
# We grep the whole capture, not just the final line: a spinner or layout
# shift can re-flow the footer's position, but the substring presence
# survives. False positives (the literal string appearing in scrolled-back
# content) are not a practical concern — `esc to interrupt` is the TUI's
# interrupt hint, not a phrase users type into prompts.
#
# Fail-safe is silence: callers MUST treat anything other than rc=0 as
# "do not claim working". This fixes the original typing-at-idle bug —
# transcript age cannot distinguish "replied N seconds ago, now idle"
# from "actively producing"; the pane content can.
pane_working() {
  local sess="$1" tmux_bin="${2:-tmux}"
  command -v "$tmux_bin" >/dev/null 2>&1 || return 2
  local out
  out="$("$tmux_bin" capture-pane -t "$sess" -p 2>/dev/null)" || return 2
  [ -z "$out" ] && return 2
  printf '%s' "$out" | grep -qF 'esc to interrupt'
}

# pane_state SESSION TMUX_BIN
#
# A finer-grained variant of pane_working used by the active alerter in
# swarm-watch.sh. Distinguishes FIVE pane situations so the watcher can
# tell "the swarm is paused on a usage limit" apart from "the pane is in
# an unknown / unparseable state" — the original alerting bug was that
# both surface as `pane_working != 0` (idle), so a usage-throttled swarm
# read as "ready · waiting for input" and produced DEAD SILENCE.
#
# Exit codes:
#   0 — working      (footer contains "esc to interrupt")
#   1 — at-prompt    (footer contains "← for agents", i.e. clean prompt)
#   2 — paused-limit (capture contains a known Claude Code limit-message
#                     substring — see SWARM_LIMIT_PATTERNS below)
#   3 — unknown      (capture succeeded but matches none of the above —
#                     scrolled, sub-UI, or a TUI state we don't recognize)
#   4 — uncertain    (tmux missing, session absent, capture failed, empty)
#
# Side channel: when rc=2 (paused-limit) the matched limit-substring line
# is written to $SWARM_PANE_STATE_DETAIL (a shell global). The caller may
# read it to parse a reset time. Empty for any other return code.
#
# Limit substrings. These are the substrings Claude Code's TUI shows when
# a usage cap is hit; they are stable enough across versions to be useful
# matchers but specific enough that they don't appear in normal prompt
# content. The set is overridable via SWARM_LIMIT_PATTERNS (newline- or
# pipe-separated; each entry treated as a case-insensitive fixed string).
#
#   usage limit          — "Claude usage limit reached", "Approaching usage limit"
#   5-hour limit         — "5-hour limit reached · resets at 11pm"
#   limit reached        — generic suffix used across variants
#   rate limit           — provider-side rate limit surface
#   approaching usage    — early-warning variant
#
# Matching is case-insensitive (grep -i) and substring (grep -F). The
# whole capture is grep'd, not just the footer — limit messages render at
# various pane positions depending on the TUI's modal state.
SWARM_PANE_STATE_DETAIL=""

_swarm_default_limit_patterns() {
  printf '%s\n' "usage limit"
  printf '%s\n' "5-hour limit"
  printf '%s\n' "limit reached"
  printf '%s\n' "rate limit"
  printf '%s\n' "approaching usage"
}

pane_state() {
  local sess="$1" tmux_bin="${2:-tmux}"
  SWARM_PANE_STATE_DETAIL=""
  command -v "$tmux_bin" >/dev/null 2>&1 || return 4
  local out
  out="$("$tmux_bin" capture-pane -t "$sess" -p 2>/dev/null)" || return 4
  [ -z "$out" ] && return 4

  # Limit substrings checked FIRST: a session that just hit a cap may
  # still have a lingering spinner verb above the cap message; the cap
  # message wins (that's the actionable reality).
  local patterns_raw="${SWARM_LIMIT_PATTERNS:-}"
  local patterns
  if [ -n "$patterns_raw" ]; then
    # Operator override. Accept newline- OR pipe-separated entries.
    patterns="$(printf '%s' "$patterns_raw" | tr '|' '\n')"
  else
    patterns="$(_swarm_default_limit_patterns)"
  fi
  local hit
  hit="$(printf '%s' "$out" | grep -i -F -m1 -f <(printf '%s' "$patterns") 2>/dev/null)"
  if [ -n "$hit" ]; then
    # Trim ANSI / leading whitespace from the captured line for cleaner
    # downstream parsing. Best-effort; the raw line is fine too.
    hit="$(printf '%s' "$hit" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    SWARM_PANE_STATE_DETAIL="$hit"
    return 2
  fi

  if printf '%s' "$out" | grep -qF 'esc to interrupt'; then
    return 0
  fi
  if printf '%s' "$out" | grep -qF '← for agents'; then
    return 1
  fi
  return 3
}

# parse_limit_reset DETAIL
#
# Best-effort: read the limit-message line captured by pane_state and
# print a reset-time fragment to stdout (empty if nothing parseable).
# Looks for "resets at <X>" / "reset at <X>" / "resets <X>", stopping at
# the next bullet/pipe/period/newline. Used by the alerter to enrich the
# Discord push with a concrete reset hint when Claude Code provides one.
parse_limit_reset() {
  local detail="$1"
  [ -z "$detail" ] && return 0
  printf '%s' "$detail" | python3 -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"reset(?:s)?\s+(?:at\s+)?([^·|.\n]+)", s, re.IGNORECASE)
if m:
    val = m.group(1).strip().rstrip(",;:")
    # Cap to a reasonable length so weird captures cant blow up the alert.
    if len(val) > 60:
        val = val[:60] + "…"
    print(val)
' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 2) Manifest walker + per-class apply helpers.
# ---------------------------------------------------------------------------
#
# The manifest lives at $SWARM_HOME/templates/<type>/manifest.tsv where <type>
# is the swarm's archetype (resolved by swarm_type_of from .claude/swarm-type,
# default 'engineering-cto'). Each non-comment line is "behavior | src | tgt".
# See that file for what each behavior means.
#
# Consumers call manifest_apply REPO MODE with environment flags set; mode
# selects per-class policy (init / sync / onboard / check). Each class has
# its own helper so a new behavior is added in exactly two places (the
# manifest and a new manifest_apply_<class> function).
#
# Public surface:
#   manifest_walk     CALLBACK              — iterate lines, call CALLBACK <behavior> <src> <tgt>
#   manifest_apply    REPO MODE             — drive a full pass; MODE in {init,sync,onboard,check}
#   manifest_check    REPO                  — pure-report; alias for MODE=check
#
# MODE-policy flags (read from environment; absent = default):
#   SWARM_FORCE_DOCS          (onboard) overwrite refresh-class doctrine files even on conflict
#   SWARM_FORCE_HOOKS         (onboard) overwrite .claude/hooks/* even on conflict
#   SWARM_FORCE_PRECOMMIT     (onboard) overwrite foreign .git/hooks/pre-commit
#   SWARM_FORCE_SEED          (init)    re-seed PROJECT_SPEC.md and .claude/test-cmd
#   SWARM_FORCE_DIRTY         (sync, onboard) proceed despite dirty working tree
#   SWARM_DRY_RUN             (any)     report only, write nothing
#
# Side outputs (read by callers after manifest_apply):
#   SWARM_RESULT_CHANGED      "1" if any artifact actually changed on disk
#   SWARM_RESULT_COLLISIONS   newline-separated list of "<class>:<tgt>" entries that
#                             were refused due to collision (onboard)
#   SWARM_RESULT_FOREIGN_PRECOMMIT  "1" if a foreign pre-commit was encountered
#                                   (sync/init warn-and-skip; onboard refuses)
#
# All paths the helpers print are RELATIVE to the target repo, for readability.

# swarm_type_of REPO
#
# Resolve a repo's archetype from the .claude/swarm-type marker file.
# Returns the type name on stdout. Defaults to 'engineering-cto' when the
# marker is absent or empty — so existing swarms (which were stamped
# before the per-type dispatch existed) keep getting engineering-cto
# doctrine without requiring a marker write. Whitespace stripped.
swarm_type_of() {
  local repo="$1"
  local marker="$repo/.claude/swarm-type"
  if [ -f "$marker" ]; then
    local t
    t="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$t" ]; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  printf '%s\n' "engineering-cto"
}

# Resolve and verify the manifest file for a given archetype. Refuses
# (caller-side) to run if it's missing — caller checks file existence
# after this returns.
swarm_manifest_path() {
  local type="${1:-engineering-cto}"
  printf '%s\n' "$SWARM_HOME/templates/$type/manifest.tsv"
}

manifest_walk() {
  local cb="$1"
  local type="${SWARM_APPLY_TYPE:-engineering-cto}"
  local mf
  mf="$(swarm_manifest_path "$type")"
  if [ ! -f "$mf" ]; then
    echo "swarm-lib: manifest not found at $mf — aborting" >&2
    return 2
  fi
  local behavior src tgt line
  # Read pipe-delimited fields, skip comments + blanks, trim each field.
  while IFS='|' read -r behavior src tgt; do
    # Trim leading/trailing whitespace (bash 3.2: use parameter expansion + sed).
    behavior="$(printf '%s' "$behavior" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    src="$(printf '%s' "$src" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    tgt="$(printf '%s' "$tgt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$behavior" in
      ''|'#'*) continue ;;
    esac
    [ -z "$src" ] && continue
    [ -z "$tgt" ] && continue
    "$cb" "$behavior" "$src" "$tgt" || return $?
  done < "$mf"
}

# Internal: copy SRC to TGT, mkdir -p on the target dir. Sets SWARM_RESULT_CHANGED.
# Honors SWARM_DRY_RUN: when set, prints "would <label>" and returns without
# touching the filesystem. Used by onboard's preflight to detect all
# collisions/changes BEFORE any write happens (atomicity). The label is the
# past-tense verb used in live output ("wrote", "updated", etc.); for dry-
# run output we convert it to present tense so "would wrote" doesn't appear.
_swarm_copy() {
  local src="$1" tgt="$2" label="$3"
  local rel="${tgt#$SWARM_APPLY_REPO/}"
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    local pres="$label"
    case "$label" in
      wrote)                        pres="write" ;;
      updated)                      pres="update" ;;
      overwrote)                    pres="overwrite" ;;
      'overwrote (--force-docs)')   pres="overwrite (--force-docs)" ;;
      'overwrote (--force-hooks)')  pres="overwrite (--force-hooks)" ;;
      seeded)                       pres="seed" ;;
      're-seeded (--force)')        pres="re-seed (--force)" ;;
    esac
    echo "  would $pres: $rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  local dir
  dir="$(dirname "$tgt")"
  [ -d "$dir" ] || mkdir -p "$dir"
  cp "$src" "$tgt"
  echo "  $label: $rel"
  SWARM_RESULT_CHANGED=1
}

# ---- per-class helpers ----------------------------------------------------
#
# Each helper takes: src (template-path relative to TPL), tgt (path relative
# to target repo). They use $SWARM_APPLY_MODE and $SWARM_APPLY_REPO from the
# enclosing manifest_apply.

manifest_apply_refresh() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    _swarm_copy "$src" "$tgt" "wrote"
    return 0
  fi
  if cmp -s "$src" "$tgt"; then
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    return 0
  fi
  # File exists and differs.
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      if [ "${SWARM_FORCE_DOCS:-0}" -eq 1 ] && _swarm_is_doctrine "$tgt_rel"; then
        _swarm_copy "$src" "$tgt" "overwrote (--force-docs)"
      elif [ "${SWARM_FORCE_HOOKS:-0}" -eq 1 ] && _swarm_is_hook "$tgt_rel"; then
        _swarm_copy "$src" "$tgt" "overwrote (--force-hooks)"
      else
        echo "  COLLISION: $tgt_rel  (exists and differs from template)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
refresh:$tgt_rel"
      fi
      ;;
    init|sync)
      _swarm_copy "$src" "$tgt" "updated"
      ;;
  esac
}

_swarm_is_doctrine() {
  case "$1" in
    CLAUDE.md|TEAM_LEAD.md|ESCALATION.md) return 0 ;;
  esac
  return 1
}

# _compose_to_tmp SRC_LIST OUT_PATH
#
# Concatenate '+'-joined template sources LITERALLY (no separator injected)
# into OUT_PATH. Each source path is resolved under $SWARM_HOME/templates/.
#
# Asserts the trailing-newline invariant (see templates/_base/README.md):
# every non-final source MUST end with at least one '\n'. A fragment
# stripped of its trailing newline would run into the next fragment's
# first byte at concat time (e.g., "...content## Heading" instead of
# "...content\n## Heading"), silently corrupting the composed output.
# Failing loudly here is the defense.
#
# Returns 0 on success, non-zero on any error (missing source, invariant
# violation, write failure). Caller responsible for cleaning up OUT_PATH
# on failure.
_compose_to_tmp() {
  local src_list="$1" out_path="$2"
  : > "$out_path" || return 1
  local OLD_IFS="$IFS"
  IFS='+'
  set -- $src_list
  IFS="$OLD_IFS"
  local total=$#
  local i=0 src
  for src in "$@"; do
    i=$((i + 1))
    local src_path="$SWARM_HOME/templates/$src"
    if [ ! -f "$src_path" ]; then
      echo "compose: source missing: $src" >&2
      return 1
    fi
    if [ "$i" -lt "$total" ]; then
      local last_byte
      last_byte="$(tail -c 1 "$src_path" 2>/dev/null | xxd -p 2>/dev/null)"
      if [ "$last_byte" != "0a" ]; then
        echo "compose: source '$src' lacks trailing newline (last byte 0x$last_byte)" >&2
        echo "compose: violates templates/_base/README.md trailing-newline invariant" >&2
        return 1
      fi
    fi
    cat "$src_path" >> "$out_path" || return 1
  done
  return 0
}

_swarm_is_hook() {
  case "$1" in
    .claude/hooks/*) return 0 ;;
  esac
  return 1
}

manifest_apply_compose() {
  local src_list="$1" tgt_rel="$2"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  local tmp
  tmp="$(mktemp -t swarm-compose.XXXXXX)" || {
    echo "  ERROR: mktemp failed for compose: $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  }
  if ! _compose_to_tmp "$src_list" "$tmp"; then
    echo "  ERROR: compose failed for $tgt_rel" >&2
    SWARM_RESULT_FATAL=1
    rm -f "$tmp"
    return 1
  fi

  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (compose)"
      SWARM_RESULT_DRIFT=1
      rm -f "$tmp"
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel  (composed)"
      SWARM_RESULT_CHANGED=1
      rm -f "$tmp"
      return 0
    fi
    local dir
    dir="$(dirname "$tgt")"
    [ -d "$dir" ] || mkdir -p "$dir"
    mv "$tmp" "$tgt"
    echo "  wrote: $tgt_rel  (composed)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if cmp -s "$tmp" "$tgt"; then
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    rm -f "$tmp"
    return 0
  fi
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      rm -f "$tmp"
      ;;
    onboard)
      if [ "${SWARM_FORCE_DOCS:-0}" -eq 1 ] && _swarm_is_doctrine "$tgt_rel"; then
        if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
          echo "  would overwrite (--force-docs): $tgt_rel"
          SWARM_RESULT_CHANGED=1
          rm -f "$tmp"
        else
          mv "$tmp" "$tgt"
          echo "  overwrote (--force-docs): $tgt_rel  (composed)"
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  COLLISION: $tgt_rel  (composed differs from existing)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
compose:$tgt_rel"
        rm -f "$tmp"
      fi
      ;;
    init|sync)
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would update: $tgt_rel  (composed)"
        SWARM_RESULT_CHANGED=1
        rm -f "$tmp"
      else
        mv "$tmp" "$tgt"
        echo "  updated: $tgt_rel  (composed)"
        SWARM_RESULT_CHANGED=1
      fi
      ;;
  esac
}

manifest_apply_seed() {
  # seed-class is per-repo content. By design:
  #   - init/onboard: write if absent (placeholder/template for the CTO).
  #   - sync: NEVER touch — these files are operator-owned, not infra.
  #   - check: report MISSING as informational, NOT as drift (sync can't
  #     fix it; run swarm-init to seed).
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "init" ] && [ "${SWARM_FORCE_SEED:-0}" -eq 1 ]; then
      _swarm_copy "$src" "$tgt" "re-seeded (--force)"
      return 0
    fi
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (seed; not drift — sync won't fix; init/onboard would)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (seed; sync does not seed): $tgt_rel"
    return 0
  fi
  _swarm_copy "$src" "$tgt" "seeded"
}

manifest_apply_seed_text() {
  # seed-text is per-repo content (e.g., .claude/test-cmd). Same policy as
  # seed: init/onboard seed if absent; sync never touches; check reports
  # MISSING informationally but does NOT mark drift.
  local text="$1" tgt_rel="$2"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ -e "$tgt" ]; then
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
    if [ "$SWARM_APPLY_MODE" = "init" ] && [ "${SWARM_FORCE_SEED:-0}" -eq 1 ]; then
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would re-seed (--force): $tgt_rel"
      else
        printf '%s\n' "$text" > "$tgt"
        echo "  re-seeded (--force): $tgt_rel"
      fi
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (seed-text; not drift — sync won't fix; init/onboard would)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (seed-text; sync does not seed): $tgt_rel"
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would seed: $tgt_rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  local dir
  dir="$(dirname "$tgt")"
  [ -d "$dir" ] || mkdir -p "$dir"
  printf '%s\n' "$text" > "$tgt"
  echo "  seeded: $tgt_rel  (initial content; edit to your repo's real value)"
  SWARM_RESULT_CHANGED=1
}

manifest_apply_settings() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (settings)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    local dir
    dir="$(dirname "$tgt")"
    [ -d "$dir" ] || mkdir -p "$dir"
    cp "$src" "$tgt"
    echo "  wrote: $tgt_rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  # Existing settings — structured merge.
  if [ "$SWARM_APPLY_MODE" = "check" ] || [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    if settings_merge_swarm "$tgt" "$src" --check; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
      [ "${SWARM_DRY_RUN:-0}" -eq 1 ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    else
      local cc=$?
      if [ "$cc" -eq 3 ]; then
        if [ "$SWARM_APPLY_MODE" = "check" ]; then
          echo "  MERGE_NEEDED: $tgt_rel  (swarm hook registrations missing or stale)"
          SWARM_RESULT_DRIFT=1
        else
          echo "  would merge: $tgt_rel"
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  ERROR: settings parse failed for $tgt_rel (rc=$cc)" >&2
        SWARM_RESULT_FATAL=1
        return 1
      fi
    fi
    return 0
  fi
  if settings_merge_swarm "$tgt" "$src"; then
    # Returns 0 on a structural change applied, 3 on no-op (see helper).
    echo "  merged: $tgt_rel  (swarm hooks registered; foreign entries preserved)"
    SWARM_RESULT_CHANGED=1
  else
    local rc=$?
    if [ "$rc" -eq 3 ]; then
      [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
    else
      echo "  ERROR: settings merge failed for $tgt_rel (rc=$rc)" >&2
      SWARM_RESULT_FATAL=1
      return 1
    fi
  fi
}

manifest_apply_git_hook() {
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  # Not a git working tree → skip silently. swarm-init has historically
  # tolerated this (non-git scaffold dirs).
  if [ ! -d "$SWARM_APPLY_REPO/.git" ] && [ ! -f "$SWARM_APPLY_REPO/.git" ]; then
    [ "$SWARM_APPLY_MODE" != "check" ] && echo "  skip: $tgt_rel  (not a git working tree)"
    return 0
  fi
  local marker='# SWARM-MANAGED pre-commit'
  # Distinct marker for the tooling/source-repo variant (anti-secret-only,
  # no docs-touch gate). When seen on a pre-commit, that's an intentional
  # opt-out from the standard hook — preserve it; do NOT overwrite back to
  # the standard variant on sync / init / onboard. See
  # templates/engineering-cto/git-hooks/pre-commit-anti-secret-only.
  local variant_marker='SWARM-MANAGED pre-commit (anti-secret-only'
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (git-hook)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    local dir
    dir="$(dirname "$tgt")"
    [ -d "$dir" ] || mkdir -p "$dir"
    cp "$src" "$tgt"
    chmod +x "$tgt"
    echo "  wrote: $tgt_rel"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  # Variant check FIRST: an anti-secret-only variant is swarm-managed but
  # deliberately different from the standard. Never clobber it.
  if head -n 5 "$tgt" | grep -qF "$variant_marker"; then
    case "$SWARM_APPLY_MODE" in
      check)
        echo "  OK:        $tgt_rel  (swarm-managed variant: anti-secret-only — preserved)"
        ;;
      *)
        [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip: $tgt_rel  (swarm-managed variant: anti-secret-only — preserved)"
        ;;
    esac
    return 0
  fi
  # Existing pre-commit — marker-aware (standard).
  if head -n 5 "$tgt" | grep -qF "$marker"; then
    # It's our own hook from a previous stamp.
    if cmp -s "$src" "$tgt"; then
      [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel"
      [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  unchanged: $tgt_rel"
      return 0
    fi
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  OUTDATED:  $tgt_rel"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would update: $tgt_rel  (existing is swarm-managed)"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    cp "$src" "$tgt"
    chmod +x "$tgt"
    echo "  updated: $tgt_rel  (existing was swarm-managed)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  # Foreign pre-commit (no marker).
  SWARM_RESULT_FOREIGN_PRECOMMIT=1
  case "$SWARM_APPLY_MODE" in
    check)
      echo "  FOREIGN:   $tgt_rel  (existing pre-commit has no SWARM-MANAGED marker)"
      SWARM_RESULT_DRIFT=1
      ;;
    onboard)
      if [ "${SWARM_FORCE_PRECOMMIT:-0}" -eq 1 ]; then
        if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
          echo "  would overwrite (--force-precommit): $tgt_rel"
          SWARM_RESULT_CHANGED=1
        else
          cp "$src" "$tgt"
          chmod +x "$tgt"
          echo "  overwrote (--force-precommit): $tgt_rel"
          SWARM_RESULT_CHANGED=1
        fi
      else
        echo "  COLLISION: $tgt_rel  (foreign pre-commit; pass --force-precommit to replace)"
        SWARM_RESULT_COLLISIONS="$SWARM_RESULT_COLLISIONS
git-hook:$tgt_rel"
      fi
      ;;
    init|sync)
      echo "  NOTE: kept existing $tgt_rel  (no SWARM-MANAGED marker); review"
      echo "        $SWARM_HOME/templates/$src_rel and merge by hand if you want"
      echo "        the docs-touch + anti-secret gate active."
      ;;
  esac
}

manifest_apply_gitignore() {
  # template-path field = the literal line we want present in .gitignore.
  local line="$1" tgt_rel="$2"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -e "$tgt" ]; then
    if [ "$SWARM_APPLY_MODE" = "check" ]; then
      echo "  MISSING:   $tgt_rel  (no .gitignore; line '$line' would be added)"
      SWARM_RESULT_DRIFT=1
      return 0
    fi
    if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
      echo "  would write: $tgt_rel  (would create with '$line' entry)"
      SWARM_RESULT_CHANGED=1
      return 0
    fi
    {
      echo "# Per-teammate git worktrees (CTO provisions before spawn;"
      echo "# never tracked in the integration tree)."
      echo "$line"
    } > "$tgt"
    echo "  wrote: $tgt_rel  (created with $line entry)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  if grep -qxF "$line" "$tgt"; then
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel  ('$line' present)"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (already gitignored): $line"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING_LINE: $tgt_rel  ('$line' absent)"
    SWARM_RESULT_DRIFT=1
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would append: $tgt_rel  ('$line' entry)"
    SWARM_RESULT_CHANGED=1
    return 0
  fi
  {
    echo ""
    echo "# Per-teammate git worktrees (CTO provisions before spawn;"
    echo "# never tracked in the integration tree)."
    echo "$line"
  } >> "$tgt"
  echo "  appended: $tgt_rel  ($line entry)"
  SWARM_RESULT_CHANGED=1
}

# Dispatch one manifest line to the right helper.
_manifest_apply_one() {
  local behavior="$1" src="$2" tgt="$3"
  case "$behavior" in
    refresh)   manifest_apply_refresh   "$src" "$tgt" ;;
    compose)   manifest_apply_compose   "$src" "$tgt" ;;
    seed)      manifest_apply_seed      "$src" "$tgt" ;;
    seed-text) manifest_apply_seed_text "$src" "$tgt" ;;
    settings)  manifest_apply_settings  "$src" "$tgt" ;;
    git-hook)  manifest_apply_git_hook  "$src" "$tgt" ;;
    gitignore) manifest_apply_gitignore "$src" "$tgt" ;;
    *)
      echo "  ERROR: unknown manifest behavior '$behavior' for $tgt" >&2
      SWARM_RESULT_FATAL=1
      return 1
      ;;
  esac
}

# manifest_apply REPO MODE [QUIET_UNCHANGED]
#   Modes:
#     init     — first stamp; --force re-seeds spec + test-cmd via SWARM_FORCE_SEED=1
#     sync     — upgrade existing repo; structured-merge settings
#     onboard  — pre-existing real repo; refuse-and-report on conflict
#     check    — dry-run drift report; never writes
#
# Resets and exports SWARM_RESULT_* outputs so callers can read them.
manifest_apply() {
  local repo="$1" mode="$2"
  [ -d "$repo" ] || { echo "swarm-lib: not a directory: $repo" >&2; return 1; }
  case "$mode" in init|sync|onboard|check) ;; *)
    echo "swarm-lib: invalid mode '$mode'" >&2; return 1 ;;
  esac
  SWARM_APPLY_REPO="$repo"
  SWARM_APPLY_MODE="$mode"
  SWARM_APPLY_TYPE="$(swarm_type_of "$repo")"
  SWARM_RESULT_CHANGED=0
  SWARM_RESULT_DRIFT=0
  SWARM_RESULT_COLLISIONS=""
  SWARM_RESULT_FOREIGN_PRECOMMIT=0
  SWARM_RESULT_FATAL=0
  export SWARM_APPLY_REPO SWARM_APPLY_MODE SWARM_APPLY_TYPE
  manifest_walk _manifest_apply_one || return $?
  [ "$SWARM_RESULT_FATAL" -eq 1 ] && return 1
  return 0
}

manifest_check() {
  manifest_apply "$1" check
}

# ---------------------------------------------------------------------------
# 3) Structured settings.json merger.
# ---------------------------------------------------------------------------
#
# settings_merge_swarm TARGET TEMPLATE [--check]
#
# Reads TARGET (existing repo .claude/settings.json) and TEMPLATE
# ($SWARM_HOME/templates/<type>/settings.example.json), produces a merged object,
# and atomically writes it back to TARGET. Foreign hook entries (anything
# whose command does NOT reference $CLAUDE_PROJECT_DIR/.claude/hooks/) are
# preserved. Swarm hooks are deduplicated by command path — running this
# multiple times is idempotent.
#
# Merge rules:
#   - Top-level scalars: template wins if target's value is missing.
#     Existing target scalars are LEFT ALONE (operator may have customized
#     env.CLAUDE_TEST_CMD, teammateMode, etc.).
#   - env: union; target's existing keys keep their values.
#   - enabledPlugins: union; target's existing entries keep their values.
#   - permissions.allow: union (dedup, sorted).
#   - hooks.<event>: for each swarm hook in the template, ensure it appears
#     exactly once in the target's flat list of {type,command,timeout}
#     entries. Foreign entries preserved in place; swarm entries that drift
#     (e.g., wrong timeout) are corrected to the template value.
#
# Exit codes:
#   0 — merge applied and written (target changed).
#   3 — already in sync (no changes needed). [non-zero so callers branch easily]
#   2 — fatal: parse failure, write failure, etc.
#
# With --check: 0 if already-in-sync, 3 if merge would change something, 2 on
# error. (Caller reads exit code, never writes.)
settings_merge_swarm() {
  local target="$1" template="$2" check_only=""
  [ "${3:-}" = "--check" ] && check_only="1"
  if [ ! -f "$target" ] || [ ! -f "$template" ]; then
    echo "settings_merge_swarm: missing file: $target or $template" >&2
    return 2
  fi
  local tmp
  tmp="$(mktemp -t swarm-settings.XXXXXX)" || return 2

  # Run merger in python3, write result to $tmp, signal status via exit code.
  python3 - "$target" "$template" "$tmp" "${check_only:-}" <<'PY'
import json, sys, os

target_path, template_path, out_path, check_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def load(p):
    with open(p) as f:
        return json.load(f)

try:
    tgt = load(target_path)
    tpl = load(template_path)
except Exception as e:
    sys.stderr.write(f"settings_merge_swarm: parse failure: {e}\n")
    sys.exit(2)

if not isinstance(tgt, dict) or not isinstance(tpl, dict):
    sys.stderr.write("settings_merge_swarm: settings root must be an object\n")
    sys.exit(2)

import copy
before = json.dumps(tgt, sort_keys=True)

# --- Top-level scalars: only fill missing ---
for k, v in tpl.items():
    if k in ("env", "enabledPlugins", "permissions", "hooks"):
        continue
    if k not in tgt:
        tgt[k] = copy.deepcopy(v)

# --- env: union, target wins on conflict ---
tpl_env = tpl.get("env") or {}
tgt_env = tgt.get("env") or {}
for k, v in tpl_env.items():
    if k not in tgt_env:
        tgt_env[k] = v
if tpl_env or tgt_env:
    tgt["env"] = tgt_env

# --- enabledPlugins: union, target wins ---
tpl_ep = tpl.get("enabledPlugins") or {}
tgt_ep = tgt.get("enabledPlugins") or {}
for k, v in tpl_ep.items():
    if k not in tgt_ep:
        tgt_ep[k] = v
if tpl_ep or tgt_ep:
    tgt["enabledPlugins"] = tgt_ep

# --- permissions.allow: union + dedup, preserve order with new items appended ---
tpl_perm = tpl.get("permissions") or {}
tgt_perm = tgt.get("permissions") or {}
tpl_allow = list(tpl_perm.get("allow") or [])
tgt_allow = list(tgt_perm.get("allow") or [])
seen = set(tgt_allow)
for item in tpl_allow:
    if item not in seen:
        tgt_allow.append(item)
        seen.add(item)
if tpl_perm or tgt_perm:
    tgt_perm["allow"] = tgt_allow
    # Preserve any other fields the operator may have under permissions.
    for k, v in tpl_perm.items():
        if k != "allow" and k not in tgt_perm:
            tgt_perm[k] = copy.deepcopy(v)
    tgt["permissions"] = tgt_perm

# --- hooks: per-event swarm-aware merge ---
SWARM_HOOK_MARKER = "$CLAUDE_PROJECT_DIR/.claude/hooks/"

def hook_cmd_filename(cmd):
    """Return the swarm hook's filename (e.g., 'test-gate.sh') if the
    command references a swarm-managed hook; else None."""
    if not isinstance(cmd, str):
        return None
    idx = cmd.find(SWARM_HOOK_MARKER)
    if idx < 0:
        return None
    rest = cmd[idx + len(SWARM_HOOK_MARKER):]
    # Strip a possible trailing quote and anything beyond the .sh.
    for q in ('"', "'", " "):
        cut = rest.find(q)
        if cut >= 0:
            rest = rest[:cut]
    return rest or None

def collect_swarm_entries(event_block):
    """From the template's event_block, return dict: filename -> entry."""
    out = {}
    for matcher in event_block or []:
        for h in matcher.get("hooks") or []:
            fn = hook_cmd_filename(h.get("command"))
            if fn:
                out[fn] = h
    return out

tpl_hooks = tpl.get("hooks") or {}
tgt_hooks = tgt.get("hooks") or {}

for event, tpl_event in tpl_hooks.items():
    tpl_swarm = collect_swarm_entries(tpl_event)
    if not tpl_swarm:
        continue
    tgt_event = tgt_hooks.get(event)
    if not tgt_event:
        # No entries yet for this event — drop the template's full block in.
        tgt_hooks[event] = copy.deepcopy(tpl_event)
        continue
    # Walk existing matchers, dedup-by-command and update swarm entries.
    seen_swarm = set()
    for matcher in tgt_event:
        new_hooks = []
        for h in matcher.get("hooks") or []:
            fn = hook_cmd_filename(h.get("command"))
            if fn and fn in tpl_swarm:
                if fn in seen_swarm:
                    # Drop duplicate swarm entry.
                    continue
                seen_swarm.add(fn)
                # Replace with template's version (corrects timeout drift).
                new_hooks.append(copy.deepcopy(tpl_swarm[fn]))
            else:
                # Foreign or unknown — preserve verbatim.
                new_hooks.append(h)
        matcher["hooks"] = new_hooks
    # Any swarm entry not yet present anywhere: add to a fresh matcher block.
    missing = [fn for fn in tpl_swarm if fn not in seen_swarm]
    if missing:
        tgt_event.append({"hooks": [copy.deepcopy(tpl_swarm[fn]) for fn in missing]})

if tpl_hooks or tgt_hooks:
    tgt["hooks"] = tgt_hooks

after = json.dumps(tgt, sort_keys=True)
changed = (before != after)

if check_only:
    sys.exit(3 if changed else 0)

if not changed:
    sys.exit(3)

# Atomic write — write to tmp, fsync, rename.
try:
    with open(out_path, "w") as f:
        json.dump(tgt, f, indent=2)
        f.write("\n")
except Exception as e:
    sys.stderr.write(f"settings_merge_swarm: write failure: {e}\n")
    sys.exit(2)
sys.exit(0)
PY
  local rc=$?
  if [ -n "$check_only" ]; then
    rm -f "$tmp"
    return $rc
  fi
  case "$rc" in
    0)
      # Merger wrote the new contents to $tmp; atomically rename into place.
      if ! mv "$tmp" "$target"; then
        echo "settings_merge_swarm: rename failed for $target" >&2
        rm -f "$tmp"
        return 2
      fi
      return 0
      ;;
    3) rm -f "$tmp"; return 3 ;;
    *) rm -f "$tmp"; return "$rc" ;;
  esac
}
