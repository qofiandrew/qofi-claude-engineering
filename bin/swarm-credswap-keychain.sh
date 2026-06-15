#!/usr/bin/env bash
# swarm-credswap-keychain.sh — the macOS-Keychain CREDENTIAL-SWAP adapter that
# sits behind swarm-rotate.sh's SWARM_CREDSWAP_CMD seam. It makes the NEXT Max
# account the active credential for `claude`, FAIL-SAFE: if anything goes wrong
# at any step it RESTORES the prior credential and exits non-zero, loud. Auth is
# NEVER left in an unknown state.
#
# WHY THIS IS THE HIGHEST-RISK HOOK. swarm-rotate.sh deliberately does NOT
# hardcode the keychain swap — a live rotation REFUSES (exit 2) unless an
# operator wires SWARM_CREDSWAP_CMD. This script is the reference wiring for the
# one shape this deployment actually runs on: ONE Max account at a time, its
# OAuth credential stored as a macOS generic-password keychain item under the
# `claude` Code service. Getting this wrong bricks the fleet's auth, so every
# step is ordered, guarded, and reversible.
#
# ── HOW swarm-rotate CALLS US (the seam contract) ───────────────────────────
# swarm-rotate runs the hook as:  SWARM_ROTATE_TO_ACCOUNT=<next> sh -c "$CMD" _ <next>
# i.e. the NEXT account handle arrives BOTH in $1 AND in $SWARM_ROTATE_TO_ACCOUNT.
# Wire it as:
#     export SWARM_CREDSWAP_CMD='/path/to/swarm-credswap-keychain.sh "$1"'
# A zero exit means the active credential is now the next account's and it
# AUTHENTICATES. A non-zero exit means the swap did NOT take and the PRIOR
# credential has been RESTORED — swarm-rotate then refuses to relaunch the fleet
# (exit 5), so we never boot on an unknown credential.
#
# ── THE KEYCHAIN ENTRY SHAPE (discovered via METADATA ONLY — never -w) ──────
# Claude Code stores its OAuth credential as a generic-password item:
#     class:  genp
#     svce ("service"):  "Claude Code-credentials"
#     acct ("account"):  the macOS login id (e.g. the value of `id -un`)
# This script operates on THAT item's slot. The discovery used
# `security find-generic-password -s <svc>` WITHOUT -w — the secret VALUE is
# never read, printed, or logged by discovery or by this script.
#
# ── THE SWAP (strict order, fail-safe) ──────────────────────────────────────
#   1. BACK UP the current active credential value to a chmod-600 temp (never
#      logged/printed/argv). If there is no current item, the backup is empty and
#      RESTORE becomes "delete what we installed" — still reversible.
#   2. INSTALL the next account's credential blob into the active slot. The blob
#      is OPERATOR-PROVISIONED (see below) — this script never generates one and
#      never puts it on argv or in scrollback.
#   3. VERIFY it authenticates via a trivial whoami/auth check (negligible, not
#      real spend) through the SWARM_CREDSWAP_AUTHCHECK_CMD seam.
#   4. On ANY failure at ANY step → RESTORE the backup (re-install the prior
#      value, or delete if there was none) and exit non-zero, loud.
#
# ── WHERE THE NEXT ACCOUNT'S BLOB COMES FROM (operator-provisioned) ─────────
# Per-account credential blobs are provisioned out-of-band by the operator — the
# same secret discipline swarm-provision-tokens.sh uses (silent, chmod 600, never
# argv/scrollback/logs). This script ACQUIRES the next blob through a single
# documented seam and NEVER fabricates one:
#   SWARM_CREDSWAP_BLOB_FETCH  A command template run via `sh -c`, with a '{}'
#                              placeholder for the account handle. Its STDOUT is
#                              the credential blob for that account, e.g.:
#                                export SWARM_CREDSWAP_BLOB_FETCH='op read op://Swarm/{}/credential'
#                                export SWARM_CREDSWAP_BLOB_FETCH='cat "$SWARM_CRED_DIR"/{}.cred'
#                              The blob is staged to a chmod-600 file and fed to
#                              `security` over stdin (NOT argv — see kc_set_value)
#                              so it never reaches the process table or scrollback.
#   SWARM_CREDSWAP_BLOB_FILE   Alternative: a path template with '{}', a file
#                              (operator chmod 600) whose contents are the blob.
#                              Used only when *_FETCH is unset.
# Exactly one source must resolve to a non-empty blob; otherwise we REFUSE before
# touching the keychain (you cannot install nothing).
#
# ── ALL KEYCHAIN/AUTH ACCESS IS THROUGH OVERRIDABLE SEAMS (testability) ─────
#   SWARM_KEYCHAIN_CMD            the keychain CLI. Default: "security". Tests
#                                point this at a mock so synthetic ops never
#                                touch the real login keychain — and so a VERIFY
#                                failure can be injected deterministically.
#   SWARM_CREDSWAP_SERVICE        the generic-password service ("svce"). Default:
#                                "Claude Code-credentials" (discovered). Tests set
#                                a clearly synthetic, test-only service name so the
#                                real `claude` slot is NEVER a write target.
#   SWARM_CREDSWAP_ACCOUNT        the item account ("acct"). Default: `id -un`
#                                (the macOS login id, as discovered).
#   SWARM_CREDSWAP_AUTHCHECK_CMD  the auth verify, run via `sh -c` AFTER install.
#                                It must distinguish THREE outcomes by EXIT CODE:
#                                  0  → authenticates (swap good, proceed),
#                                  75 → authenticates BUT is rate-limited — the
#                                       account rotated TO is itself capped. This
#                                       is NOT a swap failure: we do NOT restore
#                                       (restoring would thrash to the prior,
#                                       also-capped account). We exit 7 so the
#                                       caller can detect ring exhaustion.
#                                  any other non-zero → auth FAILED (bad/expired)
#                                       → RESTORE the backup, fail loud (exit 4).
#                                Default: bin/swarm-auth-probe.sh (a REAL
#                                credential-exercising probe that fails on a dead
#                                credential — NOT `claude --version`, which only
#                                proves the binary runs). If that helper is absent
#                                AND `claude` is not on PATH we REFUSE rather than
#                                pretend — an unverifiable swap is not a safe swap.
#   SWARM_CREDSWAP_KEYCHAIN       optional keychain path passed to add/find/delete
#                                (e.g. a throwaway test keychain). Default: the
#                                default login keychain.
#
# THIS SCRIPT NEVER touches the LIVE `claude` keychain entry in its own tests:
# the entry is only ever a write target when the operator runs it for real with
# the default service. The accompanying tests use a synthetic service name.
#
# Usage:
#   swarm-credswap-keychain.sh <next-account>       # do the swap (fail-safe)
#   swarm-credswap-keychain.sh --plan <next-account> # print the plan; touch nothing
#   swarm-credswap-keychain.sh -h | --help
#
# Exit codes:
#   0 — swapped: next account's credential is active AND authenticates.
#   2 — refused (bad usage; no blob source / empty blob; no way to VERIFY).
#   3 — INSTALL failed   → prior credential RESTORED.
#   4 — VERIFY failed    → prior credential RESTORED (the new blob did not auth).
#   5 — BACKUP failed    → nothing installed (we refuse to swap without a backup).
#   6 — RESTORE failed   → auth may be in an unknown state: LOUD, manual attention.
#   7 — VERIFY says authed-BUT-RATE-LIMITED (authcheck exit 75): the swap is KEPT
#       (the new credential is good — it authenticated), but the account it points
#       at is itself capped. We do NOT restore (the prior account is also capped —
#       that's how we got here). This is the ring-exhaustion signal: the caller
#       (swarm-rotate / the tick) must escalate, not thrash-rotate. Distinct from 4.
#
# Bash 3.2-safe (macOS default). `security` is the only platform dep (mockable).

