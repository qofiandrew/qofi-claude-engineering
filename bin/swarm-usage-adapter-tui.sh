#!/usr/bin/env bash
# swarm-usage-adapter-tui.sh — emit the swarm-usage-poll PROBE SCHEMA from the
# AUTHORITATIVE source: the Claude Code TUI's /usage panel, scraped from an
# IDLE swarm pane over tmux. This replaces the ccusage token-burn proxy
# (swarm-usage-adapter-ccusage.sh) as the default detector.
#
# ── WHY THE TOKEN PROXY IS WRONG (the operator's falsifier, confirmed) ───────
# ccusage counts transcript tokens, but CACHE READS DO NOT COUNT against the
# Max rate limit — so on cache-heavy workloads (this fleet) the proxy
# over-reports burn wildly. Observed on this machine 2026-07-09: proxy said
# weekly 97.5%; /usage said weekly 6%. The ccusage adapter's own header named
# this falsifier ("an endpoint that returns the true Max cap % would make the
# budget-ratio estimate obsolete — replace, don't extend"). /usage IS that
# source: exact percentages for the 5h session window and the weekly windows,
# straight from Anthropic. This adapter replaces; it does not extend.
#
# ── WHAT /usage RENDERS (observed 2026-07-09, Claude Code v2.1.205) ──────────
#     Current session
#     █████████████                                      26% used
#     Resets 8pm (America/Buenos_Aires)
#
#     Current week (all models)
#     ███                                                6% used
#     Resets Jul 10 at 5am (America/Buenos_Aires)
#
#     Current week (Fable)
#     █▌                                                 3% used
#     Resets Jul 10 at 5am (America/Buenos_Aires)
# The dialog footer shows "Esc to cancel"; Escape closes it cleanly ("Settings
# dialog dismissed"). Section headers + "% used" lines + "Resets …" hints are
# the parse surface (all pattern seams below). WEEKLY = the MAX across every
# "Current week" section — whichever weekly window (all-models or per-model)
# is closest to its cap is the one that will stall the fleet.
#
# ── THE HEIGHT PROBLEM (why we resize) ───────────────────────────────────────
# The /usage panel is TALLER than a headless swarm pane (80x24): the window
# "% used" bars render at the TOP of the panel, scrolled ABOVE the visible 24
# rows, so a plain capture only sees the panel's bottom (contributing-factors)
# and finds no percentages. The dialog is not scrollable (PageUp/Up do nothing).
# So we TEMPORARILY grow the pane to SWARM_USAGE_TUI_ROWS (default 60), capture
# the now-visible top, then RESTORE the original geometry. This is safe because
# swarm panes are HEADLESS (the operator's surface is Discord, not tmux attach
# — doctrine), the pane is IDLE, and a trap restores the size on EVERY exit
# path. Panes already tall enough are not resized.
#
# ── THE PANE DISCIPLINE (never interrupt work) ───────────────────────────────
#   * Only an IDLE pane is probed (pane_working == 1). Working or unreadable
#     panes are skipped; if NO live idle pane exists we emit NOTHING and exit 1
#     — swarm-usage-poll classifies that as UNKNOWN, which is fail-safe (the
#     tick does nothing this cycle and retries next tick).
#   * The idle check is re-run immediately before keys are sent (narrows the
#     idle->turn-starts race to milliseconds).
#   * FRESHNESS GATE (the swarm-login-relay lesson): the panel is only parsed
#     when the count of "% used" lines EXCEEDS the pre-/usage baseline — stale
#     pane content containing usage-ish text can never satisfy the scrape.
#   * Every exit path after /usage was sent restores the pane:
#       - parsed OK            -> Escape (closes the dialog)
#       - timeout, dialog open -> Escape (closes the dialog)
#       - timeout, turn RUNNING (a message landed mid-probe and the pane shows
#         "esc to interrupt") -> C-u only (clears any un-submitted input);
#         Escape here would INTERRUPT the turn, so we never send it. If /usage
#         did submit, its dialog will sit until the next probe's stale-dialog
#         self-heal (below) closes it.
#       - a stale dialog left open reads as idle with a non-zero baseline; the
#         freshness gate then times out and the Escape path closes it — the
#         NEXT tick probes a clean pane (self-healing).
#
# ── OUTPUT (the swarm-usage-poll schema; see swarm-usage-poll.sh header) ─────
#   {"five_hour":{"used_pct":26,"reset_hint":"8pm (America/Buenos_Aires)"},
#    "weekly":{"used_pct":6,"reset_hint":"Jul 10 at 5am (America/Buenos_Aires)"},
#    "account":"default"}
#
# ── OPERATOR WIRING ──────────────────────────────────────────────────────────
#   SWARM_USAGE_PROBE='bash /path/to/bin/swarm-usage-adapter-tui.sh'
#   (in launchd/rotate-tick.env.local; no token budgets needed — the
#   percentages are Anthropic's own.)
#
# ── ENV (all overridable; tests inject these) ────────────────────────────────
#   SWARM_TMUX_BIN            tmux binary. Default "tmux".
#   SWARM_TMUX_PREFIX         session prefix. Default "swarm".
#   SWARM_USAGE_TUI_SESSION   probe THIS exact tmux session (bypasses
#                             swarm.conf; tests / manual runs). Default unset.
#   SWARM_USAGE_TUI_SWARM     pin the probe to one swarm.conf row by name.
#                             Default unset = first live idle swarm wins.
#   SWARM_USAGE_TUI_TIMEOUT   seconds to wait for the panel. Default 12.
#   SWARM_USAGE_TUI_POLL      seconds between captures. Default 1.
#   SWARM_USAGE_TUI_ROWS      rows to grow the pane to so the panel top fits.
#                             Default 60. A pane already >= this is not resized.
#   SWARM_USAGE_TUI_SESSION_PAT  header marking the 5h window section.
#                             Default "current session" (case-insensitive).
#   SWARM_USAGE_TUI_WEEK_PAT  header marking a weekly section. Default
#                             "current week" (case-insensitive).
#   SWARM_USAGE_ACCOUNT       "account" string stamped into the payload.
#                             Default "default" (shared keychain account).
#
# Exit codes:
#   0 — payload emitted (both/either window parsed).
#   1 — fail-safe: no live idle pane, panel never rendered fresh, or parse
#       failed. NOTHING emitted -> poll says UNKNOWN -> tick does nothing.
#   2 — usage/config error (bad flag, bad timeout).
#
# This script reads percentages only. It never reads, prints, or logs a
# credential or token value. bash 3.2-safe (macOS default). CWD-independent.

