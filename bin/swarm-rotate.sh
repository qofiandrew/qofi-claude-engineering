#!/usr/bin/env bash
# swarm-rotate.sh — single-account ROTATION: swap the active Max account's
# credentials to the NEXT account and relaunch the fleet.
#
# THE MODEL. This deployment runs ONE Max account at a time on macOS (no
# concurrency, no per-account config-dir isolation). Rotation is a DURATION
# mechanism, not a scale-out one: when the active account nears its 5h/weekly
# cap (detected by swarm-usage-poll.sh — the TRIGGER), we swap the active
# credentials to the next account in the ring and bring the whole fleet back
# up on the fresh account. That buys more wall-clock before the fleet stalls.
#
# ── ROTATION = FLEET RESTART = RAM-STATE LOSS. The clean-boundary discipline ─
# A rotation tears down every tmux session and relaunches it. Per
# swarm-up.sh / swarm-restart.sh / TEAM_LEAD.md, in-process teammates are
# RAM-only and do NOT survive a relaunch — the lead rebuilds from DISK (its
# stamped doctrine + any COMMITTED branches). So rotation must respect the same
# discipline a restart does, made explicit here:
#
#   1. CLEAN BOUNDARY. Rotation should fire at a clean phase boundary, never
#      mid-turn. We reuse the repo's existing liveness signal (repo_activity in
#      swarm-lib.sh — the same one swarm-restart.sh's safety rail uses): if any
#      swarm produced a transcript write within ${SWARM_STALE_SECONDS:-300}s it
#      is WORKING, and we REFUSE to rotate unless --force. This is the
#      "fire at a clean boundary" rule encoded as a guard, not a comment.
#
#   2. CHECKPOINT BEFORE ROTATING. Because a restart costs only what is NOT on
#      disk, we run a CHECKPOINT step before swapping: commit + branch-push each
#      swarm's working tree so an imminent rotation costs minutes, not work. The
#      checkpoint is a pluggable hook (SWARM_CHECKPOINT_CMD) so the operator can
#      wire it to whatever "save my place" means for their fleet; the default is
#      a no-op that simply WARNS, because this script must never silently mutate
#      a teammate's git state. The discipline is: rotate only from a checkpointed
#      boundary. (See ESCALATION/TEAM_LEAD: commit at clean boundaries.)
#
# ── EVERY SIDE EFFECT IS A PLUGGABLE, GUARDED HOOK ───────────────────────────
# This script performs THREE side effects: checkpoint, credential-swap, fleet
# relaunch. NONE of them are hardcoded against the operator's real keychain,
# git, or tmux — each is an overridable command (the same swappable-seam idiom
# swarm-provision-tokens.sh uses for SWARM_VAULT_FETCH). That keeps rotation
# testable (stub the hooks), reversible, and host-portable; and it means this
# script NEVER reads or writes real OAuth credentials directly.
#
#   SWARM_CREDSWAP_CMD   REQUIRED to actually rotate. Run via `sh -c` with the
#                        NEXT account name in $1 (and exported as
#                        SWARM_ROTATE_TO_ACCOUNT). It must make that account the
#                        active credential for `claude`. The repo deliberately
#                        does NOT hardcode the macOS keychain swap — wire this to
#                        your mechanism, e.g.:
#                          export SWARM_CREDSWAP_CMD='claude-account use "$1"'   # hypothetical
#                        Without it, --dry-run still works; a live run REFUSES
#                        (exit 2) rather than guess how to swap credentials.
#   SWARM_CHECKPOINT_CMD Optional. Run via `sh -c` BEFORE the swap, once per
#                        swarm repo, with the repo path in $1. Should commit +
#                        push a checkpoint branch. Default: a WARNING that no
#                        checkpoint hook is wired (rotation proceeds; the warning
#                        is the discipline reminder). A non-zero checkpoint
#                        ABORTS the rotation (we do not rotate over a failed
#                        save) unless --force.
#   SWARM_FLEET_RELAUNCH_CMD  Optional. The fleet bring-up after the swap.
#                        Default: "$SCRIPT_DIR/swarm-up.sh down && … up" — i.e.
#                        take the whole fleet down then up on the new account.
#                        Overridable so tests stub it and operators can sequence
#                        it differently.
#
# ── THE ACCOUNT RING ─────────────────────────────────────────────────────────
#   SWARM_ACCOUNTS   space- or comma-separated ordered list of account handles,
#                    e.g. "max-a max-b max-c". Required for a live run.
#   SWARM_ACTIVE_ACCOUNT  the currently-active handle (must be in the ring). The
#                    "next" account is the one after it, wrapping around. If
#                    unset, we start from the first and rotate to the second.
#                    (--to <acct> overrides the computed next.)
#
# Usage:
#   swarm-rotate.sh                 # rotate active → next: checkpoint, swap, relaunch
#   swarm-rotate.sh --to <account>  # rotate to a specific account in the ring
#   swarm-rotate.sh --force         # rotate even if a swarm is WORKING / checkpoint failed
#   swarm-rotate.sh --dry-run       # print the plan; run NO hook (no swap, no restart)
#   swarm-rotate.sh --next          # print only the computed next account, exit
#   swarm-rotate.sh -h | --help
#
# Exit codes:
#   0 — rotated (or dry-run plan printed, or --next printed).
#   2 — refused (no credswap hook on a live run; bad/empty account ring;
#       unknown --to account).
#   3 — REFUSED: a swarm is WORKING (clean-boundary guard) and --force absent.
#   4 — checkpoint hook failed and --force absent (rotate only from a saved
#       boundary).
#   5 — credential swap hook failed (the swap did not take — fleet NOT relaunched
#       so we don't bring everything up on an unknown credential).
#   6 — RING EXHAUSTED: the swap hook reported the rotate TARGET authenticates but
#       is itself RATE-LIMITED (credswap exit 7). Rotation has nowhere fresh to
#       go — every reachable account is capped. The fleet is NOT relaunched (we
#       refuse to boot the fleet on a capped account), and an attention flag is
#       raised if SWARM_ATTENTION_CMD is wired. This is a LOUD, terminal stop, not
#       a thrash-rotate. The caller (the tick) surfaces it and does NOT retry.
#
# ── RING-EXHAUSTION ESCALATION HOOK ──────────────────────────────────────────
#   SWARM_ATTENTION_CMD  Optional. Run via `sh -c` with a one-line reason in $1
#                        when ring exhaustion is detected, to raise the operator
#                        attention flag. Default: a loud WARNING only (this script
#                        cannot self-locate a tmux channel; the real attention
#                        flag is raised from inside a swarm session — see
#                        bin/swarm-attention.sh — or wired here by the operator/
#                        orchestrator). Example:
#                          export SWARM_ATTENTION_CMD='notify-ops "$1"'
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-rotate: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so tests substitute a stub fleet bring-up.
SWARM_UP="${SWARM_UP_BIN:-$SCRIPT_DIR/swarm-up.sh}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"

# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # swarm_conf_parse_line, repo_activity, SWARM_NO_TRANSCRIPT_AGE

usage() { sed -n '1,110p' "$0"; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
FORCE=0
DRY_RUN=0
PRINT_NEXT=0
TO_ACCOUNT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --next)    PRINT_NEXT=1; shift ;;
    --to)      shift; TO_ACCOUNT="${1:-}"; [ -z "$TO_ACCOUNT" ] && { echo "swarm-rotate: --to needs an account" >&2; exit 2; }; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "swarm-rotate: unknown flag: $1" >&2; usage 2 ;;
    *)         echo "swarm-rotate: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# The account ring + next-account computation.
# ---------------------------------------------------------------------------
# Normalize SWARM_ACCOUNTS: commas → spaces, collapse whitespace, then DE-DUPLICATE
# (keep first occurrence, preserve order). De-dup matters for correctness: a ring
# with a duplicated active handle (e.g. "a a b", active a) would otherwise let
# compute_next pick the SECOND "a" — rotating the account to ITSELF (a no-op swap
# that still tears down + relaunches the fleet for nothing). The ring is a SET of
# distinct accounts; duplicates are operator typos, not extra capacity.
ACCOUNTS_RAW="${SWARM_ACCOUNTS:-}"
ACCOUNTS="$(printf '%s' "$ACCOUNTS_RAW" | tr ',' ' ' | xargs 2>/dev/null || true)"
ACCOUNTS="$(
  _seen=" "
  _out=""
  for _a in $ACCOUNTS; do
    # Membership test via prefix-removal (NOT `case`+`continue`, which trips
    # `set -u` on bash 3.2). If " $_a " is already in $_seen, drop this duplicate.
    if [ "${_seen#*" $_a "}" != "$_seen" ]; then continue; fi
    _seen="$_seen$_a "
    _out="${_out:+$_out }$_a"
  done
  printf '%s' "$_out"
)"
ACTIVE="${SWARM_ACTIVE_ACCOUNT:-}"

