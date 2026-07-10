#!/usr/bin/env bash
# swarm-usage-adapter-tui.sh — emit the swarm-usage-poll PROBE SCHEMA from the
# AUTHORITATIVE source: the Claude Code TUI's /usage panel. It drives /usage in
# a DEDICATED, ISOLATED probe session — never a production CTO pane — so it can
# never interrupt a lead's Discord/CTO coordination. Replaces the ccusage
# token-burn proxy as the default detector.
#
# ── WHY THE TOKEN PROXY IS WRONG (the operator's falsifier, confirmed) ───────
# ccusage counts transcript tokens, but CACHE READS DO NOT COUNT against the
# Max rate limit — so on cache-heavy workloads (this fleet) the proxy
# over-reports burn wildly (observed: proxy weekly 97.5% vs /usage 6%). /usage
# reports Anthropic's OWN exact percentages for the 5h session window and the
# weekly windows. This adapter replaces the proxy; it does not extend it.
#
# ── WHY A DEDICATED SESSION (never touch a CTO pane) ─────────────────────────
# /usage is a slash command that needs a live claude TUI. An earlier design
# drove it in an idle SWARM lead pane, but that risked interfering with the
# lead's Discord coordination: the probe holds the pane for seconds, and its
# dialog-closing Escape (Claude Code's interrupt key) could clip a turn that a
# just-arrived Discord message started. Discord I/O itself travels over the MCP
# channel (bridge/server.ts), NOT the keyboard, so a message is never lost —
# but "never interrupt a CTO" must be PROVABLE, not merely unlikely. So this
# adapter uses its OWN throwaway session (SWARM_USAGE_PROBE_SESSION, default
# "swarm-usage-probe"): a plain `claude` on the DEFAULT account that is never
# bound to a Discord channel and never takes a turn. /usage there is fully
# isolated. The default account is the fleet's shared keychain state, so its
# /usage numbers equal any default-account lead's — the reading is identical,
# the blast radius is zero.
#
# The session is LONG-LIVED (created once, reused every tick) and created at
# SWARM_USAGE_TUI_ROWS height so the panel top always fits — no pane resizing.
# It is NOT in swarm.conf, so swarm-watch and the WORKING rails never count it.
# (A no-arg `swarm-up down` DOES glob-kill every `swarm-*` session including
# this probe — harmless: it is stateless and recreated on the next poll. And
# swarm-reauth.sh kills it DELIBERATELY after a successful in-place re-auth so
# the next poll reads the NEW account.) If it is missing or unhealthy (crash,
# host reboot, stale credential) the adapter recreates it and retries once.
#
# ── OUTPUT (the swarm-usage-poll schema; see swarm-usage-poll.sh header) ─────
#   {"five_hour":{"used_pct":26,"reset_hint":"8pm (…)"},
#    "weekly":{"used_pct":6,"reset_hint":"Jul 10 at 5am (…)"},
#    "account":"default"}
#
# ── OPERATOR WIRING ──────────────────────────────────────────────────────────
#   SWARM_USAGE_PROBE='bash /path/to/bin/swarm-usage-adapter-tui.sh'
#   (in launchd/rotate-tick.env.local; no token budgets — the % are exact.)
#
# ── ENV (all overridable; tests inject these) ────────────────────────────────
#   SWARM_TMUX_BIN            tmux binary. Default "tmux".
#   SWARM_USAGE_PROBE_SESSION the dedicated session name. Default
#                             "swarm-usage-probe".
#   SWARM_USAGE_PROBE_CWD     cwd to launch the probe claude in. MUST be a
#                             directory claude already TRUSTS (else the launch
#                             blocks on a trust prompt). Default: $SWARM_HOME
#                             (trusted — swarm commands run claude here).
#   SWARM_USAGE_PROBE_LAUNCH  the launch command line run inside the session.
#                             Default: "claude" (plain — NO dev-channels, NO
#                             plugin, NO labeled account; API keys are unset
#                             first so it uses the Max keychain/default account).
#                             Tests point this at a stub TUI.
#   SWARM_USAGE_TUI_SESSION   probe THIS exact existing session and do NOT
#                             create/destroy anything (manual runs / tests).
#                             When set, the dedicated-session lifecycle is
#                             bypassed entirely.
#   SWARM_USAGE_PROBE_READY_PAT  idle-ready marker in the launched TUI. Default
#                             "for agents|for shortcuts|auto mode" (the idle
#                             prompt footer). A freshly-created DETACHED tmux
#                             session often captures BLANK until a redraw, so the
#                             launch loop nudges Ctrl-L each poll until this
#                             marker appears.
#   SWARM_USAGE_PROBE_TRUST_PAT  a trust/confirm prompt to accept with Enter
#                             during launch. Default
#                             "trust the files|Do you trust|Yes, proceed".
#   SWARM_USAGE_PROBE_LAUNCH_TIMEOUT  seconds to wait for readiness. Default 40.
#   SWARM_USAGE_TUI_ROWS      probe session height (panel top must fit).
#                             Default 60.
#   SWARM_USAGE_TUI_COLS      probe session width. Default 200.
#   SWARM_USAGE_TUI_TIMEOUT   seconds to wait for the /usage panel. Default 12.
#   SWARM_USAGE_TUI_POLL      seconds between captures. Default 1.
#   SWARM_USAGE_TUI_SESSION_PAT  header marking the 5h window. Default
#                             "current session" (case-insensitive).
#   SWARM_USAGE_TUI_WEEK_PAT  header marking a weekly section. Default
#                             "current week" (case-insensitive). BOTH the
#                             session and a weekly header must be present before
#                             a panel is accepted (prevents a half-rendered
#                             capture from yielding a weekly-missing reading
#                             that would flap across ticks).
#   SWARM_USAGE_ACCOUNT       "account" string stamped into the payload.
#                             Default "default" (the shared keychain account).
#
# Exit codes:
#   0 — payload emitted.
#   1 — fail-safe: probe session unavailable/unhealthy after a retry, panel
#       never rendered fresh, or parse failed. NOTHING emitted -> poll UNKNOWN
#       -> the tick does nothing this cycle and retries next tick.
#   2 — usage/config error (bad flag, bad timeout/rows).
#
# Reads percentages only — never a credential/token value. bash 3.2-safe.

