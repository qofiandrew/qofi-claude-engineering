#!/usr/bin/env bash
# test-swarm-usage-adapter-tui.sh — regression tests for
# bin/swarm-usage-adapter-tui.sh, the /usage-panel scraper that emits the
# swarm-usage-poll PROBE SCHEMA from Anthropic's authoritative percentages
# (replacing the ccusage token-burn proxy, which mis-counts cache reads).
#
# SYNTHETIC-FIXTURE discipline (mirrors test-swarm-login-relay.sh):
#   - MOCK tmux: records every invocation (send-keys included) and serves
#     SCRIPTED capture-pane frames that advance and stick on the last.
#   - The panel fixture is a REAL /usage capture (tests/fixtures/
#     usage-panel.frame.txt) so the parser is pinned against ground truth.
#   - No real tmux, no live pane, no credential ever touched.
#
# WHAT THIS PROTECTS:
#   1. Happy path: idle pane -> /usage sent -> panel scraped -> exact schema
#      JSON (five_hour + weekly, weekly = MAX across weekly sections) -> Escape
#      closes the dialog -> exit 0.
#   2. Real-fixture parse: session 26% / weekly 6% (max of all-models 6% and
#      Fable 3%) with reset hints, and the "% of your usage" distractor lines
#      are NOT misread as window readings.
#   3. Never interrupt work: a WORKING pane is skipped (fail-safe UNKNOWN, no
#      keys sent); no live idle pane -> exit 1, nothing emitted.
#   4. Restore discipline: on the timeout path an OPEN dialog gets Escape, but
#      a pane that started a TURN mid-probe gets C-u only (never Escape — that
#      would interrupt the turn).
#   5. Freshness gate: a stale panel already showing "% used" does NOT satisfy
#      the scrape (count must EXCEED the baseline).
#   6. Auto-select: with no explicit session, the first live IDLE swarm.conf
#      row is probed; a working first row is stepped over.
#   7. Config: bad timeout / poll -> exit 2.
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
json_field() { printf '%s' "$1" | python3 -c 'import json,sys
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

cat > "$FAKE_SH/swarm.conf" <<EOF
alpha | $TMP/repo-alpha | BOT_ALPHA | 111 | |
beta  | $TMP/repo-beta  | BOT_BETA  | 222 | |
EOF

# ── MOCK tmux: records invocations; serves scripted capture frames ──────────
MOCK_TMUX="$TMP/stubbin/tmux"
MOCK_TMUX_LOG="$TMP/tmux.log"
MOCK_FRAMES_DIR="$TMP/frames"
mkdir -p "$TMP/stubbin" "$MOCK_FRAMES_DIR"
cat > "$MOCK_TMUX" <<'EOF'
#!/usr/bin/env bash
set -u
log="${MOCK_TMUX_LOG:?}"; frames="${MOCK_FRAMES_DIR:?}"
printf '%s\n' "$*" >> "$log"
# Per-session has-session results, e.g. MOCK_SESSIONS="swarm-alpha swarm-beta".
case "${1:-}" in
  display)      printf '%s\n' "${MOCK_PANE_ROWS:-24}"; exit 0 ;;   # #{window_height}
  resize-window) exit 0 ;;
  set-option)   exit 0 ;;
  show-options) exit "${MOCK_WSZ_RC:-1}"; ;;   # rc=1 => option inherited (unset)
  has-session)
    tgt=""; shift || true
    while [ $# -gt 0 ]; do case "$1" in -t) shift; tgt="${1:-}";; esac; shift; done
    for s in ${MOCK_SESSIONS:-}; do [ "$s" = "$tgt" ] && exit 0; done
    exit 1 ;;
  send-keys) exit 0 ;;
  capture-pane)
    # Frame set is chosen per-session-target when MOCK_FRAMES_<sess> dirs exist;
    # else the default $MOCK_FRAMES_DIR. Advancing counter; sticks on last.
    tgt=""; for a in "$@"; do :; done
    # crude -t extraction
    prev=""; for a in "$@"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done
    fdir="$frames"
    var="MOCK_FRAMES_${tgt//-/_}"
    eval "alt=\${$var:-}"
    [ -n "${alt:-}" ] && [ -d "$alt" ] && fdir="$alt"
    cfile="$fdir/.counter"
    n="$(cat "$cfile" 2>/dev/null || echo 1)"
    f="$fdir/frame-$n.txt"
    if [ -f "$f" ]; then echo $((n+1)) > "$cfile"
    else
      last=0
      for ff in "$fdir"/frame-*.txt; do
        [ -f "$ff" ] || continue
        num="${ff##*frame-}"; num="${num%.txt}"
        case "$num" in *[!0-9]*) continue;; esac
        [ "$num" -gt "$last" ] && last="$num"
      done
      [ "$last" -eq 0 ] && exit 1
      f="$fdir/frame-$last.txt"
    fi
    cat "$f"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_TMUX"