set -uo pipefail

PROG="swarm-usage-adapter-tui"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # swarm_conf_parse_line, pane_working

usage() { sed -n '1,95p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    *) echo "$PROG: unknown arg: $1" >&2; usage 2 ;;
  esac
done

TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TIMEOUT="${SWARM_USAGE_TUI_TIMEOUT:-12}"
POLL="${SWARM_USAGE_TUI_POLL:-1}"
ROWS="${SWARM_USAGE_TUI_ROWS:-60}"
SESSION_PAT="${SWARM_USAGE_TUI_SESSION_PAT:-current session}"
WEEK_PAT="${SWARM_USAGE_TUI_WEEK_PAT:-current week}"
ACCOUNT="${SWARM_USAGE_ACCOUNT:-default}"

case "$TIMEOUT" in ''|*[!0-9]*) echo "$PROG: SWARM_USAGE_TUI_TIMEOUT must be an integer (got '$TIMEOUT')" >&2; exit 2 ;; esac
case "$POLL" in ''|.|*[!0-9.]*|*.*.*) echo "$PROG: SWARM_USAGE_TUI_POLL must be a number (got '$POLL')" >&2; exit 2 ;; esac
case "$ROWS" in ''|*[!0-9]*) echo "$PROG: SWARM_USAGE_TUI_ROWS must be an integer (got '$ROWS')" >&2; exit 2 ;; esac

fail_safe() { echo "$PROG: $1 — emitting nothing (poll resolves UNKNOWN, fail-safe)" >&2; exit 1; }

command -v "$TMUX_BIN" >/dev/null 2>&1 || fail_safe "tmux binary '$TMUX_BIN' not found"

# ---------------------------------------------------------------------------
# Pick the pane: explicit session seam, else first live IDLE swarm.conf row.
# ---------------------------------------------------------------------------
SESS=""
if [ -n "${SWARM_USAGE_TUI_SESSION:-}" ]; then
  SESS="$SWARM_USAGE_TUI_SESSION"
  "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null || fail_safe "session '$SESS' (SWARM_USAGE_TUI_SESSION) does not exist"
  pane_working "$SESS" "$TMUX_BIN"; _pw=$?
  [ "$_pw" -eq 1 ] || fail_safe "session '$SESS' is not idle (pane_working rc=$_pw); refusing to interject"
