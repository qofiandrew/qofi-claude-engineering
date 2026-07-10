#!/usr/bin/env bash
# swarm-limit-detect.sh — detect the REAL rate-limit signal (the actual usage-cap
# message the active account is shown) and emit it as the poller's AT-LIMIT
# verdict. This is the AUTHORITATIVE "on-limit" detector; the token-burn estimate
# in swarm-usage-poll.sh remains the early NEAR warning.
#
# ── WHY THIS EXISTS (real signal vs. proxy) ──────────────────────────────────
# swarm-usage-poll.sh decides "near a cap" from a token-BURN estimate vs. a
# budget. That's a forward-looking PROXY: good for an early NEAR warning, but it
# is not the cap itself. The authoritative "you are capped" signal is the actual
# usage-limit message Claude Code shows when the account hits its 5h/weekly limit
# (or a provider 429). THIS deployment already OBSERVES that message: the watcher
# (swarm-watch.sh) reads it via pane_state() in swarm-lib.sh, which returns rc=2
# ("paused-limit") when a live tmux pane shows a known limit substring
# ("usage limit" / "5-hour limit" / "limit reached" / "rate limit" / ...). Those
# substrings are the same ones the watcher alerts on, and they are overridable via
# SWARM_LIMIT_PATTERNS. So the real signal IS reliably observable here, and this
# detector simply turns "any live swarm pane is paused on a limit" into the
# poller's AT verdict.
#
# ── HOW IT FITS THE SEAMS (feeds the poller's AT verdict; rewrites nothing) ──
# This is a NEW detector behind the poll seam, NOT a rewrite of swarm-usage-poll.
# The orchestrator (swarm-rotate-tick.sh) consults the poll via SWARM_POLL_CMD.
# To make the REAL signal authoritative while keeping the burn estimate as the
# NEAR early-warning, wire the tick's poll seam to this combiner form:
#
#     export SWARM_POLL_CMD='swarm-limit-detect.sh --or-poll'
#
# In --or-poll mode we first check the real signal:
#   * real limit observed  -> emit AT (exit 20) immediately. The cap is real; the
#                             estimate is moot.
#   * no real limit         -> DELEGATE to swarm-usage-poll.sh and pass through its
#                             verdict (so NEAR/OK/UNKNOWN from the burn proxy still
#                             flows). The proxy is the early warning; the real
#                             signal is the hard stop.
# Without --or-poll the detector reports ONLY the real signal (AT or OK/UNKNOWN),
# which is useful for observe-mode logging alongside the proxy.
#
# ── EXIT CODES (same contract as swarm-usage-poll.sh, so it drops into the seam)─
#   20 — AT-LIMIT   a live swarm pane is showing a known usage/rate-limit message
#                   (pane_state rc=2). The active account is really capped.
#   0  — OK         no live pane shows a limit message (real signal: not capped).
#                   In --or-poll this is never emitted directly — we delegate.
#   3  — UNKNOWN    cannot observe (no tmux, no live sessions, capture failed). A
#                   detector that cannot see must NOT claim "not capped"; it yields
#                   to the proxy. Fail-safe: never trips a rotation on its own.
#   2  — config/usage error.
#
# ── OBSERVABILITY OVERRIDE (testability) ─────────────────────────────────────
#   SWARM_PANE_STATE_CMD  Optional. A command run via `sh -c` with a session name
#                         in $1; its EXIT CODE is interpreted as pane_state's
#                         (0 working / 1 at-prompt / 2 paused-limit / 3 unknown /
#                         4 uncertain), and its STDOUT (if any) is the matched
#                         limit line. Tests inject this so no real tmux is needed.
#                         Default: the real pane_state() from swarm-lib.sh.
#   SWARM_POLL_CMD_INNER  In --or-poll mode, the proxy poller to delegate to.
#                         Default: "$SCRIPT_DIR/swarm-usage-poll.sh".
#   SWARM_TMUX_PREFIX     tmux session prefix (default "swarm"), as elsewhere.
#   SWARM_TMUX_BIN        tmux binary (default "tmux").
#
# Usage:
#   swarm-limit-detect.sh             # real signal only -> AT(20)/OK(0)/UNKNOWN(3)
#   swarm-limit-detect.sh --or-poll   # AT if real cap, else delegate to the proxy
#   swarm-limit-detect.sh --json      # one JSON line describing what was seen
#   swarm-limit-detect.sh -h | --help
#
# bash 3.2-safe (macOS default). Read-only: never swaps a credential, never
# restarts anything. python3 only via the delegated poller (not here).

set -uo pipefail

PROG="swarm-limit-detect"
usage() { sed -n '1,80p' "$0"; exit "${1:-0}"; }

