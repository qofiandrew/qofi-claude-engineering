#!/usr/bin/env bash
# Evidence-bound recovery must preserve a retained signal on every ambiguity.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-recover.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

SWARM="$TMP/swarm"
HOME_DIR="$TMP/home"
STUB="$TMP/stub"
REPO="$TMP/repo"
mkdir -m 700 "$SWARM" "$HOME_DIR" "$STUB" "$REPO"
printf 'qofi-swarm-recovery-test-fixture/v1\n' > "$TMP/.swarm-recovery-test-fixture"
chmod 600 "$TMP/.swarm-recovery-test-fixture"
ln -s "$ROOT/templates" "$SWARM/templates"
CONF="$SWARM/swarm.conf"
MUTATION="$CONF.mutation.lock"
LAUNCH_ROOT="$CONF.launch.locks"
SESSIONS="$TMP/sessions"
TMUX_LOG="$TMP/tmux.log"
RUNTIME_LOG="$TMP/runtime.log"
: > "$SESSIONS"
: > "$TMUX_LOG"
: > "$RUNTIME_LOG"

cat > "$STUB/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in
  list-sessions)
    cat "$TMUX_SESSIONS_FILE"
    exit "${TMUX_LIST_RC:-0}"
    ;;
  *) exit 99 ;;
esac
SH
cat > "$STUB/runtime" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNTIME_LOG"
if [ "${1:-}" = workspace-journal-evidence ] && [ "${2:-}" = --repo ]; then
  _journal_sha="${JOURNAL_SHA_VALUE:-$(printf '%064d' 1)}"
  printf '{"journal_sha256":"%s","present":true,"repo":"%s","schema":"qofi-codex-workspace-journal-evidence/v1"}\n' "$_journal_sha" "$3"
  exit 0
fi
if [ "${1:-}" = release-workspace ]; then
  [ "${4:-}" = --expected-journal-sha256 ] || exit 92
  [ "${5:-}" = "$(printf '%064d' 1)" ] || exit 93
fi
if [ "${1:-}" = quiescence-proof ]; then
  [ "${RUNTIME_ORPHAN_ACTIVE:-0}" = 0 ] || exit 94
  printf '%s\n' '{"schema":"qofi-codex-quiescence-proof/v1","status":"quiescent"}'
  exit 0
fi
if [ "${RUNTIME_MUTATE_REPO:-0}" = 1 ] && [ "${1:-}" = prepare-workspace ] && [ "${2:-}" = --repo ]; then
  chmod 700 "$3" || exit 91
fi
exit "${RUNTIME_RC:-0}"
SH
chmod 755 "$STUB/tmux" "$STUB/runtime"

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi
}
has() {
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi
}
lacks() {
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi
}

recover() {
  HOME="$HOME_DIR" SWARM_HOME="$SWARM" \
    SWARM_RECOVERY_ALLOW_FAKE_HOME=1 \
    SWARM_RECOVERY_TEST_ROOT="$TMP" \
    SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMUX_LOG" \
    TMUX_SESSIONS_FILE="$SESSIONS" \
    SWARM_CODEX_RUNTIME_BIN="$STUB/runtime" RUNTIME_LOG="$RUNTIME_LOG" \
    bash "$ROOT/bin/swarm-recover.sh" "$@"
}

set_conf_claude() {
  printf 'alpha | %s | BOT_ALPHA | 123 | | | claude\n' "$REPO" > "$CONF"
  chmod 644 "$CONF"
}

set_conf_codex() {
  printf 'alpha | %s | BOT_ALPHA | 123 | | | codex\n' "$REPO" > "$CONF"
  chmod 644 "$CONF"
}

dead_lock() {
  local path="$1"
  mkdir -m 700 "$path"
  printf '2147483647\n' > "$path/owner"
  chmod 600 "$path/owner"
}

receipt_from() {
  printf '%s\n' "$1" | sed -n 's/^RECEIPT=//p'
}

