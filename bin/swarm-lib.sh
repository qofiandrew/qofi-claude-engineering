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
SWARM_CONF_F_ACCOUNT=""

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
  local _name _repo _tokvar _channel _guild _account _rest
  # Full known arity + `_rest` catch-all so a row with MORE columns than the
  # current schema cannot corrupt the last named field (see header). ACCOUNT
  # (field 6) is the multi-account partition label; absent in legacy 4/5-col
  # rows → empty → the default account (today's behavior). Resolve it via
  # swarm_account_resolve — never construct an account path by hand.
  IFS='|' read -r _name _repo _tokvar _channel _guild _account _rest <<EOF
$_line
EOF
  SWARM_CONF_F_NAME="$(_swarm_trim "$_name")"
  SWARM_CONF_F_REPO="$(_swarm_trim "$_repo")"
  SWARM_CONF_F_TOKVAR="$(_swarm_trim "$_tokvar")"
  # Field 3 (TOKEN_VAR_NAME) is later deref'd by NAME via ${!tokvar} (swarm-up /
  # swarm-typing / swarm-watch) and spliced into the pane env line. A value that
  # is not a legal shell IDENTIFIER is an injection sink: the array-subscript form
  # NAME[$(...)] fires command substitution inside the launcher (which could
  # re-source and exfiltrate the whole vault), and a quote-break escapes the pane
  # env string — either defeats F1 token isolation (ADR-0018). A `case` match does
  # NOT evaluate the value, so checking it is itself safe. Reject a malformed
  # non-empty token-var by BLANKING it; the consumers' empty-token guards then skip
  # the swarm (fail-safe) rather than deref a hostile name. (The OAUTH token-var is
  # built by swarm_account_resolve from a charset-validated label, already safe.)
  case "$SWARM_CONF_F_TOKVAR" in
    '') : ;;                                   # empty is fine — guards skip the swarm
    [0-9]* | *[!A-Za-z0-9_]*)                  # not ^[A-Za-z_][A-Za-z0-9_]*$ → reject
      echo "swarm_conf_parse_line: refusing non-identifier TOKEN_VAR_NAME '$SWARM_CONF_F_TOKVAR' for swarm '$SWARM_CONF_F_NAME' (must match [A-Za-z_][A-Za-z0-9_]*); blanking it." >&2
      SWARM_CONF_F_TOKVAR="" ;;
  esac
  SWARM_CONF_F_CHANNEL="$(_swarm_trim "$_channel")"
  SWARM_CONF_F_GUILD="$(_swarm_trim "$_guild")"
  SWARM_CONF_F_ACCOUNT="$(_swarm_trim "$_account")"
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

# swarm_known_types — print the known archetype names, one per line.
# A type passed to swarm-init --type / swarm-new --type / swarm-add --type
# is validated against this list; an unknown type is refused so a typo
# (--type cpoo) cannot silently misclassify the swarm. Update this list
# when a new archetype is added under templates/.
swarm_known_types() {
  printf '%s\n' engineering-cto cpo company-brain
}

# swarm_type_is_known TYPE — return 0 iff TYPE is in swarm_known_types.
swarm_type_is_known() {
  local t="$1"
  swarm_known_types | grep -qxF "$t"
}

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

# swarm_known_profiles — print the known engineering-cto profile names, one
# per line. A profile is an ORTHOGONAL axis layered on top of the
# engineering-cto archetype (ADR-0013): it does not replace the archetype, it
# appends a stack-specific overlay to the composed CLAUDE.md only. A value
# passed to swarm-init/swarm-add/swarm-new --profile is validated against this
# list so a typo cannot silently misclassify. 'backend' is intentionally
# present but LABEL-ONLY in v1 (today's engineering-cto IS the backend case),
# so it ships no overlay fragment; 'frontend' is the only profile with overlay
# content. Update this list when a new profile overlay is added under
# templates/engineering-cto/profiles/.
swarm_known_profiles() {
  printf '%s\n' frontend backend
}

# swarm_profile_is_known PROFILE — return 0 iff PROFILE is in
# swarm_known_profiles.
swarm_profile_is_known() {
  local p="$1"
  swarm_known_profiles | grep -qxF "$p"
}

# swarm_profile_of REPO
#
# Resolve a repo's profile from the .claude/swarm-profile marker file.
# Returns the profile name on stdout, or the EMPTY string when the marker is
# absent or empty. Unlike swarm_type_of (which defaults to engineering-cto),
# an absent profile resolves to NO profile — so a markerless swarm composes
# byte-identically to a pre-profile swarm (ADR-0013: the no-op default that
# keeps existing swarms untouched; do NOT change this to default to a value).
# Whitespace stripped.
swarm_profile_of() {
  local repo="$1"
  local marker="$repo/.claude/swarm-profile"
  if [ -f "$marker" ]; then
    local p
    p="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  printf '%s' ""
}