set -uo pipefail

PROG="swarm-usage-adapter-tui"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '1,110p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    *) echo "$PROG: unknown arg: $1" >&2; usage 2 ;;
  esac
done

TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
PROBE_SESSION="${SWARM_USAGE_PROBE_SESSION:-swarm-usage-probe}"
PROBE_CWD="${SWARM_USAGE_PROBE_CWD:-$SWARM_HOME}"
PROBE_LAUNCH="${SWARM_USAGE_PROBE_LAUNCH:-claude}"
READY_PAT="${SWARM_USAGE_PROBE_READY_PAT:-for agents|for shortcuts|auto mode}"
TRUST_PAT="${SWARM_USAGE_PROBE_TRUST_PAT:-trust the files|Do you trust|Yes, proceed}"
LAUNCH_TIMEOUT="${SWARM_USAGE_PROBE_LAUNCH_TIMEOUT:-40}"
ROWS="${SWARM_USAGE_TUI_ROWS:-60}"
COLS="${SWARM_USAGE_TUI_COLS:-200}"
TIMEOUT="${SWARM_USAGE_TUI_TIMEOUT:-12}"
POLL="${SWARM_USAGE_TUI_POLL:-1}"
SESSION_PAT="${SWARM_USAGE_TUI_SESSION_PAT:-current session}"
WEEK_PAT="${SWARM_USAGE_TUI_WEEK_PAT:-current week}"
ACCOUNT="${SWARM_USAGE_ACCOUNT:-default}"

for _v in "$TIMEOUT" "$LAUNCH_TIMEOUT" "$ROWS" "$COLS"; do
  case "$_v" in ''|*[!0-9]*) echo "$PROG: timeout/rows/cols must be integers (got '$_v')" >&2; exit 2 ;; esac
done
case "$POLL" in ''|.|*[!0-9.]*|*.*.*) echo "$PROG: SWARM_USAGE_TUI_POLL must be a number (got '$POLL')" >&2; exit 2 ;; esac

fail_safe() { echo "$PROG: $1 — emitting nothing (poll resolves UNKNOWN, fail-safe)" >&2; exit 1; }
command -v "$TMUX_BIN" >/dev/null 2>&1 || fail_safe "tmux binary '$TMUX_BIN' not found"

# Whether we own the session's lifecycle. With SWARM_USAGE_TUI_SESSION set we
# probe an existing session and never create/kill it.
EXPLICIT_SESSION="${SWARM_USAGE_TUI_SESSION:-}"
if [ -n "$EXPLICIT_SESSION" ]; then
  SESS="$EXPLICIT_SESSION"
