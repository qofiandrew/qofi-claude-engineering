#!/usr/bin/env bash
# End-to-end registration coverage for swarm-add --engine.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-add-engine.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

HOME="$TMP/home"; export HOME
SWARM="$TMP/swarm"
REPO="$TMP/repo"
mkdir -p "$SWARM" "$REPO" "$HOME/.claude/channels/discord"
ln -s "$ROOT/templates" "$SWARM/templates"
cat > "$SWARM/codex-profiles.json" <<'JSON'
{
  "schema": "qofi-codex-profiles/v1",
  "profiles": [
    {"label":"default","shared":true},
    {"label":"premium_a","shared":false}
  ],
  "pools": {
    "default":{"profiles":["default"],"thresholdPercent":85},
    "premium":{"profiles":["premium_a","default"],"thresholdPercent":85}
  }
}
JSON
cat > "$SWARM/swarm.conf" <<CONF
# fixture
legacy | $REPO | BOT_LEGACY | 111
CONF
cat > "$SWARM/tokens.env" <<'TOKENS'
export BOT_LEGACY="fixture-token"
export BOT_FRESH="fixture-token"
export BOT_DEFAULT="fixture-token"
export BOT_BLOCKED="fixture-token"
export BOT_LIVE="fixture-token"
export BOT_RUNTIME="fixture-token"
export BOT_LATE="fixture-token"
export BOT_CAS="fixture-token"
export BOT_LEGACY3="fixture-token"
export BOT_LOCKED="fixture-token"
export BOT_ACLBLOCKED="fixture-token"
export BOT_NORUNTIME="fixture-token"
export BOT_VERIFYFAIL="fixture-token"
export BOT_LASTCODEX="fixture-token"
export BOT_RELEASEBLOCKED="fixture-token"
export BOT_REVERSECAS="fixture-token"
export BOT_FORWARDVERIFY="fixture-token"
export BOT_ALIASROW="fixture-token"
export BOT_REPOSWAP="fixture-token"
export BOT_LABELEDCLAUDE="fixture-token"
export BOT_LABELEDREVERSE="fixture-token"
export BOT_MISSINGTMUX="fixture-token"
TOKENS
printf '{"dmPolicy":"pairing","allowFrom":["owner"],"groups":{},"pending":{}}\n' > "$HOME/.claude/channels/discord/access.json"

RUNTIME_LOG="$TMP/runtime.log"; : > "$RUNTIME_LOG"; export RUNTIME_LOG
RUNTIME_STUB="$TMP/codex-runtime"
cat > "$RUNTIME_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNTIME_LOG"
if [ "${CODEX_RUNTIME_REQUIRE_LOCK:-0}" = 1 ] && [ ! -d "$SWARM_HOME/swarm.conf.mutation.lock" ]; then
  printf 'missing-lifecycle-lock:%s\n' "$*" >> "$RUNTIME_LOG"
  exit 35
fi
case "${1:-}" in
  prepare-workspace)
    if [ "${CODEX_RUNTIME_SWAP_REPO:-0}" = 1 ]; then
      mv "$3" "$3.original" || exit 36
      mkdir "$3" || exit 36
    fi
    [ "${CODEX_RUNTIME_FAIL_PREPARE:-0}" = 1 ] && exit 31
    ;;
  verify) [ "${CODEX_RUNTIME_FAIL_VERIFY:-0}" = 1 ] && exit 32 ;;
  release-workspace) [ "${CODEX_RUNTIME_FAIL_RELEASE:-0}" = 1 ] && exit 33 ;;
  *) exit 34 ;;