reset_state() {
  rm -rf "$MUTATION" "$LAUNCH_ROOT" "$HOME_DIR/.codex"
  : > "$SESSIONS"
  : > "$TMUX_LOG"
  : > "$RUNTIME_LOG"
  set_conf_claude
}

make_runtime() {
  local pid="$1" state="$HOME_DIR/.codex/channels/discord-alpha"
  mkdir -m 700 -p "$state"
  chmod 700 "$HOME_DIR/.codex" "$HOME_DIR/.codex/channels" "$state"
  cat > "$state/runtime.json" <<EOF
{"schema":"codex-bridge-runtime/v1","pid":$pid,"started_at":"2026-07-11T00:00:00Z","updated_at":"2026-07-11T00:00:00Z","ready":true,"active":false,"queue_depth":0,"child_pid":null,"backend":"exec"}
EOF
  chmod 600 "$state/runtime.json"
}

LEASE_TOKEN="123e4567-e89b-42d3-a456-426614174000"
make_repo_lease() {
  local pid="$1" token="${2:-$LEASE_TOKEN}" operation="${3:-turn}"
  local pair dev ino root lock state
  pair="$(/usr/bin/python3 -I -B - "$REPO" <<'PY'
import os,sys
info=os.lstat(sys.argv[1]); print(f'{info.st_dev} {info.st_ino}')
PY
)"
  read -r dev ino <<EOF
$pair
EOF
  root="$HOME_DIR/.codex/channels/repo-locks"
  state="$HOME_DIR/.codex/channels/discord-alpha"
  mkdir -m 700 -p "$root"
  chmod 700 "$HOME_DIR/.codex" "$HOME_DIR/.codex/channels" "$root"
  lock="$root/$dev-$ino.lock"
  mkdir -m 700 "$lock"
  cat > "$lock/owner.json" <<EOF
{"schema":"qofi-codex-repo-lease/v1","pid":$pid,"token":"$token","repo_dev":$dev,"repo_ino":$ino,"repo_path":"$REPO","swarm_name":"alpha","state_dir":"$state","operation":"$operation","started_at":"2026-07-11T00:00:00Z"}
EOF
  chmod 600 "$lock/owner.json"
  printf '%s\n' "$lock"
}

make_release_tombstone() { # canonical-lock owner-name token phase
  /usr/bin/python3 -I -B - "$1" "$2" "$3" "$4" <<'PY'
import hashlib,json,os,sys
lock,owner_name,token,phase=sys.argv[1:5]
parent=os.path.dirname(lock); base=os.path.basename(lock)
old_name=f".{base}.release.0123456789abcdef01234567"
old_path=os.path.join(parent,old_name); owner_path=os.path.join(lock,owner_name)
l=os.lstat(lock); o=os.lstat(owner_path); raw=open(owner_path,'rb').read()
marker={
  "schema":"qofi-lock-release/v1","phase":"exchanged","lock_name":base,
  "old_lock_name":old_name,"old_lock_dev":l.st_dev,"old_lock_ino":l.st_ino,
  "owner_name":owner_name,"owner_dev":o.st_dev,"owner_ino":o.st_ino,
  "owner_sha256":hashlib.sha256(raw).hexdigest(),
  "token_sha256":hashlib.sha256(token.encode()).hexdigest(),
}
def write_marker(path):
  os.mkdir(path,0o700)
  with open(os.path.join(path,'release.json'),'w') as out:
    json.dump(marker,out,sort_keys=True,separators=(',',':')); out.write('\n')
  os.chmod(os.path.join(path,'release.json'),0o600)
if phase=='pre-exchange':
  write_marker(old_path)
elif phase in ('exchanged','empty-old','missing-old'):
  os.rename(lock,old_path); write_marker(lock)
  if phase in ('empty-old','missing-old'):
    os.unlink(os.path.join(old_path,owner_name))
  if phase=='missing-old': os.rmdir(old_path)
else: raise SystemExit(2)
print(old_path)
PY
}