# swarm_canon_mode_of REPO
#
# Resolve a repo's source-of-truth mode from the .claude/canon-mode marker.
# Returns 'external' only when the marker exists and says so; ANYTHING else
# (absent marker, empty, 'local', junk) resolves to 'local' — the no-op
# default that keeps every existing swarm byte-identical (same posture as
# swarm_profile_of; do NOT change the default). Whitespace stripped.
swarm_canon_mode_of() {
  local repo="$1"
  local marker="$repo/.claude/canon-mode"
  if [ -f "$marker" ]; then
    local m
    m="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')"
    if [ "$m" = "external" ]; then
      printf 'external\n'
      return 0
    fi
  fi
  printf 'local\n'
}

# swarm_required_doctrine TYPE
#
# Emit the doctrine filenames (relative to the swarm repo root, one per
# line) that swarm-up's gate (c) must see stamped before it agrees to
# launch a swarm of this type. The list is INTENTIONALLY data-driven
# per archetype so adding a new type means adding a case here, not
# reopening swarm-up.sh.
#
# Unknown / future types FALL THROUGH to the engineering-cto triad
# (CLAUDE.md + ESCALATION.md + TEAM_LEAD.md). This is the fail-safe
# direction: a swarm with a misclassified or future marker still gets
# refused (with a clear "TEAM_LEAD.md missing" error) rather than
# silently launching a swarm whose doctrine never landed.
swarm_required_doctrine() {
  case "$1" in
    cpo)
      printf '%s\n' CLAUDE.md ESCALATION.md
      ;;
    engineering-cto|*)
      printf '%s\n' CLAUDE.md ESCALATION.md TEAM_LEAD.md
      ;;
  esac
}

# swarm_launch_brief TYPE
#
# Emit the initial brief swarm-up's launch_one() sends into the tmux
# pane right after `claude` finishes booting. The brief is the agent's
# first instruction set and frames its role; engineering-cto and cpo
# have fundamentally different roles, so each archetype owns its own
# brief.
#
# Unknown / future types fall through to engineering-cto for the same
# fail-safe reason as swarm_required_doctrine: a misclassified swarm
# at least gets the engineering brief (a known-good orientation),
# rather than launching with no instructions at all.
#
# Both briefs open with an explicit READ-YOURSELF-DO-NOT-DELEGATE clause.
# This is load-bearing, not boilerplate: launch_one sends `/effort
# ultracode` BEFORE this brief (swarm-up.sh), and under ultracode the lead
# defaults to fanning every substantive task out to a workflow/subagents.
# Without the clause, the lead reads its doctrine in ephemeral subagent
# contexts that are discarded — TEAM_LEAD.md / ESCALATION.md /
# PROJECT_SPEC.md (none auto-loaded; only CLAUDE.md is) never land in the
# lead's own context and it boots without its operating manual. Keep the
# clause unless ultracode is moved to AFTER the brief.
swarm_launch_brief() {
  case "$1" in
    cpo)
      printf '%s' "Read CLAUDE.md, ESCALATION.md, CONVERSATION.md, EVALUATION.md, SURFACING.md, MEMORY.md, READINESS_BAR.md NOW, yourself, directly with the file-reading tool — read them into your OWN context. Do NOT delegate this to a workflow or to subagents: your operating doctrine must live in your context, not an ephemeral one, so read the files inline before doing anything else. You are the CPO for this product-vision repo; operate per CLAUDE.md. The operator will hold the product conversation with you over Discord. You write into products/<product>/<facet>.md via the refine → ratify → write protocol in MEMORY.md. Do NOT act as an engineering team lead and do NOT execute engineering work — that is the CTOs' lane."
      ;;
    engineering-cto|*)
      printf '%s' "Read TEAM_LEAD.md, ESCALATION.md, CLAUDE.md and PROJECT_SPEC.md NOW, yourself, directly with the file-reading tool — read them into your OWN context. Do NOT delegate this to a workflow or to subagents: your operating doctrine must live in your context, not an ephemeral one, so read the files inline before doing anything else. You are the team lead (CTO) for this repo; operate per TEAM_LEAD.md. The human will hold a product design conversation with you over Discord and the spec may be empty for now — do NOT build during the conversation. When the human says to build, first author PROJECT_SPEC.md and the one-way-door ADRs from the conversation, confirm them with the human, then decompose and spawn the team. Keep the docs reconciled with the implementation as it proceeds, and message the human for any major spec decision."
      ;;
  esac
}

