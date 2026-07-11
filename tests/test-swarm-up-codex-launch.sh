#!/usr/bin/env bash
# test-swarm-up-codex-launch.sh — regression tests for _launch_codex_lead in
# bin/swarm-up.sh (the engine=codex lane's pane bring-up).
#
# THE BUG THIS PINS (live, 2026-07-11): the launch used ONE ~800-char
# send-keys line (doctrine preamble inline). The pane tty mangled it — the
# export echoed interleaved with itself, the command never executed, the
# daemon never started, and the first codex-engine cycle of press-backend
# failed. The program now lives in a generated per-swarm launcher FILE
# ($state_dir/launch.sh, mode 700, no secrets); the tty receives one SHORT
# sourcing line. Invariants pinned here:
#   - launch.sh is written with the doctrine, the state/cwd exports, and an
#     exec of the codex-bridge daemon; mode 700;
#   - every send-keys line stays SHORT (< 200 chars) — the tty never sees the
#     doctrine text or any long program again;
#   - the pane line SOURCES the launcher (". '<state>/launch.sh'");
#   - no secret in the launcher: DISCORD_BOT_TOKEN comes from the pane env
#     line (sourced from tokens.env by var name), never lands in launch.sh;
#   - first-launch access.json seeding still happens (shared Claude-side copy).
#
# Everything external is stubbed: mock tmux (records argv; capture-pane says
# "gateway connected"), stub bun/codex on PATH, fixture HOME + SWARM_HOME.
# bash 3.2-safe. Run: bash tests/test-swarm-up-codex-launch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-launch-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── fixture SWARM_HOME: real bin/, stub codex-bridge, one codex row ─────────
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/codex-bridge/node_modules"
ln -s "$ROOT/bin" "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
printf '// stub daemon — never executed (tmux is mocked)\n' > "$FAKE_SH/codex-bridge/daemon.ts"
REPO="$TMP/repo-codextest"; mkdir -p "$REPO"
cat > "$FAKE_SH/swarm.conf" <<CONF
codextest | $REPO | BOT_CODEXTEST | 424242 | | | codex
CONF
SYNTH_TOKEN="SYNTH-CODEX-TOKEN-$$"
printf 'export BOT_CODEXTEST="%s"\n' "$SYNTH_TOKEN" > "$FAKE_SH/tokens.env"

# ── fixture HOME (state dirs live under it) + shared access.json to seed ────
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/channels/discord"
printf '{"dmPolicy":"pairing","allowFrom":["999"],"groups":{}}\n' > "$FAKE_HOME/.claude/channels/discord/access.json"

# ── stubs: tmux records argv, capture says "gateway connected"; bun+codex ok ─
STUB="$TMP/stubbin"; mkdir -p "$STUB"
TMUX_LOG="$TMP/tmux.log"
cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMUX_LOG"
case "\${1:-}" in
  has-session) exit 1 ;;
  capture-pane) echo "gateway connected"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/bun";   chmod +x "$STUB/bun"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/codex"; chmod +x "$STUB/codex"

echo "=== launch a codex-engine swarm through swarm-up.sh up ==="
OUT="$(HOME="$FAKE_HOME" SWARM_HOME="$FAKE_SH" SWARM_UP_SKIP_SANITY=1 \
       PATH="$STUB:$PATH" bash "$ROOT/bin/swarm-up.sh" up codextest 2>&1)"; rc=$?
assert_eq 0 "$rc" "up exits 0"
assert_has "$OUT" "codex lead up" "reports the codex lead up (gateway connected seen)"

STATE="$FAKE_HOME/.codex/channels/discord-codextest"
LAUNCHER="$STATE/launch.sh"

echo ""
echo "=== the generated launcher carries the program ==="
[ -f "$LAUNCHER" ] && ok "launch.sh generated in the state dir" || bad "launch.sh generated in the state dir"
L="$(cat "$LAUNCHER" 2>/dev/null)"
assert_has "$L" "SWARM DOCTRINE" "doctrine preamble lives in the FILE"
assert_has "$L" "DISCORD_STATE_DIR='$STATE'" "state-dir export in the file"
assert_has "$L" "CODEX_BRIDGE_CWD='$REPO'" "repo cwd export in the file"
assert_has "$L" "exec bun '$FAKE_SH/codex-bridge/daemon.ts'" "execs the daemon (replaces the pane shell)"
assert_has "$L" 'adversarial-review.sh' "review-lane pointer preserved in the doctrine"
assert_lacks "$L" "$SYNTH_TOKEN" "NO secret in the launcher (token rides the pane env line only)"
_mode="$(stat -f %Lp "$LAUNCHER" 2>/dev/null || stat -c %a "$LAUNCHER" 2>/dev/null)"
assert_eq "700" "$_mode" "launcher is mode 700"

echo ""
echo "=== the tty only ever sees SHORT lines (the actual regression) ==="
assert_has "$(grep '^send-keys' "$TMUX_LOG")" ". '$STATE/launch.sh'" "pane line SOURCES the launcher"
assert_lacks "$(grep '^send-keys' "$TMUX_LOG")" "SWARM DOCTRINE" "doctrine text never typed into the tty"
_long="$(grep '^send-keys' "$TMUX_LOG" | awk 'length($0) >= 550 { c++ } END { print c+0 }')"
assert_eq "0" "$_long" "no send-keys line >= 550 chars (tty canonical-buffer safety margin)"

echo ""
echo "=== first-launch seeding still works ==="
assert_has "$(cat "$STATE/access.json" 2>/dev/null)" '"999"' "shared Claude-side access.json seeded"
assert_has "$(cat "$STATE/access.json" 2>/dev/null)" '"424242"' "swarm channel group ensured"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