FRAME_IDLE='>
? for shortcuts · ← for agents'
FRAME_WORKING='✻ Baking… (esc to interrupt)'
PANEL="$(cat "$ROOT/tests/fixtures/usage-panel.frame.txt")"

# lay_frames DIR FRAME... — write a scripted capture sequence.
lay_frames() {
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  local i=1
  for _f in "$@"; do printf '%s\n' "$_f" > "$dir/frame-$i.txt"; i=$((i+1)); done
}

send_keys_log() { grep '^send-keys' "$MOCK_TMUX_LOG" 2>/dev/null || true; }
reset_log() { : > "$MOCK_TMUX_LOG"; }

run_adapter() {  # env-assignments... (as VAR=val strings) — sets OUT/rc
  reset_log
  OUT="$(
    export SWARM_HOME="$FAKE_SH" SWARM_TMUX_BIN="$MOCK_TMUX"
    export MOCK_TMUX_LOG MOCK_FRAMES_DIR
    export SWARM_USAGE_TUI_POLL=0 SWARM_USAGE_TUI_TIMEOUT=3
    env "$@" bash "$ADAPTER" 2>&1
  )"; rc=$?
}

echo "=== 1) HAPPY PATH: idle pane -> /usage -> panel scraped -> schema JSON, exit 0 ==="
# Captures: pane_working(idle), baseline(idle), re-verify(idle), poll->panel.
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_IDLE" "$PANEL"
run_adapter MOCK_SESSIONS="swarm-alpha swarm-beta" SWARM_USAGE_TUI_SESSION=swarm-alpha
assert_eq 0 "$rc" "happy path exits 0"
assert_eq "26" "$(json_field "$OUT" five_hour.used_pct)" "five_hour used_pct parsed (26)"
assert_eq "6" "$(json_field "$OUT" weekly.used_pct)" "weekly used_pct = MAX weekly window (6, not Fable's 3)"
assert_eq "8pm (America/Buenos_Aires)" "$(json_field "$OUT" five_hour.reset_hint)" "five_hour reset hint parsed"
assert_eq "default" "$(json_field "$OUT" account)" "account defaults to 'default'"
assert_has "$(send_keys_log)" "/usage" "sent /usage to the pane"
assert_has "$(send_keys_log)" "swarm-alpha C-u /usage Enter" "exact keystrokes: C-u then /usage then Enter"
assert_eq "send-keys -t swarm-alpha Escape" "$(send_keys_log | tail -n 1)" "closed the dialog with Escape after scraping"
# The pane (24 rows, < ROWS default 60) is grown then restored.
assert_has "$(cat "$MOCK_TMUX_LOG")" "resize-window -t swarm-alpha -y 60" "grew the short pane to fit the panel top"
assert_has "$(cat "$MOCK_TMUX_LOG")" "resize-window -t swarm-alpha -y 24" "restored the pane to its original height"
assert_has "$(cat "$MOCK_TMUX_LOG")" "set-option -t swarm-alpha -uw window-size" "restored the inherited window-size option (unset the manual override)"

echo ""
echo "=== 2) DISTRACTOR SAFETY: '% of your usage' lines are not misread as windows ==="
# The fixture contains '93% of your usage ...' etc.; only 'NN% used' under a
# section header may be a reading. If a distractor leaked, five/weekly would be
# wrong (e.g. 93).
assert_lacks "$(json_field "$OUT" five_hour.used_pct)" "93" "five_hour is not a contributing-factor percentage"
assert_lacks "$(json_field "$OUT" weekly.used_pct)" "84" "weekly is not a contributing-factor percentage"

echo ""
echo "=== 3) NEVER INTERRUPT WORK ==="
echo "--- 3a) explicit WORKING session -> fail-safe UNKNOWN, no keys sent ---"
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_WORKING"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha
assert_eq 1 "$rc" "working pane -> exit 1 (fail-safe)"
assert_eq "" "$(send_keys_log)" "NO keys sent to a working pane"
assert_has "$OUT" "not idle" "explains the skip"
echo "--- 3b) explicit MISSING session -> exit 1, nothing emitted ---"
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE"
run_adapter MOCK_SESSIONS="swarm-beta" SWARM_USAGE_TUI_SESSION=swarm-alpha
assert_eq 1 "$rc" "missing session -> exit 1"
assert_has "$OUT" "does not exist" "explains the missing session"
echo "--- 3c) no live idle swarm at all (auto-select finds none) -> exit 1 ---"
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE"
run_adapter MOCK_SESSIONS=""    # no sessions live
assert_eq 1 "$rc" "no live idle pane -> exit 1"
assert_has "$OUT" "no live IDLE" "explains the fail-safe"