OR_POLL=0
JSON=0
BY_ACCOUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --or-poll)    OR_POLL=1; shift ;;
    --json)       JSON=1; shift ;;
    --by-account) BY_ACCOUNT=1; shift ;;
    -h|--help) usage 0 ;;
    --*) echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)   echo "$PROG: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

if [ -z "${SWARM_HOME:-}" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME so swarm.conf is found." >&2
  exit 2
fi
CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
POLL_INNER="${SWARM_POLL_CMD_INNER:-$SCRIPT_DIR/swarm-usage-poll.sh}"

# ── THE PANE-NOTICE TIER (--or-poll only): the yellow "approaching" warning ──
# Claude Code shows a PRE-cap warning in the pane (binary v2.1.206 templates):
#     You've used ${r}% of your ${t} · resets ${o}     t ∈ session|weekly|usage limit
#     Approaching ${t} · resets ${o}
# That notice is PER-LEAD ground truth about the account the lead is actually
# burning — immune to the split-brain where the /usage probe reads a different
# account than the leads hold (the shared keychain item is last-writer-wins
# across processes' token refreshes). So in --or-poll mode a notice at >= the
# threshold is a NEAR trigger, ahead of the delegated percentage poll.
#
# THE LATCH (anti-loop; why pane text was previously demoted to alert-only):
# under no-restart re-auth, a lead that does NOT adopt the fresh credential
# keeps showing the old account's notice/cap — an unlatched pane trigger would
# re-fire a login URL EVERY tick. So the pane tier fires ONCE per SIGNATURE:
# the matched lines with the climbing percentage stripped ("resets 8:39am"
# makes it window-unique). Emitting writes the signature to a PENDING file;
# swarm-reauth PROMOTES pending -> latched only on a SUCCESSFUL re-auth. A
# signature equal to the latched one — or ANY pane signal within
# SWARM_PANE_LATCH_COOLDOWN of the last success — is suppressed (delegates to
# the poll instead). The notice self-clears at window roll, so a new window's
# notice is a new signature and re-arms naturally. The percentage-poll tier is
# NEVER latched — it reads the current keychain account and cannot loop (the
# probe is recycled onto the new account after each successful re-auth).
#
#   SWARM_NEAR_PATTERNS           notice patterns: newline-separated EXTENDED
#                                 REGEXES (case-SENSITIVE; pipes within a line
#                                 are ERE alternation). The defaults are built
#                                 from the binary's actual templates and are
#                                 deliberately shaped against quoted/prose text:
#                                 the percentage form REQUIRES digits+% (source
#                                 code or prose quoting the pattern text has
#                                 none), and the Approaching form REQUIRES the
#                                 "· resets" tail. Limit labels observed in
#                                 v2.1.206: session|weekly|Opus|Sonnet|Fable 5
#                                 (+ usage credit) — matched generically.
#   SWARM_NEAR_EXCLUDE_PATTERNS   benign-notice exclusions (pipe/newline-
#                                 separated case-INsensitive fixed strings).
#   SWARM_ROTATE_THRESHOLD_PCT    fire only at >= this percent (default 85,
#                                 same default as swarm-usage-poll.sh; the
#                                 no-percent "Approaching" form always fires).
#   SWARM_PANE_LATCH_COOLDOWN     seconds after a successful re-auth during
#                                 which the WHOLE pane tier stays suppressed
#                                 (default 900). 0 disables the cooldown.
#   SWARM_PANE_REPROMPT_COOLDOWN  seconds between pane-tier FIRES while a
#                                 prompt goes unanswered/fails (default 3600):
#                                 an unanswered login URL re-prompts hourly,
#                                 not every tick. 0 disables. (Note: a manual
#                                 `--dry-run` tick that fires also arms this —
#                                 a live prompt for the same window can be
#                                 deferred up to this long after a dry-run.)
#   SWARM_PANE_LATCH_TTL          seconds a latched signature stays suppressing
#                                 (default 604800 = 7d, the longest real limit
#                                 window) — bounds "latched forever" for
#                                 signals with no resets identity.
#   SWARM_PANE_NOTICE_CMD         test seam: run via `sh -c "$cmd" _ <sess>`;
#                                 stdout = matched notice lines, rc 0 = found.
#                                 When SWARM_PANE_STATE_CMD is injected WITHOUT
#                                 this, the notice tier is DISABLED (keeps
#                                 pre-tier tests/observers hermetic).
#   SWARM_STATE_DIR               latch dir (default ~/.config/swarm).
# NOTE the default is hoisted into its own variable: it contains ERE braces,
# and inside ${VAR:-default} the FIRST '}' would close the expansion and
# silently mangle the regex.
_NEAR_DEFAULT='[0-9]{1,3}% of your [A-Za-z0-9 .-]{1,30}limit|Approaching [A-Za-z0-9 .-]{1,30}limit · resets'
NEAR_PATTERNS="${SWARM_NEAR_PATTERNS:-$_NEAR_DEFAULT}"
NEAR_EXCLUDE="${SWARM_NEAR_EXCLUDE_PATTERNS:-you can use up to|can use up to}"
NEAR_THRESHOLD="${SWARM_ROTATE_THRESHOLD_PCT:-85}"
LATCH_COOLDOWN="${SWARM_PANE_LATCH_COOLDOWN:-900}"
REPROMPT_COOLDOWN="${SWARM_PANE_REPROMPT_COOLDOWN:-3600}"
LATCH_TTL="${SWARM_PANE_LATCH_TTL:-604800}"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
PENDING_FILE="$STATE_DIR/swarm-pane-signal.pending"
LATCHED_FILE="$STATE_DIR/swarm-pane-signal.latched"
# These knobs are consumed only by the --or-poll pane tiers; validating them in
# plain/--by-account mode would turn a bad var into exit 2 where main returned a
# verdict — a regression for callers that never use the tier.
if [ "$OR_POLL" -eq 1 ]; then
  for _nv in "$NEAR_THRESHOLD" "$LATCH_COOLDOWN" "$REPROMPT_COOLDOWN" "$LATCH_TTL"; do
    case "$_nv" in ''|*[!0-9]*) echo "$PROG: SWARM_ROTATE_THRESHOLD_PCT / SWARM_PANE_LATCH_COOLDOWN / SWARM_PANE_REPROMPT_COOLDOWN / SWARM_PANE_LATCH_TTL must be plain integers (got '$_nv')" >&2; exit 2 ;; esac
  done
