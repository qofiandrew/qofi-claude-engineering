#!/usr/bin/env bash
# Traditional attach must never expose a Codex daemon pane.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-attach-engine.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SWARM="$TMP/swarm"; STUB="$TMP/stub"
mkdir -p "$SWARM/templates" "$STUB"
cat > "$SWARM/swarm.conf" <<'CONF'
claude-row | /tmp/claude | BOT_CLAUDE | 111
codex-row | /tmp/codex | BOT_CODEX | 222 | | | codex
CONF
TMUX_LOG="$TMP/tmux.log"; VIEW_LOG="$TMP/view.log"; export TMUX_LOG VIEW_LOG
cat > "$STUB/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
[ "${1:-}" = has-session ] && exit 0
[ "${1:-}" = display-message ] && { printf '%s\n' '$101'; exit 0; }
exit 0
SH
cat > "$STUB/view" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VIEW_LOG"
SH
chmod +x "$STUB"/*

PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3"; fi; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3"; else ok "$3"; fi; }

: > "$TMUX_LOG"; : > "$VIEW_LOG"
OUT="$(SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_VIEW_BIN="$STUB/view" \
  bash "$ROOT/bin/swarm-attach.sh" codex-row 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "Codex attach dispatch succeeds" || bad "Codex attach dispatch succeeds"
has "$OUT" "supported operator view" "Codex attach explains the safe routing"
has "$(cat "$VIEW_LOG")" "codex-row" "Codex attach invokes swarm-view with the configured name"
lacks "$(cat "$TMUX_LOG")" "attach -t swarm-codex-row" "Codex attach never opens the daemon session"

: > "$TMUX_LOG"; : > "$VIEW_LOG"
SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux" SWARM_VIEW_BIN="$STUB/view" \
  bash "$ROOT/bin/swarm-attach.sh" claude-row >/dev/null 2>&1
has "$(cat "$TMUX_LOG")" 'attach -t $101' "Claude attach remains the native tmux TUI path bound to one session generation"
lacks "$(cat "$VIEW_LOG")" "claude-row" "Claude attach never dispatches to Codex view"

cat >> "$SWARM/swarm.conf" <<'CONF'
race-row | /tmp/race | BOT_RACE | 333 | | | claude
CONF
RACE_RUNNING="$TMP/race-running"; export RACE_RUNNING
cat > "$STUB/tmux-dynamic" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
if [ "${1:-}" = has-session ]; then [ -f "$RACE_RUNNING" ]; exit $?; fi
if [ "${1:-}" = display-message ]; then printf '%s\n' '$202'; exit 0; fi
exit 0
SH
cat > "$STUB/up-migrate" <<SH
#!/usr/bin/env bash
/usr/bin/python3 - "$SWARM/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; data=open(p).read(); data=data.replace(
  'race-row | /tmp/race | BOT_RACE | 333 | | | claude',
  'race-row | /tmp/race | BOT_RACE | 333 | | | codex')
open(p,'w').write(data)
PY
: > "$RACE_RUNNING"
SH
chmod +x "$STUB/tmux-dynamic" "$STUB/up-migrate"
: > "$TMUX_LOG"; : > "$VIEW_LOG"; rm -f "$RACE_RUNNING"
OUT="$(SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux-dynamic" SWARM_UP_BIN="$STUB/up-migrate" \
  SWARM_VIEW_BIN="$STUB/view" SWARM_ATTACH_LAUNCH_WAIT=1 bash "$ROOT/bin/swarm-attach.sh" race-row 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "launch-then-attach tolerates a stopped-row engine migration" || bad "launch-then-attach tolerates a stopped-row engine migration"
has "$(cat "$VIEW_LOG")" "race-row" "post-launch engine re-resolution routes the newly Codex row to its view"
lacks "$(cat "$TMUX_LOG")" "attach -t swarm-race-row" "stale pre-launch Claude identity never exposes the Codex daemon pane"

cat >> "$SWARM/swarm.conf" <<'CONF'
aba-row | /tmp/aba | BOT_ABA | 334 | | | claude
CONF
cat > "$STUB/tmux-aba" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMUX_LOG"
case "\${1:-}" in
  has-session) exit 0 ;;
  display-message)
    n=0; [ -f "$TMP/aba-count" ] && n=\$(cat "$TMP/aba-count")
    n=\$((n + 1)); printf '%s\n' "\$n" > "$TMP/aba-count"
    if [ "\$n" -eq 1 ]; then
      /usr/bin/python3 - "$SWARM/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; data=open(p).read().replace(
 'aba-row | /tmp/aba | BOT_ABA | 334 | | | claude',
 'aba-row | /tmp/aba | BOT_ABA | 334 | | | codex')
open(p,'w').write(data)
PY
      printf '%s\n' '\$301'
    else
      printf '%s\n' '\$302'
    fi
    exit 0 ;;
esac
exit 0
SH
chmod +x "$STUB/tmux-aba"
: > "$TMUX_LOG"; : > "$VIEW_LOG"; rm -f "$TMP/aba-count"
OUT="$(SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$STUB/tmux-aba" SWARM_VIEW_BIN="$STUB/view" \
  bash "$ROOT/bin/swarm-attach.sh" aba-row 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "session-generation ABA is refused" || bad "session-generation ABA is refused"
has "$OUT" "was replaced while resolving its engine" "ABA refusal explains the generation change"
lacks "$(cat "$TMUX_LOG")" "attach -t" "ABA refusal attaches to neither old nor replacement pane"
lacks "$(cat "$VIEW_LOG")" "aba-row" "ABA refusal opens no stale-engine viewer"

: > "$TMUX_LOG"; : > "$VIEW_LOG"
PATH="$STUB:$PATH" SWARM_HOME="$SWARM" SWARM_VIEW_BIN="$STUB/view" \
  bash "$ROOT/bin/swarm-up.sh" attach codex-row >/dev/null 2>&1
has "$(cat "$VIEW_LOG")" "codex-row" "swarm-up attach also routes Codex to the supported view"
lacks "$(cat "$TMUX_LOG")" "attach -t swarm-codex-row" "swarm-up attach never exposes the Codex daemon pane"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