esac
exit 0
SH
chmod +x "$RUNTIME_STUB"
SWARM_CODEX_RUNTIME_BIN="$RUNTIME_STUB"; export SWARM_CODEX_RUNTIME_BIN

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=$1 got=$2)"; fi; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
lacks(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

run_add(){
  HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-add.sh" "$@" 2>&1
}
engine_for(){
  awk -F'|' -v n="$1" '$1 ~ "^[[:space:]]*" n "[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $7); print $7; exit}' "$SWARM/swarm.conf"
}
pool_for(){
  awk -F'|' -v n="$1" '$1 ~ "^[[:space:]]*" n "[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $8); print ($8 == "" ? "default" : $8); exit}' "$SWARM/swarm.conf"
}
field_count(){ awk -F'|' -v n="$1" '$1 ~ "^[[:space:]]*" n "[[:space:]]*$" {print NF; exit}' "$SWARM/swarm.conf"; }
file_id(){ stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1"; }
codex_surfaces_ok(){
  HOME="$HOME" SWARM_HOME="$SWARM" bash -c '. "$1"; swarm_codex_managed_surfaces_check "$2"' \
    _ "$ROOT/bin/swarm-lib.sh" "$1" >/dev/null 2>&1
}

echo '=== help routes Codex auth to the dedicated runtime ==='
OUT="$(run_add --help)"; rc=$?
eq 0 "$rc" 'swarm-add help succeeds'
has "$OUT" 'swarm-codex-runtime.sh login' 'Codex help names the dedicated hidden-account login command'
lacks "$OUT" 'host `codex login`' 'Codex help never recommends current-user auth for an unattended lead'

echo '=== explicit engine upgrades an existing legacy row ==='
OUT="$(run_add legacy "$REPO" 111 --skip-walkthrough --type cpo --engine codex --codex-auth-pool premium)"; rc=$?
eq 0 "$rc" 'existing-row Codex registration succeeds'
eq codex "$(engine_for legacy)" 'existing legacy row is padded and switched to Codex'
eq premium "$(pool_for legacy)" 'engine migration commits distinct field-8 Codex pool atomically'
has "$OUT" "committed: 'legacy' ENGINE claude -> codex" 'registration commits the engine only after target setup verifies'
has "$OUT" 'Claude channel-plugin verification  [SKIPPED: engine=codex]' 'Codex onboarding skips the Claude-only plugin gate'
has "$(cat "$RUNTIME_LOG")" "prepare-workspace --repo $REPO" 'Codex adoption prepares the dedicated workspace before commit'
has "$(cat "$RUNTIME_LOG")" "verify --repo $REPO" 'Codex adoption verifies the installed runtime before commit'
eq 600 "$(stat -f %Lp "$HOME/.claude/channels/discord/access.json" 2>/dev/null || stat -c %a "$HOME/.claude/channels/discord/access.json")" 'historical access.json mode is narrowed to 0600'
eq True "$(/usr/bin/python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["allowFrom"])' "$HOME/.claude/channels/discord/access.json" 1507069153335443608)" 'explicit operator id is migrated into top-level allowFrom'
eq 1507069153335443608 "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("loginControlOwnerId", ""))' "$HOME/.claude/channels/discord/access.json")" 'explicit operator id is pinned for secure login control'
eq True "$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(all(x in d["groups"][sys.argv[2]]["allowFrom"] for x in sys.argv[3:]))' "$HOME/.claude/channels/discord/access.json" 1510301812434141194 1507069153335443608 1510298728148369448)" 'fresh CPO bus ACL includes explicit operator and watcher'

echo '=== idempotent rerun without --engine preserves the row runtime ==='
OUT="$(run_add legacy "$REPO" 111 --skip-walkthrough)"; rc=$?
eq 0 "$rc" 'idempotent rerun succeeds'
eq codex "$(engine_for legacy)" 'implicit default does not revert an existing Codex row'
eq premium "$(pool_for legacy)" 'rerun without pool flag preserves the configured Codex pool'
has "$OUT" 'engine:    codex' 'phase zero reports the preserved runtime'

echo '=== explicit same-engine pool update rewrites only field eight ==='
OUT="$(run_add legacy "$REPO" 111 --skip-walkthrough --codex-auth-pool default)"; rc=$?
eq 0 "$rc" 'same-engine pool update succeeds after Codex verification'
eq codex "$(engine_for legacy)" 'pool update preserves the Codex engine'
eq default "$(pool_for legacy)" 'pool update commits the requested declared pool'
has "$OUT" 'CODEX_AUTH_POOL premium -> default' 'pool update reports the committed transition'

echo '=== existing registration identity cannot be redirected by same-name input ==='
OTHER_REPO="$TMP/other-repo"; mkdir -p "$OTHER_REPO"
before="$(cat "$SWARM/swarm.conf")"
OUT="$(run_add legacy "$OTHER_REPO" 111 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'same name with a different canonical repo is refused'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'repo mismatch leaves config byte-unchanged'
eq no "$([ -e "$OTHER_REPO/AGENTS.md" ] && echo yes || echo no)" 'repo mismatch is refused before stamping the wrong repo'
has "$OUT" 'already registered to repo' 'repo mismatch explains the bound identity'

OUT="$(run_add legacy "$REPO" 999 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'same name with a different explicit channel is refused'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'channel mismatch leaves config byte-unchanged'
has "$OUT" 'already registered to channel' 'channel mismatch explains the bound identity'

echo '=== legacy blank-channel migration fills channel in the same engine CAS ==='
cat >> "$SWARM/swarm.conf" <<CONF
legacy3 | $REPO | BOT_LEGACY3
CONF
OUT="$(run_add legacy3 "$REPO" 449 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 0 "$rc" 'legacy three-column row migrates with an explicit channel'
eq codex "$(engine_for legacy3)" 'legacy row engine commits to Codex'
eq 449 "$(awk -F'|' '$1 ~ /legacy3/ {gsub(/[[:space:]]/,"",$4); print $4}' "$SWARM/swarm.conf")" 'channel fill and engine switch commit together'

before="$(cat "$SWARM/swarm.conf")"
cat >> "$SWARM/swarm.conf" <<CONF
malformed | $REPO | bad-token-name! | 450
CONF
OUT="$(run_add malformed "$REPO" 450 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'existing row with malformed token field is refused'
has "$OUT" 'existing row' 'malformed-row refusal happens during identity preflight'
eq "$before" "$(sed '$d' "$SWARM/swarm.conf")" 'malformed row causes no mutation to prior config bytes'
sed '$d' "$SWARM/swarm.conf" > "$SWARM/swarm.conf.clean"
mv "$SWARM/swarm.conf.clean" "$SWARM/swarm.conf"

echo '=== engine migration refuses live sessions before writes ==='
MISSING_TMUX_REPO="$TMP/missing-tmux-repo"; mkdir -p "$MISSING_TMUX_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
missingtmux | $MISSING_TMUX_REPO | BOT_MISSINGTMUX | 443 | | | claude
CONF
before="$(cat "$SWARM/swarm.conf")"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/no-such-tmux" bash "$ROOT/bin/swarm-add.sh" missingtmux "$MISSING_TMUX_REPO" 443 --skip-walkthrough --type cpo --engine codex 2>&1)"; rc=$?
eq 2 "$rc" 'missing tmux refuses engine migration'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'missing-tmux refusal leaves config byte-unchanged'
has "$OUT" 'tmux is unavailable' 'missing-tmux migration explains the quiescence gap'

cat >> "$SWARM/swarm.conf" <<CONF
live | $REPO | BOT_LIVE | 444 | | | claude
CONF
cat > "$TMP/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'has-session -t swarm-live'*) exit 0 ;; esac
exit 1
SH
chmod +x "$TMP/tmux"
before="$(cat "$SWARM/swarm.conf")"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/tmux" bash "$ROOT/bin/swarm-add.sh" live "$REPO" 444 --skip-walkthrough --type cpo --engine codex 2>&1)"; rc=$?
eq 2 "$rc" 'live primary session blocks engine migration'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'live migration refusal leaves the row byte-unchanged'
has "$OUT" 'while swarm-live is live' 'live migration refusal names the session'

cat >> "$SWARM/swarm.conf" <<CONF
runtime | $REPO | BOT_RUNTIME | 445 | | | claude
CONF
RUNTIME_DIR="$HOME/.codex/channels/discord-runtime"; mkdir -p "$RUNTIME_DIR"; chmod 700 "$RUNTIME_DIR"
python3 - "$RUNTIME_DIR/runtime.json" "$$" <<'PY'
import datetime,json,sys
now=datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
json.dump({'schema':'codex-bridge-runtime/v1','pid':int(sys.argv[2]),'started_at':now,'updated_at':now,
'ready':True,'active':False,'queue_depth':0,'child_pid':None,'turn_started_at':None,
'last_completed_at':None,'last_error':None,'backend':'exec','app_server_endpoint':None},open(sys.argv[1],'w'))
PY
before="$(cat "$SWARM/swarm.conf")"
OUT="$(run_add runtime "$REPO" 445 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'live Codex runtime PID blocks engine migration even without tmux'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'runtime-live refusal leaves the row byte-unchanged'
has "$OUT" 'runtime PID' 'runtime-live refusal names the process boundary'

# Schema/freshness validation is intentionally stricter for status consumers,
# but an engine migration must still honor positive live PIDs in malformed
# state: configuration must never cross a process that may own the old runtime.
printf '{"schema":"foreign-runtime","pid":%s}\n' "$$" > "$RUNTIME_DIR/runtime.json"
OUT="$(run_add runtime "$REPO" 445 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'malformed runtime with a live recorded PID still blocks migration'
eq claude "$(engine_for runtime)" 'malformed runtime refusal preserves the old engine'

printf '{"schema":"foreign-runtime"}\n' > "$RUNTIME_DIR/runtime.json"
OUT="$(run_add runtime "$REPO" 445 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'malformed runtime without a salvageable PID is not treated as quiescent'
has "$OUT" 'runtime-unreadable' 'unclassifiable runtime state explains the fail-closed migration'
eq claude "$(engine_for runtime)" 'unclassifiable runtime state leaves the old engine configured'

rm -f "$RUNTIME_DIR/runtime.json"
mkdir -p "$RUNTIME_DIR/daemon.lock"
printf '{"schema":"codex-bridge-lock/v1","pid":%s}\n' "$$" > "$RUNTIME_DIR/daemon.lock/owner.json"
OUT="$(run_add runtime "$REPO" 445 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'live lock owner blocks migration without runtime state'
eq claude "$(engine_for runtime)" 'lock-owner refusal preserves the old engine'
rm -rf "$RUNTIME_DIR"

echo '=== engine commit rechecks liveness and CASes the original row ==='
LATE_REPO="$TMP/late-repo"; mkdir -p "$LATE_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
late | $LATE_REPO | BOT_LATE | 446 | | | claude
CONF
cat > "$TMP/tmux-late" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'has-session -t swarm-late'*)
    n=0; [ -f "$TMP/tmux-late.count" ] && n=\$(cat "$TMP/tmux-late.count")
    n=\$((n + 1)); printf '%s\n' "\$n" > "$TMP/tmux-late.count"
    [ "\$n" -ge 2 ] && exit 0
    exit 1 ;;
esac
exit 1
EOF
chmod +x "$TMP/tmux-late"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/tmux-late" bash "$ROOT/bin/swarm-add.sh" late "$LATE_REPO" 446 --skip-walkthrough --type cpo --engine codex 2>&1)"; rc=$?
eq 2 "$rc" 'session appearing during setup blocks the final engine commit'
eq claude "$(engine_for late)" 'late-session race leaves the old engine configured'
has "$OUT" 'while swarm-late is live' 'late-session refusal names the new live boundary'

CAS_REPO="$TMP/cas-repo"; mkdir -p "$CAS_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
cas | $CAS_REPO | BOT_CAS | 447 | | | claude
CONF
cat > "$TMP/tmux-cas" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'has-session -t swarm-cas'*)
    n=0; [ -f "$TMP/tmux-cas.count" ] && n=\$(cat "$TMP/tmux-cas.count")
    n=\$((n + 1)); printf '%s\n' "\$n" > "$TMP/tmux-cas.count"
    if [ "\$n" -ge 2 ]; then
      python3 - "$SWARM/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('cas | $CAS_REPO | BOT_CAS | 447 | | | claude', 'cas | $CAS_REPO | BOT_CAS | 448 | | | claude'); open(p,'w').write(s)