else
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    [ -z "$SWARM_CONF_F_NAME" ] && continue
    if [ -n "${SWARM_USAGE_TUI_SWARM:-}" ] && [ "$SWARM_CONF_F_NAME" != "$SWARM_USAGE_TUI_SWARM" ]; then
      continue
    fi
    _s="${PREFIX}-${SWARM_CONF_F_NAME}"
    "$TMUX_BIN" has-session -t "$_s" 2>/dev/null || continue
    pane_working "$_s" "$TMUX_BIN"; _pw=$?
    # Only a confirmed-IDLE pane may be probed. Working (0) and uncertain (2)
    # are both skipped — we never interject into a pane we can't read.
    [ "$_pw" -eq 1 ] || continue
    SESS="$_s"
    break
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  [ -z "$SESS" ] && fail_safe "no live IDLE swarm pane available to probe"
fi

pane_capture() { "$TMUX_BIN" capture-pane -p -J -t "$SESS" 2>/dev/null; }

# ── Geometry save/grow/restore (see "THE HEIGHT PROBLEM" above) ──────────────
# The /usage panel top only fits in a tall pane. We grow the window, and a trap
# restores the exact prior geometry on EVERY exit — a killed probe must never
# strand a swarm pane at the wrong size. window-size may be a window-level
# option OR inherited (empty); we restore it faithfully either way.
RESIZED=0
ORIG_ROWS=""
ORIG_WSZ=""
ORIG_WSZ_SET=0
restore_geometry() {
  [ "$RESIZED" -eq 1 ] || return 0
  [ -n "$ORIG_ROWS" ] && "$TMUX_BIN" resize-window -t "$SESS" -y "$ORIG_ROWS" >/dev/null 2>&1
  if [ "$ORIG_WSZ_SET" -eq 1 ]; then
    "$TMUX_BIN" set-option -t "$SESS" -w window-size "$ORIG_WSZ" >/dev/null 2>&1
  else
    "$TMUX_BIN" set-option -t "$SESS" -uw window-size >/dev/null 2>&1
  fi
  RESIZED=0
}
grow_pane() {
  ORIG_ROWS="$("$TMUX_BIN" display -t "$SESS" -p '#{window_height}' 2>/dev/null)"
  case "$ORIG_ROWS" in ''|*[!0-9]*) ORIG_ROWS="" ; return 1 ;; esac
  # Already tall enough (e.g. an operator attached at a big terminal): no resize.
  [ "$ORIG_ROWS" -ge "$ROWS" ] && return 0
  # Capture the window-size option state so we can restore its exact prior mode.
  if ORIG_WSZ="$("$TMUX_BIN" show-options -t "$SESS" -wv window-size 2>/dev/null)" && [ -n "$ORIG_WSZ" ]; then
    ORIG_WSZ_SET=1
  else
    ORIG_WSZ_SET=0
  fi
  "$TMUX_BIN" set-option -t "$SESS" -w window-size manual >/dev/null 2>&1 || return 1
  RESIZED=1   # from here the trap must fire even if resize itself half-applied
  "$TMUX_BIN" resize-window -t "$SESS" -y "$ROWS" >/dev/null 2>&1 || return 1
  return 0
}