fi

# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # pane_state, swarm_conf_parse_line, SWARM_PANE_STATE_DETAIL

# probe_pane SESSION -> sets PANE_RC and PANE_DETAIL
# Uses the injectable SWARM_PANE_STATE_CMD seam if set (tests), else the real
# pane_state() from swarm-lib.sh. Either way the rc encodes the same states.
probe_pane() {
  local sess="$1"
  if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
    PANE_DETAIL="$(sh -c "$SWARM_PANE_STATE_CMD" _ "$sess" 2>/dev/null)"; PANE_RC=$?
  else
    pane_state "$sess" "$TMUX_BIN"; PANE_RC=$?
    PANE_DETAIL="$SWARM_PANE_STATE_DETAIL"
  fi
}

# _near_pats — the notice EREs, one per line (pipes WITHIN a line are ERE
# alternation, so no tr here), blanks stripped (a blank line makes grep -f
# match EVERYTHING). _near_excl — fixed-string exclusions, pipe- or newline-
# separated like pane_state's sets in swarm-lib.sh.
_near_pats() { printf '%s' "$NEAR_PATTERNS" | grep -v '^[[:space:]]*$'; }
_near_excl() { printf '%s' "$NEAR_EXCLUDE"  | tr '|' '\n' | grep -v '^[[:space:]]*$'; }

# notice_tier_enabled — the notice tier runs only when it can observe honestly:
# its own seam is injected, OR we are on the real-tmux path. An injected
# pane-state WITHOUT an injected notice cmd means a pre-tier test/observer —
# stay silent there rather than capture real panes behind a stub's back.
notice_tier_enabled() {
  [ -n "${SWARM_PANE_NOTICE_CMD:-}" ] && return 0
  [ -n "${SWARM_PANE_STATE_CMD:-}" ] && return 1
  return 0
}

# ── THE TRANSCRIPT TIER (--or-poll; highest priority) ─────────────────────────
# Pane text is a RENDERING of the limit state — the status strip cycles, wraps,
# and clears, so a 300s-cadence capture is a sampling lottery (missed a real
# deployment-core rate_limit on 2026-07-10 whose pane never showed a matchable
# line at capture time). The lead's TRANSCRIPT is the RECORD: Claude Code
# writes `"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429`
# events (top-level keys, ISO timestamp) into the session jsonl the moment the
# API throttles it. Those events are durable, per-lead, and timestamped — no
# lottery. This tier scans each swarm's newest transcript tails for a
# rate_limit event younger than SWARM_XSCRIPT_LIMIT_WINDOW and fires AT.
# Top-level-key parsing (not substring) so a lead merely WRITING code or prose
# about rate limits can never trip it — the marker text inside message content
# is nested, never top-level.
#
# Latch identity: "transcript rate_limit <swarm> <UTC-hour-bucket>" — one
# prompt per swarm-hour through the same pending/latched machinery; a lead
# that stays throttled after a successful re-auth (did not adopt the fresh
# credential) re-fires at most hourly and is named by the stuck-pane alerter.
#
#   SWARM_XSCRIPT_LIMIT_WINDOW  max event age in seconds (default 900 = 3
#                               ticks). 0 disables the tier.
#   SWARM_XSCRIPT_TAIL_BYTES    how much of each transcript tail to scan
#                               (default 4194304 = 4MB). Must comfortably
#                               cover WINDOW seconds of writing: a hot lead
#                               bursts ~0.5MB/15min, and an undersized tail
#                               silently misses in-window events (the first
#                               live proof missed 22MB-deep events with a
#                               256KB tail).
#   SWARM_XSCRIPT_TIER          force-enable (1) even when a pane stub is
#                               injected — tests set this with a fixture
#                               CLAUDE_PROJECTS_DIR; without it an injected
#                               pane-state disables the tier (hermetic, same
#                               rule as the notice tier).
XSCRIPT_WINDOW="${SWARM_XSCRIPT_LIMIT_WINDOW:-900}"
case "$XSCRIPT_WINDOW" in ''|*[!0-9]*) XSCRIPT_WINDOW=900 ;; esac
XSCRIPT_TAIL="${SWARM_XSCRIPT_TAIL_BYTES:-4194304}"
case "$XSCRIPT_TAIL" in ''|*[!0-9]*) XSCRIPT_TAIL=4194304 ;; esac