PY
    fi
    exit 1 ;;
esac
exit 1
EOF
chmod +x "$TMP/tmux-cas"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/tmux-cas" bash "$ROOT/bin/swarm-add.sh" cas "$CAS_REPO" 447 --skip-walkthrough --type cpo --engine codex 2>&1)"; rc=$?
eq 2 "$rc" 'concurrent row mutation fails the exact-row CAS'
eq claude "$(engine_for cas)" 'CAS refusal never overwrites the raced row engine'
has "$OUT" 'row changed during setup' 'CAS refusal is actionable'

LOCKED_REPO="$TMP/locked-repo"; mkdir -p "$LOCKED_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
locked | $LOCKED_REPO | BOT_LOCKED | 451 | | | claude
CONF
mkdir -m 700 "$SWARM/swarm.conf.mutation.lock"
printf '%s\n' "$$" > "$SWARM/swarm.conf.mutation.lock/owner"
OUT="$(run_add locked "$LOCKED_REPO" 451 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'global config mutation lock blocks an engine commit'
eq claude "$(engine_for locked)" 'lock contention leaves the old engine configured'
has "$OUT" 'mutation/incomplete transaction already exists' 'lock contention names the fail-closed shared transaction boundary'
rm -rf "$SWARM/swarm.conf.mutation.lock"