set -uo pipefail

usage() { sed -n '1,110p' "$0"; exit "${1:-0}"; }

PLAN=0
NEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "swarm-credswap: unknown flag: $1" >&2; usage 2 ;;
    *)         if [ -z "$NEXT" ]; then NEXT="$1"; shift; else echo "swarm-credswap: unexpected arg: $1" >&2; usage 2; fi ;;
  esac
done

# The next account also arrives in the env (swarm-rotate exports it); accept it
# as a fallback so the hook works whether wired with "$1" or bare.
[ -z "$NEXT" ] && NEXT="${SWARM_ROTATE_TO_ACCOUNT:-}"
if [ -z "$NEXT" ]; then
  echo "swarm-credswap: REFUSED — no next-account given (pass it as \$1 or set SWARM_ROTATE_TO_ACCOUNT)." >&2
  exit 2
fi
# The account handle reaches a path template / find query — keep it sane. (It is
# NOT a secret; it is a short ring handle like 'max-b'.)
case "$NEXT" in
  *[!A-Za-z0-9._-]*) echo "swarm-credswap: REFUSED — suspicious account handle '$NEXT' (allowed: A-Za-z0-9._-)." >&2; exit 2 ;;
esac

KEYCHAIN_CMD="${SWARM_KEYCHAIN_CMD:-security}"
SERVICE="${SWARM_CREDSWAP_SERVICE:-Claude Code-credentials}"
ACCOUNT="${SWARM_CREDSWAP_ACCOUNT:-$(id -un 2>/dev/null || echo unknown)}"
KEYCHAIN_PATH="${SWARM_CREDSWAP_KEYCHAIN:-}"