xscript_tier_enabled() {
  [ "$XSCRIPT_WINDOW" -eq 0 ] && return 1
  [ "${SWARM_XSCRIPT_TIER:-}" = "1" ] && return 0
  [ -n "${SWARM_PANE_STATE_CMD:-}" ] && return 1
  return 0
}

# transcript_limit_scan — scan every swarm's transcript tails for a recent
# top-level rate_limit event. Prints "<swarm>\t<iso-ts>\t<hour-bucket>" for the
# NEWEST such event; rc 0 = found. One python pass over all swarms; per entry
# dir only the 2 newest jsonl files, tail 256KB each — cheap at tick cadence.
transcript_limit_scan() {
  local rows="" _projects
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    [ -z "$SWARM_CONF_F_NAME" ] && continue
    [ -z "$SWARM_CONF_F_REPO" ] && continue
    swarm_account_resolve "$SWARM_CONF_F_ACCOUNT" || continue
    _projects="$SWARM_ACCT_PROJECTS_DIR"
    rows="$rows$SWARM_CONF_F_NAME|$SWARM_CONF_F_REPO|$_projects
"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  [ -z "$rows" ] && return 1
  printf '%s' "$rows" | python3 -c '
import json, os, re, sys, time
window = int(sys.argv[1])
tail_bytes = int(sys.argv[2])
now = time.time()
best = None  # (epoch, swarm, iso)
for row in sys.stdin.read().splitlines():
    parts = row.split("|")
    if len(parts) < 3: continue
    swarm, repo, projects = parts[0], parts[1], parts[2]
    lead_enc = re.sub(r"[/.]", "-", repo)
    tm_prefix = lead_enc + "--claude-worktrees-"
    try:
        entries = os.listdir(projects)
    except Exception:
        continue
    for entry in entries:
        if entry != lead_enc and not entry.startswith(tm_prefix):
            continue
        d = os.path.join(projects, entry)
        try:
            js = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".jsonl")]
        except Exception:
            continue
        js.sort(key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)
        for path in js[:2]:
            try:
                size = os.path.getsize(path)
                with open(path, "rb") as fh:
                    if size > tail_bytes:
                        fh.seek(-tail_bytes, 2)
                    tail = fh.read().decode("utf-8", "replace")
            except Exception:
                continue
            for line in tail.splitlines():
                if "\"rate_limit\"" not in line or "isApiErrorMessage" not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                # TOP-LEVEL keys only: nested mentions (a lead writing about
                # rate limits) never count.
                if not isinstance(e, dict): continue
                if e.get("error") != "rate_limit" or e.get("isApiErrorMessage") is not True:
                    continue
                ts = e.get("timestamp", "")
                m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", str(ts))
                if not m: continue
                import calendar
                ep = calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0))
                if now - ep > window or ep - now > 300:
                    continue
                if best is None or ep > best[0]:
                    best = (ep, swarm, str(ts))
if best is None:
    sys.exit(1)
bucket = best[2][:13]  # YYYY-MM-DDTHH
print("%s\t%s\t%s" % (best[1], best[2], bucket))
' "$XSCRIPT_WINDOW" "$XSCRIPT_TAIL"
}