# swarm_effort_for TYPE
#
# Emit the `/effort` command swarm-up's launch_one() sends into the tmux pane
# right after `claude` boots, per archetype. The CPO swarm is a single
# conversational product agent that should NOT fan every turn out to a workflow,
# so it launches at medium effort; every engineering CTO swarm stays on ultracode
# (xhigh effort + automatic workflow orchestration). Effort is SESSION-ONLY
# (ultracode has no settings.json / env / --effort form — see launch_one), which
# is why it is a launch-time `/effort` send rather than config, and why this
# helper is the single tuning point for per-archetype effort.
#
# Unknown / future types fall through to ultracode — the same fail-safe direction
# as swarm_required_doctrine / swarm_launch_brief: a misclassified or future
# swarm gets the engineering path, never a silent downgrade.
swarm_effort_for() {
  case "$1" in
    cpo)
      printf '%s' "/effort medium"
      ;;
    engineering-cto|*)
      printf '%s' "/effort ultracode"
      ;;
  esac
}

# swarm_account_resolve LABEL — resolve an account label to ITS config dir,
# projects dir, access.json, and vault token-var name. SINGLE SOURCE OF TRUTH:
# every consumer that needs an account's paths/token derives all four from here
# and NEVER hand-constructs a $HOME/.claude path. A missed site silently reads
# the WRONG account's transcripts → the WORKING rail (repo_activity) disarms →
# a live swarm is killed. A repo-wide grep-assert (tests/test-account-paths-
# sole-constructor.sh) pins this function as the sole builder of those paths.
#
# Empty label = the DEFAULT account = today's behavior, byte-for-byte:
#   CONFIG_DIR  $HOME/.claude          (keychain auth; no token var)
#   PROJECTS    $HOME/.claude/projects
#   ACCESS      $HOME/.claude/channels/discord/access.json
#   TOKEN_VAR   ""   (empty → launch_one keeps keychain auth, no token export)
# A non-empty <label> maps to an ISOLATED config dir + a vault token var:
#   CONFIG_DIR  $HOME/.claude-accounts/<label>
#   TOKEN_VAR   OAUTH_TOKEN_<LABEL_UPPER>   (lowercase→UPPER, '-'→'_')
# CAVEAT (provisioning footgun, ADR-0018): the '-'→'_' fold means two labels that
# differ ONLY by '-' vs '_' (e.g. 'max-a' and 'max_a') collapse to the SAME token
# var (OAUTH_TOKEN_MAX_A) while keeping DISTINCT config dirs — a wrong-credential
# risk. Operators must not create two accounts whose labels differ only by '-'/'_'.
#
# Sets (does not echo): SWARM_ACCT_CONFIG_DIR, SWARM_ACCT_PROJECTS_DIR,
# SWARM_ACCT_ACCESS_FILE, SWARM_ACCT_TOKEN_VAR. Returns 0; 2 on a malformed
# label (rejected BEFORE any path is built — a bad label must never name a dir).
SWARM_ACCT_CONFIG_DIR=""
SWARM_ACCT_PROJECTS_DIR=""
SWARM_ACCT_ACCESS_FILE=""
SWARM_ACCT_TOKEN_VAR=""
swarm_account_resolve() {
  local label="${1:-}"
  if [ -z "$label" ]; then
    # The DEFAULT account PRESERVES the env overrides the consumers honor today,
    # so threading them through the resolver stays byte-identical:
    #   CLAUDE_PROJECTS_DIR — the WORKING-rail projects dir (watch/restart/rotate/typing)
    #   SWARM_ACCESS_FILE   — the access.json path (bus-wire/doctor; up/add/remove were
    #                         bare → now uniformly honor it, identical when unset).
    # LABELED accounts are isolated and ignore both (each lives under its own dir),
    # so an override can never leak a labeled lane onto the default's transcripts.
    SWARM_ACCT_CONFIG_DIR="$HOME/.claude"
    SWARM_ACCT_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    SWARM_ACCT_ACCESS_FILE="${SWARM_ACCESS_FILE:-$HOME/.claude/channels/discord/access.json}"
    SWARM_ACCT_TOKEN_VAR=""
    return 0
  fi
  # Validate the handle BEFORE building any path (same shape swarm-account-state
  # trusts): leading alpha, then only [A-Za-z0-9_-].
  case "$label" in
    [A-Za-z]*) ;;
    *) echo "swarm_account_resolve: invalid account label '$label' (need [A-Za-z][A-Za-z0-9_-]*)" >&2; return 2 ;;
  esac
  case "$label" in
    *[!A-Za-z0-9_-]*) echo "swarm_account_resolve: invalid account label '$label' (need [A-Za-z][A-Za-z0-9_-]*)" >&2; return 2 ;;
  esac
  SWARM_ACCT_CONFIG_DIR="$HOME/.claude-accounts/$label"
  SWARM_ACCT_PROJECTS_DIR="$SWARM_ACCT_CONFIG_DIR/projects"
  SWARM_ACCT_ACCESS_FILE="$SWARM_ACCT_CONFIG_DIR/channels/discord/access.json"
  SWARM_ACCT_TOKEN_VAR="OAUTH_TOKEN_$(printf '%s' "$label" | tr 'a-z-' 'A-Z_')"
  return 0
}