echo "=== fake-home isolation is strictly test-fixture gated ==="
reset_state
dead_lock "$MUTATION"
OUT="$(HOME="$HOME_DIR" SWARM_HOME="$SWARM" SWARM_RECOVERY_ALLOW_FAKE_HOME=1 \
  SWARM_TMUX_BIN="$STUB/tmux" TMUX_LOG="$TMUX_LOG" TMUX_SESSIONS_FILE="$SESSIONS" \
  SWARM_CODEX_RUNTIME_BIN="$STUB/runtime" RUNTIME_LOG="$RUNTIME_LOG" \
  bash "$ROOT/bin/swarm-recover.sh" audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "fake HOME flag alone cannot redirect production recovery evidence"
has "$OUT" "explicit canonical test root" "fake-home refusal requires the isolated fixture boundary"
if [ -d "$MUTATION" ]; then ok "ungated fake HOME retains the lock"; else bad "ungated fake HOME retains the lock"; fi

echo "=== read-only mutation audit binds dead owner and exact evidence ==="
reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha 2>&1)"; RC=$?
eq 0 "$RC" "dead mutation owner reaches audited-ready state"
has "$OUT" "OWNER_STATE=dead" "audit reports why PID evidence is acceptable"
RECEIPT="$(receipt_from "$OUT")"
case "$RECEIPT" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#RECEIPT}" -eq 64 ] && ok "audit emits a 64-hex receipt" || bad "audit emits a 64-hex receipt" ;;
  *) bad "audit emits a 64-hex receipt" ;;
esac
if [ -d "$MUTATION" ]; then ok "audit is non-mutating"; else bad "audit is non-mutating"; fi

echo ""
echo "=== acknowledgement and receipt are hard mutation gates ==="
OUT_NO_ACK="$(recover recover mutation --receipt "$RECEIPT" --operation account --name alpha 2>&1)"; RC=$?
eq 2 "$RC" "missing acknowledgement refuses recovery"
has "$OUT_NO_ACK" "no state changed" "missing acknowledgement is explicit"
if [ -d "$MUTATION" ]; then ok "missing acknowledgement retains lock"; else bad "missing acknowledgement retains lock"; fi

BAD_RECEIPT="$(printf '%064d' 0)"
OUT_BAD="$(recover recover mutation --receipt "$BAD_RECEIPT" --ack-reconciled --operation account --name alpha 2>&1)"; RC=$?
eq 3 "$RC" "wrong receipt refuses recovery"
has "$OUT_BAD" "receipt mismatch" "wrong receipt explains fresh-audit requirement"
if [ -d "$MUTATION" ]; then ok "wrong receipt retains lock"; else bad "wrong receipt retains lock"; fi

BEFORE_CONF="$(shasum -a 256 "$CONF" | awk '{print $1}')"
recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation account --name alpha >/dev/null 2>&1; RC=$?
eq 0 "$RC" "matching receipt plus acknowledgement recovers exact lock"
if [ ! -e "$MUTATION" ]; then ok "successful recovery removes retained mutation lock"; else bad "successful recovery removes retained mutation lock"; fi
eq "$BEFORE_CONF" "$(shasum -a 256 "$CONF" | awk '{print $1}')" "Claude config remains byte-identical"
has "$(cat "$RUNTIME_LOG")" "quiescence-proof" "recovery proves the hidden Codex uid quiescent before deletion"
lacks "$(cat "$RUNTIME_LOG")" "prepare-workspace" "Claude recovery invokes no Codex workspace mutation"
lacks "$(cat "$RUNTIME_LOG")" "release-workspace" "Claude recovery invokes no Codex workspace release"
if grep -qv '^list-sessions ' "$TMUX_LOG"; then bad "recovery never kills or attaches tmux sessions"; else ok "recovery never kills or attaches tmux sessions"; fi

reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha)"; RECEIPT="$(receipt_from "$OUT")"
export RUNTIME_ORPHAN_ACTIVE=1
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation account --name alpha 2>&1)"; RC=$?
unset RUNTIME_ORPHAN_ACTIVE
eq 3 "$RC" "orphan hidden-UID process proof blocks recovery deletion"
has "$OUT" "quiescence could not be proven" "orphan refusal names the root proof boundary"
if [ -d "$MUTATION" ]; then ok "orphan proof failure retains mutation lock"; else bad "orphan proof failure retains mutation lock"; fi

