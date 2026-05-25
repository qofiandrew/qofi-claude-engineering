#!/usr/bin/env bash
# swarm-provision-tokens.sh — provision THIS machine's tokens.env from a
# durable secret store (vault).
#
# THE MODEL (see SETUP.md §4). Bot tokens live in a vault (the durable source
# of truth — 1Password is the lean, but ANY vault works). tokens.env is a
# per-machine, least-privilege DERIVATIVE: it holds exactly the tokens for the
# swarms THIS machine runs, and nothing else. This script regenerates it from
# the vault, so tokens.env is disposable — anything that must persist belongs
# in the vault, not here.
#
# WHICH TOKENS. The set is defined by $SWARM_HOME/swarm.conf: for every row,
# its TOKEN_VAR_NAME (3rd column) is fetched. (At n=1 — one mini running all
# swarms — that's every token; this is the shared-swarm.conf / n=1 case.
# See SETUP.md §4's SHARDING note for n>1.) Same name flows vault ->
# tokens.env -> swarm.conf, so provisioning is mechanical.
#
# VAULT-AGNOSTIC. You supply the fetch command via SWARM_VAULT_FETCH, a
# template containing '{}' which is replaced by the secret's name and run by
# the shell. Examples:
#   1Password:  export SWARM_VAULT_FETCH='op read op://Swarm/{}/credential'
#   pass:       export SWARM_VAULT_FETCH='pass show swarm/{}'
#   (test):     export SWARM_VAULT_FETCH='printf %s MOCK-{}'
# The command must print ONLY the secret value to stdout (trailing newline is
# trimmed). Secret values are NEVER echoed by this script.
#
# Usage:
#   swarm-provision-tokens.sh                 # write BOT_* subset to tokens.env
#   swarm-provision-tokens.sh --status        # ALSO pull SWARM_STATUS_SECRET +
#                                             # SWARM_STATUS_ENDPOINT (shared,
#                                             # not per-swarm; for the iOS feed)
#   swarm-provision-tokens.sh --dry-run       # list var names only; no fetch, no write
#   swarm-provision-tokens.sh -h | --help
#
# bash 3.2-safe. Atomic: fetches everything into a temp file first; if any
# fetch fails, the existing tokens.env is left untouched.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-provision-tokens: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

usage() { sed -n '2,40p' "$0"; exit "${1:-0}"; }

# shellcheck source=swarm-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/swarm-lib.sh"   # swarm_conf_parse_line

WITH_STATUS=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --status)  WITH_STATUS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         echo "swarm-provision-tokens: unknown arg: $1" >&2; usage 1 ;;
  esac
done

CONF="$SWARM_HOME/swarm.conf"
TOKENS="$SWARM_HOME/tokens.env"

# Refuse if tokens.env is git-tracked — same fatal guard as swarm-add. A
# tracked secrets file is a leak waiting to happen.
if git -C "$SWARM_HOME" ls-files --error-unmatch tokens.env >/dev/null 2>&1; then
  echo "swarm-provision-tokens: FATAL — tokens.env is tracked by git. Untrack it before provisioning:" >&2
  echo "    git -C \"$SWARM_HOME\" rm --cached tokens.env" >&2
  exit 2
fi

# Collect this machine's token var names from swarm.conf (dedup, preserve order).
VARS=""
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  tv="$SWARM_CONF_F_TOKVAR"
  [ -z "$tv" ] && continue
  case " $VARS " in *" $tv "*) ;; *) VARS="$VARS $tv" ;; esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$WITH_STATUS" -eq 1 ]; then
  # Shared secret + its endpoint. Not per-swarm: the same value goes on every
  # machine that POSTs the iOS status feed, and must match the ingest endpoint.
  VARS="$VARS SWARM_STATUS_SECRET SWARM_STATUS_ENDPOINT"
fi

VARS="$(echo "$VARS" | xargs)"   # trim
if [ -z "$VARS" ]; then
  echo "swarm-provision-tokens: no token vars found in $CONF (no swarm rows?) — nothing to do." >&2
  exit 0
fi

# Validate every name is a safe shell identifier BEFORE we interpolate it into
# the fetch command (no shell metacharacters can reach `sh -c`).
for v in $VARS; do
  case "$v" in
    [A-Za-z_]*) ;;
    *) echo "swarm-provision-tokens: refusing suspicious var name: $v" >&2; exit 1 ;;
  esac
  echo "$v" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || {
    echo "swarm-provision-tokens: refusing suspicious var name: $v" >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "swarm-provision-tokens: --dry-run — would provision into $TOKENS:"
  for v in $VARS; do echo "  $v"; done
  echo "(no vault calls made, tokens.env not touched)"
  exit 0
fi

FETCH="${SWARM_VAULT_FETCH:-}"
if [ -z "$FETCH" ]; then
  echo "swarm-provision-tokens: SWARM_VAULT_FETCH unset. Set it to your vault's fetch" >&2
  echo "  command template (use '{}' for the secret name), e.g.:" >&2
  echo "    export SWARM_VAULT_FETCH='op read op://Swarm/{}/credential'" >&2
  exit 1
fi
case "$FETCH" in *'{}'*) ;; *) echo "swarm-provision-tokens: SWARM_VAULT_FETCH must contain '{}' (the secret name placeholder)." >&2; exit 1 ;; esac

umask 077
TMP="$(mktemp "${TMPDIR:-/tmp}/tokens.env.XXXXXX")" || { echo "swarm-provision-tokens: mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT

{
  echo "# tokens.env — provisioned by swarm-provision-tokens.sh from the vault."
  echo "# Per-machine least-privilege subset; regenerate, don't hand-edit. chmod 600."
} >> "$TMP"

fetch_secret() {  # name -> prints secret (no value ever logged)
  local name="$1" cmd
  cmd="${FETCH//\{\}/$name}"
  sh -c "$cmd"
}

count=0
for v in $VARS; do
  val="$(fetch_secret "$v")" || { echo "swarm-provision-tokens: vault fetch FAILED for $v — tokens.env left unchanged." >&2; exit 1; }
  # Trim a single trailing newline that CLIs commonly add; keep the value otherwise verbatim.
  val="${val%$'\n'}"
  if [ -z "$val" ]; then
    echo "swarm-provision-tokens: vault returned EMPTY for $v — tokens.env left unchanged." >&2
    exit 1
  fi
  # Reject embedded newline / double-quote that would break the export line or
  # smuggle a second statement. Tokens/snowflakes/URLs never contain these.
  case "$val" in
    *$'\n'*|*'"'*) echo "swarm-provision-tokens: value for $v contains newline or quote — refusing." >&2; exit 1 ;;
  esac
  printf 'export %s="%s"\n' "$v" "$val" >> "$TMP"
  count=$((count + 1))
done

# Atomic replace. chmod before move so the secret is never world-readable.
chmod 600 "$TMP"
mv "$TMP" "$TOKENS"
trap - EXIT

echo "swarm-provision-tokens: wrote $count secret(s) to $TOKENS (chmod 600)."
echo "  vars: $VARS"
# Final guards: perms + not tracked.
perms="$(stat -f '%Lp' "$TOKENS" 2>/dev/null || echo '???')"
[ "$perms" = "600" ] || echo "swarm-provision-tokens: WARNING — $TOKENS perms are $perms, expected 600" >&2
git -C "$SWARM_HOME" status --short tokens.env 2>/dev/null | grep -q . && \
  echo "swarm-provision-tokens: NOTE — tokens.env shows in git status; confirm it's gitignored, not staged." >&2 || true
exit 0