echo '=== failed Codex adoption never commits the engine switch ==='
BLOCKED_REPO="$TMP/blocked-repo"; mkdir -p "$BLOCKED_REPO"
printf 'operator-owned agents\n' > "$BLOCKED_REPO/AGENTS.md"
blocked_agents_id="$(file_id "$BLOCKED_REPO/AGENTS.md")"
cat >> "$SWARM/swarm.conf" <<CONF
blocked | $BLOCKED_REPO | BOT_BLOCKED | 555 | | | claude
CONF
OUT="$(run_add blocked "$BLOCKED_REPO" 555 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'foreign AGENTS makes target Codex setup fail'
eq claude "$(engine_for blocked)" 'failed target setup leaves old engine configured'
eq 'operator-owned agents' "$(cat "$BLOCKED_REPO/AGENTS.md")" 'failed migration preserves operator AGENTS bytes'
eq "$blocked_agents_id" "$(file_id "$BLOCKED_REPO/AGENTS.md")" 'no-write target refusal preserves the original AGENTS inode and metadata carrier'

echo '=== dedicated runtime failures cannot create an unlaunchable Codex row ==='
NORUNTIME_REPO="$TMP/no-runtime-repo"; mkdir -p "$NORUNTIME_REPO"; : > "$RUNTIME_LOG"
OUT="$(CODEX_RUNTIME_FAIL_PREPARE=1 run_add noruntime "$NORUNTIME_REPO" 557 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'prepare-workspace failure aborts Codex registration'
eq '' "$(engine_for noruntime)" 'prepare-workspace failure commits no Codex row'
has "$OUT" 'install --repo' 'runtime failure prints the one-time install remediation'
lacks "$(cat "$RUNTIME_LOG")" 'release-workspace' 'transactional prepare failure needs no extra release'