# swarm_conf_set_account CONF NAME ACCOUNT — atomically rewrite field 6 (ACCOUNT)
# of the swarm.conf row whose field-1 (name) trims to NAME, leaving every other
# row, comment, and blank line BYTE-for-byte untouched. This is the per-swarm
# persistence of a failover swap (ADR-0018): the conf rewrite IS the durable
# "which account is this swarm on" — it sticks across restarts until the next cap.
#
# Reuses swarm-remove.sh's awk temp→mv idiom (comments/blanks/non-matching rows
# pass through verbatim via the raw $0/$i fields), adapted to REWRITE field 6
# instead of deleting the row. Arity-safe across legacy widths (tightening #2):
#   - 4-/5-column rows are PADDED so the account always lands in field 6 (a 4-col
#     row gains an empty guild field-5 so positions don't shift);
#   - 6-column rows have field 6 replaced;
#   - any field 7+ (the parser's _rest catch-all) is preserved verbatim.
# Fields 1..5 are emitted from the RAW split ($i still carries each field's own
# surrounding whitespace), so the operator's column spacing on this row's other
# fields is preserved; only field 6 is (re)written.
#
# An EMPTY ACCOUNT restores the row to the DEFAULT account: a row that already had
# no account (≤5 cols) is left verbatim; a row that had one (≥6 cols) has field 6
# DROPPED (not left as a dangling empty field) so the result is a clean ≤5-col row.
#
# Returns 0 on a successful rewrite (atomic mv), 1 if NAME matched no data row
# (conf left untouched), 2 on a write/mv failure. The CALLER validates the ACCOUNT
# label (via swarm_account_resolve) — this helper is purely mechanical.
swarm_conf_set_account() {
  local _conf="$1" _name="$2" _acct="${3:-}"
  local _tmp="$_conf.tmp.$$"
  awk -F'|' -v n="$_name" -v acct="$_acct" '
    /^[[:space:]]*(#|$)/ { print; next }
    {
      v=$1; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != n) { print; next }
      found=1
      if (acct == "") {
        if (NF <= 5) { print; next }          # already default → verbatim
        out=$1
        for (i=2; i<=5; i++) out = out "|" $i # drop field 6, keep 1..5 + 7+
        for (i=7; i<=NF; i++) out = out "|" $i
        print out; next
      }
      out=$1
      for (i=2; i<=5; i++) out = out "|" (i<=NF ? $i : "")   # pad short rows to col 5
      out = out "| " acct
      for (i=7; i<=NF; i++) out = out "|" $i                 # preserve any 7+ verbatim
      print out
    }
    END { exit (found ? 0 : 1) }
  ' "$_conf" > "$_tmp"
  local _rc=$?
  if [ "$_rc" -ne 0 ]; then rm -f "$_tmp"; return 1; fi      # NAME not found → no change
  if ! mv "$_tmp" "$_conf"; then rm -f "$_tmp"; return 2; fi
  return 0
}