reset_state
dead_lock "$MUTATION"
OLD_RELEASE="$(make_release_tombstone "$MUTATION" owner - exchanged)"
OUT="$(recover audit mutation --operation account --name alpha)"; RECEIPT="$(receipt_from "$OUT")"
recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation account --name alpha >/dev/null 2>&1; RC=$?
eq 0 "$RC" "mutation recovery completes an exchanged plain-owner tombstone"
if [ ! -e "$MUTATION" ] && [ ! -e "$OLD_RELEASE" ]; then ok "mutation tombstone and old owner are both removed"; else bad "mutation tombstone and old owner are both removed"; fi

reset_state
mkdir -m 700 "$LAUNCH_ROOT"; dead_lock "$LAUNCH_ROOT/alpha"
OLD_RELEASE="$(make_release_tombstone "$LAUNCH_ROOT/alpha" owner - pre-exchange)"
OUT="$(recover audit launch alpha)"; RECEIPT="$(receipt_from "$OUT")"
recover recover launch alpha --receipt "$RECEIPT" --ack-reconciled >/dev/null 2>&1; RC=$?
eq 0 "$RC" "launch recovery atomically advances a pre-exchange plain-owner tombstone"
if [ ! -e "$LAUNCH_ROOT/alpha" ] && [ ! -e "$OLD_RELEASE" ]; then ok "launch tombstone bundle is removed exactly"; else bad "launch tombstone bundle is removed exactly"; fi

echo ""
echo "=== live and malformed owners never produce a receipt ==="
reset_state
mkdir -m 700 "$MUTATION"; printf '%s\n' "$$" > "$MUTATION/owner"; chmod 600 "$MUTATION/owner"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "live lock owner is refused"
has "$OUT" "is live" "live-owner refusal is diagnostic"
if [ -d "$MUTATION" ]; then ok "live-owner refusal retains lock"; else bad "live-owner refusal retains lock"; fi

reset_state
dead_lock "$MUTATION"; : > "$MUTATION/unexpected"; chmod 600 "$MUTATION/unexpected"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "unexpected lock entry is refused"
has "$OUT" "neither an owner lock nor an exact release marker" "malformed lock boundary is explained"
if [ -d "$MUTATION" ]; then ok "malformed lock is retained"; else bad "malformed lock is retained"; fi

echo ""
echo "=== config and inode ABA invalidate an old receipt ==="
reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha)"; RECEIPT="$(receipt_from "$OUT")"
printf '# noncooperating edit\n' >> "$CONF"
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled --operation account --name alpha 2>&1)"; RC=$?
eq 3 "$RC" "config digest change invalidates receipt"
if [ -d "$MUTATION" ]; then ok "config change retains lock"; else bad "config change retains lock"; fi

reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha)"; RECEIPT="$(receipt_from "$OUT")"
mv "$MUTATION" "$TMP/original-mutation-lock"
dead_lock "$MUTATION"
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled --operation account --name alpha 2>&1)"; RC=$?
eq 3 "$RC" "replacement lock inode invalidates receipt"
has "$OUT" "receipt mismatch" "ABA refusal requires a fresh audit"
if [ -d "$MUTATION" ] && [ -d "$TMP/original-mutation-lock" ]; then ok "ABA refusal removes neither inode"; else bad "ABA refusal removes neither inode"; fi
rm -rf "$TMP/original-mutation-lock"

reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha)"; RECEIPT="$(receipt_from "$OUT")"
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation up --name alpha 2>&1)"; RC=$?
eq 3 "$RC" "reconciliation operation/name tuple is part of the receipt"
has "$OUT" "action-bound receipt mismatch" "action mismatch requires a new exact audit"
if [ -d "$MUTATION" ]; then ok "action mismatch retains mutation lock"; else bad "action mismatch retains mutation lock"; fi

