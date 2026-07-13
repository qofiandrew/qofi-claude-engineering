#!/usr/bin/env bash
# swarm-account.sh — swap ONE swarm to a different Max account (the per-swarm
# FAILOVER actuator, ADR-0018). Where swarm-rotate.sh moves the WHOLE fleet to
# the next ring account, this moves a SINGLE swarm to a named account and leaves
# every other swarm where it is. It is the actuator the failover router
# (swarm-rotate-tick.sh --failover) drives once per capped swarm.
#
# THE SWAP, IN ORDER (never a half-swap):
#   1. Validate <name> is a configured swarm and <account> is a well-formed,
#      PROVISIONED account (isolated config dir present + OAUTH_TOKEN_<UPPER> in
#      the vault). A missing piece fails LOUD before anything is touched.
#   2. AUTH-PROBE the target token (swarm-auth-probe.sh) so we never move a swarm
#      onto a dead or capped credential:
#        authenticates  -> proceed
#        auth-fail      -> REFUSE, do not swap (exit 4); the swarm stays put
#        authed-but-capped -> REFUSE (exit 7) so the router tries the NEXT account
#   3. CHECKPOINT the swarm's repo (commit+push its own branch) so the restart
#      can't lose committed work. A checkpoint failure aborts unless --force.
#   4. Atomically rewrite the swarm's swarm.conf ACCOUNT field (field 6) to the
#      target. THIS rewrite IS the persistence — it sticks across restarts until
#      the next cap. (The pre-failover split is snapshotted once so --reset can
#      restore it.)
#   5. Restart just this swarm (swarm-restart.sh) so it comes up on the new
#      account. swarm-restart.sh owns the WORKING-rail guard: if the swarm is
#      mid-turn and --force was not given it REFUSES — and we then REVERT the
#      field so the conf never disagrees with what is actually running.
#
#   swarm-account.sh --reset [--force]   restores every swarm's ACCOUNT field to
#       the snapshotted default split (churn-free: only rewrites rows that drifted;
#       does not restart — it advises which swarms to cycle).
#
# INERT BY DEFAULT. With no provisioned accounts and an all-empty-ACCOUNT
# swarm.conf nothing here ever runs against the real fleet; the swap path requires
# a labeled, provisioned target that only the operator creates (terms-gated).
#
# Every external effect is an injectable seam so the tests stub it (no real probe,
# checkpoint, or restart ever fires in the suite):
#   SWARM_ACCOUNT_AUTHCHECK_CMD  default swarm-auth-probe.sh, run with the TARGET
#                                creds exported; exit 0/1/75/2 = auth/fail/capped/err.
#   SWARM_CHECKPOINT_CMD         default swarm-checkpoint.sh; `sh -c "$cmd \"$1\""` repo.
#   SWARM_RESTART_CMD            default swarm-restart.sh; `<cmd> <name> [--force]`.
#   SWARM_ACCOUNT_DEFAULT_SNAPSHOT default $SWARM_HOME/.swarm-accounts-default.
#   SWARM_TOKENS_ENV             default $SWARM_HOME/tokens.env (the vault).
#
# Exit codes:
#   0  swapped (or already on target = no-op; or --reset completed)
#   1  usage / SWARM_HOME wrong / no such swarm
#   2  invalid target account label
#   3  target not provisioned (config dir or vault token missing)
#   4  target token AUTH-FAILED — not swapped, swarm stays put
#   5  auth probe could not decide (uncertain) — not swapped (fail-safe)
#   6  restart REFUSED at the clean-boundary guard — field REVERTED; pass --force
#   7  target authenticates but is CAPPED — not swapped; router should try another
#   8  checkpoint FAILED — not swapped (pass --force to swap anyway)
#   9  swapped + field written, but the RESTART failed for another reason — the
#      conf now points at the target; operator must check swarm-restart output
#
# bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-account"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

