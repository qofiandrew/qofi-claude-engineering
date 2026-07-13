#!/usr/bin/env bash
# adversarial-review.sh — engine-aware dispatcher for the contrarian review lane.
#
# The lane's whole value is a reviewer from a DIFFERENT model family than the
# code's author, so the reviewer is chosen by the swarm's ENGINE (swarm.conf
# field 7, resolved by matching the current repo to its conf row):
#
#   engine claude           -> codex-review.sh   (Codex reviews Claude's work)
#   engine codex            -> claude-review.sh  (Claude/Fable reviews Codex's work)
#
# All args (--range, --check) pass through. Advisory, never gating — both
# underlying lanes carry the same subscription-only money-path floor and
# advisory-down semantics. Registered rows are authoritative. An unregistered
# repo preserves the historical Claude default, or accepts an explicit
# `--engine claude|codex`; duplicate/malformed identities still fail closed.
#
# Bash 3.2-safe.

set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_RESOLVER="$SCRIPT_DIR/resolve-swarm-engine.py"

requested_engine=""
forward_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine)
      [ "$#" -ge 2 ] || { echo "adversarial-review: --engine requires claude or codex" >&2; exit 2; }
      requested_engine="$2"; shift 2 ;;
    --engine=*) requested_engine="${1#--engine=}"; shift ;;
    *) forward_args+=("$1"); shift ;;
  esac
done
case "$requested_engine" in ''|claude|codex) : ;; *)
  echo "adversarial-review: --engine requires claude or codex" >&2; exit 2 ;;
esac

if [ ! -x /usr/bin/python3 ] || [ ! -f "$ENGINE_RESOLVER" ] || [ -L "$ENGINE_RESOLVER" ]; then
  echo "adversarial-review: ADVISORY-DOWN — trusted engine resolver is unavailable" >&2
  exit 3
fi
resolver_args=("$ENGINE_RESOLVER" "$SWARM_ROOT/swarm.conf" "$(pwd -P)")
[ -z "$requested_engine" ] || resolver_args+=("$requested_engine")
engine="$(/usr/bin/python3 -I -B "${resolver_args[@]}" 2>&1)"
resolve_rc=$?
if [ "$resolve_rc" -eq 4 ]; then
  # A valid but unregistered repository historically meant Claude-authored
  # work. Keep that path, while allowing first-class ad-hoc Codex review to be
  # declared explicitly.
  engine="${requested_engine:-claude}"
elif [ "$resolve_rc" -ne 0 ]; then
  echo "adversarial-review: ADVISORY-DOWN — $engine" >&2
  exit 3
elif [ -n "$requested_engine" ] && [ "$requested_engine" != "$engine" ]; then
  echo "adversarial-review: ADVISORY-DOWN — requested engine '$requested_engine' does not match registered engine '$engine'" >&2
  exit 3
fi

if [ "$engine" = "codex" ]; then
  exec "$SCRIPT_DIR/claude-review.sh" "${forward_args[@]}"
else
  exec "$SCRIPT_DIR/codex-review.sh" "${forward_args[@]}"
fi