echo ""
echo "=== fleet and per-name launch quiescence are scoped correctly ==="
reset_state
dead_lock "$MUTATION"
printf 'swarm-alpha\n' > "$SESSIONS"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "mutation audit refuses a running fleet session"
has "$OUT" "fleet tmux sessions remain" "fleet quiescence refusal is explicit"

reset_state
dead_lock "$MUTATION"
mkdir -m 700 "$LAUNCH_ROOT"; dead_lock "$LAUNCH_ROOT/alpha"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "mutation recovery refuses an outstanding launch transaction"
has "$OUT" "recover each exact launch" "lock ordering directs launch recovery first"

printf 'swarm-alpha\n' > "$SESSIONS"
OUT="$(recover audit launch alpha 2>&1)"; RC=$?
eq 3 "$RC" "launch audit refuses its exact tmux session"
has "$OUT" "still exists" "launch quiescence refusal names exact session"

: > "$SESSIONS"
OUT="$(recover audit launch alpha)"; RC=$?; RECEIPT="$(receipt_from "$OUT")"
eq 0 "$RC" "launch audit can run while older global transaction signal remains"
recover recover launch alpha --receipt "$RECEIPT" --ack-reconciled >/dev/null 2>&1; RC=$?
eq 0 "$RC" "exact quiescent launch lock recovers first"
if [ ! -e "$LAUNCH_ROOT/alpha" ] && [ -d "$MUTATION" ]; then ok "launch recovery preserves global transaction signal"; else bad "launch recovery preserves global transaction signal"; fi

echo ""
echo "=== malformed and live Codex runtime evidence fails closed ==="
reset_state
dead_lock "$MUTATION"
STATE="$HOME_DIR/.codex/channels/discord-alpha"
mkdir -m 700 -p "$STATE"; chmod 700 "$HOME_DIR/.codex" "$HOME_DIR/.codex/channels" "$STATE"
printf '{bad json\n' > "$STATE/runtime.json"; chmod 600 "$STATE/runtime.json"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "malformed runtime state blocks mutation recovery"
has "$OUT" "runtime state for alpha is malformed" "malformed runtime is identified"
if [ -d "$MUTATION" ]; then ok "malformed runtime retains transaction signal"; else bad "malformed runtime retains transaction signal"; fi

reset_state
dead_lock "$MUTATION"; make_runtime "$$"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "live Codex runtime PID blocks recovery even on a Claude row"
has "$OUT" "live PID" "live runtime refusal is explicit"

reset_state
dead_lock "$MUTATION"; make_runtime 2147483647
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 0 "$RC" "well-formed dead runtime evidence is auditable"
has "$OUT" $'RUNTIME\talpha\tquiescent' "dead runtime is reported as quiescent, not silently ignored"

echo ""
echo "=== Codex workspace mutations are explicit and config-consistent ==="
reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation)"; RECEIPT="$(receipt_from "$OUT")"
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation remove --name retired --engine claude --repo "$REPO" \
  --workspace-action release 2>&1)"; RC=$?
eq 2 "$RC" "Claude recovery rejects every Codex workspace action"
has "$OUT" "Claude add/remove cannot carry" "Claude action refusal names the engine boundary"
eq "" "$(cat "$RUNTIME_LOG")" "Claude action refusal reaches no root runtime command"

OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation remove --name retired --engine codex --repo "$REPO" 2>&1)"; RC=$?
eq 2 "$RC" "Codex add/remove recovery requires a named workspace action"
eq "" "$(cat "$RUNTIME_LOG")" "missing action cannot reach privileged runtime helper"
if [ -d "$MUTATION" ]; then ok "missing workspace action retains lock"; else bad "missing workspace action retains lock"; fi

OUT="$(recover audit mutation --operation remove --name retired --engine codex \
  --repo "$REPO" --workspace-action release)"; RECEIPT="$(receipt_from "$OUT")"
: > "$RUNTIME_LOG"
recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation remove --name retired --engine codex --repo "$REPO" \
  --workspace-action release >/dev/null 2>&1; RC=$?