else
  SESS="$PROBE_SESSION"
fi

pane_capture() { "$TMUX_BIN" capture-pane -p -J -t "$SESS" 2>/dev/null; }

match_pat() { printf '%s' "$1" | grep -q -i -E "$2" 2>/dev/null; }

# session_ready — the dedicated session exists AND shows an idle claude prompt
# (ready marker present, not mid-turn). A crashed/exited claude (shell prompt)
# fails this, triggering recreation.
session_ready() {
  "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null || return 1
  local frame; frame="$(pane_capture)"
  [ -z "$frame" ] && return 1
  match_pat "$frame" "$READY_PAT" || return 1
  printf '%s' "$frame" | grep -qF 'esc to interrupt' && return 1   # mid-turn: not ready
  return 0
}

# create_probe_session — (re)create the dedicated probe session: a plain claude
# on the default account, in a trusted cwd, at ROWS height. Returns 0 when the
# TUI is idle-ready. Only used when we OWN the lifecycle (no explicit session).
create_probe_session() {
  "$TMUX_BIN" kill-session -t "$SESS" 2>/dev/null || true
  "$TMUX_BIN" new-session -d -s "$SESS" -x "$COLS" -y "$ROWS" 2>/dev/null \
    || { echo "$PROG: could not create probe session '$SESS'" >&2; return 1; }
  # API keys unset so the probe uses the Max keychain (default account), matching
  # the fleet's shared credential. exec so the claude process replaces the shell.
  "$TMUX_BIN" send-keys -t "$SESS" "cd $(printf '%q' "$PROBE_CWD") && unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN && exec $PROBE_LAUNCH" Enter 2>/dev/null || true

  local _deadline=$((SECONDS + LAUNCH_TIMEOUT)) _trusted=0 _frame
  while :; do
    _frame="$(pane_capture)"
    # Ready = the idle footer marker is showing and no turn is running.
    if match_pat "$_frame" "$READY_PAT" && ! printf '%s' "$_frame" | grep -qF 'esc to interrupt'; then
      return 0
    fi
    if [ "$_trusted" -eq 0 ] && match_pat "$_frame" "$TRUST_PAT"; then
      # Accept a one-time trust/confirm prompt (default option is "Yes, proceed").
      "$TMUX_BIN" send-keys -t "$SESS" Enter 2>/dev/null || true
      _trusted=1
    else
      # A detached session frequently captures BLANK until a redraw; Ctrl-L at
      # the prompt is a harmless repaint nudge (never submits input).
      "$TMUX_BIN" send-keys -t "$SESS" C-l 2>/dev/null || true
    fi
    if [ "$SECONDS" -ge "$_deadline" ]; then
      echo "$PROG: probe session '$SESS' did not become idle-ready within ${LAUNCH_TIMEOUT}s." >&2
      "$TMUX_BIN" kill-session -t "$SESS" 2>/dev/null || true
      return 1
    fi
    sleep "$POLL"
  done
}

# ensure_session — reuse a healthy probe session, else (re)create it. For an
# explicit external session we only verify it exists (never create/kill it).
ensure_session() {
  if [ -n "$EXPLICIT_SESSION" ]; then
    "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null || fail_safe "session '$SESS' (SWARM_USAGE_TUI_SESSION) does not exist"
    return 0
  fi
  session_ready && return 0
  create_probe_session || fail_safe "could not stand up a healthy probe session '$SESS'"
}