# compute_next — print the account that follows ACTIVE in the ring (wrapping).
# If ACTIVE is empty/unknown, the next is the FIRST account (a cold start
# rotates onto a defined account rather than guessing). Pure; reads ACCOUNTS +
# ACTIVE. Returns non-zero (empty stdout) only when the ring itself is empty.
compute_next() {
  [ -z "$ACCOUNTS" ] && return 1
  # If a specific --to was requested, it must be a ring member.
  if [ -n "$TO_ACCOUNT" ]; then
    for a in $ACCOUNTS; do
      [ "$a" = "$TO_ACCOUNT" ] && { printf '%s' "$TO_ACCOUNT"; return 0; }
    done
    return 2   # --to not in ring
  fi
  local first="" prev="" pick="" found_active=0
  for a in $ACCOUNTS; do
    [ -z "$first" ] && first="$a"
    if [ "$found_active" -eq 1 ] && [ -z "$pick" ]; then
      pick="$a"
    fi
    [ "$a" = "$ACTIVE" ] && found_active=1
    prev="$a"
  done
  if [ -z "$ACTIVE" ] || [ "$found_active" -eq 0 ]; then
    # Active unknown → start at the first account.
    printf '%s' "$first"
    return 0
  fi
  if [ -z "$pick" ]; then
    # Active was the last in the ring → wrap to the first.
    printf '%s' "$first"
    return 0
  fi
  printf '%s' "$pick"
  return 0
}

NEXT="$(compute_next)"; nrc=$?
if [ "$nrc" -eq 2 ]; then
  echo "swarm-rotate: --to '$TO_ACCOUNT' is not in SWARM_ACCOUNTS ring [$ACCOUNTS]" >&2
  exit 2
fi
if [ "$PRINT_NEXT" -eq 1 ]; then
  if [ -z "$NEXT" ]; then echo "swarm-rotate: empty SWARM_ACCOUNTS ring — no next account" >&2; exit 2; fi
  printf '%s\n' "$NEXT"
  exit 0
fi
if [ -z "$NEXT" ]; then
  echo "swarm-rotate: SWARM_ACCOUNTS is empty — cannot rotate. Set the account ring, e.g." >&2
  echo "    export SWARM_ACCOUNTS='max-a max-b'" >&2
  exit 2
fi
if [ "$NEXT" = "$ACTIVE" ] && [ -n "$ACTIVE" ] && [ -z "$TO_ACCOUNT" ]; then
  echo "swarm-rotate: ring has a single usable account ('$ACTIVE') — nowhere to rotate." >&2
  exit 2
fi

echo "swarm-rotate: plan — active='${ACTIVE:-<unset>}'  ->  next='$NEXT'  (ring: $ACCOUNTS)"

# ---------------------------------------------------------------------------
# CLEAN-BOUNDARY guard — refuse to rotate while any swarm is WORKING.
# ---------------------------------------------------------------------------
# Rotation = fleet restart = RAM-state loss; it must fire at a clean phase
# boundary. We reuse repo_activity (swarm-lib.sh) per swarm — the SAME signal
# swarm-restart.sh's safety rail uses. If any swarm wrote a transcript within
# STALE_SECONDS it is mid-turn; refuse unless --force.
working_swarms=""
if [ ! -d "$CLAUDE_PROJECTS" ]; then
  echo "swarm-rotate: NOTE — Claude projects dir not found ($CLAUDE_PROJECTS); cannot probe activity. Treating fleet as idle."