eq 0 "$RC" "explicit orphan-journal release permits recovery"
has "$(cat "$RUNTIME_LOG")" "release-workspace --repo $REPO --expected-journal-sha256" "release action is journal-CAS-bound exact argv"

reset_state
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation remove --name retired --engine codex \
  --repo "$REPO" --workspace-action release)"; RECEIPT="$(receipt_from "$OUT")"
: > "$RUNTIME_LOG"
export JOURNAL_SHA_VALUE="$(printf '%064d' 2)"
OUT="$(recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation remove --name retired --engine codex --repo "$REPO" \
  --workspace-action release 2>&1)"; RC=$?
unset JOURNAL_SHA_VALUE
eq 3 "$RC" "root workspace-journal change invalidates the action receipt"
has "$OUT" "action-bound receipt mismatch" "journal mismatch requires a new exact audit"
lacks "$(cat "$RUNTIME_LOG")" "release-workspace" "changed root journal cannot reach authority release"
if [ -d "$MUTATION" ]; then ok "journal mismatch retains mutation lock"; else bad "journal mismatch retains mutation lock"; fi

reset_state
set_conf_codex
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation remove --name alpha --engine codex \
  --repo "$REPO" --workspace-action release 2>&1)"; RC=$?
eq 3 "$RC" "release conflicts during action-bound audit with a current Codex reference"
has "$OUT" "configured Codex reference" "reference conflict explains safe action choice"
lacks "$(cat "$RUNTIME_LOG")" "release-workspace" "conflicting release runs no mutating runtime command"
if [ -d "$MUTATION" ]; then ok "conflicting release retains lock"; else bad "conflicting release retains lock"; fi

OUT="$(recover audit mutation --operation add --name alpha --engine codex \
  --repo "$REPO" --workspace-action prepare)"; RECEIPT="$(receipt_from "$OUT")"
: > "$RUNTIME_LOG"
recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation add --name alpha --engine codex --repo "$REPO" \
  --workspace-action prepare >/dev/null 2>&1; RC=$?
eq 0 "$RC" "explicit prepare reconciles a currently referenced Codex workspace"
RUNTIME_COMMANDS="$(cat "$RUNTIME_LOG")"
has "$RUNTIME_COMMANDS" "prepare-workspace --repo $REPO" "prepare mutation is explicit"
has "$RUNTIME_COMMANDS" "verify --repo $REPO" "current Codex authority is verified before unlock"

reset_state
set_conf_codex
chmod 755 "$REPO"
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation add --name alpha --engine codex \
  --repo "$REPO" --workspace-action prepare)"; RECEIPT="$(receipt_from "$OUT")"
export RUNTIME_MUTATE_REPO=1
recover recover mutation --receipt "$RECEIPT" --ack-reconciled \
  --operation add --name alpha --engine codex --repo "$REPO" \
  --workspace-action prepare >/dev/null 2>&1; RC=$?
unset RUNTIME_MUTATE_REPO
eq 0 "$RC" "real workspace metadata mutation does not invalidate its inode-bound recovery receipt"
eq 700 "$(stat -f %Lp "$REPO" 2>/dev/null || stat -c %a "$REPO")" "mutating recovery fixture actually changed repository mode"

if [ "$(uname -s)" = Darwin ]; then
  reset_state
  dead_lock "$MUTATION"
  chmod +a 'everyone allow read' "$MUTATION/owner"
  OUT="$(recover audit mutation 2>&1)"; RC=$?
  eq 3 "$RC" "mutation owner with an extended ACL is not auditable"
  has "$OUT" "must not have an extended ACL" "mutation ACL refusal names the hidden authority"
  chmod -N "$MUTATION/owner"

  chmod +a 'everyone allow read' "$CONF"
  OUT="$(recover audit mutation 2>&1)"; RC=$?
  eq 3 "$RC" "swarm.conf with an extended ACL is not auditable"
  has "$OUT" "swarm.conf must not have an extended ACL" "config ACL refusal is explicit"
  chmod -N "$CONF"