AUTHCHECK_CMD="${SWARM_ACCOUNT_AUTHCHECK_CMD:-$SCRIPT_DIR/swarm-auth-probe.sh}"
CHECKPOINT_CMD="${SWARM_CHECKPOINT_CMD:-$SCRIPT_DIR/swarm-checkpoint.sh}"
RESTART_CMD="${SWARM_RESTART_CMD:-$SCRIPT_DIR/swarm-restart.sh}"
SNAPSHOT="${SWARM_ACCOUNT_DEFAULT_SNAPSHOT:-$SWARM_HOME/.swarm-accounts-default}"
TOKENS="${SWARM_TOKENS_ENV:-$SWARM_HOME/tokens.env}"

usage() { sed -n '1,60p' "$0"; exit "${1:-0}"; }
log()  { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
RESET=0
FORCE=0
NAME=""
ACCOUNT=""
SAW_ACCOUNT=0
for arg in "$@"; do
  case "$arg" in
    --reset)   RESET=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage 0 ;;
    --*)       echo "$PROG: unknown flag: $arg" >&2; usage 1 ;;
    *)
      if [ -z "$NAME" ] && [ "$SAW_ACCOUNT" -eq 0 ]; then NAME="$arg"
      elif [ "$SAW_ACCOUNT" -eq 0 ]; then ACCOUNT="$arg"; SAW_ACCOUNT=1
      else echo "$PROG: too many positional args" >&2; usage 1
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Snapshot the pre-failover default split ONCE, so --reset can restore it.
# Captures every row's name + current account at the moment of the FIRST swap;
# subsequent swaps leave it alone. In a fresh (all-empty) fleet this records the
# all-default split, so --reset returns the fleet to single-account.
# ---------------------------------------------------------------------------
snapshot_default_if_absent() {
  [ -f "$SNAPSHOT" ] && return 0
  local _tmp="$SNAPSHOT.tmp.$$"
  {
    echo "# swarm-account default split snapshot — name<TAB>account (auto-captured at first failover; used by --reset)"
    while IFS= read -r _line; do
      swarm_conf_parse_line "$_line" || continue
      [ -z "$SWARM_CONF_F_NAME" ] && continue
      [ "$SWARM_CONF_F_ENGINE" = "codex" ] && continue
      printf '%s\t%s\n' "$SWARM_CONF_F_NAME" "$SWARM_CONF_F_ACCOUNT"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  } > "$_tmp" 2>/dev/null && mv "$_tmp" "$SNAPSHOT" 2>/dev/null || { rm -f "$_tmp"; warn "could not write default-split snapshot $SNAPSHOT (--reset will be unavailable)"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# --reset: restore each swarm's ACCOUNT to the snapshotted default. Churn-free —
# only rewrites rows that drifted; never restarts (advises instead).
# ---------------------------------------------------------------------------
if [ "$RESET" -eq 1 ]; then
  [ -n "$NAME" ] && { echo "$PROG: --reset takes no swarm name" >&2; usage 1; }
  if [ ! -f "$SNAPSHOT" ]; then
    log "no default-split snapshot at $SNAPSHOT — the fleet has never failed over; nothing to reset."
    exit 0
  fi
  changed=""
  while IFS="$(printf '\t')" read -r _sname _sacct; do
    case "$_sname" in '#'*|'') continue ;; esac
    # Current account for this swarm.
    _cur=""; _engine=""
    while IFS= read -r _line; do
      swarm_conf_parse_line "$_line" || continue
      if [ "$SWARM_CONF_F_NAME" = "$_sname" ]; then
        _cur="$SWARM_CONF_F_ACCOUNT"; _engine="$SWARM_CONF_F_ENGINE"; break
      fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
    # ACCOUNT is a Claude-auth partition only. Ignore legacy snapshot rows for
    # Codex so reset preserves field 6 for a possible future engine switch.
    [ "$_engine" = "codex" ] && continue
    if [ "$_cur" != "$_sacct" ]; then
      if swarm_conf_set_account "$CONF" "$_sname" "$_sacct"; then
        changed="$changed $_sname(->${_sacct:-default})"
      else
        warn "could not restore '$_sname' to '${_sacct:-default}' (row missing?)"
      fi
    fi
  done < "$SNAPSHOT"
  if [ -z "$changed" ]; then
    log "fleet already matches the default split — nothing to reset (churn-free)."
  else
    log "restored default split for:$changed"
    log "restart those swarms to move them back: bin/swarm-restart.sh <name>  (or swarm-up.sh restart)."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Swap: validate <name> and <account>.
# ---------------------------------------------------------------------------
[ -z "$NAME" ]    && { echo "$PROG: missing <name>" >&2; usage 1; }
[ "$SAW_ACCOUNT" -eq 0 ] && { echo "$PROG: missing <account> (use --reset to return to the default split)" >&2; usage 1; }
[ -z "$ACCOUNT" ] && { echo "$PROG: empty <account> — use --reset to return a swarm to the default account" >&2; usage 1; }

# Find the swarm's row: capture its repo + current account.
REPO=""; CUR_ACCOUNT=""; ENGINE=""; FOUND=0
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$NAME" ]; then
    REPO="$SWARM_CONF_F_REPO"; CUR_ACCOUNT="$SWARM_CONF_F_ACCOUNT"; ENGINE="$SWARM_CONF_F_ENGINE"; FOUND=1; break
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
[ "$FOUND" -eq 0 ] && { echo "$PROG: no swarm named '$NAME' in $CONF" >&2; exit 1; }
if [ "$ENGINE" = "codex" ]; then
  echo "$PROG: REFUSED — '$NAME' uses engine=codex; ACCOUNT and Claude Max failover do not apply. No checkpoint, auth probe, config rewrite, or restart was performed." >&2
  exit 1
fi
case "$REPO" in "~"*) REPO="$HOME${REPO#\~}" ;; esac