# probe_notice SESSION -> stdout = matched notice lines (exclusions applied);
# rc 0 = at least one line, 1 = none/can't capture. Default implementation
# captures the pane (-J joins soft-wrapped lines) and greps the pattern EREs
# (case-SENSITIVE — the real notices are cased; source/prose quoting the
# pattern text stays lowercase or percentless and misses).
probe_notice() {
  local sess="$1" cap hits
  if [ -n "${SWARM_PANE_NOTICE_CMD:-}" ]; then
    sh -c "$SWARM_PANE_NOTICE_CMD" _ "$sess" 2>/dev/null
    return $?
  fi
  cap="$("$TMUX_BIN" capture-pane -p -J -t "$sess" 2>/dev/null)" || return 1
  [ -z "$cap" ] && return 1
  hits="$(printf '%s\n' "$cap" | grep -E -f <(_near_pats) 2>/dev/null | grep -i -v -F -f <(_near_excl) 2>/dev/null)"
  [ -z "$hits" ] && return 1
  printf '%s\n' "$hits"
  return 0
}

# notice_qualifies LINES -> 0 if the notice warrants NEAR: any matched line has
# a percentage >= NEAR_THRESHOLD, or carries no percentage at all (the
# "Approaching <limit>" form — imminent by definition).
notice_qualifies() {
  local max=-1 saw_nopct=0 _l _p
  while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    _p="$(printf '%s' "$_l" | grep -oE '[0-9]{1,3}%' | tr -d '%' | sort -n | tail -n 1)"
    if [ -z "$_p" ]; then saw_nopct=1; continue; fi
    [ "$_p" -gt "$max" ] && max="$_p"
  done <<EOF
$1
EOF
  [ "$saw_nopct" -eq 1 ] && return 0
  [ "$max" -ge "$NEAR_THRESHOLD" ] && return 0
  return 1
}

# pane_signature LINES -> the window-stable identity of a pane signal: matched
# lines with the CLIMBING percentage neutralized (95%→%, 98%→%), whitespace
# squeezed, sorted unique. "resets 8:39am" stays, making it window-unique; the
# percentage climbing 95→98 does NOT change the signature (no re-fire).
pane_signature() {
  printf '%s\n' "$1" | sed -e 's/[0-9][0-9]*%/%/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g' \
    | grep -v '^$' | sort -u
}

# _file_age FILE -> prints seconds since FILE's mtime, or nothing if
# unreadable/non-numeric. (macOS stat -f first; -c is the GNU spelling — on a
# GNU system -f prints filesystem info, non-numeric, which the guard rejects,
# so the age gates are simply inert off macOS rather than wrong.)
_file_age() {
  local now mt
  now="$(date +%s 2>/dev/null)"; mt="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)"
  case "$now$mt" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$mt" ] || return 1
  printf '%s' $((now - mt))
}

# pane_tier_suppressed SIG -> 0 if this signature must NOT fire:
#   (a) every line of SIG is already LATCHED (a successful re-auth answered it)
#       and its latch entry is younger than LATCH_TTL — SUBSET semantics, so a
#       multi-pane union that loses a pane, or a notice/cap alternation, never
#       re-prompts an already-answered window;
#   (b) the last successful re-auth is younger than LATCH_COOLDOWN (any pane
#       signal that soon is the un-adopted old account, not a fresh need);
#   (c) the last pane-tier FIRE (pending mtime) is younger than
#       REPROMPT_COOLDOWN — an unanswered/failed prompt re-prompts at that
#       cadence, not every tick.
# LATCHED format: "epoch<TAB>line" per entry (epoch = promotion time, for TTL).
pane_tier_suppressed() {
  local sig="$1" age live _l
  if [ -f "$LATCHED_FILE" ]; then
    if [ "$LATCH_COOLDOWN" -gt 0 ] && age="$(_file_age "$LATCHED_FILE")" && [ "$age" -lt "$LATCH_COOLDOWN" ]; then
      return 0
    fi
    # Live latched SET: entries younger than the TTL, epoch stripped.
    live="$(awk -F'\t' -v now="$(date +%s 2>/dev/null)" -v ttl="$LATCH_TTL" \
      'NF>=2 && $1+0>0 && (now-$1)<ttl { sub(/^[^\t]*\t/,""); print }' "$LATCHED_FILE" 2>/dev/null)"
    if [ -n "$live" ] && [ -n "$sig" ]; then
      local all_in=1
      while IFS= read -r _l; do
        [ -z "$_l" ] && continue
        printf '%s\n' "$live" | grep -qxF -- "$_l" || { all_in=0; break; }
      done <<EOF
$sig
EOF
      [ "$all_in" -eq 1 ] && return 0
    fi
  fi
  if [ "$REPROMPT_COOLDOWN" -gt 0 ] && [ -f "$PENDING_FILE" ]; then
    if age="$(_file_age "$PENDING_FILE")" && [ "$age" -lt "$REPROMPT_COOLDOWN" ]; then
      return 0
    fi
  fi
  return 1
}