# swarm_bound_exports NAME CHANNEL — emit the shell `export` statements that
# scope a swarm's Discord bridge binding. ALL swarms get DISCORD_BOUND_CHANNEL =
# their own channel (single-bound, unchanged). The ONE exception is the CPO
# swarm (name matches $SWARM_CPO_NAME, default "qofi-product"): it is bound to
# the UNION of its operator channel + the bus, and additionally gets the role
# env vars so doctrine's register-by-channel can compare a message's source id
# against DISCORD_OPERATOR_CHANNEL vs DISCORD_BUS_CHANNEL. The CPO name and bus
# id are the only deployment-specific values; both are env-overridable so this
# shared lib stays portable. Single source of truth: binding and role env are
# derived together here, so they can't disagree. A CTO swarm NEVER reaches this
# branch — its binding is exactly its own channel and it gets no bus access.
swarm_bound_exports() {
  local name="$1" channel="$2"
  local cpo_name="${SWARM_CPO_NAME:-qofi-product}"
  local bus="${SWARM_BUS_CHANNEL:-1510301812434141194}"
  if [ -n "$channel" ] && [ "$name" = "$cpo_name" ]; then
    printf "export DISCORD_OPERATOR_CHANNEL='%s'; export DISCORD_BUS_CHANNEL='%s'; export DISCORD_BOUND_CHANNEL='%s,%s'" \
      "$channel" "$bus" "$channel" "$bus"
  else
    # Every non-CPO swarm (and the legacy empty-channel row): single-bound, no
    # operator/bus role env. Empty channel → empty bind (prior behavior).
    printf "export DISCORD_BOUND_CHANNEL='%s'" "$channel"
  fi
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
  local behavior src tgt covers line
  # Read pipe-delimited fields, skip comments + blanks, trim each field. The
  # 4th field (covers) is the optional route-before-scan note; a catch-all var
  # absorbs it (and any further '|') so tgt is always exactly field 3 — same
  # arity-safety idiom as the swarm.conf parser's trailing _rest. covers is
  # human/agent-facing only and intentionally unused here.
  while IFS='|' read -r behavior src tgt covers; do
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
  # Profile overlay (ADR-0013) — engineering-cto only, CLAUDE.md only.
  # When the repo's resolved profile has an overlay fragment on disk, append
  # it as the FINAL compose source so the profile's stack-specific doctrine
  # layers on top of the base teammate manual. THREE states fall out of one
  # guard, by design:
  #   - absent/empty profile        -> nothing appended; a markerless swarm
  #     composes byte-identically to a pre-profile swarm (the no-op default)
  #   - a profile with no fragment   -> nothing appended; v1 'backend' is
  #     label-only (today's engineering-cto IS the backend case), so the
  #     marker is a label and the compose is unchanged
  #   - a profile WITH a fragment    -> appended (e.g. 'frontend')
  # Gated on SWARM_APPLY_TYPE=engineering-cto so a non-engineering-cto compose
  # (e.g. the cpo CLAUDE.md, same target name) is never touched even if a
  # stray marker exists. This and the canon-mode overlay below are the ONLY
  # dynamically-sourced compose inputs; every other source is the static
  # '+'-joined list on the manifest line, which stays profile- and
  # mode-agnostic (see templates/engineering-cto/manifest.tsv header +
  # templates/_base/README.md).
  if [ "$tgt_rel" = "CLAUDE.md" ] && \
     [ "${SWARM_APPLY_TYPE:-}" = "engineering-cto" ] && \
     [ -n "${SWARM_APPLY_PROFILE:-}" ]; then
    local _overlay_rel="engineering-cto/profiles/${SWARM_APPLY_PROFILE}/CLAUDE.md"
    if [ -f "$SWARM_HOME/templates/$_overlay_rel" ]; then
      src_list="${src_list}+${_overlay_rel}"
    fi
  fi
  # Canon-mode overlay (source-of-truth axis) — engineering-cto only,
  # CLAUDE.md only, external mode only. Appends AFTER any profile overlay:
  # first the shared external-canon doctrine fragment (template-sourced),
  # then — post-compose, below — the repo-local canon binding, which names
  # this repo's canon/spec repo and cannot live in templates/. A repo in
  # 'local' mode (the default; absent/any-other marker) composes
  # byte-identically to a pre-canon-mode swarm.
  local _canon_binding=""
  if [ "$tgt_rel" = "CLAUDE.md" ] && \
     [ "${SWARM_APPLY_TYPE:-}" = "engineering-cto" ] && \
     [ "${SWARM_APPLY_CANON_MODE:-local}" = "external" ]; then
    local _canon_rel="engineering-cto/canon/CLAUDE.external-canon.md"
    if [ -f "$SWARM_HOME/templates/$_canon_rel" ]; then
      src_list="${src_list}+${_canon_rel}"
    fi
    if [ -f "$SWARM_APPLY_REPO/.claude/canon-binding.md" ]; then
      _canon_binding="$SWARM_APPLY_REPO/.claude/canon-binding.md"
    fi
  fi
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
  # Repo-local canon binding: the ONE compose input sourced from the target
  # repo itself (seeded by bin/swarm-canon-enable.sh, operator/CTO-owned).
  # Appended last so the binding always terminates the composed manual.
  if [ -n "$_canon_binding" ]; then
    cat "$_canon_binding" >> "$tmp" || {
      echo "  ERROR: compose failed appending canon binding for $tgt_rel" >&2
      SWARM_RESULT_FATAL=1
      rm -f "$tmp"
      return 1
    }
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

manifest_apply_operator_owned() {
  # operator-owned: per-repo content the OPERATOR authors (product vision,
  # strategy doc, etc.). The CRITICAL difference from `seed`: --force does
  # NOT re-seed. By design:
  #   - init/onboard: write if absent (initial placeholder for the operator).
  #   - sync: NEVER touch — operator-owned, not infra.
  #   - init --force / SWARM_FORCE_SEED=1: IGNORED. Operator-authored
  #     content is sacred; --force on init is for re-seeding infra
  #     templates, never for clobbering operator content. To reset
  #     operator content, the operator deletes the file by hand and
  #     re-runs init.
  #   - check: report MISSING informationally, NOT as drift.
  #
  # SUBTREE SEMANTICS. An entry whose target is `<dir>/.keep` declares the
  # WHOLE `<dir>/` subtree operator-owned, not just the .keep marker. The
  # .keep file is the seed anchor; the protected unit is the directory.
  # An entry whose target is a real file (no `.keep` basename) protects
  # exactly that path. The pre-walk in manifest_apply collects these as
  # SWARM_OO_PREFIXES / SWARM_OO_FILES and refuses any other manifest
  # entry that would write under a protected prefix or onto a protected
  # file — so a future `refresh | ... | products/foo.md` is a fatal
  # manifest defect, not a silent clobber.
  #
  # Paired with the staging protection in templates/<type>/git-hooks/
  # pre-commit (Layer 3): the auto-stamped .claude/operator-owned-paths
  # list contains the canonical form (prefix entries end in `/`; exact
  # entries do not) and the hook prefix-matches `/`-suffixed lines so a
  # teammate cannot stage a file anywhere under an operator-owned subtree.
  local src_rel="$1" tgt_rel="$2"
  local src="$SWARM_HOME/templates/$src_rel"
  local tgt="$SWARM_APPLY_REPO/$tgt_rel"
  if [ ! -f "$src" ]; then
    echo "  ERROR: template missing: $src_rel" >&2
    SWARM_RESULT_FATAL=1
    return 1
  fi
  if [ -e "$tgt" ]; then
    # NO SWARM_FORCE_SEED branch — that is the whole point.
    [ "$SWARM_APPLY_MODE" = "check" ] && echo "  OK:        $tgt_rel  (operator-owned)"
    [ "$SWARM_APPLY_MODE" != "check" ] && [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (operator-owned; exists): $tgt_rel"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    echo "  MISSING:   $tgt_rel  (operator-owned; not drift — sync won't fix; init/onboard would seed)"
    return 0
  fi
  if [ "$SWARM_APPLY_MODE" = "sync" ]; then
    [ "${SWARM_QUIET_UNCHANGED:-0}" -ne 1 ] && echo "  skip (operator-owned; sync does not seed): $tgt_rel"
    return 0
  fi
  _swarm_copy "$src" "$tgt" "seeded (operator-owned)"
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
#
# Before dispatch, refuse any non-operator-owned entry whose target falls
# under an operator-owned subtree prefix (or exactly matches an operator-
# owned file). This enforces the doctrine "products/ is operator-owned"
# against every other class: a stray `refresh | ... | products/foo.md`
# is rejected as a fatal manifest defect, never silently honored.
_manifest_apply_one() {
  local behavior="$1" src="$2" tgt="$3"
  if [ "$behavior" != "operator-owned" ] && _swarm_target_in_oo_subtree "$tgt"; then
    echo "  ERROR: manifest entry '$behavior | $src | $tgt' targets operator-owned content (refused)" >&2
    echo "         operator-owned subtrees + files in this manifest:" >&2
    local p
    for p in $SWARM_OO_PREFIXES $SWARM_OO_FILES; do
      echo "           $p" >&2
    done
    SWARM_RESULT_FATAL=1
    return 1
  fi
  case "$behavior" in
    refresh)        manifest_apply_refresh        "$src" "$tgt" ;;
    compose)        manifest_apply_compose        "$src" "$tgt" ;;
    seed)           manifest_apply_seed           "$src" "$tgt" ;;
    seed-text)      manifest_apply_seed_text      "$src" "$tgt" ;;
    operator-owned) manifest_apply_operator_owned "$src" "$tgt" ;;
    settings)       manifest_apply_settings       "$src" "$tgt" ;;
    git-hook)       manifest_apply_git_hook       "$src" "$tgt" ;;
    gitignore)      manifest_apply_gitignore      "$src" "$tgt" ;;
    *)
      echo "  ERROR: unknown manifest behavior '$behavior' for $tgt" >&2
      SWARM_RESULT_FATAL=1
      return 1
      ;;
  esac
}