# Validate the target label + resolve its paths/token-var (the SOLE constructor).
if ! swarm_account_resolve "$ACCOUNT"; then
  echo "$PROG: invalid target account label '$ACCOUNT' (need [A-Za-z][A-Za-z0-9_-]*)" >&2
  exit 2
fi

# Already on the target? No-op.
if [ "$CUR_ACCOUNT" = "$ACCOUNT" ]; then
  log "'$NAME' is already on account '$ACCOUNT' — nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# Provisioning gate — fail LOUD before any swap. The target needs an isolated
# config dir AND a vault token; we never move a swarm onto a half-provisioned
# account.
# ---------------------------------------------------------------------------
if [ ! -d "$SWARM_ACCT_CONFIG_DIR" ]; then
  echo "$PROG: account '$ACCOUNT' is not provisioned — config dir missing: $SWARM_ACCT_CONFIG_DIR" >&2
  echo "       provision the account (config dir + OAUTH_TOKEN_$(printf '%s' "$ACCOUNT" | tr 'a-z-' 'A-Z_') in $TOKENS) before failing over to it." >&2
  exit 3
fi
# Source the vault so the token var is visible, then deref by NAME (never echo it).
# shellcheck disable=SC1090
[ -f "$TOKENS" ] && { set -a; . "$TOKENS"; set +a; }
TOKEN_VAR="$SWARM_ACCT_TOKEN_VAR"
TOKVAL="${!TOKEN_VAR:-}"
if [ -z "$TOKVAL" ]; then
  echo "$PROG: account '$ACCOUNT' is not provisioned — no token in vault var \$$TOKEN_VAR ($TOKENS)" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Auth-probe the TARGET token (never move onto a dead/capped credential). The
# probe runs with the target creds exported; its literal value never reaches the
# command line. swarm-auth-probe.sh exit: 0 authenticates / 1 auth-fail / 75
# authed-but-capped / 2 usage error.
# ---------------------------------------------------------------------------
CLAUDE_CONFIG_DIR="$SWARM_ACCT_CONFIG_DIR" \
CLAUDE_CODE_OAUTH_TOKEN="$TOKVAL" \
ANTHROPIC_API_KEY= ANTHROPIC_AUTH_TOKEN= \
  sh -c "$AUTHCHECK_CMD" _ "$ACCOUNT" >/dev/null 2>&1