else
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _name="$SWARM_CONF_F_NAME"; _repo="$SWARM_CONF_F_REPO"
    [ -z "$_name" ] && continue
    [ -z "$_repo" ] && continue
    _sess="${PREFIX}-${_name}"
    # Only swarms that are actually live can be "working".
    if command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" has-session -t "$_sess" 2>/dev/null; then
      :
    else
      continue
    fi
    _act="$(repo_activity "$_repo" "$CLAUDE_PROJECTS" "$STALE_SECONDS")"
    _age="${_act%%|*}"
    case "$_age" in ''|*[!0-9]*) _age="$SWARM_NO_TRANSCRIPT_AGE" ;; esac
    if [ "$_age" -ne "$SWARM_NO_TRANSCRIPT_AGE" ] && [ "$_age" -le "$STALE_SECONDS" ]; then
      working_swarms="$working_swarms $_name(${_age}s)"
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
fi

if [ -n "$working_swarms" ]; then
  if [ "$FORCE" -eq 1 ]; then
    echo "swarm-rotate: WARNING — working swarms:$working_swarms — proceeding because --force. Uncommitted teammate work in those will be lost on relaunch." >&2
  else
    {
      echo "swarm-rotate: REFUSED — NOT a clean phase boundary. Working swarms:$working_swarms"
      echo "  Rotation restarts the whole fleet; in-process teammates are RAM-only and"
      echo "  do NOT survive relaunch. Wait for the fleet to idle (>${STALE_SECONDS}s since"
      echo "  the last transcript write), or pass --force to rotate anyway."
    } >&2
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# CHECKPOINT — save each swarm's place before the restart.
# ---------------------------------------------------------------------------
# Default is a WARNING no-op: this script must never silently mutate teammate
# git state. Wire SWARM_CHECKPOINT_CMD to a real commit+push to make a rotation
# cost minutes, not work. A non-zero checkpoint aborts unless --force.
run_checkpoint() {
  local hook="${SWARM_CHECKPOINT_CMD:-}"
  if [ -z "$hook" ]; then
    echo "swarm-rotate: NOTE — no SWARM_CHECKPOINT_CMD wired; NOT committing/pushing before rotation." >&2
    echo "             Discipline: rotate only from a checkpointed boundary. Set SWARM_CHECKPOINT_CMD" >&2
    echo "             to commit+branch-push each repo so a restart costs minutes, not work." >&2
    return 0
  fi
  local failed=""
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    _repo="$SWARM_CONF_F_REPO"
    [ -z "$_repo" ] && continue
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  would checkpoint: $_repo  (SWARM_CHECKPOINT_CMD)"
      continue
    fi
    echo "  checkpoint: $_repo"
    if ! sh -c "$hook" _ "$_repo"; then
      failed="$failed $_repo"
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  if [ -n "$failed" ]; then
    echo "swarm-rotate: checkpoint FAILED for:$failed" >&2
    return 1
  fi
  return 0
}

echo ""
echo "swarm-rotate: step 1/3 — checkpoint (commit + push before restart)"
if ! run_checkpoint; then
  if [ "$FORCE" -eq 1 ]; then
    echo "swarm-rotate: WARNING — checkpoint failed; proceeding because --force." >&2
  else
    echo "swarm-rotate: ABORTED — checkpoint failed and --force not given. Rotate only from a saved boundary." >&2
    exit 4
  fi
fi

# ---------------------------------------------------------------------------
# CREDENTIAL SWAP — make NEXT the active credential.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-rotate: step 2/3 — credential swap to '$NEXT'"
CREDSWAP="${SWARM_CREDSWAP_CMD:-}"
if [ "$DRY_RUN" -eq 1 ]; then
  if [ -n "$CREDSWAP" ]; then
    echo "  would run SWARM_CREDSWAP_CMD with account '$NEXT' (dry-run; not executed)"
  else
    echo "  (dry-run) NOTE: no SWARM_CREDSWAP_CMD wired — a live run would REFUSE here."
  fi