# _swarm_oo_canonical TGT_REL — print the canonical operator-owned form
# of a manifest target. A target whose basename is `.keep` declares the
# WHOLE parent directory operator-owned, so it canonicalizes to
# `<dir>/` (subtree prefix, trailing slash). Any other target
# canonicalizes to itself (exact file). This is the single rule both
# the prefix collector (manifest_apply) and the paths-list stamper
# (_swarm_stamp_operator_owned_list) consume — keeping the in-memory
# refusal set and the on-disk pre-commit contract in lockstep.
_swarm_oo_canonical() {
  local tgt_rel="$1"
  case "$tgt_rel" in
    */.keep|.keep)
      local dir
      dir="${tgt_rel%.keep}"
      [ -z "$dir" ] && dir="./"
      printf '%s' "$dir"
      ;;
    *)
      printf '%s' "$tgt_rel"
      ;;
  esac
}

# _swarm_target_in_oo_subtree TGT_REL — return 0 if TGT_REL falls under
# any operator-owned prefix (canonical form ending in `/`) or exactly
# equals any operator-owned file (canonical form without `/`). Reads
# SWARM_OO_PREFIXES + SWARM_OO_FILES, populated by manifest_apply's
# pre-walk.
_swarm_target_in_oo_subtree() {
  local tgt_rel="$1" p
  for p in $SWARM_OO_FILES; do
    [ "$tgt_rel" = "$p" ] && return 0
  done
  for p in $SWARM_OO_PREFIXES; do
    case "$tgt_rel" in
      "$p"*) return 0 ;;
    esac
  done
  return 1
}

