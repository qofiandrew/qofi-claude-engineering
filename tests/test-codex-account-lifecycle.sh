#!/usr/bin/env bash
# Claude-account/limit/admin automation must never act on engine=codex rows.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-account-lifecycle.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/home"; export HOME
SWARM="$TMP/swarm"; STUB="$TMP/stub"; mkdir -p "$SWARM" "$STUB" "$HOME"
chmod 700 "$HOME"
ln -s "$ROOT/templates" "$SWARM/templates"
: > "$SWARM/tokens.env"

PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

echo "=== single-swarm account actuator refuses Codex before every effect ==="
cat > "$SWARM/swarm.conf" <<CONF
codex | $TMP/codex-repo | BOT_CODEX | 111 | | old-max | codex
CONF
: > "$TMP/effects.log"
cat > "$STUB/effect" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EFFECT_LOG"
SH
chmod +x "$STUB/effect"
OUT="$(SWARM_HOME="$SWARM" EFFECT_LOG="$TMP/effects.log" \
  SWARM_ACCOUNT_AUTHCHECK_CMD="$STUB/effect" SWARM_CHECKPOINT_CMD="$STUB/effect" SWARM_RESTART_CMD="$STUB/effect" \
  bash "$ROOT/bin/swarm-account.sh" codex new-max 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "swarm-account refuses a Codex target"; else bad "swarm-account refuses a Codex target"; fi
has "$OUT" "engine=codex" "account refusal explains the engine boundary"
eq "" "$(cat "$TMP/effects.log")" "refusal runs no auth/checkpoint/restart command"
has "$(cat "$SWARM/swarm.conf")" "old-max | codex" "refusal does not rewrite ACCOUNT"

echo ""
echo "=== snapshot/reset and account universes include Claude rows only ==="
cat > "$SWARM/swarm.conf" <<CONF
codex | $TMP/codex-repo | BOT_CODEX | 111 | | codex-retained | codex
claude | $TMP/claude-repo | BOT_CLAUDE | 222 | | drifted | claude
CONF
cat > "$SWARM/.swarm-accounts-default" <<'SNAP'
# legacy snapshot may contain both engines
codex	legacy-default
claude	base-max
SNAP
SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-account.sh" --reset >/dev/null
CODEX_ACCOUNT="$(awk -F'|' '$1 ~ /codex/ {gsub(/[[:space:]]/,"",$6); print $6}' "$SWARM/swarm.conf")"
CLAUDE_ACCOUNT="$(awk -F'|' '$1 ~ /claude/ {gsub(/[[:space:]]/,"",$6); print $6}' "$SWARM/swarm.conf")"
eq codex-retained "$CODEX_ACCOUNT" "reset preserves a Codex row's dormant ACCOUNT field"
eq base-max "$CLAUDE_ACCOUNT" "reset restores the Claude row"

before_conf="$(cat "$SWARM/swarm.conf")"
mkdir -m 700 "$SWARM/swarm.conf.mutation.lock"; printf '%s\n' "$$" > "$SWARM/swarm.conf.mutation.lock/owner"
LOCK_RC="$(SWARM_HOME="$SWARM" bash -c '. "$1"; swarm_conf_set_account "$2" claude raced >/dev/null 2>&1; printf "%s" "$?"' _ "$ROOT/bin/swarm-lib.sh" "$SWARM/swarm.conf")"
eq 2 "$LOCK_RC" "account writer honors the shared global config lock"
eq "$before_conf" "$(cat "$SWARM/swarm.conf")" "contended account rewrite leaves config byte-unchanged"
rm -rf "$SWARM/swarm.conf.mutation.lock"