fi

echo ""
echo "=== shared repo lease recovery binds config, repo inode, token, and owner ==="
reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?; RECEIPT="$(receipt_from "$OUT")"
eq 0 "$RC" "dead exact repo lease reaches audited-ready state"
has "$OUT" "REPO_ID=" "repo lease audit reports its bound device/inode"
has "$OUT" "LEASE_OPERATION=turn" "repo lease audit reports the bounded operation"
has "$OUT" "OWNER_TOKEN_SHA256=" "repo lease audit reports only the token digest"
lacks "$OUT" "$LEASE_TOKEN" "repo lease audit never prints the raw owner token"

OUT_NO_ACK="$(recover recover repo-lease "$REPO" --receipt "$RECEIPT" 2>&1)"; RC=$?
eq 2 "$RC" "repo lease recovery also requires acknowledgement"
if [ -d "$LEASE" ]; then ok "missing repo acknowledgement retains lease"; else bad "missing repo acknowledgement retains lease"; fi

recover recover repo-lease "$REPO" --receipt "$RECEIPT" --ack-reconciled >/dev/null 2>&1; RC=$?
eq 0 "$RC" "dead token-bound repo lease recovers"
if [ ! -e "$LEASE" ]; then ok "repo recovery removes only the exact lease directory"; else bad "repo recovery removes only the exact lease directory"; fi
if [ -d "$HOME_DIR/.codex/channels/repo-locks" ]; then ok "repo recovery preserves the shared lease root"; else bad "repo recovery preserves the shared lease root"; fi

LEASE="$(make_repo_lease 2147483647 "$LEASE_TOKEN" startup)"
OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?; STARTUP_RECEIPT="$(receipt_from "$OUT")"
eq 0 "$RC" "dead startup lease uses the same exact recovery boundary"
has "$OUT" "LEASE_OPERATION=startup" "startup lease operation is reported explicitly"
recover recover repo-lease "$REPO" --receipt "$STARTUP_RECEIPT" --ack-reconciled >/dev/null 2>&1

for RELEASE_PHASE in pre-exchange exchanged missing-old; do
  reset_state
  set_conf_codex
  LEASE="$(make_repo_lease 2147483647)"
  OLD_RELEASE="$(make_release_tombstone "$LEASE" owner.json "$LEASE_TOKEN" "$RELEASE_PHASE")"
  OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?; RELEASE_RECEIPT="$(receipt_from "$OUT")"
  eq 0 "$RC" "repo release tombstone phase $RELEASE_PHASE is auditable"
  recover recover repo-lease "$REPO" --receipt "$RELEASE_RECEIPT" --ack-reconciled >/dev/null 2>&1; RC=$?
  eq 0 "$RC" "repo release tombstone phase $RELEASE_PHASE completes exactly"
  if [ ! -e "$LEASE" ] && [ ! -e "$OLD_RELEASE" ]; then ok "repo $RELEASE_PHASE bundle leaves no active lock"; else bad "repo $RELEASE_PHASE bundle leaves no active lock"; fi
done

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
OLD_RELEASE="$(make_release_tombstone "$LEASE" owner.json "$LEASE_TOKEN" exchanged)"
INERT="$HOME_DIR/.codex/channels/repo-locks/.$(basename "$LEASE").released.abcdefabcdefabcdefabcdef"
mv "$LEASE" "$INERT"
rm -rf "$OLD_RELEASE"
dead_lock "$MUTATION"
OUT="$(recover audit mutation --operation account --name alpha)"; RC=$?; RECEIPT="$(receipt_from "$OUT")"
eq 0 "$RC" "finalized .released repo marker is inert for mutation recovery"
recover recover mutation --receipt "$RECEIPT" --ack-reconciled --operation account --name alpha >/dev/null 2>&1; RC=$?
eq 0 "$RC" "inert finalized marker cannot block exact mutation recovery"

