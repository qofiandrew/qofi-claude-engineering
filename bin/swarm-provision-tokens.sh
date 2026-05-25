#!/usr/bin/env bash
# swarm-provision-tokens.sh — provision THIS machine's tokens.env by pasting
# each secret from your password manager (1Password is the durable source of
# truth; you are the manual conduit per machine).
#
# THE MODEL (see SETUP.md §4). Bot tokens live in 1Password — the durable
# source of truth, the same across every machine. tokens.env is a per-machine,
# least-privilege DERIVATIVE: it holds exactly the tokens for the swarms THIS
# machine runs, and nothing else. This script regenerates it; tokens.env is
# disposable — anything that must persist belongs in 1Password, not here.
#
# WHICH TOKENS. The set is defined by $SWARM_HOME/swarm.conf: for every row,
# its TOKEN_VAR_NAME (3rd column). (At n=1 — one mini running all swarms —
# that's every token; the shared-swarm.conf / n=1 case. See SETUP.md §4's
# SHARDING note for n>1.) Same name flows 1Password -> tokens.env -> swarm.conf.
#
# DEFAULT FLOW: manual paste. For each var, the script shows a SILENT prompt
# (read -s — never echoed, never in scrollback, never on the command line);
# you copy that secret from 1Password and paste it. The same secret discipline
# swarm-add uses for new bot tokens.
#
# OPTIONAL automation (power-user): if SWARM_VAULT_FETCH is set, the script
# fetches non-interactively instead of prompting. It's a command template with
# a '{}' placeholder for the secret name, run by the shell, e.g.:
#   export SWARM_VAULT_FETCH='op read op://Swarm/{}/credential'   # 1Password CLI
# Unset (the default), you get the manual prompt. Either way, secret VALUES are
# NEVER echoed by this script.
#
# Usage:
#   swarm-provision-tokens.sh                 # prompt for the BOT_* subset
#   swarm-provision-tokens.sh --status        # ALSO prompt for SWARM_STATUS_SECRET
#                                             # + SWARM_STATUS_ENDPOINT (shared,
#                                             # not per-swarm; for the iOS feed)
#   swarm-provision-tokens.sh --dry-run       # list var names only; no prompt, no write
#   swarm-provision-tokens.sh -h | --help
#
# bash 3.2-safe. Atomic: collects everything into a temp file first; if any
# value is missing/invalid, the existing tokens.env is left untouched.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-provision-tokens: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

usage() { sed -n '2,46p' "$0"; exit "${1:-0}"; }

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

# Collect this machine's token var names from swarm.conf (dedup, preserve
# order) and remember each one's swarm name for a friendlier prompt.
VARS=""
MAP=""   # newline-separated "VAR|swarmname" pairs
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  tv="$SWARM_CONF_F_TOKVAR"
  [ -z "$tv" ] && continue
  case " $VARS " in
    *" $tv "*) ;;
    *) VARS="$VARS $tv"; MAP="$MAP$tv|$SWARM_CONF_F_NAME
" ;;
  esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$WITH_STATUS" -eq 1 ]; then
  # Shared secret + its endpoint. Not per-swarm: the same value goes on every
  # machine that POSTs the iOS status feed, and must match the ingest endpoint.
  # (No MAP entry — their names are self-describing, so the prompt shows no
  # "(swarm: …)" suffix for them.)
  VARS="$VARS SWARM_STATUS_SECRET SWARM_STATUS_ENDPOINT"
fi

VARS="$(echo "$VARS" | xargs)"   # trim
if [ -z "$VARS" ]; then
  echo "swarm-provision-tokens: no token vars found in $CONF (no swarm rows?) — nothing to do." >&2
  exit 0
fi

# Validate every name is a safe shell identifier BEFORE it reaches an export
# line (or, on the optional path, `sh -c`). No metacharacters can sneak in.
for v in $VARS; do
  echo "$v" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || {
    echo "swarm-provision-tokens: refusing suspicious var name: $v" >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "swarm-provision-tokens: --dry-run — would provision into $TOKENS:"
  for v in $VARS; do echo "  $v"; done
  echo "(no prompts shown, no vault calls, tokens.env not touched)"
  exit 0
fi

swarm_for() {  # VAR -> its swarm name (or empty)
  printf '%s\n' "$MAP" | awk -F'|' -v k="$1" '$1==k{print $2; exit}'
}

FETCH="${SWARM_VAULT_FETCH:-}"
if [ -n "$FETCH" ]; then
  case "$FETCH" in *'{}'*) ;; *) echo "swarm-provision-tokens: SWARM_VAULT_FETCH is set but lacks the '{}' placeholder." >&2; exit 1 ;; esac
  echo "swarm-provision-tokens: SWARM_VAULT_FETCH set — fetching non-interactively (optional automation path)." >&2
else
  {
    echo "swarm-provision-tokens: paste each secret from 1Password. Input is HIDDEN"
    echo "  (nothing is echoed); press Enter after each. Provisioning $(echo "$VARS" | wc -w | xargs) value(s):"
  } >&2
fi

# is_secret VAR -> 0 if it should be read silently (everything except the
# status ENDPOINT, which is a non-secret URL worth seeing as you type).
is_secret() { [ "$1" != "SWARM_STATUS_ENDPOINT" ]; }

# get_value VAR -> prints the acquired value to stdout. Prompts (manual path)
# go to stderr so they never contaminate the captured value. Returns non-zero
# on a fetch failure (optional path only).
get_value() {  # VAR
  local v="$1" val sw
  if [ -n "$FETCH" ]; then
    val="$(sh -c "${FETCH//\{\}/$v}")" || return 1
  else
    sw="$(swarm_for "$v")"
    if is_secret "$v"; then
      printf '  %s%s [hidden]: ' "$v" "${sw:+  (swarm: $sw)}" >&2
      IFS= read -rs val || true
      printf '\n' >&2
    else
      printf '  %s%s: ' "$v" "${sw:+  (swarm: $sw)}" >&2
      IFS= read -r val || true
    fi
  fi
  printf '%s' "$val"
}

umask 077
TMP="$(mktemp "${TMPDIR:-/tmp}/tokens.env.XXXXXX")" || { echo "swarm-provision-tokens: mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT

{
  echo "# tokens.env — provisioned by swarm-provision-tokens.sh."
  echo "# Per-machine least-privilege subset, pasted from 1Password. Regenerate,"
  echo "# don't hand-edit. chmod 600, gitignored."
} >> "$TMP"

count=0
for v in $VARS; do
  val="$(get_value "$v")" || { echo "swarm-provision-tokens: fetch FAILED for $v — tokens.env left unchanged." >&2; exit 1; }
  # Trim a single trailing newline (CLIs add one; read already strips it).
  val="${val%$'\n'}"
  if [ -z "$val" ]; then
    echo "swarm-provision-tokens: EMPTY value for $v — tokens.env left unchanged." >&2
    exit 1
  fi
  # Reject embedded newline / double-quote that would break the export line or
  # smuggle a second statement. Tokens/snowflakes/URLs never contain these.
  case "$val" in
    *$'\n'*|*'"'*) echo "swarm-provision-tokens: value for $v contains a newline or quote — refusing." >&2; exit 1 ;;
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