mkdir -m 700 "$SWARM/swarm.conf.mutation.lock"; printf '%s\n' 2147483647 > "$SWARM/swarm.conf.mutation.lock/owner"
STALE_RC="$(SWARM_HOME="$SWARM" bash -c '. "$1"; swarm_conf_lock_acquire "$2" >/dev/null 2>&1; rc=$?; [ "$rc" -eq 0 ] && swarm_conf_lock_release; printf "%s" "$rc"' _ "$ROOT/bin/swarm-lib.sh" "$SWARM/swarm.conf")"
eq 1 "$STALE_RC" "dead cross-resource config lock remains fail-closed for explicit transaction audit"
if [ -d "$SWARM/swarm.conf.mutation.lock" ]; then ok "dead transaction signal is retained"; else bad "dead transaction signal is retained"; fi
rm -rf "$SWARM/swarm.conf.mutation.lock"

OUT="$(SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-failover-target.sh" --capped base-max 2>&1)"; RC=$?
eq 6 "$RC" "Codex-only spare label cannot become a Claude failover target"
lacks "$OUT" "codex-retained" "failover selector excludes Codex account labels"

OUT="$(SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-account-verify.sh" --dry-run 2>&1)"; RC=$?
eq 0 "$RC" "account verifier still sees the labeled Claude row"
lacks "$OUT" "codex-retained" "account verifier excludes Codex account labels"

echo ""
echo "=== limit detection and failover routing ignore Codex panes ==="
cat > "$SWARM/swarm.conf" <<CONF
codex | $TMP/codex-repo | BOT_CODEX | 111 | | max-a | codex
CONF
: > "$TMP/pane.log"
cat > "$STUB/pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PANE_LOG"
echo 'usage limit reached'; exit 2
SH
chmod +x "$STUB/pane"
OUT="$(SWARM_HOME="$SWARM" PANE_LOG="$TMP/pane.log" SWARM_PANE_STATE_CMD="$STUB/pane" \
  bash "$ROOT/bin/swarm-limit-detect.sh" --by-account 2>&1)"; RC=$?
eq 3 "$RC" "Codex-only fleet yields no observable Claude account"
eq "" "$(cat "$TMP/pane.log")" "limit detector never probes the Codex daemon pane"
eq "" "$OUT" "Codex-only by-account detector emits no UNKNOWN pseudo-account"

cat > "$STUB/detect" <<'SH'
#!/usr/bin/env bash
echo 'account=max-a verdict=AT swarm=codex detail=cap'; exit 20
SH
cat > "$STUB/account" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ACCOUNT_LOG"
SH
chmod +x "$STUB/detect" "$STUB/account"
: > "$TMP/account.log"
SWARM_HOME="$SWARM" ACCOUNT_LOG="$TMP/account.log" SWARM_LIMIT_DETECT_CMD="$STUB/detect" \
  SWARM_ACCOUNT_CMD="$STUB/account" bash "$ROOT/bin/swarm-rotate-tick.sh" --failover >/dev/null 2>&1
eq "" "$(cat "$TMP/account.log")" "failover router never invokes account actuator for a Codex row"

echo ""
echo "=== login relay refuses Codex before tmux/Discord activity ==="
OUT="$(SWARM_HOME="$SWARM" SWARM_LOGIN_RELAY_SWARM=codex \
  bash "$ROOT/bin/swarm-login-relay.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "login relay refuses a Codex target"; else bad "login relay refuses a Codex target"; fi
has "$OUT" "Choose a Claude-engine swarm" "login relay gives Claude-target guidance"

