#!/usr/bin/env bash
# swarm-account-state.sh — persist the swarm fleet's ACTIVE Max account across
# rotations, so the account ring advances correctly turn over turn.
#
# THE MODEL. swarm-rotate.sh computes the NEXT account from two inputs: the
# ring (SWARM_ACCOUNTS) and the currently-active handle (SWARM_ACTIVE_ACCOUNT).
# The ring is static config; the active handle is STATE that must survive a
# rotation — and a rotation is a full fleet restart, so it cannot live in a
# process's environment. swarm-rotate.sh says so explicitly at its tail:
#   "Persist SWARM_ACTIVE_ACCOUNT='$NEXT' for the next rotation
#    (operator/orchestrator owns this)."
# This script IS that persistence: a tiny get/set over a single-line state file.
# The orchestrator reads it to seed SWARM_ACTIVE_ACCOUNT before a rotation and
# writes it to the freshly-rotated account after a successful swap.
#
# WHAT IT STORES. Exactly one line: the active account HANDLE (e.g. "max-b").
# Not a secret — it's just the name of a credential the swap hook will switch
# to — but we still chmod 600 the file (single-owner, tidy) and never log values
# beyond the handle the operator already typed.
#
# STATE FILE. Default ~/.config/swarm/active-account (XDG-ish under the user's
# config root). Overridable via SWARM_ACCOUNT_STATE_FILE so tests — and operators
# with a non-standard layout — point it elsewhere without touching the real one.
# Parent directories are created on `set` as needed.
#
# Usage:
#   swarm-account-state.sh get             # print the stored handle; exit 0.
#                                          # Missing/empty file -> print nothing,
#                                          # exit 1 (the CALLER decides a default,
#                                          # e.g. cold-start to the first account).
#   swarm-account-state.sh set <account>  # persist <account> as the active handle.
#   swarm-account-state.sh path            # print the resolved state-file path.
#   swarm-account-state.sh -h | --help
#
# Exit codes:
#   0 — get printed a non-empty handle; or set succeeded; or path/help.
#   1 — get found no stored handle (missing/empty file) — not an error, a signal.
#   2 — usage error (bad subcommand, set without/with a bad account handle, or a
#       write failure).
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-account-state"

usage() { sed -n '1,46p' "$0"; exit "${1:-0}"; }

# Resolve the state-file path: explicit override wins; else XDG-ish default.
# We do NOT require SWARM_HOME here — this is a leaf utility the orchestrator
# calls with a clean env, and the state lives in the user's config root, not in
# the template repo.
STATE_FILE="${SWARM_ACCOUNT_STATE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/swarm/active-account}"

# An account handle is the same shape swarm-add validates for swarm names and
# the ring uses: a leading letter, then letters/digits/_/- . This both keeps the
# file to a single tidy token and refuses anything with a newline, slash, or
# shell metacharacter that has no business in a credential handle.
valid_handle() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*$'; }

cmd_get() {
  # Missing or empty file => no stored handle. Exit 1 (signal, not error): the
  # caller supplies the default (swarm-rotate cold-starts to the first account).
  [ -f "$STATE_FILE" ] || return 1
  local val
  # First non-empty line only; ignore trailing blank lines / accidental noise.
  val="$(grep -vE '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null | head -n1)"
  val="$(printf '%s' "$val" | tr -d '[:space:]')"
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
  return 0
}

cmd_set() {
  local acct="$1"
  if [ -z "$acct" ]; then
    echo "$PROG: set needs an account handle, e.g. '$PROG set max-b'" >&2
    return 2
  fi
  if ! valid_handle "$acct"; then
    echo "$PROG: refusing suspicious account handle: '$acct' (expected [A-Za-z][A-Za-z0-9_-]*)" >&2
    return 2
  fi
  local dir
  dir="$(dirname "$STATE_FILE")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "$PROG: could not create state dir: $dir" >&2
    return 2
  fi
  # Write atomically: stage a temp in the same dir, chmod, then mv into place so
  # a concurrent reader never sees a half-written or wrong-perm file.
  umask 077
  local tmp
  tmp="$(mktemp "$dir/.active-account.XXXXXX" 2>/dev/null)" || {
    echo "$PROG: mktemp failed in $dir" >&2; return 2; }
  printf '%s\n' "$acct" > "$tmp" || { rm -f "$tmp"; echo "$PROG: write failed" >&2; return 2; }
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    echo "$PROG: could not write $STATE_FILE" >&2
    return 2
  fi
  echo "$PROG: active account -> '$acct' ($STATE_FILE)"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || usage 2

case "$1" in
  get)
    shift
    [ $# -eq 0 ] || { echo "$PROG: get takes no arguments" >&2; exit 2; }
    cmd_get; exit $?
    ;;
  set)
    shift
    cmd_set "${1:-}"; exit $?
    ;;
  path)
    printf '%s\n' "$STATE_FILE"; exit 0
    ;;
  -h|--help)
    usage 0
    ;;
  *)
    echo "$PROG: unknown subcommand: '$1' (expected get|set|path)" >&2
    usage 2
    ;;
esac