# _swarm_load_oo_from_list REPO — populate SWARM_OO_PREFIXES + SWARM_OO_FILES
# from REPO's stamped .claude/operator-owned-paths (the same canonical list
# manifest_apply writes via _swarm_stamp_operator_owned_list and the Layer-3
# pre-commit hook reads: subtree-prefix entries end in `/`, exact-file entries
# do not). After this, _swarm_target_in_oo_subtree classifies a repo-relative
# path against EXACTLY the set manifest_apply will skip-and-never-commit.
#
# RESETS both vars first (so a stale set from an earlier call never leaks). A
# MISSING or empty list yields EMPTY sets — so nothing classifies as operator-
# owned and any caller's dirty-tree test fails SAFE to refuse. This is read-only
# and independent of manifest_apply's own pre-walk (which resets and repopulates
# these vars itself), so calling it before manifest_apply is harmless.
_swarm_load_oo_from_list() {
  local repo="$1" list="$1/.claude/operator-owned-paths" line
  SWARM_OO_PREFIXES=""
  SWARM_OO_FILES=""
  [ -f "$list" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      */)     SWARM_OO_PREFIXES="$SWARM_OO_PREFIXES $line" ;;
      *)      SWARM_OO_FILES="$SWARM_OO_FILES $line" ;;
    esac
  done < "$list"
  return 0
}

# swarm_dirty_classify_oo REPO — classify a repo's dirty working tree against
# its operator-owned set. Reads `git status --porcelain` and prints, to stdout,
# one line per dirty path that is NOT operator-owned (a sync-managed path:
# doctrine / hooks / settings / gitignore / anything outside products etc.).
# Empty stdout + a dirty tree => every dirty path is operator-owned (sync skips
# them all and will not commit them). Renames are split so BOTH the old and new
# path must be operator-owned. Return: 0 if the tree is dirty AND every dirty
# path is operator-owned; 1 otherwise (clean tree, OR at least one sync-managed
# path is dirty — printed). Unparseable/quoted paths fall through as NON-owned
# (fail-safe to refuse). Caller must have loaded the OO set first
# (_swarm_load_oo_from_list).
swarm_dirty_classify_oo() {
  local repo="$1" porcelain line path any_dirty=0 any_foreign=0
  porcelain="$(git -C "$repo" status --porcelain 2>/dev/null)"
  [ -n "$porcelain" ] || return 1   # clean tree: not "dirty-but-all-oo"
  # Split each porcelain entry into its path(s): strip the 2-col status + space,
  # and turn a rename "old -> new" into two paths so both must be operator-owned.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    any_dirty=1
    line="${line#???}"                 # drop the "XY " status prefix
    case "$line" in
      *" -> "*)
        for path in "${line%% -> *}" "${line##* -> }"; do
          _swarm_target_in_oo_subtree "$path" || { printf '%s\n' "$path"; any_foreign=1; }
        done ;;
      *)
        _swarm_target_in_oo_subtree "$line" || { printf '%s\n' "$line"; any_foreign=1; } ;;
    esac
  done <<EOF
$porcelain
EOF
  [ "$any_dirty" -eq 1 ] && [ "$any_foreign" -eq 0 ]
}

# _swarm_collect_oo_prefixes — manifest_walk callback that populates
# SWARM_OO_PREFIXES (space-separated subtree prefixes, each ending in `/`)
# and SWARM_OO_FILES (space-separated exact-file paths). Called in the
# pre-walk before _manifest_apply_one so the dispatcher's refusal set is
# fully known by the time any entry is processed.
_swarm_collect_oo_prefixes() {
  local behavior="$1" tgt="$3"
  [ "$behavior" = "operator-owned" ] || return 0
  local canon
  canon="$(_swarm_oo_canonical "$tgt")"
  case "$canon" in
    */)  SWARM_OO_PREFIXES="$SWARM_OO_PREFIXES $canon" ;;
    *)   SWARM_OO_FILES="$SWARM_OO_FILES $canon" ;;
  esac
}