echo ""
echo "=== doctor uses Codex-native checks and the default canonical ACL ==="
REPO="$TMP/codex-repo"; mkdir -p "$REPO"
(
  export SWARM_HOME="$SWARM"
  . "$ROOT/bin/swarm-lib.sh"
  SWARM_APPLY_TYPE_OVERRIDE=engineering-cto SWARM_APPLY_ENGINE_OVERRIDE=codex SWARM_QUIET_UNCHANGED=1 manifest_apply "$REPO" init >/dev/null
)
printf 'export BOT_CODEX="fixture-token"\n' > "$SWARM/tokens.env"
mkdir -p "$SWARM/cto-watcher"
cat > "$SWARM/cto-watcher/config.json" <<'JSON'
{"ctoChannels":{"codex":{"channelId":"111","botUserId":"bot-user"}}}
JSON
ACCESS="$TMP/default-access.json"
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"111":{"allowFrom":["1507069153335443608","watcher-id"]}}}
JSON
chmod 600 "$ACCESS"
cat > "$SWARM/swarm.conf" <<CONF
codex | $REPO | BOT_CODEX | 111 | | stale-claude-label | codex
CONF
mkdir -p "$SWARM/bin"
cat > "$SWARM/bin/codex-host-preflight.py" <<'PY'
import os,pwd
pw=pwd.getpwuid(os.getuid())
print('|'.join(['/trusted/codex','/trusted/bun',os.environ['HOME'],os.environ['HOME']+'/.codex',
  '0.144.1','/trusted/codex.js','/usr/bin:/bin',str(os.getuid()),pw.pw_name,
  os.environ['HOME']+'/runtime',os.environ['HOME']+'/runtime/.codex',str(pw.pw_gid),
  'fixture-shared','/usr/local/libexec/qofi-codex-runner','qofi-codex-runtime/v2',
  'fixture_operator_canary-1234567890']))
PY
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" CTO_BUS_WATCHER_BOT_ID=watcher-id \
  bash "$ROOT/bin/swarm-doctor.sh" codex 2>&1)"; RC=$?
eq 0 "$RC" "Codex doctor passes a fully wired Codex CTO"
has "$OUT" "Claude channel plugin: n/a" "doctor does not impose Claude plugin checks on Codex"
has "$OUT" "exact ChatGPT subscription status verified" "doctor runs the shared exact Codex auth diagnostic"
has "$OUT" "empty managed neutralizer" "doctor verifies neutral command-hook config"
lacks "$OUT" "stale-claude-label" "doctor does not resolve Codex through dormant Claude ACCOUNT"

echo ""
echo "=== doctor verifies Codex CPO operator+bus canonical ACL ==="
CPO_REPO="$TMP/cpo-repo"; mkdir -p "$CPO_REPO/.claude"; printf 'cpo\n' > "$CPO_REPO/.claude/swarm-type"
cat > "$SWARM/swarm.conf" <<CONF
cpo-codex | $CPO_REPO | BOT_CODEX | 222 | | | codex
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"222":{"allowFrom":["1507069153335443608"]},"333":{"allowFrom":["1507069153335443608","watcher-id"]}}}
JSON
chmod 600 "$ACCESS"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" SWARM_BUS_CHANNEL=333 CTO_BUS_WATCHER_BOT_ID=watcher-id \
  bash "$ROOT/bin/swarm-doctor.sh" cpo-codex 2>&1)"; RC=$?
eq 0 "$RC" "Codex CPO doctor accepts explicit operator+bus ACL wiring"
has "$OUT" "effective groups=222,333" "doctor reports both effective CPO channels"
/usr/bin/python3 - "$ACCESS" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['groups']['333']['allowFrom'].remove('watcher-id'); json.dump(d,open(p,'w'))
PY
chmod 600 "$ACCESS"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" SWARM_BUS_CHANNEL=333 CTO_BUS_WATCHER_BOT_ID=watcher-id \
  bash "$ROOT/bin/swarm-doctor.sh" cpo-codex 2>&1)"; RC=$?
eq 1 "$RC" "Codex CPO doctor blocks a bus group missing the watcher"
has "$OUT" "CPO bus group lacks the watcher id" "doctor names the missing bus principal"

# Restore the engineering Codex row/ACL for the removal lifecycle below.
cat > "$SWARM/swarm.conf" <<CONF
codex | $REPO | BOT_CODEX | 111 | | stale-claude-label | codex
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"111":{"allowFrom":["1507069153335443608","watcher-id"]}}}
JSON
chmod 600 "$ACCESS"