# pane_tier_arm SIG — record the signature we are about to fire on (also the
# re-prompt stamp). Promotion to latched happens in swarm-reauth.sh, only after
# a SUCCESSFUL re-auth. Returns 1 on write failure — the caller must then NOT
# fire (an unarmed fire re-prompts every tick; fail toward the poll tier).
pane_tier_arm() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$1" > "$PENDING_FILE" 2>/dev/null || return 1
}

# ── Scan live swarms for the real limit signal ───────────────────────────────
# We consider only sessions that look live (tmux has-session), exactly as the
# rotate clean-boundary guard does. Any one paused-limit pane means the ACTIVE
# account (single-account deployment) is capped — that's the whole fleet's cap.
SAW_LIMIT=0           # 1 once any pane shows a known limit message
SAW_ANY_PANE=0        # 1 once we could read at least one live pane
LIMIT_DETAIL=""       # first matched limit line (for logging/JSON)
LIMIT_SWARM=""        # which swarm showed it

have_tmux=0
if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
  have_tmux=1         # injected probe stands in for tmux
elif command -v "$TMUX_BIN" >/dev/null 2>&1; then
  have_tmux=1
fi

# ── --by-account: per-ACCOUNT cap grouping (the failover router's detector) ───
# The single-account scan below collapses the whole fleet to one verdict and
# BREAKS on the first capped pane. The failover model (ADR-0018) needs the
# OPPOSITE: scan EVERY live swarm, GROUP by its swarm.conf field-6 account, and
# report each account's verdict — an account is AT if ANY of its swarms shows a
# limit pane, OK if any of its swarms is readable-and-not-capped, else UNKNOWN.
# We emit one stable line per account; the router parses these to decide which
# accounts must evacuate. The aggregate exit mirrors the single-account contract
# (20 if any account is capped / 0 if any readable-not-capped / 3 if none
# observable) so a caller that only checks the exit code still gets a sane signal.
if [ "$BY_ACCOUNT" -eq 1 ]; then
  # Always iterate the conf to build the account UNIVERSE (so an account whose
  # swarms are all down still reports UNKNOWN rather than vanishing). Probe each
  # live swarm; record observations as TAB-delimited "<acctkey> <rc> <swarm> <detail>".
  OBS=""
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _name="$SWARM_CONF_F_NAME"
    [ -z "$_name" ] && continue
    _key="$SWARM_CONF_F_ACCOUNT"; [ -z "$_key" ] && _key="_default_"
    _sess="${PREFIX}-${_name}"
    _rc=4; _det=""
    if [ "$have_tmux" -eq 1 ]; then
      if [ -n "${SWARM_PANE_STATE_CMD:-}" ]; then
        probe_pane "$_sess"; _rc="$PANE_RC"; _det="$PANE_DETAIL"
      elif "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null; then
        probe_pane "$_sess"; _rc="$PANE_RC"; _det="$PANE_DETAIL"
      fi
    fi
    OBS="$OBS$_key	$_rc	$_name	$_det
"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

  if [ "$JSON" -eq 1 ]; then
    printf '%s' "$OBS" | python3 -c '
import json,sys
acc={}   # key -> dict; preserves first-seen order (py3.7+ dict is ordered)
for raw in sys.stdin.read().splitlines():
    if not raw.strip(): continue
    parts=raw.split("\t")
    while len(parts)<4: parts.append("")
    key,rc,sw,det=parts[0],parts[1],parts[2],parts[3]
    a=acc.setdefault(key,{"account":(None if key=="_default_" else key),"verdict":"UNKNOWN","swarm":None,"limit_line":None,"_readable":False})
    if rc=="2" and a["verdict"]!="AT":
        a["verdict"]="AT"; a["swarm"]=sw; a["limit_line"]=(det or None)
    if rc!="4" and a["verdict"]!="AT":
        a["verdict"]="OK"; a["_readable"]=True
out=[]
anyAT=anyOK=False
for k,a in acc.items():
    if a["verdict"]=="AT": anyAT=True
    elif a["verdict"]=="OK": anyOK=True
    a.pop("_readable",None)
    out.append(a)
print(json.dumps({"accounts":out}))
sys.exit(20 if anyAT else (0 if anyOK else 3))
' ; exit $?
  fi

  printf '%s' "$OBS" | awk -F'\t' '
    $1=="" { next }
    {
      key=$1; rc=$2; sw=$3; det=$4
      if (!(key in firstseen)) { firstseen[key]=1; order[++n]=key }
      if (rc=="2") { if (!(key in atsw)) { atsw[key]=sw; atdet[key]=det }; at[key]=1 }
      if (rc!="4") readable[key]=1
    }
    END {
      anyAT=0; anyOK=0
      for (i=1;i<=n;i++) {
        k=order[i]
        if (k in at)            { anyAT=1; printf "account=%s verdict=AT swarm=%s detail=%s\n", k, atsw[k], atdet[k] }
        else if (k in readable) { anyOK=1; printf "account=%s verdict=OK\n", k }
        else                    {          printf "account=%s verdict=UNKNOWN\n", k }
      }
      if (anyAT) exit 20; else if (anyOK) exit 0; else exit 3
    }
  '
  exit $?