probe_rc=$?
case "$probe_rc" in
  0)  log "target '$ACCOUNT' authenticates — proceeding with the swap of '$NAME'." ;;
  1)  echo "$PROG: target '$ACCOUNT' token AUTH-FAILED — NOT swapping '$NAME' (it stays on '${CUR_ACCOUNT:-default}'). Fix the token in $TOKENS." >&2; exit 4 ;;
  75) echo "$PROG: target '$ACCOUNT' authenticates but is CAPPED (rate-limited) — NOT swapping '$NAME'. The router should try another account." >&2; exit 7 ;;
  *)  echo "$PROG: could not verify target '$ACCOUNT' (probe exit $probe_rc) — NOT swapping '$NAME' (fail-safe)." >&2; exit 5 ;;
esac

# ---------------------------------------------------------------------------
# Checkpoint the swarm's repo BEFORE the restart so committed work survives the
# relaunch. A checkpoint failure aborts the swap unless --force.
# ---------------------------------------------------------------------------
if [ -n "$REPO" ]; then
  if sh -c "$CHECKPOINT_CMD \"\$1\"" _ "$REPO"; then
    log "checkpointed '$NAME' repo ($REPO)."
  else
    if [ "$FORCE" -eq 1 ]; then
      warn "checkpoint of '$REPO' FAILED — proceeding anyway because --force (committed work may be at risk)."
    else
      echo "$PROG: checkpoint of '$NAME' repo ($REPO) FAILED — NOT swapping. Resolve the repo state, or pass --force." >&2
      exit 8
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Snapshot the default split (once) BEFORE the first rewrite, then rewrite the
# ACCOUNT field to the target. The rewrite IS the persistence.
# ---------------------------------------------------------------------------
snapshot_default_if_absent || true
if ! swarm_conf_set_account "$CONF" "$NAME" "$ACCOUNT"; then
  echo "$PROG: failed to rewrite '$NAME' ACCOUNT field in $CONF — aborting (no change made)." >&2
  exit 1
fi
log "rewrote '$NAME' -> account '$ACCOUNT' in swarm.conf (persisted)."

# ---------------------------------------------------------------------------
# Restart just this swarm onto the new account. swarm-restart.sh owns the
# WORKING-rail guard; on a clean-boundary REFUSAL (exit 2 without --force) we
# REVERT the field so the conf never disagrees with what is actually running.
# ---------------------------------------------------------------------------
if [ "$FORCE" -eq 1 ]; then
  sh -c "$RESTART_CMD \"\$1\" --force" _ "$NAME"; restart_rc=$?
else
  sh -c "$RESTART_CMD \"\$1\"" _ "$NAME"; restart_rc=$?
fi

case "$restart_rc" in
  0)
    log "'$NAME' restarted on account '$ACCOUNT'. Swap complete."
    exit 0
    ;;
  2)
    # Clean-boundary refusal (swarm working). Undo the field rewrite so the conf
    # matches the still-running swarm; the operator can retry with --force.
    if swarm_conf_set_account "$CONF" "$NAME" "$CUR_ACCOUNT"; then
      warn "'$NAME' is WORKING — restart REFUSED at the clean-boundary guard. REVERTED the ACCOUNT field to '${CUR_ACCOUNT:-default}' (no swap). Re-run with --force to swap anyway (loses in-process teammate work)."
    else
      warn "'$NAME' restart REFUSED, AND the revert of the ACCOUNT field FAILED — swarm.conf now says '$ACCOUNT' but the swarm still runs '${CUR_ACCOUNT:-default}'. Fix the ACCOUNT field by hand."
    fi
    exit 6
    ;;
  *)
    warn "'$NAME' ACCOUNT was rewritten to '$ACCOUNT' but the restart FAILED (exit $restart_rc) — the swarm may be down. Check swarm-restart output; fix or revert the ACCOUNT field as needed."
    exit 9
    ;;
esac