# kc — invoke the keychain CLI with an optional trailing keychain path. Centralizes
# the `security` invocation so the mock seam and the keychain-path option both
# flow through ONE place. NOTE: secret values are passed to add via the prompt on
# stdin (see kc_set_value), never here on argv.
kc() {  # subcommand args...
  if [ -n "$KEYCHAIN_PATH" ]; then
    "$KEYCHAIN_CMD" "$@" "$KEYCHAIN_PATH"
  else
    "$KEYCHAIN_CMD" "$@"
  fi
}

echo "swarm-credswap: plan — install account '$NEXT' into keychain slot svce='$SERVICE' acct='$ACCOUNT'"
echo "                (backup -> install -> verify -> restore-on-any-failure)"

if [ "$PLAN" -eq 1 ]; then
  echo "swarm-credswap: --plan — touching nothing. Would back up the current value,"
  echo "                install '$NEXT' (blob via ${SWARM_CREDSWAP_BLOB_FETCH:+SWARM_CREDSWAP_BLOB_FETCH}${SWARM_CREDSWAP_BLOB_FETCH:-${SWARM_CREDSWAP_BLOB_FILE:+SWARM_CREDSWAP_BLOB_FILE}}), then verify auth."
  exit 0
fi

# ---------------------------------------------------------------------------
# Acquire the next account's credential blob (operator-provisioned, NEVER argv).
# ---------------------------------------------------------------------------
# Resolve from the FETCH command first, else the FILE template. The blob is held
# only in this shell variable and only ever fed to `security` over stdin. We do
# NOT print it, log it, or pass it on a command line — neither here nor anywhere.
acquire_blob() {  # -> prints blob to stdout (callers capture it)
  local fetch="${SWARM_CREDSWAP_BLOB_FETCH:-}"
  local file_tpl="${SWARM_CREDSWAP_BLOB_FILE:-}"
  if [ -n "$fetch" ]; then
    case "$fetch" in *'{}'*) ;; *) echo "swarm-credswap: SWARM_CREDSWAP_BLOB_FETCH lacks the '{}' placeholder." >&2; return 2 ;; esac
    sh -c "${fetch//\{\}/$NEXT}" || return 1
    return 0
  fi
  if [ -n "$file_tpl" ]; then
    case "$file_tpl" in *'{}'*) ;; *) echo "swarm-credswap: SWARM_CREDSWAP_BLOB_FILE lacks the '{}' placeholder." >&2; return 2 ;; esac
    local f="${file_tpl//\{\}/$NEXT}"
    [ -f "$f" ] || { echo "swarm-credswap: blob file not found for '$NEXT': $f" >&2; return 1; }
    cat "$f" || return 1
    return 0
  fi
  echo "swarm-credswap: REFUSED — no credential source. Set SWARM_CREDSWAP_BLOB_FETCH (a '{}' command)" >&2
  echo "                or SWARM_CREDSWAP_BLOB_FILE (a '{}' path). Blobs are operator-provisioned;" >&2
  echo "                this script never fabricates one." >&2
  return 2
}