fi

NOTICE_LINES=""       # accumulated matched notice lines across panes (or-poll tier)
NOTICE_SWARMS=""      # which swarms showed a notice
if [ "$have_tmux" -eq 1 ]; then
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _name="$SWARM_CONF_F_NAME"
    [ -z "$_name" ] && continue
    _sess="${PREFIX}-${_name}"
    # Liveness: with a real tmux, require an actual session; with an injected
    # probe, the stub decides (it returns rc=4 "uncertain" for absent sessions).
    if [ -z "${SWARM_PANE_STATE_CMD:-}" ]; then
      "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null || continue
    fi
    probe_pane "$_sess"
    case "$PANE_RC" in
      4) : ;;                       # uncertain (no session / capture failed) — skip
      *) SAW_ANY_PANE=1 ;;          # we read SOME pane state
    esac
    if [ "$PANE_RC" -eq 2 ]; then
      SAW_LIMIT=1
      LIMIT_DETAIL="$PANE_DETAIL"
      LIMIT_SWARM="$_name"
      break                         # one capped pane is enough — the account is capped
    fi
    # Pane-notice tier (--or-poll only): collect the yellow approaching-limit
    # warning from readable, non-capped panes. Never breaks the scan — a real
    # cap elsewhere still outranks a notice.
    if [ "$OR_POLL" -eq 1 ] && [ "$PANE_RC" -ne 4 ] && notice_tier_enabled; then
      _nl="$(probe_notice "$_sess")" && [ -n "$_nl" ] && {
        NOTICE_LINES="${NOTICE_LINES}${_nl}
"
        NOTICE_SWARMS="$NOTICE_SWARMS $_name"
      }
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
fi

# ── Decide the REAL-signal verdict ───────────────────────────────────────────
# AT  if we saw a limit message.
# OK  if we read at least one live pane and none showed a limit (real "not capped").
# UNKNOWN if we could not observe at all (no tmux / no live sessions) — the
#         detector that cannot see yields rather than asserting "not capped".
if [ "$SAW_LIMIT" -eq 1 ]; then
  REAL_VERDICT="AT"; REAL_CODE=20
elif [ "$SAW_ANY_PANE" -eq 1 ]; then
  REAL_VERDICT="OK"; REAL_CODE=0
else
  REAL_VERDICT="UNKNOWN"; REAL_CODE=3
fi

emit_json() {  # verdict source detail
  local v="$1" src="$2" det="$3"
  python3 - "$v" "$src" "$det" "$LIMIT_SWARM" <<'PY' 2>/dev/null || printf '{"verdict":"%s","source":"%s"}\n' "$v" "$src"
import json,sys
print(json.dumps({
  "verdict": sys.argv[1],
  "source": sys.argv[2],
  "limit_line": (sys.argv[3] or None),
  "swarm": (sys.argv[4] or None),
}))
PY
}

