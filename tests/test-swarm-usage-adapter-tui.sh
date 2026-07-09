#!/usr/bin/env bash
# test-swarm-usage-adapter-tui.sh — regression tests for
# bin/swarm-usage-adapter-tui.sh, the /usage scraper that reads Anthropic's
# authoritative percentages from a DEDICATED, ISOLATED probe session (never a
# production CTO pane) and emits the swarm-usage-poll schema.
#
# SYNTHETIC-FIXTURE discipline: a MOCK tmux records every invocation and serves
# scripted capture frames; a file-backed session set makes new/kill/has-session
# behave. The panel fixture is a REAL /usage capture. No live tmux, no CTO pane,
# no credential ever touched.
#
# WHAT THIS PROTECTS:
#   1. Scrape (explicit session): /usage -> full panel -> exact schema JSON
#      (five_hour + weekly=MAX weekly window) -> dialog closed with Escape.
#   2. PARTIAL-PANEL GATE (audit: major/unsafe): a capture with the session
#      window but NO weekly section must NOT be accepted (it would drop weekly
#      and the poll would read weekly=0% -> false OK). Must wait for BOTH, or
#      fail-safe UNKNOWN — never emit a weekly-missing payload.
#   3. RESET-HINT attribution (audit: minor): a MAX weekly window whose own
#      "Resets" line is off-screen must NOT inherit a following section's reset.
#   4. Distractor safety: "NN% of your usage" lines are never window readings.
#   5. Freshness + self-heal: a stale-open panel is dismissed and a fresh one
#      read; a repaint nudge (Ctrl-L) drives detached-session captures.
#   6. Isolation: the adapter only ever sends keys to the probe session — never
#      a swarm-* CTO session.
#   7. Lifecycle: missing/unhealthy session -> create -> ready -> scrape;
#      first-scrape failure -> recreate + retry once.
#   8. Config: bad timeout/rows/poll -> exit 2.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-usage-adapter-tui.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
jf() { printf '%s' "$1" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("<BADJSON>"); sys.exit()
cur=d
for k in sys.argv[1].split("."):
    if isinstance(cur,dict) and k in cur: cur=cur[k]
    else: print("<ABSENT>"); sys.exit()
print(cur)' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/usage-tui-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-usage-adapter-tui.sh" "$FAKE_SH/bin/swarm-usage-adapter-tui.sh"
chmod +x "$FAKE_SH/bin/swarm-usage-adapter-tui.sh"
ADAPTER="$FAKE_SH/bin/swarm-usage-adapter-tui.sh"
: > "$FAKE_SH/swarm.conf"   # a probe session is NEVER in swarm.conf

# ── MOCK tmux: records invocations; file-backed session set; scripted frames ─
MOCK_TMUX="$TMP/stubbin/tmux"
MOCK_TMUX_LOG="$TMP/tmux.log"
MOCK_SESS_FILE="$TMP/sessions"
MOCK_FRAMES_DIR="$TMP/frames"
mkdir -p "$TMP/stubbin" "$MOCK_FRAMES_DIR"
: > "$MOCK_SESS_FILE"
cat > "$MOCK_TMUX" <<'EOF'
#!/usr/bin/env bash
set -u
log="${MOCK_TMUX_LOG:?}"; sf="${MOCK_SESS_FILE:?}"; frames="${MOCK_FRAMES_DIR:?}"
printf '%s\n' "$*" >> "$log"
# extract the -t or -s target session name
tgt=""; prev=""
for a in "$@"; do case "$prev" in -t|-s) tgt="$a";; esac; prev="$a"; done
case "${1:-}" in
  has-session) grep -qx "$tgt" "$sf" && exit 0 || exit 1 ;;
  new-session) grep -qx "$tgt" "$sf" || printf '%s\n' "$tgt" >> "$sf"; exit 0 ;;
  kill-session) grep -vx "$tgt" "$sf" > "$sf.tmp" 2>/dev/null || true; mv "$sf.tmp" "$sf" 2>/dev/null || true; exit 0 ;;
  send-keys) exit 0 ;;
  display) printf '%s\n' "${MOCK_PANE_ROWS:-60}"; exit 0 ;;
  capture-pane)
    fdir="$frames"; var="MOCK_FRAMES_${tgt//-/_}"; eval "alt=\${$var:-}"
    [ -n "${alt:-}" ] && [ -d "$alt" ] && fdir="$alt"
    grep -qx "$tgt" "$sf" || { exit 0; }   # dead session -> empty capture
    cfile="$fdir/.counter"; n="$(cat "$cfile" 2>/dev/null || echo 1)"
    f="$fdir/frame-$n.txt"
    if [ -f "$f" ]; then echo $((n+1)) > "$cfile"
    else
      last=0
      for ff in "$fdir"/frame-*.txt; do
        [ -f "$ff" ] || continue; num="${ff##*frame-}"; num="${num%.txt}"
        case "$num" in *[!0-9]*) continue;; esac; [ "$num" -gt "$last" ] && last="$num"
      done
      [ "$last" -eq 0 ] && exit 0; f="$fdir/frame-$last.txt"
    fi
    cat "$f"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_TMUX"