# _swarm_stamp_operator_owned_list REPO
#
# Maintain .claude/operator-owned-paths — a flat list of every operator-
# owned target in the current archetype's manifest, one per line, in
# CANONICAL form: a `<dir>/.keep` manifest entry stamps as `<dir>/` (the
# whole directory, subtree-prefix form, trailing slash); any other
# operator-owned entry stamps as itself (exact-file form). Read by
# templates/<type>/git-hooks/pre-commit (Layer 3) which prefix-matches
# `/`-suffixed lines and exact-matches the rest, so a teammate cannot
# stage anything under an operator-owned subtree or onto an exact
# operator-owned file.
#
# Always reflects the current manifest exactly:
#   - has entries → file written with current set (overwrites stale).
#   - no entries → file removed (so removing operator-owned entries from
#     the manifest does not leave a stale block-list behind).
#   - check mode  → reports drift, no writes.
#   - dry-run     → reports the would-be change, no writes.
#
# Called once at the end of manifest_apply so each init/sync/onboard
# leaves the list in sync with the manifest.
_swarm_stamp_operator_owned_list() {
  local repo="$1"
  local list_path="$repo/.claude/operator-owned-paths"
  local list_path_rel=".claude/operator-owned-paths"
  local tmp
  tmp="$(mktemp -t swarm-oo.XXXXXX)" || return 1
  : > "$tmp"
  _collect_oo() {
    case "$1" in
      operator-owned) _swarm_oo_canonical "$3" >> "$tmp"; printf '\n' >> "$tmp" ;;
    esac
  }
  manifest_walk _collect_oo >/dev/null

  local has_entries=0
  [ -s "$tmp" ] && has_entries=1

  if [ "$SWARM_APPLY_MODE" = "check" ]; then
    if [ "$has_entries" -eq 1 ]; then
      if [ ! -f "$list_path" ] || ! cmp -s "$tmp" "$list_path"; then
        echo "  DRIFT:     $list_path_rel  (operator-owned paths list)"
        SWARM_RESULT_DRIFT=1
      fi
    elif [ -f "$list_path" ]; then
      echo "  DRIFT:     $list_path_rel  (should be removed; no operator-owned entries)"
      SWARM_RESULT_DRIFT=1
    fi
    rm -f "$tmp"
    return 0
  fi

  if [ "$has_entries" -eq 0 ]; then
    rm -f "$tmp"
    if [ -f "$list_path" ]; then
      if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
        echo "  would remove: $list_path_rel  (no operator-owned entries)"
      else
        rm -f "$list_path"
        echo "  removed: $list_path_rel  (no operator-owned entries)"
      fi
      SWARM_RESULT_CHANGED=1
    fi
    return 0
  fi

  if [ -f "$list_path" ] && cmp -s "$tmp" "$list_path"; then
    rm -f "$tmp"
    return 0
  fi
  if [ "${SWARM_DRY_RUN:-0}" -eq 1 ]; then
    echo "  would write: $list_path_rel  (operator-owned paths)"
    SWARM_RESULT_CHANGED=1
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$repo/.claude"
  mv "$tmp" "$list_path"
  echo "  wrote: $list_path_rel  (operator-owned paths)"
  SWARM_RESULT_CHANGED=1
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
  # Orthogonal profile axis (ADR-0013): empty for markerless swarms (no-op).
  # Consumed by manifest_apply_compose to optionally append a profile overlay
  # to the composed CLAUDE.md (engineering-cto only).
  SWARM_APPLY_PROFILE="$(swarm_profile_of "$repo")"
  # Orthogonal source-of-truth axis: 'local' (default, no-op) or 'external'.
  # Consumed by manifest_apply_compose to append the external-canon overlay
  # + the repo-local canon binding to the composed CLAUDE.md
  # (engineering-cto only). See docs/CANON-MODES.md.
  SWARM_APPLY_CANON_MODE="$(swarm_canon_mode_of "$repo")"
  SWARM_RESULT_CHANGED=0
  SWARM_RESULT_DRIFT=0
  SWARM_RESULT_COLLISIONS=""
  SWARM_RESULT_FOREIGN_PRECOMMIT=0
  SWARM_RESULT_FATAL=0
  # Pre-walk: collect operator-owned prefixes + exact files so the
  # dispatcher can refuse any other manifest entry that would write into
  # an operator-owned subtree (the doctrine "products/ is sacred"
  # enforced across every class, every --force flag).
  SWARM_OO_PREFIXES=""
  SWARM_OO_FILES=""
  export SWARM_APPLY_REPO SWARM_APPLY_MODE SWARM_APPLY_TYPE SWARM_APPLY_PROFILE SWARM_APPLY_CANON_MODE
  manifest_walk _swarm_collect_oo_prefixes >/dev/null || return $?
  manifest_walk _manifest_apply_one || return $?
  [ "$SWARM_RESULT_FATAL" -eq 1 ] && return 1
  # Auto-stamp the operator-owned paths list (no-op if no entries; deletes
  # the file if entries were removed from the manifest). MUST run after the
  # walk so the list reflects the current manifest, never partial state.
  _swarm_stamp_operator_owned_list "$repo"
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