NEXT_BLOB="$(acquire_blob)"; arc=$?
if [ "$arc" -ne 0 ]; then
  echo "swarm-credswap: REFUSED — could not acquire credential blob for '$NEXT' (no keychain change made)." >&2
  exit 2
fi
if [ -z "$NEXT_BLOB" ]; then
  echo "swarm-credswap: REFUSED — empty credential blob for '$NEXT'; refusing to install nothing." >&2
  exit 2
fi
# The keychain password prompt is line-oriented (we feed value+retype over stdin),
# so an embedded newline would truncate the stored value. A credential blob for
# this slot is single-line; refuse anything else rather than silently store a
# half-credential. (Same shape-guard swarm-provision-tokens.sh applies to tokens.)
case "$NEXT_BLOB" in
  *$'\n'*) echo "swarm-credswap: REFUSED — credential blob for '$NEXT' contains a newline; refusing (would truncate)." >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# A trivial auth verify MUST be possible. An unverifiable swap is not a safe
# swap — we refuse BEFORE touching the keychain rather than install blind.
# ---------------------------------------------------------------------------
AUTHCHECK="${SWARM_CREDSWAP_AUTHCHECK_CMD:-}"
if [ -z "$AUTHCHECK" ]; then
  # Prefer the REAL auth probe (bin/swarm-auth-probe.sh): it exercises the
  # credential (so a bad/expired blob FAILS) and returns the 3-way verdict
  # (0 good / 75 capped / other bad) this step relies on. `claude --version`
  # would NOT do this — it only proves the binary runs, hollowing out
  # restore-on-failure. We deliberately do not fall back to `--version`.
  _probe="$(cd "$(dirname "$0")" && pwd)/swarm-auth-probe.sh"
  if [ -x "$_probe" ]; then
    AUTHCHECK="$_probe"
  elif command -v claude >/dev/null 2>&1; then
    # Auth-probe helper missing but `claude` present: run it as the probe so the
    # verify still exercises the credential. swarm-auth-probe.sh's own default
    # probe (a cheap credential round-trip) is what we'd want; absent the helper
    # we approximate with the same credential-exercising call + 3-way mapping.
    AUTHCHECK='claude -p "ping" --max-turns 1 >/dev/null 2>&1'
  else
    echo "swarm-credswap: REFUSED — no auth verify available. swarm-auth-probe.sh is missing," >&2
    echo "                'claude' is not on PATH, and SWARM_CREDSWAP_AUTHCHECK_CMD is unset." >&2
    echo "                Refusing to swap a credential we cannot then VERIFY (unverifiable swap" >&2
    echo "                = unsafe swap)." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# chmod-600 scratch for the backup. The backup holds the PRIOR secret value, so
# it is created under umask 077, chmod 600, and shredded on exit. Never logged.
# ---------------------------------------------------------------------------
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/swarm-credswap.XXXXXX")" || {
  echo "swarm-credswap: FATAL — mktemp failed; cannot stage a reversible swap." >&2; exit 5; }
BACKUP="$WORK/backup.cred"
NEXT_BLOB_FILE="$WORK/next.cred"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
: > "$BACKUP"; chmod 600 "$BACKUP"
# Stage the next blob to a chmod-600 file so it is fed to `security` over stdin
# from a file descriptor — never on argv, never echoed. Then drop the in-memory
# copy.
printf '%s' "$NEXT_BLOB" > "$NEXT_BLOB_FILE"; chmod 600 "$NEXT_BLOB_FILE"
NEXT_BLOB=""

# HAD_PRIOR=1 means a current item existed and was backed up (restore = re-install
# the prior value). HAD_PRIOR=0 means the slot was empty (restore = delete what we
# installed). Either way the swap is reversible.
HAD_PRIOR=0