reset_state
set_conf_codex
LEASE="$(make_repo_lease "$$")"
OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?
eq 3 "$RC" "live repo lease owner is refused"
has "$OUT" "is live" "live repo lease owner is diagnostic"
if [ -d "$LEASE" ]; then ok "live repo lease is retained"; else bad "live repo lease is retained"; fi

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
chmod 644 "$LEASE/owner.json"
OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?
eq 3 "$RC" "wrong-mode repo owner is refused"
has "$OUT" "expected 0600" "repo owner mode contract is explicit"

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
OUT="$(recover audit repo-lease "$REPO")"; RECEIPT="$(receipt_from "$OUT")"
/usr/bin/python3 -I -B - "$LEASE/owner.json" <<'PY'
import json,sys
path=sys.argv[1]; value=json.load(open(path)); value['token']='223e4567-e89b-42d3-a456-426614174000'
with open(path,'w') as out: json.dump(value,out); out.write('\n')
PY
chmod 600 "$LEASE/owner.json"
OUT="$(recover recover repo-lease "$REPO" --receipt "$RECEIPT" --ack-reconciled 2>&1)"; RC=$?
eq 3 "$RC" "repo owner token change invalidates receipt"
if [ -d "$LEASE" ]; then ok "token mismatch retains repo lease"; else bad "token mismatch retains repo lease"; fi

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
OUT="$(recover audit repo-lease "$REPO")"; RECEIPT="$(receipt_from "$OUT")"
mv "$LEASE" "$TMP/original-repo-lease"
mkdir -m 700 "$LEASE"
cp "$TMP/original-repo-lease/owner.json" "$LEASE/owner.json"; chmod 600 "$LEASE/owner.json"
OUT="$(recover recover repo-lease "$REPO" --receipt "$RECEIPT" --ack-reconciled 2>&1)"; RC=$?
eq 3 "$RC" "repo lease directory ABA invalidates receipt"
if [ -d "$LEASE" ] && [ -d "$TMP/original-repo-lease" ]; then ok "repo ABA refusal removes neither inode"; else bad "repo ABA refusal removes neither inode"; fi
rm -rf "$TMP/original-repo-lease"

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
OUT="$(recover audit repo-lease "$REPO")"; RECEIPT="$(receipt_from "$OUT")"
mv "$REPO" "$TMP/original-repo"
mkdir -m 700 "$REPO"
OUT="$(recover recover repo-lease "$REPO" --receipt "$RECEIPT" --ack-reconciled 2>&1)"; RC=$?
eq 3 "$RC" "repository inode replacement invalidates repo lease receipt"
if [ -d "$LEASE" ]; then ok "repo inode mismatch retains old lease"; else bad "repo inode mismatch retains old lease"; fi
rm -rf "$REPO"; mv "$TMP/original-repo" "$REPO"

reset_state
set_conf_codex
LEASE="$(make_repo_lease 2147483647)"
set_conf_claude
OUT="$(recover audit repo-lease "$REPO" 2>&1)"; RC=$?
eq 0 "$RC" "repo lease audit remains available after its Codex row was removed"
RECEIPT="$(receipt_from "$OUT")"
has "$OUT" "SWARM_NAME=alpha" "unreferenced lease remains bound to its exact owner evidence"
recover recover repo-lease "$REPO" --receipt "$RECEIPT" --ack-reconciled >/dev/null 2>&1; RC=$?
eq 0 "$RC" "config-independent exact owner evidence recovers the removed row's lease"
if [ ! -e "$LEASE" ]; then ok "unreferenced exact lease is removed"; else bad "unreferenced exact lease is removed"; fi

reset_state
set_conf_codex
dead_lock "$MUTATION"
LEASE="$(make_repo_lease 2147483647)"
OUT="$(recover audit mutation 2>&1)"; RC=$?
eq 3 "$RC" "global mutation recovery refuses a retained repo lease"
has "$OUT" "recover each exact dead repo lease" "global recovery gives repo-lease ordering"
if [ -d "$MUTATION" ] && [ -d "$LEASE" ]; then ok "repo-lease ordering retains both signals"; else bad "repo-lease ordering retains both signals"; fi

echo ""
printf 'swarm-recover: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