echo ""
echo "=== remove kills viewer, uses default ACL, and preserves Codex state by default ==="
RUNTIME_LOG="$TMP/remove-runtime.log"; : > "$RUNTIME_LOG"; export RUNTIME_LOG
cat > "$STUB/codex-runtime" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNTIME_LOG"
exit 0
SH
chmod +x "$STUB/codex-runtime"
SWARM_CODEX_RUNTIME_BIN="$STUB/codex-runtime"; export SWARM_CODEX_RUNTIME_BIN
STATE="$HOME/.codex/channels/discord-codex"; mkdir -p "$STATE"
printf 'evidence\n' > "$STATE/events.jsonl"
chmod 700 "$HOME/.codex" "$HOME/.codex/channels" "$STATE"
chmod 600 "$STATE/events.jsonl"
mkdir -p "$HOME/.config/swarm"; : > "$HOME/.config/swarm/heartbeat-111.id"; : > "$HOME/.config/swarm/attention-111.flag"
mkdir -p "$HOME/.claude-accounts/stale-claude-label/channels/discord"
printf '{"groups":{"111":{"allowFrom":["labeled"]}}}\n' > "$HOME/.claude-accounts/stale-claude-label/channels/discord/access.json"
cat > "$STUB/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
[ "$1" = has-session ] && exit 0
exit 0
SH
chmod +x "$STUB/tmux"; : > "$TMP/tmux.log"
mkdir -m 700 "$STATE/daemon.lock"
printf '{"schema":"wrong-lock","pid":%s}\n' "$$" > "$STATE/daemon.lock/owner.json"
chmod 600 "$STATE/daemon.lock/owner.json"
OUT_UNSAFE="$(printf 'n\nn\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_REMOVE_CODEX_TIMEOUT=0 SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC_UNSAFE=$?
eq 1 "$RC_UNSAFE" "malformed live lock owner refuses Codex removal"
has "$OUT_UNSAFE" "lock-owner-unreadable" "removal names the unreadable singleton boundary"
has "$(cat "$SWARM/swarm.conf")" "codex |" "malformed lock leaves the config row registered"
rm -rf "$STATE/daemon.lock"

: > "$TMP/tmux.log"
mkdir -m 700 "$SWARM/swarm.conf.mutation.lock"; printf '%s\n' "$$" > "$SWARM/swarm.conf.mutation.lock/owner"
OUT_LOCK="$(printf 'n\nn\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC_LOCK=$?
eq 1 "$RC_LOCK" "remove writer honors the shared global config lock"
has "$(cat "$SWARM/swarm.conf")" "codex |" "contended remove leaves the row registered"
eq "" "$(cat "$TMP/tmux.log")" "contended remove stops no primary or viewer tmux session"
rm -rf "$SWARM/swarm.conf.mutation.lock"

LEASE_ROOT="$HOME/.codex/channels/repo-locks"
read -r REPO_DEV REPO_INO <<EOF
$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os,sys
value=os.lstat(sys.argv[1]); print(value.st_dev,value.st_ino)
PY
)
EOF
REPO_LEASE="$LEASE_ROOT/$REPO_DEV-$REPO_INO.lock"
mkdir -m 700 -p "$LEASE_ROOT" "$REPO_LEASE"
chmod 700 "$HOME/.codex" "$HOME/.codex/channels" "$LEASE_ROOT" "$REPO_LEASE"
cat > "$REPO_LEASE/owner.json" <<EOF
{"schema":"qofi-codex-repo-lease/v1","pid":2147483647,"token":"123e4567-e89b-42d3-a456-426614174000","repo_dev":$REPO_DEV,"repo_ino":$REPO_INO,"repo_path":"$REPO","swarm_name":"codex","state_dir":"$STATE","operation":"turn","started_at":"2026-07-11T00:00:00Z"}
EOF
chmod 600 "$REPO_LEASE/owner.json"
: > "$RUNTIME_LOG"
OUT_LEASE="$(printf 'n\nn\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC_LEASE=$?
eq 1 "$RC_LEASE" "remove refuses a retained physical repo lease"
has "$OUT_LEASE" "recover the exact repo lease" "repo-lease refusal gives the evidence-bound recovery path"
has "$(cat "$SWARM/swarm.conf")" "codex |" "repo-lease refusal retains the owning config row"
lacks "$(cat "$RUNTIME_LOG")" "release-workspace" "repo-lease refusal cannot release workspace authority"
rm -rf "$REPO_LEASE"