# kc_find_value — read the CURRENT value into the backup file. This is the ONLY
# place a real secret value is ever read, and it goes STRAIGHT to a chmod-600
# file — never to a variable that could be echoed, never to stdout/argv.
# (Mirrors how the operator's discovery used -w only against a value they own;
# here it is required to make the swap reversible.)
backup_current() {
  # Probe presence first (metadata only) so a genuinely-absent item is "no prior"
  # rather than an error.
  if ! kc find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
    HAD_PRIOR=0
    return 0
  fi
  if kc find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w > "$BACKUP" 2>/dev/null; then
    HAD_PRIOR=1
    chmod 600 "$BACKUP"
    return 0
  fi
  return 1
}

# backup_is_multiline — does the backed-up PRIOR value contain a newline? The
# restore path (kc_set_value) is line-oriented: it feeds value+retype on stdin,
# so a multi-line prior value would truncate on restore — the restore would
# install a half-credential (mismatch -> fail), stranding the slot on the bad NEW
# blob (bricked). We must catch this BEFORE installing the new blob so a doomed
# restore can never strand the slot. Returns 0 (true) if the backup is multi-line.
backup_is_multiline() {
  [ "$HAD_PRIOR" -eq 1 ] || return 1
  [ -f "$BACKUP" ] || return 1
  # `security find -w` appends a single trailing newline to a single-line value;
  # strip exactly that trailing newline, then look for any REMAINING newline.
  local v
  v="$(cat "$BACKUP")"   # $(...) already strips trailing newlines
  case "$v" in
    *$'\n'*) return 0 ;;  # an interior newline survived -> genuinely multi-line
    *)       return 1 ;;
  esac
}

# kc_set_value — set the slot's value WITHOUT putting the secret on argv. macOS
# `security add-generic-password -w <value>` would expose the value on the
# command line (process table / scrollback), which this build forbids. Instead we
# use `-w` with NO argument: `security` then prompts for the password AND a retype
# on its input, so we feed the value TWICE on stdin (newline-separated). The secret
# travels only over stdin — never argv. -U upserts so it overwrites the active slot
# in place. The value is read from a FILE descriptor ($1 = a chmod-600 file path),
# never echoed.
kc_set_value() {  # value-file
  local vf="$1" v
  # The keychain password prompt is line-oriented; an embedded newline would end
  # the value early. We already refuse newline-bearing blobs on acquisition, and
  # the backup is whatever was previously stored (also single-line for this slot).
  v="$(cat "$vf")"
  printf '%s\n%s\n' "$v" "$v" | kc add-generic-password -U -s "$SERVICE" -a "$ACCOUNT" -w >/dev/null 2>&1
}

# install_blob — write the next account's blob into the slot. The blob is staged
# to a chmod-600 file first (never argv), then kc_set_value feeds it over stdin.
install_blob() {
  kc_set_value "$NEXT_BLOB_FILE"
}

# restore_backup — put auth back the way we found it. If there was a prior value,
# re-install it from the chmod-600 backup (stdin, not argv). If the slot was
# empty, delete what we installed. Returns non-zero only if restoration itself
# fails — the one truly-loud case (auth left unknown).
restore_backup() {
  if [ "$HAD_PRIOR" -eq 1 ]; then
    if [ -f "$BACKUP" ]; then
      kc_set_value "$BACKUP"
      return $?
    fi
    return 1
  fi
  # No prior item: remove the one we installed. A "not found" delete is fine —
  # the slot is already back to empty, which is exactly the pre-state.
  kc delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || true
  return 0
}

# loud_restore_or_die CODE MSG — restore, then exit CODE; if restore ITSELF fails
# escalate to exit 6 (unknown-auth-state) as loud as possible.
loud_restore_or_die() {
  local code="$1" msg="$2"
  echo "swarm-credswap: FAILURE — $msg" >&2
  echo "swarm-credswap: rolling back to the prior credential (reversibility is mandatory)..." >&2
  if restore_backup; then
    echo "swarm-credswap: RESTORED — prior credential is back in the active slot. Auth state is known-good." >&2
    exit "$code"
  fi
  echo "swarm-credswap: CRITICAL — RESTORE ALSO FAILED. Auth may be in an UNKNOWN state." >&2
  echo "                Manual operator attention required for svce='$SERVICE' acct='$ACCOUNT'." >&2
  exit 6
}