echo ""
echo "=== 4) RESTORE DISCIPLINE on timeout ==="
echo "--- 4a) dialog never renders, pane still idle -> Escape (close), exit 1 ---"
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE"    # idle sticks; no panel ever
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha SWARM_USAGE_TUI_TIMEOUT=1
assert_eq 1 "$rc" "no panel -> exit 1"
assert_eq "send-keys -t swarm-alpha Escape" "$(send_keys_log | tail -n 1)" "Escape closes the (idle) dialog on timeout"
echo "--- 4b) a TURN starts mid-probe -> C-u only, NEVER Escape (would interrupt) ---"
# idle for the guards + baseline + re-verify, then a WORKING frame sticks.
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_WORKING"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha SWARM_USAGE_TUI_TIMEOUT=1
assert_eq 1 "$rc" "turn-started-mid-probe -> exit 1"
assert_eq "send-keys -t swarm-alpha C-u" "$(send_keys_log | tail -n 1)" "cleared input with C-u only"
assert_lacks "$(send_keys_log | tail -n 1)" "Escape" "did NOT Escape (that would interrupt the running turn)"
assert_has "$OUT" "no Escape" "notes the turn-guard restore"

echo ""
echo "=== 5) SELF-HEAL: a stale panel already open is dismissed and a FRESH one is read THIS tick ==="
# Baseline ALREADY shows a panel (a prior probe / the observe double-poll left
# the dialog open). Without self-heal the gate could never exceed that count and
# the tick would waste itself on UNKNOWN. The adapter must Escape the stale
# panel, re-baseline, then scrape a fresh one -> exit 0.
#  captures: pane_working(idle), baseline(STALE PANEL) -> self-heal Escape,
#            re-baseline(idle), re-verify(idle), poll->fresh panel.
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE" "$PANEL" "$FRAME_IDLE" "$FRAME_IDLE" "$PANEL"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha
assert_eq 0 "$rc" "stale-open panel is self-healed and a fresh scrape succeeds (exit 0)"
assert_eq "26" "$(json_field "$OUT" five_hour.used_pct)" "fresh panel parsed after self-heal"
assert_eq "send-keys -t swarm-alpha Escape" "$(send_keys_log | head -n 1)" "the FIRST key is the self-heal Escape (dismiss the stale panel before /usage)"
assert_has "$(send_keys_log)" "swarm-alpha C-u /usage Enter" "then /usage is sent for a fresh read"

echo ""
echo "=== 6) AUTO-SELECT: skip a WORKING first row, probe the idle second row ==="
# swarm-alpha WORKING, swarm-beta IDLE -> beta is probed.
mkdir -p "$TMP/frames_alpha" "$TMP/frames_beta"
lay_frames "$TMP/frames_alpha" "$FRAME_WORKING"
lay_frames "$TMP/frames_beta"  "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_IDLE" "$PANEL"
run_adapter MOCK_SESSIONS="swarm-alpha swarm-beta" \
  MOCK_FRAMES_swarm_alpha="$TMP/frames_alpha" MOCK_FRAMES_swarm_beta="$TMP/frames_beta"
assert_eq 0 "$rc" "auto-select probes an idle row and exits 0"
assert_has "$(send_keys_log)" "swarm-beta C-u /usage Enter" "probed the IDLE swarm (beta), not the working one (alpha)"
assert_lacks "$(send_keys_log)" "swarm-alpha C-u /usage" "never sent /usage to the working swarm"

echo ""
echo "=== 8) PANE ALREADY TALL ENOUGH -> not resized ==="
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE" "$FRAME_IDLE" "$FRAME_IDLE" "$PANEL"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha MOCK_PANE_ROWS=80
assert_eq 0 "$rc" "tall pane scrapes fine"
assert_lacks "$(cat "$MOCK_TMUX_LOG")" "resize-window" "a pane >= ROWS is never resized"

echo ""
echo "=== 9) CONFIG errors ==="
lay_frames "$MOCK_FRAMES_DIR" "$FRAME_IDLE"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha SWARM_USAGE_TUI_TIMEOUT=soon
assert_eq 2 "$rc" "non-integer timeout -> exit 2"
run_adapter MOCK_SESSIONS="swarm-alpha" SWARM_USAGE_TUI_SESSION=swarm-alpha SWARM_USAGE_TUI_POLL=fast
assert_eq 2 "$rc" "non-numeric poll -> exit 2"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