# ── --or-poll: pane signals are the hard stop; otherwise delegate to the poll ─
# Order: cap (AT) > qualifying notice (NEAR) > delegate. BOTH pane tiers go
# through the signature latch — see the PANE-NOTICE TIER block up top: fire
# once per window signature, re-arm only after swarm-reauth promotes the
# pending signature on a successful re-auth (or the window rolls).
if [ "$OR_POLL" -eq 1 ]; then
  # TRANSCRIPT tier first — the durable record outranks the visual rendering.
  if xscript_tier_enabled && _xs="$(transcript_limit_scan)"; then
    _xswarm="$(printf '%s' "$_xs" | cut -f1)"
    _xts="$(printf '%s' "$_xs" | cut -f2)"
    _xbucket="$(printf '%s' "$_xs" | cut -f3)"
    _sig="transcript rate_limit $_xswarm $_xbucket"
    if pane_tier_suppressed "$_sig"; then
      printf '%s: transcript rate_limit suppressed (answered window / cooldown) — swarm %s throttled at %s; if it persists past the re-auth it re-fires hourly and the stuck-pane alerter names it. Delegating to the poll.\n' "$PROG" "$_xswarm" "$_xts" >&2
    elif ! pane_tier_arm "$_sig"; then
      printf '%s: WARNING — cannot persist the pane-signal latch (%s unwritable); NOT firing the transcript tier. Delegating to the poll.\n' "$PROG" "$STATE_DIR" >&2
    else
      if [ "$JSON" -eq 1 ]; then
        LIMIT_SWARM="$_xswarm"
        emit_json "AT" "transcript-limit" "rate_limit event at $_xts"
      else
        printf '%s: AT-LIMIT (TRANSCRIPT record) — swarm %s logged an API rate_limit event at %s (within %ss). The lead is being throttled on ITS account regardless of what the /usage probe reads.\n' "$PROG" "$_xswarm" "$_xts" "$XSCRIPT_WINDOW"
      fi
      exit 20
    fi
  fi
  if [ "$REAL_VERDICT" = "AT" ]; then
    _sig="$(pane_signature "$LIMIT_DETAIL")"
    if pane_tier_suppressed "$_sig"; then
      # Suppression prose goes to STDERR: in --json mode stdout must stay the
      # delegated poll's clean JSON.
      printf '%s: pane cap suppressed (latched/answered window, re-auth cooldown, or re-prompt cooldown) — a lead still showing it needs a manual nudge (see the stuck-pane alerter). Delegating to the poll.\n' "$PROG" >&2
    elif ! pane_tier_arm "$_sig"; then
      printf '%s: WARNING — cannot persist the pane-signal latch (%s unwritable); NOT firing the pane tier (an unlatched fire would re-prompt every tick). Delegating to the poll.\n' "$PROG" "$STATE_DIR" >&2
    else
      if [ "$JSON" -eq 1 ]; then emit_json "AT" "real-limit" "$LIMIT_DETAIL"
      else printf '%s: AT-LIMIT (REAL signal) — swarm %s pane shows: %s\n' "$PROG" "${LIMIT_SWARM:-?}" "${LIMIT_DETAIL:-<limit message>}"; fi
      exit 20
    fi
  elif [ -n "$NOTICE_LINES" ] && notice_qualifies "$NOTICE_LINES"; then
    _sig="$(pane_signature "$NOTICE_LINES")"
    # Evidence line = the QUALIFYING line: highest percentage, else the first
    # (no-percent Approaching form).
    _first="$(printf '%s\n' "$NOTICE_LINES" | grep -v '^$' | awk '{
      p=0; if (match($0, /[0-9]{1,3}%/)) p=substr($0, RSTART, RLENGTH-1)+0
      if (p>=best) { best=p; line=$0 } } END { print line }')"
    if pane_tier_suppressed "$_sig"; then
      printf '%s: pane notice suppressed (latched/answered window, re-auth cooldown, or re-prompt cooldown) — delegating to the poll.\n' "$PROG" >&2
    elif ! pane_tier_arm "$_sig"; then
      printf '%s: WARNING — cannot persist the pane-signal latch (%s unwritable); NOT firing the pane tier. Delegating to the poll.\n' "$PROG" "$STATE_DIR" >&2
    else
      if [ "$JSON" -eq 1 ]; then
        # emit_json reads $LIMIT_SWARM for the "swarm" field; for a notice the
        # right attribution is the (first) notice-bearing swarm, not the cap
        # scan's empty LIMIT_SWARM.
        _ns="${NOTICE_SWARMS# }"; LIMIT_SWARM="${_ns%% *}"
        emit_json "NEAR" "pane-notice" "$_first"
      else printf '%s: NEAR (PANE notice) — swarm%s pane shows: %s (threshold %s%%)\n' "$PROG" "${NOTICE_SWARMS:-?}" "$_first" "$NEAR_THRESHOLD"; fi
      exit 10
    fi
  fi
  # No pane signal fired (none seen, below threshold, or latched): defer to the
  # percentage poller and pass its verdict straight through — NEAR/OK/UNKNOWN/
  # error all flow from there. The poll tier is never latched.
  if [ "$JSON" -eq 1 ]; then
    sh -c "$POLL_INNER --json" ; exit $?
  else
    printf '%s: no REAL limit observed (real=%s) — delegating to burn-proxy poller.\n' "$PROG" "$REAL_VERDICT"
    sh -c "$POLL_INNER" ; exit $?
  fi
fi

# ── real-signal-only mode ────────────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  emit_json "$REAL_VERDICT" "real-limit" "$LIMIT_DETAIL"
else
  case "$REAL_VERDICT" in
    AT)      printf '%s: AT-LIMIT (REAL signal) — swarm %s pane shows: %s\n' "$PROG" "${LIMIT_SWARM:-?}" "${LIMIT_DETAIL:-<limit message>}" ;;
    OK)      printf '%s: OK (REAL signal) — no live swarm pane shows a usage-limit message.\n' "$PROG" ;;
    UNKNOWN) printf '%s: UNKNOWN — could not observe any live swarm pane (no tmux / no live sessions). Yielding (no AT claimed).\n' "$PROG" ;;
  esac
fi
exit "$REAL_CODE"