VERIFYFAIL_REPO="$TMP/verify-fail-repo"; mkdir -p "$VERIFYFAIL_REPO"; : > "$RUNTIME_LOG"
OUT="$(CODEX_RUNTIME_FAIL_VERIFY=1 run_add verifyfail "$VERIFYFAIL_REPO" 558 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'post-prepare verification failure aborts Codex registration'
eq '' "$(engine_for verifyfail)" 'verification failure commits no Codex row'
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $VERIFYFAIL_REPO" 'verification failure revokes uncommitted workspace authority'

FORWARD_VERIFY_REPO="$TMP/forward-verify-repo"; mkdir -p "$FORWARD_VERIFY_REPO"
HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-init.sh" "$FORWARD_VERIFY_REPO" --type cpo --engine claude >/dev/null
forward_agents_before="$(cat "$FORWARD_VERIFY_REPO/AGENTS.md")"
cat >> "$SWARM/swarm.conf" <<CONF
forwardverify | $FORWARD_VERIFY_REPO | BOT_FORWARDVERIFY | 563 | | | claude
CONF
: > "$RUNTIME_LOG"
OUT="$(CODEX_RUNTIME_FAIL_VERIFY=1 CODEX_RUNTIME_REQUIRE_LOCK=1 run_add forwardverify "$FORWARD_VERIFY_REPO" 563 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'failed forward migration remains uncommitted'
eq claude "$(engine_for forwardverify)" 'failed forward migration leaves the Claude row truthful'
eq "$forward_agents_before" "$(cat "$FORWARD_VERIFY_REPO/AGENTS.md")" 'failed forward migration restores the exact Claude AGENTS surface'
has "$(cat "$RUNTIME_LOG")" "verify --repo $FORWARD_VERIFY_REPO" 'known Claude AGENTS is adopted before runtime verification'
lacks "$(cat "$RUNTIME_LOG")" 'missing-lifecycle-lock' 'prepare, verify, and rollback all stay inside the lifecycle lock'

REPOSWAP_REPO="$TMP/repo-swap"; mkdir -p "$REPOSWAP_REPO"
HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-init.sh" "$REPOSWAP_REPO" --type cpo --engine claude >/dev/null
cat >> "$SWARM/swarm.conf" <<CONF
reposwap | $REPOSWAP_REPO | BOT_REPOSWAP | 565 | | | claude
CONF
: > "$RUNTIME_LOG"
OUT="$(CODEX_RUNTIME_SWAP_REPO=1 run_add reposwap "$REPOSWAP_REPO" 565 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'repository replacement during runtime preparation aborts migration'
eq claude "$(engine_for reposwap)" 'repository replacement cannot commit the target engine'
eq no "$([ -e "$REPOSWAP_REPO/AGENTS.md" ] && echo yes || echo no)" 'rollback never writes prior AGENTS bytes into a replacement inode'
has "$(cat "$RUNTIME_LOG")" "prepare-workspace --repo $REPOSWAP_REPO" 'repository-swap regression reaches the runtime boundary'
has "$OUT" 'repo identity changed' 'repository replacement is surfaced as a critical identity failure'

echo '=== unsafe canonical ACL never commits an engine switch ==='
ACCESS="$HOME/.claude/channels/discord/access.json"
mv "$ACCESS" "$TMP/access.backup"
printf 'outside acl sentinel\n' > "$TMP/outside-access"
ln -s "$TMP/outside-access" "$ACCESS"
cat >> "$SWARM/swarm.conf" <<CONF
aclblocked | $REPO | BOT_ACLBLOCKED | 448 | | | claude
CONF
OUT="$(run_add aclblocked "$REPO" 448 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 2 "$rc" 'symlinked access.json is refused'
eq claude "$(engine_for aclblocked)" 'ACL reconciliation failure preserves the old engine'
eq 'outside acl sentinel' "$(cat "$TMP/outside-access")" 'access symlink destination is untouched'
rm "$ACCESS"; mv "$TMP/access.backup" "$ACCESS"