# ── Frames ───────────────────────────────────────────────────────────────────
READY='❯
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
BLANK=''
PANEL_FULL="$(cat "$ROOT/tests/fixtures/usage-panel.frame.txt")"
PANEL_PARTIAL='  Current session
  ████████  26% used
  Resets 8pm (America/Buenos_Aires)'   # NO weekly section — the unsafe partial
PANEL_MAXNORESET='  Current session
  ███ 26% used
  Resets 8pm
  Current week (all models)
  ██████ 80% used
  Current week (Fable)
  █ 4% used
  Resets Jul 15 at 2am'                # all-models 80% is MAX, its reset off-screen

lay() { local dir="$1"; shift; rm -rf "$dir"; mkdir -p "$dir"; local i=1
  for f in "$@"; do printf '%s\n' "$f" > "$dir/frame-$i.txt"; i=$((i+1)); done; }
seed_session() { printf '%s\n' "$1" >> "$MOCK_SESS_FILE"; }
reset_state() { : > "$MOCK_TMUX_LOG"; : > "$MOCK_SESS_FILE"; }
sk() { grep '^send-keys' "$MOCK_TMUX_LOG" 2>/dev/null || true; }

# scrape against an EXISTING explicit session (bypasses create/kill lifecycle)
run_explicit() {  # session frames-dir; extra env after --
  local sess="$1" fdir="$2"; shift 2
  reset_state; seed_session "$sess"
  OUT="$(
    export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX"
    export MOCK_TMUX_LOG MOCK_SESS_FILE MOCK_FRAMES_DIR="$fdir"
    export SWARM_USAGE_TUI_SESSION="$sess"
    export SWARM_USAGE_TUI_POLL=0 SWARM_USAGE_TUI_TIMEOUT=3
    "$@" bash "$ADAPTER" 2>&1
  )"; rc=$?
}

echo "=== 1) SCRAPE happy path (explicit session) -> schema JSON, Escape close ==="
lay "$MOCK_FRAMES_DIR" "$READY" "$PANEL_FULL"    # baseline(after C-l), then panel
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR"
assert_eq 0 "$rc" "scrape exits 0"
assert_eq "26" "$(jf "$OUT" five_hour.used_pct)" "five_hour parsed (26)"
assert_eq "6" "$(jf "$OUT" weekly.used_pct)" "weekly = MAX weekly window (6, not Fable 3)"
assert_eq "8pm (America/Buenos_Aires)" "$(jf "$OUT" five_hour.reset_hint)" "five_hour reset hint parsed"
assert_has "$(sk)" "swarm-usage-probe C-u /usage Enter" "sent /usage to the probe session"
assert_eq "send-keys -t swarm-usage-probe Escape" "$(sk | tail -n 1)" "closed the dialog with Escape"

echo ""
echo "=== 6) ISOLATION: keys go ONLY to the probe session, never a CTO pane ==="
assert_lacks "$(sk)" "swarm-qofi" "never sent keys to a qofi CTO pane"
assert_lacks "$(sk)" "swarm-press" "never sent keys to a press CTO pane"
badpane="$(sk | grep -v 'swarm-usage-probe' || true)"
assert_eq "" "$badpane" "every send-keys targets the probe session only"

echo ""
echo "=== 2) PARTIAL-PANEL GATE (audit: major) — weekly-missing capture is NOT accepted ==="
echo "--- 2a) partial (session only) then FULL -> waits, accepts full, weekly present ---"
lay "$MOCK_FRAMES_DIR" "$READY" "$PANEL_PARTIAL" "$PANEL_FULL"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR"
assert_eq 0 "$rc" "waits past the partial and accepts the full panel"
assert_eq "26" "$(jf "$OUT" five_hour.used_pct)" "five_hour from the full panel"
assert_eq "6" "$(jf "$OUT" weekly.used_pct)" "weekly present (partial was correctly skipped)"
echo "--- 2b) partial-ONLY (weekly never renders) -> fail-safe UNKNOWN, NO weekly-missing payload ---"
lay "$MOCK_FRAMES_DIR" "$READY" "$PANEL_PARTIAL"   # partial sticks forever
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR" env SWARM_USAGE_TUI_TIMEOUT=1
assert_eq 1 "$rc" "partial-only times out to UNKNOWN (exit 1), not a false reading"
assert_lacks "$OUT" "five_hour" "emitted NO payload (would have been weekly-missing -> false OK)"