mkdir -m 700 "$REPO_LEASE"
printf '{"schema":"qofi-lock-release/v1","phase":"exchanged"}\n' > "$REPO_LEASE/release.json"
chmod 600 "$REPO_LEASE/release.json"
OUT_TOMBSTONE="$(printf 'n\nn\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC_TOMBSTONE=$?
eq 1 "$RC_TOMBSTONE" "remove refuses a canonical exact-release tombstone"
has "$(cat "$SWARM/swarm.conf")" "codex |" "release tombstone retains the owning config row"
rm -rf "$REPO_LEASE"

OUT_REREG="$({
  while grep -q '^codex[[:space:]]*|' "$SWARM/swarm.conf" 2>/dev/null \
        || [ -d "$SWARM/swarm.conf.mutation.lock" ]; do sleep 0.02; done
  printf 'codex | %s | BOT_CODEX | 111 | | stale-claude-label | codex\n' "$REPO" >> "$SWARM/swarm.conf"
  printf 'y\ny\ny\ny\n'
} | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC_REREG=$?
eq 0 "$RC_REREG" "remove completes its row transaction when the name is re-registered during an optional prompt"
has "$OUT_REREG" "optional cleanup skipped" "re-registration invalidates every old optional cleanup choice"
has "$(cat "$SWARM/swarm.conf")" "codex |" "newly registered replacement row remains active"
if [ -f "$HOME/.config/swarm/heartbeat-111.id" ] && [ -f "$HOME/.config/swarm/attention-111.flag" ]; then
  ok "re-registration preserves replacement operator state"
else
  bad "re-registration preserves replacement operator state"
fi
has "$(cat "$ACCESS")" '"111"' "re-registration preserves the replacement canonical ACL group"
if [ -f "$STATE/events.jsonl" ]; then ok "re-registration preserves replacement Codex state"; else bad "re-registration preserves replacement Codex state"; fi

OUT="$(printf 'n\nn\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" codex 2>&1)"; RC=$?
eq 0 "$RC" "Codex removal completes after quiescence"
has "$(cat "$TMP/tmux.log")" "kill-session -t codex-view-codex" "remove kills the separate Codex viewer session"
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $REPO" "last Codex removal revokes dedicated workspace authority"
if [ -f "$STATE/events.jsonl" ]; then ok "Codex session/audit state is preserved by default"; else bad "Codex session/audit state is preserved by default"; fi
has "$(cat "$ACCESS")" '"111"' "default canonical ACL remains when operator declines removal"
has "$(cat "$HOME/.claude-accounts/stale-claude-label/channels/discord/access.json")" 'labeled' "dormant labeled Claude ACL is untouched"
lacks "$(cat "$SWARM/swarm.conf")" "codex |" "remove deletes the canonical config row"

echo ""
echo "=== shared-repo and Claude removals preserve lifecycle boundaries ==="
SHARED_REPO="$TMP/shared-remove-repo"; CLAUDE_REPO="$TMP/claude-remove-repo"
mkdir -p "$SHARED_REPO" "$CLAUDE_REPO"
cat > "$SWARM/swarm.conf" <<CONF
shareda | $SHARED_REPO | BOT_SHAREDA | 411 | | | codex
sharedb | $SHARED_REPO | BOT_SHAREDB | 412 | | | codex
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"411":{"allowFrom":["1507069153335443608"]},"412":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"; : > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" shareda 2>&1)"; RC=$?
eq 0 "$RC" "removing one of two Codex repo references succeeds"
eq "" "$(cat "$RUNTIME_LOG")" "non-final Codex removal does not release shared workspace authority"
has "$(cat "$SWARM/swarm.conf")" "sharedb |" "sibling Codex reference remains registered"

: > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" sharedb 2>&1)"; RC=$?
eq 0 "$RC" "removing the final shared Codex reference succeeds"
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $SHARED_REPO" "final shared reference releases workspace authority"

echo ""
echo "=== physical-repo alias references share one Codex authority lease ==="
ALIAS_REAL="$TMP/alias-shared-repo"; ALIAS_PATH="$TMP/alias-shared-link"
mkdir -p "$ALIAS_REAL"; ln -s "$ALIAS_REAL" "$ALIAS_PATH"
cat > "$SWARM/swarm.conf" <<CONF
aliasreal | $ALIAS_REAL | BOT_ALIASREAL | 421 | | | codex
aliaslink | $ALIAS_PATH | BOT_ALIASLINK | 422 | | | codex
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"421":{"allowFrom":["1507069153335443608"]},"422":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"; : > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" aliasreal 2>&1)"; RC=$?
eq 1 "$RC" "noncanonical sibling makes reference accounting fail closed"
eq "" "$(cat "$RUNTIME_LOG")" "noncanonical sibling cannot become release evidence for the canonical row"
has "$(cat "$SWARM/swarm.conf")" "aliasreal |" "canonical row remains registered until every alias is repaired"

: > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" aliaslink 2>&1)"; RC=$?
eq 1 "$RC" "noncanonical legacy Codex alias is refused before authority release"
eq "" "$(cat "$RUNTIME_LOG")" "legacy alias refusal never releases whichever target the link currently names"
has "$(cat "$SWARM/swarm.conf")" "aliaslink |" "legacy alias row stays registered for explicit repair"
has "$OUT" "canonical physical path" "legacy alias refusal gives canonical-row remediation"

ALIAS_OTHER="$TMP/alias-other-repo"; mkdir -p "$ALIAS_OTHER"
rm "$ALIAS_PATH"; ln -s "$ALIAS_OTHER" "$ALIAS_PATH"
: > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" aliaslink 2>&1)"; RC=$?
eq 1 "$RC" "retargeted Codex alias is refused"
eq "" "$(cat "$RUNTIME_LOG")" "retargeted alias cannot release an unrelated replacement repo"
has "$(cat "$SWARM/swarm.conf")" "aliaslink |" "retargeted alias cannot delete the only authority reference"

/usr/bin/python3 - "$SWARM/swarm.conf" "$ALIAS_PATH" "$ALIAS_REAL" <<'PY'
import sys
p, old, new=sys.argv[1:4]
data=open(p).read(); data=data.replace(f'aliaslink | {old} |',f'aliaslink | {new} |')
open(p,'w').write(data)
PY
: > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" aliasreal 2>&1)"; RC=$?
eq 0 "$RC" "canonical row removal succeeds after every alias row is repaired"
eq "" "$(cat "$RUNTIME_LOG")" "repaired canonical sibling retains the shared authority lease"
has "$(cat "$SWARM/swarm.conf")" "aliaslink |" "repaired sibling remains registered"

: > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" aliaslink 2>&1)"; RC=$?
eq 0 "$RC" "operator-repaired canonical alias row can be removed"
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $ALIAS_REAL" "canonical repair releases the originally prepared physical repo"