echo '=== Claude account-partition ACLs remain authoritative across rerun and reverse migration ==='
LABELED_ACCESS="$HOME/.claude-accounts/max-a/channels/discord/access.json"
mkdir -p "$(dirname "$LABELED_ACCESS")"
printf '{"dmPolicy":"pairing","allowFrom":["owner"],"groups":{},"pending":{}}\n' > "$LABELED_ACCESS"
chmod 600 "$LABELED_ACCESS"
LABELED_CLAUDE_REPO="$TMP/labeled-claude-repo"; mkdir -p "$LABELED_CLAUDE_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
labeledclaude | $LABELED_CLAUDE_REPO | BOT_LABELEDCLAUDE | 566 | | max-a | claude
CONF
OUT="$(run_add labeledclaude "$LABELED_CLAUDE_REPO" 566 --skip-walkthrough --type cpo)"; rc=$?
eq 0 "$rc" 'idempotent labeled Claude onboarding succeeds'
eq True "$(/usr/bin/python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["groups"])' "$LABELED_ACCESS" 566)" 'labeled Claude rerun writes its account-partition ACL'
eq False "$(/usr/bin/python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["groups"])' "$HOME/.claude/channels/discord/access.json" 566)" 'labeled Claude rerun never writes the default account ACL'

LABELED_REVERSE_REPO="$TMP/labeled-reverse-repo"; mkdir -p "$LABELED_REVERSE_REPO"
HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-init.sh" "$LABELED_REVERSE_REPO" --type cpo --engine codex >/dev/null
cat >> "$SWARM/swarm.conf" <<CONF
labeledreverse | $LABELED_REVERSE_REPO | BOT_LABELEDREVERSE | 567 | | max-a | codex
CONF
: > "$RUNTIME_LOG"
OUT="$(run_add labeledreverse "$LABELED_REVERSE_REPO" 567 --skip-walkthrough --type cpo --engine claude)"; rc=$?
eq 0 "$rc" 'Codex-to-labeled-Claude migration succeeds'
eq claude "$(engine_for labeledreverse)" 'reverse migration commits Claude only after labeled ACL setup'
eq True "$(/usr/bin/python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["groups"])' "$LABELED_ACCESS" 567)" 'reverse migration prepares the actual labeled Claude ACL'
eq False "$(/usr/bin/python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["groups"])' "$HOME/.claude/channels/discord/access.json" 567)" 'reverse migration does not prepare the dormant default ACL'

echo '=== reverse Codex-to-Claude migration preserves Codex surfaces ==='
[ -f "$REPO/.codex/hooks.json" ] && before_hook="$(cat "$REPO/.codex/hooks.json")" || before_hook=""
before_agents="$(cat "$REPO/AGENTS.md")"
: > "$RUNTIME_LOG"
OUT="$(run_add legacy "$REPO" 111 --skip-walkthrough --type cpo --engine claude)"; rc=$?
eq 0 "$rc" 'Codex-to-Claude migration succeeds while stopped'
eq claude "$(engine_for legacy)" 'reverse migration commits Claude engine'
eq "$before_hook" "$(cat "$REPO/.codex/hooks.json")" 'reverse migration does not delete Codex surfaces'
eq "$before_agents" "$(cat "$REPO/AGENTS.md")" 'reverse migration retains Codex AGENTS while Codex siblings share the repo'
if codex_surfaces_ok "$REPO"; then ok 'reverse migration leaves every Codex sibling launchable'; else bad 'reverse migration leaves every Codex sibling launchable'; fi
lacks "$(cat "$RUNTIME_LOG")" 'release-workspace' 'shared repo authority remains while another Codex row references it'

LAST_REPO="$TMP/last-codex-repo"; mkdir -p "$LAST_REPO"
cat >> "$SWARM/swarm.conf" <<CONF
lastcodex | $LAST_REPO | BOT_LASTCODEX | 559 | | | codex
CONF
: > "$RUNTIME_LOG"
OUT="$(run_add lastcodex "$LAST_REPO" 559 --skip-walkthrough --type cpo --engine claude)"; rc=$?
eq 0 "$rc" 'last-reference Codex-to-Claude migration succeeds'
eq claude "$(engine_for lastcodex)" 'last-reference reverse migration commits Claude'
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $LAST_REPO" 'last-reference reverse migration revokes service workspace access'