# count_pct_lines FRAME — number of lines carrying a "NN% used" reading.
count_pct_lines() {
  local n; n="$(printf '%s\n' "$1" | grep -c -i -E '[0-9]+% used' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# scrape_usage — drive /usage in $SESS and print the schema JSON, or fail (1).
# Freshness-gated against a pre-/usage baseline; requires BOTH the session and a
# weekly header before accepting; self-heals a stale-open panel; closes the
# dialog on every path. NO idle-guard/resize needed — the probe session is ours,
# always idle, created tall.
scrape_usage() {
  local BASELINE BASE_N FRAME _deadline _frame _ok=0

  # Nudge a repaint first: a freshly-created DETACHED session can capture BLANK
  # until a redraw, which would make the baseline (and the poll) miss content.
  # Ctrl-L is a harmless redraw at the prompt AND leaves an open /usage panel
  # intact (verified), so it is safe on every iteration below too.
  "$TMUX_BIN" send-keys -t "$SESS" C-l 2>/dev/null || true
  sleep "$POLL"
  BASELINE="$(pane_capture)"
  BASE_N="$(count_pct_lines "$BASELINE")"
  # Dismiss a stale-open /usage panel so the freshness gate can fire this run.
  if [ "$BASE_N" -gt 0 ] && match_pat "$BASELINE" "$SESSION_PAT"; then
    "$TMUX_BIN" send-keys -t "$SESS" Escape 2>/dev/null || true
    sleep "$POLL"
    BASELINE="$(pane_capture)"; BASE_N="$(count_pct_lines "$BASELINE")"
  fi

  "$TMUX_BIN" send-keys -t "$SESS" C-u "/usage" Enter 2>/dev/null || return 1

  _deadline=$((SECONDS + TIMEOUT))
  while :; do
    _frame="$(pane_capture)"
    # Accept a FRESH panel only when it EXCEEDS the baseline "% used" count AND
    # shows BOTH the session and a weekly header — a half-rendered capture
    # (session drawn, weekly not yet) must not yield a weekly-missing reading.
    if [ "$(count_pct_lines "$_frame")" -gt "$BASE_N" ] \
       && match_pat "$_frame" "$SESSION_PAT" \
       && match_pat "$_frame" "$WEEK_PAT"; then
      FRAME="$_frame"; _ok=1; break
    fi
    [ "$SECONDS" -ge "$_deadline" ] && break
    "$TMUX_BIN" send-keys -t "$SESS" C-l 2>/dev/null || true   # repaint nudge (detached-session blank)
    sleep "$POLL"
  done

  # Close the dialog (idempotent; the probe session has no turn to interrupt).
  "$TMUX_BIN" send-keys -t "$SESS" Escape 2>/dev/null || true
  [ "$_ok" -eq 1 ] || return 1

  SWARM_USAGE_TUI_FRAME="$FRAME" python3 - "$SESSION_PAT" "$WEEK_PAT" "$ACCOUNT" <<'PY'
import json, os, re, sys
session_pat = sys.argv[1].lower()
week_pat    = sys.argv[2].lower()
account     = sys.argv[3]
pct_re   = re.compile(r'([0-9]{1,3})%\s*used', re.I)
reset_re = re.compile(r'^\s*Resets\s+(.+?)\s*$', re.I)
five = None; week = None; mode = None; last = None
for raw in os.environ.get("SWARM_USAGE_TUI_FRAME", "").splitlines():
    low = raw.lower()
    # A section header ends the previous window: a "Resets" hint only binds to
    # the pct line that immediately precedes it. Clearing `last` here stops a
    # MAX weekly window (whose own reset line is off-screen) from inheriting a
    # following section's reset time.
    if session_pat in low:
        mode = "session"; last = None; continue
    if week_pat in low:
        mode = "week"; last = None; continue
    m = pct_re.search(raw)
    if m and mode:
        pct = int(m.group(1))
        if pct > 100: pct = 100
        entry = {"used_pct": pct}
        if mode == "session":
            if five is None: five = entry; last = entry
            else: last = None
        else:
            if week is None or pct > week["used_pct"]: week = entry; last = entry
            else: last = None
        mode = None
        continue
    r = reset_re.match(raw)
    if r and last is not None:
        last.setdefault("reset_hint", r.group(1)); last = None
if five is None and week is None:
    sys.exit(1)
out = {}
if five is not None: out["five_hour"] = five
if week is not None: out["weekly"] = week
out["account"] = account
print(json.dumps(out))
PY
}

# ---------------------------------------------------------------------------
# Ensure the probe session, scrape, and (if we own it) recreate+retry ONCE on
# failure — covers a crashed session or a stale post-rotation credential.
# ---------------------------------------------------------------------------
ensure_session
PAYLOAD="$(scrape_usage)"; src=$?
if [ "$src" -ne 0 ] || [ -z "$PAYLOAD" ]; then
  if [ -n "$EXPLICIT_SESSION" ]; then
    fail_safe "no fresh /usage panel from '$SESS'"
  fi
  echo "$PROG: NOTE — first /usage scrape from '$SESS' failed; recreating the probe session and retrying once." >&2
  create_probe_session || fail_safe "could not recreate a healthy probe session '$SESS'"
  PAYLOAD="$(scrape_usage)"; src=$?
  { [ "$src" -ne 0 ] || [ -z "$PAYLOAD" ]; } && fail_safe "no fresh /usage panel from '$SESS' after recreate"
fi

printf '%s\n' "$PAYLOAD"
exit 0