SAME_CHANNEL_REPO="$TMP/same-channel-repo"; mkdir -p "$SAME_CHANNEL_REPO"
cat > "$SWARM/swarm.conf" <<CONF
samechana | $SAME_CHANNEL_REPO | BOT_SAMEA | 431 | | | codex
samechanb | $SAME_CHANNEL_REPO | BOT_SAMEB | 431 | | | codex
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"431":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"
: > "$HOME/.config/swarm/heartbeat-431.id"; : > "$HOME/.config/swarm/attention-431.flag"
OUT="$(printf 'y\ny\ny\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" samechana 2>&1)"; RC=$?
eq 0 "$RC" "one same-channel sibling can be removed"
has "$OUT" "channel 431 is still referenced" "optional cleanup identifies shared channel state"
if [ -f "$HOME/.config/swarm/heartbeat-431.id" ] && [ -f "$HOME/.config/swarm/attention-431.flag" ]; then
  ok "same-channel sibling preserves shared operator state"
else
  bad "same-channel sibling preserves shared operator state"
fi
has "$(cat "$ACCESS")" '"431"' "same-channel sibling preserves its ACL group"
OUT="$(printf 'n\nn\nn\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" samechanb 2>&1)"; RC=$?
eq 0 "$RC" "final same-channel sibling removal succeeds"

cat > "$SWARM/swarm.conf" <<CONF
claudeonly | $CLAUDE_REPO | BOT_CLAUDEONLY | 413 | | | claude
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"413":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"; : > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" claudeonly 2>&1)"; RC=$?
eq 0 "$RC" "Claude removal keeps its historical lifecycle"
eq "" "$(cat "$RUNTIME_LOG")" "Claude removal never invokes the Codex runtime lifecycle"

cat > "$SWARM/swarm.conf" <<'CONF'
legacytilde | ~/legacy-repo | BOT_LEGACYTILDE | 414 | | | claude
CONF
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"414":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"; : > "$RUNTIME_LOG"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" legacytilde 2>&1)"; RC=$?
eq 0 "$RC" "historical Claude rows with an unexpanded tilde remain removable"
eq "" "$(cat "$RUNTIME_LOG")" "tilde-form Claude removal still avoids Codex lifecycle validation"

echo ""
echo "=== removal resolves one exact row before any tmux effect ==="
cat > "$SWARM/swarm.conf" <<CONF
missingtmux | $CLAUDE_REPO | BOT_MISSINGTMUX | 440 | | | claude
CONF
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/no-such-tmux" \
  bash "$ROOT/bin/swarm-remove.sh" missingtmux 2>&1)"; RC=$?
eq 1 "$RC" "missing tmux refuses removal before config mutation"
has "$(cat "$SWARM/swarm.conf")" "missingtmux |" "missing-tmux removal keeps the row registered"
has "$OUT" "tmux is unavailable" "missing-tmux removal explains the quiescence gap"

cat > "$SWARM/swarm.conf" <<CONF
duplicate | $CLAUDE_REPO | BOT_DUP_A | 441 | | | claude
duplicate | $CLAUDE_REPO | BOT_DUP_B | 442 | | | claude
CONF
: > "$TMP/tmux.log"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" duplicate 2>&1)"; RC=$?
eq 1 "$RC" "duplicate-name config is refused"
eq "" "$(cat "$TMP/tmux.log")" "duplicate-name refusal stops no tmux session"
has "$OUT" "2 rows named 'duplicate'" "duplicate-name refusal explains the ambiguity"

printf 'unterminated | %s | BOT_UNTERMINATED | 443 | | | claude' "$CLAUDE_REPO" > "$SWARM/swarm.conf"
cat > "$ACCESS" <<'JSON'
{"allowFrom":["1507069153335443608"],"groups":{"443":{"allowFrom":["1507069153335443608"]}}}
JSON
chmod 600 "$ACCESS"
OUT="$(printf 'n\n' | HOME="$HOME" SWARM_HOME="$SWARM" SWARM_ACCESS_FILE="$ACCESS" \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMP/tmux.log" bash "$ROOT/bin/swarm-remove.sh" unterminated 2>&1)"; RC=$?
eq 0 "$RC" "unterminated final config row remains removable"
eq "" "$(cat "$SWARM/swarm.conf")" "unterminated final row is removed exactly"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