else
  if [ -z "$CREDSWAP" ]; then
    echo "swarm-rotate: REFUSED — no SWARM_CREDSWAP_CMD wired; cannot swap credentials safely." >&2
    echo "             This script never touches the keychain/OAuth creds directly. Wire the swap, e.g." >&2
    echo "             export SWARM_CREDSWAP_CMD='your-account-switch \"\$1\"'" >&2
    exit 2
  fi
  # The next account is passed as $1 AND exported, so the hook can read either.
  # The hook's exit code is 3-way meaningful (see swarm-credswap-keychain.sh):
  #   0 → swap took and the new credential authenticates → relaunch the fleet.
  #   7 → swap took, new credential AUTHENTICATES but the target is RATE-LIMITED →
  #       RING EXHAUSTION. Do NOT relaunch on a capped account; escalate; stop.
  #   * → swap failed → fleet NOT relaunched (don't boot on an unknown credential).
  SWARM_ROTATE_TO_ACCOUNT="$NEXT" sh -c "$CREDSWAP" _ "$NEXT"; cs_rc=$?
  case "$cs_rc" in
    0)
      echo "  swapped active credential -> '$NEXT'"
      ;;
    7)
      # Concise attention reason (the flag file is length-capped). Verbose detail
      # goes to stderr below.
      _reason="RING EXHAUSTED — rotate target '$NEXT' authenticates but is rate-limited; every account in the ring is capped. Add capacity or wait for a reset."
      echo "swarm-rotate: $_reason" >&2
      echo "swarm-rotate: the fleet was NOT brought up on the capped account '$NEXT' — this is a TERMINAL stop, not a thrash-rotate." >&2
      # Escalate: raise the operator attention flag if a hook is wired. The default
      # is a loud warning only — this script cannot self-locate a tmux channel, so
      # the canonical attention flag is raised from inside a swarm session (see
      # bin/swarm-attention.sh) or wired here by the operator/orchestrator.
      if [ -n "${SWARM_ATTENTION_CMD:-}" ]; then
        if sh -c "${SWARM_ATTENTION_CMD}" _ "$_reason" >/dev/null 2>&1; then
          echo "swarm-rotate: raised operator attention flag (SWARM_ATTENTION_CMD)." >&2
        else
          echo "swarm-rotate: WARNING — SWARM_ATTENTION_CMD failed; ring exhaustion is UN-escalated. Operator must intervene." >&2
        fi
      else
        echo "swarm-rotate: NOTE — no SWARM_ATTENTION_CMD wired; ring exhaustion is surfaced on stderr only." >&2
        echo "             Wire SWARM_ATTENTION_CMD (or have the tick escalate) so a capped ring raises the attention flag." >&2
      fi
      exit 6
      ;;
    *)
      echo "swarm-rotate: credential swap FAILED for '$NEXT' (exit $cs_rc) — fleet NOT relaunched (would boot on an unknown credential)." >&2
      exit 5
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# FLEET RELAUNCH — bring everything back up on the new account.
# ---------------------------------------------------------------------------
echo ""
echo "swarm-rotate: step 3/3 — relaunch the fleet on '$NEXT'"
run_relaunch() {
  local hook="${SWARM_FLEET_RELAUNCH_CMD:-}"
  if [ -n "$hook" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  would run SWARM_FLEET_RELAUNCH_CMD (dry-run; not executed)"
      return 0
    fi
    sh -c "$hook"
    return $?
  fi
  # Default relaunch: fleet down then up via swarm-up.sh (no name filter = all).
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would run: $SWARM_UP down   (whole fleet)"
    echo "  would run: $SWARM_UP up     (whole fleet on new account)"
    return 0
  fi
  "$SWARM_UP" down && "$SWARM_UP" up
}
if ! run_relaunch; then
  echo "swarm-rotate: WARNING — fleet relaunch returned non-zero; check 'swarm-up.sh status'." >&2
  # The swap already happened; report but don't pretend success.
  exit 1
fi

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "swarm-rotate: DRY-RUN complete — would have rotated '${ACTIVE:-<unset>}' -> '$NEXT'. No hooks executed."
else
  echo "swarm-rotate: DONE — rotated to '$NEXT' and relaunched the fleet."
  echo "  Persist SWARM_ACTIVE_ACCOUNT='$NEXT' for the next rotation (operator/orchestrator owns this)."
fi
exit 0