RELEASE_BLOCKED_REPO="$TMP/release-blocked-repo"; mkdir -p "$RELEASE_BLOCKED_REPO"
HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-init.sh" "$RELEASE_BLOCKED_REPO" --type cpo --engine codex >/dev/null
release_agents_before="$(cat "$RELEASE_BLOCKED_REPO/AGENTS.md")"
cat >> "$SWARM/swarm.conf" <<CONF
releaseblocked | $RELEASE_BLOCKED_REPO | BOT_RELEASEBLOCKED | 560 | | | codex
CONF
: > "$RUNTIME_LOG"
OUT="$(CODEX_RUNTIME_FAIL_RELEASE=1 run_add releaseblocked "$RELEASE_BLOCKED_REPO" 560 --skip-walkthrough --type cpo --engine claude)"; rc=$?
eq 2 "$rc" 'failed last-reference release blocks reverse migration'
eq codex "$(engine_for releaseblocked)" 'failed release leaves the Codex row truthful'
has "$OUT" 'engine remains codex' 'failed release explains the fail-closed result'
eq "$release_agents_before" "$(cat "$RELEASE_BLOCKED_REPO/AGENTS.md")" 'failed reverse release restores the exact Codex AGENTS surface'

REVERSE_CAS_REPO="$TMP/reverse-cas-repo"; mkdir -p "$REVERSE_CAS_REPO"
HOME="$HOME" SWARM_HOME="$SWARM" bash "$ROOT/bin/swarm-init.sh" "$REVERSE_CAS_REPO" --type cpo --engine codex >/dev/null
reverse_agents_before="$(cat "$REVERSE_CAS_REPO/AGENTS.md")"
cat >> "$SWARM/swarm.conf" <<CONF
reversecas | $REVERSE_CAS_REPO | BOT_REVERSECAS | 561 | | | codex
CONF
cat > "$TMP/tmux-reverse-cas" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'has-session -t swarm-reversecas'*)
    n=0; [ -f "$TMP/tmux-reverse-cas.count" ] && n=\$(cat "$TMP/tmux-reverse-cas.count")
    n=\$((n + 1)); printf '%s\n' "\$n" > "$TMP/tmux-reverse-cas.count"
    if [ "\$n" -ge 2 ]; then
      python3 - "$SWARM/swarm.conf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('reversecas | $REVERSE_CAS_REPO | BOT_REVERSECAS | 561 | | | codex', 'reversecas | $REVERSE_CAS_REPO | BOT_REVERSECAS | 562 | | | codex'); open(p,'w').write(s)
PY
    fi
    exit 1 ;;
esac
exit 1
EOF
chmod +x "$TMP/tmux-reverse-cas"; : > "$RUNTIME_LOG"
OUT="$(HOME="$HOME" SWARM_HOME="$SWARM" SWARM_TMUX_BIN="$TMP/tmux-reverse-cas" bash "$ROOT/bin/swarm-add.sh" reversecas "$REVERSE_CAS_REPO" 561 --skip-walkthrough --type cpo --engine claude 2>&1)"; rc=$?
eq 2 "$rc" 'reverse migration CAS race is refused'
eq codex "$(engine_for reversecas)" 'raced reverse migration leaves the externally retained Codex engine'
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $REVERSE_CAS_REPO" 'reverse migration revokes before its row CAS'
has "$(cat "$RUNTIME_LOG")" "prepare-workspace --repo $REVERSE_CAS_REPO" 'lost reverse CAS restores still-referenced Codex authority'
has "$(cat "$RUNTIME_LOG")" "verify --repo $REVERSE_CAS_REPO" 'restored authority is re-verified before failure returns'
eq "$reverse_agents_before" "$(cat "$REVERSE_CAS_REPO/AGENTS.md")" 'lost reverse CAS restores the exact Codex AGENTS surface'

echo '=== canonical aliases commit one physical Codex repository identity ==='
ALIAS_REAL="$TMP/alias-real"; ALIAS_PATH="$TMP/alias-path"
mkdir -p "$ALIAS_REAL"; ln -s "$ALIAS_REAL" "$ALIAS_PATH"
cat >> "$SWARM/swarm.conf" <<CONF
aliasrow | $ALIAS_PATH | BOT_ALIASROW | 564 | | | claude
CONF
: > "$RUNTIME_LOG"
OUT="$(run_add aliasrow "$ALIAS_REAL" 564 --skip-walkthrough --type cpo --engine codex)"; rc=$?
eq 0 "$rc" 'migration accepts a configured symlink alias for the same physical repo'
alias_repo_field="$(awk -F'|' '$1 ~ /aliasrow/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$SWARM/swarm.conf")"
eq "$ALIAS_REAL" "$alias_repo_field" 'Codex commit rewrites the row to the canonical physical repo'
has "$(cat "$RUNTIME_LOG")" "prepare-workspace --repo $ALIAS_REAL" 'Codex authority uses the canonical repo rather than its alias'

echo '=== fresh Codex and default Claude rows retain distinct shapes ==='
OUT="$(run_add fresh "$REPO" 222 --skip-walkthrough --type cpo --engine=codex)"; rc=$?
eq 0 "$rc" 'fresh Codex registration succeeds'
eq codex "$(engine_for fresh)" 'fresh Codex row writes field seven'
eq default "$(pool_for fresh)" 'fresh Codex row writes the explicit default auth pool'
eq 8 "$(field_count fresh)" 'fresh Codex row has the eight-field engine/pool schema'