echo ""
echo "=== 3) RESET-HINT attribution (audit: minor) — max window doesn't inherit a later reset ==="
lay "$MOCK_FRAMES_DIR" "$READY" "$PANEL_MAXNORESET"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR"
assert_eq 0 "$rc" "max-no-reset panel scrapes"
assert_eq "80" "$(jf "$OUT" weekly.used_pct)" "weekly = the 80% MAX (all-models) window"
assert_eq "<ABSENT>" "$(jf "$OUT" weekly.reset_hint)" "max window does NOT inherit Fable's reset (hint absent)"

echo ""
echo "=== 4) DISTRACTOR safety: 'NN% of your usage' lines are never window readings ==="
lay "$MOCK_FRAMES_DIR" "$READY" "$PANEL_FULL"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR"
assert_lacks "$(jf "$OUT" five_hour.used_pct)" "93" "five_hour is not a contributing-factor %"
assert_lacks "$(jf "$OUT" weekly.used_pct)" "84" "weekly is not a contributing-factor %"

echo ""
echo "=== 5) SELF-HEAL: a stale-open panel is dismissed, a fresh one read ==="
# baseline ALREADY shows a full panel -> Escape + re-baseline -> fresh panel.
lay "$MOCK_FRAMES_DIR" "$PANEL_FULL" "$READY" "$PANEL_FULL"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR"
assert_eq 0 "$rc" "stale-open panel self-heals to a fresh read"
assert_eq "26" "$(jf "$OUT" five_hour.used_pct)" "fresh panel parsed after self-heal"

echo ""
echo "=== 7) LIFECYCLE: create a missing probe session, then scrape ==="
# No session exists; the adapter must new-session, drive claude to ready, scrape.
# Frames: blank (pre-paint) -> READY (idle footer, ends readiness) -> READY
# (scrape baseline, 0 pct) -> PANEL after /usage.
reset_state
lay "$MOCK_FRAMES_DIR" "$BLANK" "$READY" "$READY" "$PANEL_FULL"
OUT="$(
  export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX"
  export MOCK_TMUX_LOG MOCK_SESS_FILE MOCK_FRAMES_DIR
  export SWARM_USAGE_TUI_POLL=0 SWARM_USAGE_TUI_TIMEOUT=3 SWARM_USAGE_PROBE_LAUNCH_TIMEOUT=3
  export SWARM_USAGE_PROBE_LAUNCH='true'   # stub launch (mock serves the frames)
  bash "$ADAPTER" 2>&1
)"; rc=$?
assert_eq 0 "$rc" "cold-create lifecycle exits 0"
assert_eq "26" "$(jf "$OUT" five_hour.used_pct)" "scraped after creating the session"
assert_has "$(sk)" "swarm-usage-probe" "created + drove the probe session"
assert_has "$(grep '^new-session' "$MOCK_TMUX_LOG")" "swarm-usage-probe" "new-session was issued for the probe"

echo ""
echo "=== 8) LIFECYCLE: first scrape fails -> recreate + retry attempted -> fail-safe ==="
# A ready session whose /usage panel never renders (only the idle footer sticks):
# scrape#1 times out, the adapter RECREATES and retries once, that also times
# out, and it fail-safes to UNKNOWN (exit 1). Proves the retry path + fail-safe.
reset_state
lay "$MOCK_FRAMES_DIR" "$READY"   # idle footer sticks; a /usage panel never appears
OUT="$(
  export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX"
  export MOCK_TMUX_LOG MOCK_SESS_FILE MOCK_FRAMES_DIR
  export SWARM_USAGE_TUI_POLL=0 SWARM_USAGE_TUI_TIMEOUT=1 SWARM_USAGE_PROBE_LAUNCH_TIMEOUT=2
  export SWARM_USAGE_PROBE_LAUNCH='true'
  bash "$ADAPTER" 2>&1
)"; rc=$?
assert_eq 1 "$rc" "unrecoverable scrape fail-safes to UNKNOWN (exit 1)"
assert_has "$OUT" "recreating the probe session" "logged the recreate-and-retry attempt"
assert_has "$(grep -c '^new-session' "$MOCK_TMUX_LOG")" "2" "issued new-session TWICE (initial create + recreate)"

echo ""
echo "=== 9) CONFIG errors ==="
reset_state; seed_session swarm-usage-probe
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR" env SWARM_USAGE_TUI_TIMEOUT=soon
assert_eq 2 "$rc" "non-integer timeout -> exit 2"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR" env SWARM_USAGE_TUI_POLL=fast
assert_eq 2 "$rc" "non-numeric poll -> exit 2"
run_explicit swarm-usage-probe "$MOCK_FRAMES_DIR" env SWARM_USAGE_TUI_ROWS=tall
assert_eq 2 "$rc" "non-integer rows -> exit 2"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