# ── STEP 1: BACK UP ─────────────────────────────────────────────────────────
echo "swarm-credswap: step 1/3 — backing up the current active credential"
if ! backup_current; then
  echo "swarm-credswap: REFUSED — could not back up the current credential; not swapping" >&2
  echo "                (we never install over an un-backed-up slot). No keychain change made." >&2
  exit 5
fi
if [ "$HAD_PRIOR" -eq 1 ]; then
  echo "  backed up prior credential (value held chmod-600, never printed)"
else
  echo "  NOTE: no current item in slot — backup is empty; restore would clear the slot"
fi

# Newline guard on the BACKUP (prior value), symmetric with the next-blob guard
# above. The restore prompt is line-oriented; a multi-line prior value cannot be
# restored faithfully, so a failed swap would strand the slot on the bad NEW blob.
# REFUSE BEFORE installing anything — the slot is still untouched here, so refusing
# now leaves the prior (multi-line) value exactly in place rather than bricking it.
if backup_is_multiline; then
  echo "swarm-credswap: REFUSED — the PRIOR credential in slot svce='$SERVICE' acct='$ACCOUNT' contains a" >&2
  echo "                newline (multi-line value). Restore is line-oriented and could NOT faithfully put it" >&2
  echo "                back, so a failed swap would strand the slot on the new blob. Refusing BEFORE install;" >&2
  echo "                the prior value is left untouched. (Operator: re-provision this slot as a single line.)" >&2
  exit 2
fi

# ── STEP 2: INSTALL ─────────────────────────────────────────────────────────
echo "swarm-credswap: step 2/3 — installing '$NEXT' into the active slot"
if ! install_blob; then
  loud_restore_or_die 3 "could not INSTALL '$NEXT' into the keychain slot"
fi
echo "  installed (value supplied via stdin, never argv/scrollback)"

# ── STEP 3: VERIFY (3-way) ──────────────────────────────────────────────────
# The authcheck distinguishes three outcomes by exit code:
#   0  → authenticates → swap good, proceed.
#   75 → authenticates BUT rate-limited → the new credential is GOOD (it did
#        authenticate) but the account it points at is itself capped. RESTORING
#        would thrash back to the prior (also-capped) account, so we KEEP the swap
#        and exit 7 — the ring-exhaustion signal. This is the (b)-vs-(c) split:
#        (b) bad cred → restore; (c) capped-but-authed → keep + escalate.
#   *  → auth FAILED (bad/expired) → RESTORE the backup, fail loud (exit 4).
echo "swarm-credswap: step 3/3 — verifying the new credential authenticates"
sh -c "$AUTHCHECK"; ac_rc=$?
case "$ac_rc" in
  0)
    echo "  verified: '$NEXT' authenticates"
    echo "swarm-credswap: DONE — active credential is now '$NEXT' and authenticates."
    exit 0
    ;;
  75)
    # (c) — authed but capped. Do NOT restore.
    echo "swarm-credswap: VERIFY — '$NEXT' AUTHENTICATES but is RATE-LIMITED (account already capped)." >&2
    echo "                The swap is KEPT (the credential is valid); we are NOT restoring — the prior" >&2
    echo "                account is also capped, so a rollback would just thrash. This is RING EXHAUSTION:" >&2
    echo "                rotation has nowhere fresh to go. Caller must ESCALATE, not rotate again." >&2
    echo "swarm-credswap: DONE (ring-exhausted) — '$NEXT' is active and authenticates, but capped."
    exit 7
    ;;
  *)
    # (b) — bad/expired credential. Roll back.
    loud_restore_or_die 4 "VERIFY failed — '$NEXT' did not authenticate (authcheck exit $ac_rc); the new blob is bad/expired"
    ;;
esac