# count_pct_lines FRAME — how many lines carry a "NN% used" reading. The
# freshness gate compares this against the pre-/usage baseline.
count_pct_lines() {
  local n
  n="$(printf '%s\n' "$1" | grep -c -i -E '[0-9]+% used' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Probe: baseline -> /usage -> wait for a FRESH panel -> parse -> Escape.
# ---------------------------------------------------------------------------
# Restore the pane's geometry on EVERY exit from here on (the trap is the
# safety net; the happy path also restores explicitly, right after the panel is
# captured, so the pane isn't left tall during the parse).
trap restore_geometry EXIT

# Grow the (confirmed-idle) pane so the panel's top fits. A failure to resize is
# non-fatal: a too-short pane simply yields no fresh panel -> UNKNOWN, fail-safe.
grow_pane || echo "$PROG: NOTE — could not grow pane '$SESS'; the /usage panel top may not fit (will fail-safe to UNKNOWN)." >&2

BASELINE="$(pane_capture)"
BASE_N="$(count_pct_lines "$BASELINE")"

# SELF-HEAL a pre-existing /usage panel. The panel is stateful: if a prior probe
# (or a rapid back-to-back invocation — observe mode polls TWICE per tick) left
# the dialog open, the baseline already shows "% used" lines and the freshness
# gate below could NEVER exceed that count -> guaranteed timeout -> UNKNOWN. If
# the pane is idle AND already showing a panel, dismiss it and re-baseline so
# THIS probe reads a fresh one instead of failing safe until next tick.
if [ "$BASE_N" -gt 0 ] && printf '%s' "$BASELINE" | grep -q -i -F "$SESSION_PAT"; then
  "$TMUX_BIN" send-keys -t "$SESS" Escape 2>/dev/null || true
  sleep "$POLL"
  BASELINE="$(pane_capture)"
  BASE_N="$(count_pct_lines "$BASELINE")"
fi

# Narrow the idle->working race: re-verify idleness at the last instant.
pane_working "$SESS" "$TMUX_BIN"; _pw=$?
[ "$_pw" -eq 1 ] || fail_safe "pane '$SESS' stopped being idle before the probe"

# C-u clears any half-typed prompt content so "/usage" lands clean.
"$TMUX_BIN" send-keys -t "$SESS" C-u "/usage" Enter 2>/dev/null \
  || fail_safe "could not send keys to '$SESS'"

FRAME=""
_ok=0
_deadline=$((SECONDS + TIMEOUT))
while :; do
  FRAME="$(pane_capture)"
  if [ "$(count_pct_lines "$FRAME")" -gt "$BASE_N" ] \
     && printf '%s' "$FRAME" | grep -q -i -F "$SESSION_PAT"; then
    _ok=1
    break
  fi
  [ "$SECONDS" -ge "$_deadline" ] && break
  sleep "$POLL"
done

if [ "$_ok" -ne 1 ]; then
  # Restore the pane WITHOUT ever interrupting a turn: Escape only if the
  # dialog (or an idle prompt) is showing; a running turn gets C-u only.
  _now="$(pane_capture)"
  if printf '%s' "$_now" | grep -qF 'esc to interrupt'; then
    "$TMUX_BIN" send-keys -t "$SESS" C-u 2>/dev/null || true
    echo "$PROG: NOTE — a turn started mid-probe in '$SESS'; cleared input only (no Escape — it would interrupt the turn)." >&2
  else
    "$TMUX_BIN" send-keys -t "$SESS" Escape 2>/dev/null || true
  fi
  fail_safe "no fresh /usage panel within ${TIMEOUT}s in '$SESS'"
fi

# Panel parsed below; close the dialog FIRST so the pane is never left inside
# it even if parsing dies, then restore the pane's size now (the FRAME is
# already captured, so the slow parse runs against a restored pane).
"$TMUX_BIN" send-keys -t "$SESS" Escape 2>/dev/null || true
restore_geometry

# ---------------------------------------------------------------------------
# Parse: section headers -> "% used" -> "Resets …" hints. WEEKLY = max across
# every weekly section (the binding constraint is whichever weekly window is
# closest to its cap).
# ---------------------------------------------------------------------------
# The frame travels via the environment, NOT a pipe: `python3 - <<'PY'` reads
# its SCRIPT from stdin, so a `printf … | python3 -` pipe would be swallowed by
# the heredoc and sys.stdin.read() would see nothing. SWARM_USAGE_TUI_FRAME
# carries the capture; it holds only usage percentages, never a secret.
PAYLOAD="$(SWARM_USAGE_TUI_FRAME="$FRAME" python3 - "$SESSION_PAT" "$WEEK_PAT" "$ACCOUNT" <<'PY'
import json, os, re, sys

session_pat = sys.argv[1].lower()
week_pat    = sys.argv[2].lower()
account     = sys.argv[3]

pct_re   = re.compile(r'([0-9]{1,3})%\s*used', re.I)
reset_re = re.compile(r'^\s*Resets\s+(.+?)\s*$', re.I)

five = None   # {"used_pct": int, "reset_hint": str}
week = None   # worst (max) weekly window
mode = None   # which section the NEXT pct/reset lines belong to
last = None   # the window dict awaiting a reset hint

for raw in os.environ.get("SWARM_USAGE_TUI_FRAME", "").splitlines():
    low = raw.lower()
    if session_pat in low:
        mode = "session"; continue
    if week_pat in low:
        mode = "week"; continue
    m = pct_re.search(raw)
    if m and mode:
        pct = int(m.group(1))
        if pct > 100: pct = 100
        entry = {"used_pct": pct}
        if mode == "session":
            if five is None:      # first session reading wins
                five = entry; last = entry
            else:
                last = None
        else:
            if week is None or pct > week["used_pct"]:
                week = entry; last = entry
            else:
                last = None
        mode_used, mode = mode, None   # one reading per header
        continue
    r = reset_re.match(raw)
    if r and last is not None:
        last.setdefault("reset_hint", r.group(1))
        last = None

if five is None and week is None:
    sys.exit(1)   # nothing parseable -> caller fails safe

out = {}
if five is not None: out["five_hour"] = five
if week is not None: out["weekly"] = week
out["account"] = account
print(json.dumps(out))
PY
)" || fail_safe "panel rendered but no percentage could be parsed from '$SESS'"

printf '%s\n' "$PAYLOAD"
exit 0