: > "$RUNTIME_LOG"
OUT="$(run_add default "$REPO" 333 --skip-walkthrough --type cpo)"; rc=$?
eq 0 "$rc" 'fresh default registration succeeds'
eq 5 "$(field_count default)" 'fresh Claude row preserves the historical five-field shape'
eq '' "$(cat "$RUNTIME_LOG")" 'fresh Claude registration never invokes the Codex runtime lifecycle'
if codex_surfaces_ok "$REPO"; then ok 'fresh Claude sibling cannot degrade shared Codex managed surfaces'; else bad 'fresh Claude sibling cannot degrade shared Codex managed surfaces'; fi

echo '=== invalid engine is rejected before writes ==='
before="$(cat "$SWARM/swarm.conf")"
OUT="$(run_add invalid "$REPO" 444 --skip-walkthrough --type cpo --engine api 2>&1)"; rc=$?
eq 1 "$rc" 'unknown engine is rejected'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'invalid engine leaves swarm.conf untouched'
has "$OUT" '--engine must be claude or codex' 'invalid engine error is actionable'

echo '=== unknown Codex auth pool is rejected before writes ==='
before="$(cat "$SWARM/swarm.conf")"
OUT="$(run_add invalidpool "$REPO" 445 --skip-walkthrough --type cpo --engine codex --codex-auth-pool missing 2>&1)"; rc=$?
eq 2 "$rc" 'undeclared Codex auth pool is rejected'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'unknown pool leaves swarm.conf byte-unchanged'
has "$OUT" "unknown auth pool 'missing'" 'unknown pool error identifies the rejected selector'

echo '=== delimiter/control-bearing repository paths are rejected before config writes ==='
BAD_PIPE_REPO="$TMP/bad|repo"; mkdir -p "$BAD_PIPE_REPO"
before="$(cat "$SWARM/swarm.conf")"
OUT="$(run_add badpipeclaude "$BAD_PIPE_REPO" 568 --skip-walkthrough --type cpo 2>&1)"; rc=$?
eq 1 "$rc" 'Claude registration rejects a pipe-bearing repo path'
OUT_CODEX="$(run_add badpipecodex "$BAD_PIPE_REPO" 569 --skip-walkthrough --type cpo --engine codex 2>&1)"; rc=$?
eq 1 "$rc" 'Codex registration rejects a pipe-bearing repo path'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'pipe-bearing paths cannot corrupt the config schema'
has "$OUT$OUT_CODEX" 'repo path cannot contain' 'path refusal explains the delimiter boundary'
BAD_CONTROL_REPO="$TMP/bad"$'\n'"repo"; mkdir -p "$BAD_CONTROL_REPO"
OUT="$(run_add badcontrol "$BAD_CONTROL_REPO" 570 --skip-walkthrough --type cpo 2>&1)"; rc=$?
eq 1 "$rc" 'registration rejects a control-bearing repo path'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'control-bearing paths cannot create injected config rows'
BAD_TRAILING_NL_REPO="$TMP/trailing-newline"$'\n'; mkdir -p "$BAD_TRAILING_NL_REPO"
OUT="$(run_add badtrailingnl "$BAD_TRAILING_NL_REPO" 571 --skip-walkthrough --type cpo 2>&1)"; rc=$?
eq 1 "$rc" 'raw trailing-newline repo path is rejected before canonical command substitution'
BAD_TRAILING_SPACE_REPO="$TMP/trailing-space "; mkdir -p "$BAD_TRAILING_SPACE_REPO"
OUT="$(run_add badtrailingspace "$BAD_TRAILING_SPACE_REPO" 572 --skip-walkthrough --type cpo 2>&1)"; rc=$?
eq 1 "$rc" 'schema-trim-changing trailing-space repo path is rejected'
BAD_ALIAS_TARGET="$TMP/alias-target"$'\n'; BAD_ALIAS_INPUT="$TMP/clean-alias-input"
mkdir -p "$BAD_ALIAS_TARGET"; ln -s "$BAD_ALIAS_TARGET" "$BAD_ALIAS_INPUT"
OUT="$(run_add badcanonicalalias "$BAD_ALIAS_INPUT" 573 --skip-walkthrough --type cpo 2>&1)"; rc=$?
eq 1 "$rc" 'clean alias to a control-bearing canonical target is rejected'
eq "$before" "$(cat "$SWARM/swarm.conf")" 'trailing whitespace paths cannot redirect or corrupt registration'

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
