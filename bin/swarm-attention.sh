#!/usr/bin/env bash
# swarm-attention.sh — CTO-driven attention flag, written by a long-lived
# lead when it issues a BLOCKED escalation that needs the operator's eyes.
#
# This is the AUTHORITATIVE "I need you" signal — distinct from the watcher's
# inferred failure-state alerts (stalled/silent/down/paused-limit). The watcher
# catches what the CTO can't tell you (it broke or got throttled); the CTO
# raises this flag for what only it knows (it's blocked on you per
# ESCALATION.md). Both feed the same status.json `needs_attention` channel
# the iOS widget consumes; the `attention_source` field distinguishes them.
#
# This script is the ONLY mechanism the CTO has to touch $STATE_DIR — the
# permission-gate hook allows just this exact invocation form and explicitly
# denies direct redirects (`echo > ~/.config/swarm/...`). Adding another
# state-file kind means adding another helper, not relaxing the gate.
#
# Usage (from inside the swarm's tmux session — channel is resolved from
# the session name via $SWARM_HOME/swarm.conf):
#
#     "$SWARM_HOME/bin/swarm-attention.sh" raise "<one-line reason>"
#     "$SWARM_HOME/bin/swarm-attention.sh" clear
#     "$SWARM_HOME/bin/swarm-attention.sh" status
#
# Doctrine pins the quoted-$SWARM_HOME form as canonical (see
# templates/ESCALATION.md §Attention flag). The permission-gate regex also
# tolerates the unquoted and absolute-path equivalents as belt-and-
# suspenders against shell-quoting drift.
#
# Bash 3.2-safe (macOS default). No deps beyond coreutils + tmux + python3.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  swarm-attention.sh raise "<reason>"
  swarm-attention.sh clear
  swarm-attention.sh status
EOF
  exit 64
}

[ $# -ge 1 ] || usage
subcmd="$1"; shift

case "$subcmd" in
  raise|clear|status) ;;
  *) usage ;;
esac

# ---------------------------------------------------------------------------
# Channel resolution. The CTO doesn't carry its channel ID in its env; we
# derive it from tmux session name + swarm.conf so the helper has exactly
# one inferred datum (which swarm) rather than an arg the CTO has to
# remember to pass correctly. Hard-fail rather than guess: misrouted flag
# would land on the wrong widget tile.
# ---------------------------------------------------------------------------
if [ -z "${TMUX:-}" ]; then
  echo "swarm-attention: \$TMUX is unset — must be invoked from inside the swarm tmux session" >&2
  exit 1
fi

session="$(tmux display -p '#S' 2>/dev/null || true)"
case "$session" in
  swarm-*) name="${session#swarm-}" ;;
  *)
    echo "swarm-attention: tmux session '$session' is not 'swarm-<name>' — refusing to guess channel" >&2
    exit 1
    ;;
esac

# Self-locate SWARM_HOME from this script's own path as belt-and-suspenders;
# swarm-up.sh exports it into the pane env too, but a CTO that lost env
# state (rare) still works.
if [ -z "${SWARM_HOME:-}" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  SWARM_HOME="$(cd "$(dirname "$0")/.." && pwd)"
fi
CONF="$SWARM_HOME/swarm.conf"
[ -f "$CONF" ] || { echo "swarm-attention: $CONF missing — \$SWARM_HOME may be wrong" >&2; exit 1; }

channel=""
while IFS='|' read -r n r t c; do
  n="$(printf '%s' "${n:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ "$n" = "$name" ] || continue
  channel="$(printf '%s' "${c:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  break
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

[ -z "$channel" ] && { echo "swarm-attention: no swarm.conf entry for '$name'" >&2; exit 1; }
echo "$channel" | grep -qE '^[0-9]+$' || {
  echo "swarm-attention: channel '$channel' for '$name' is not all-digits — bad swarm.conf row" >&2
  exit 1
}

STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
mkdir -p "$STATE_DIR"
FLAG="$STATE_DIR/attention-${channel}.flag"

case "$subcmd" in
  raise)
    [ $# -ge 1 ] || { echo "swarm-attention: raise requires a reason" >&2; usage; }
    reason="$1"
    # Strip ASCII control chars and length-cap. Avoids smuggling newlines /
    # nulls / terminal escapes into the flag file that the watcher and
    # downstream JSON consumers would have to defend against.
    reason="$(printf '%s' "$reason" | tr -d '\000-\037' | cut -c1-256)"
    [ -z "$reason" ] && { echo "swarm-attention: reason was empty after sanitization" >&2; exit 2; }
    # Atomic write — watcher reads this on a 10s tick; never let it see a
    # half-written file. umask 077 so the flag is owner-only.
    tmp="$FLAG.tmp.$$"
    ( umask 077; printf '%s\n' "$reason" > "$tmp" )
    mv "$tmp" "$FLAG"
    echo "swarm-attention: raised for '$name' (channel $channel): $reason"
    ;;
  clear)
    if [ -e "$FLAG" ]; then
      rm -f "$FLAG"
      echo "swarm-attention: cleared for '$name' (channel $channel)"
    else
      echo "swarm-attention: already clear for '$name' (channel $channel)"
    fi
    ;;
  status)
    if [ -r "$FLAG" ]; then
      printf 'raised: '
      cat "$FLAG"
    else
      echo "clear"
    fi
    ;;
esac
