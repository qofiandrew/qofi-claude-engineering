#!/usr/bin/env bash
# Route a CPO directive to a reviewer from the other model family.
# This is an operator-host command. Swarm children request it; they do not
# launch nested network reviewers from their own sandbox.

set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE=""
CHECK=0
INPUT=""

usage() {
  cat <<'EOF'
Usage: adversarial-directive-review.sh [--engine claude|codex] [--check] [FILE]

  claude primary -> Codex reviews the directive
  codex primary  -> Claude/Fable reviews the directive

Registered repos derive their engine from swarm.conf. Unregistered repos keep
the historical Claude default unless --engine is supplied. The result is
advisory and never a gate.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --engine)
      [ $# -ge 2 ] || { echo "adversarial-directive-review: --engine requires a value" >&2; exit 2; }
      ENGINE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "adversarial-directive-review: unknown option: $1" >&2; exit 2 ;;
    *)
      [ -z "$INPUT" ] || { echo "adversarial-directive-review: at most one FILE is allowed" >&2; exit 2; }
      INPUT="$1"; shift ;;
  esac
done

case "$ENGINE" in
  ''|claude|codex) ;;
  *) echo "adversarial-directive-review: --engine must be exactly claude or codex" >&2; exit 2 ;;
esac

ENGINE_RESOLVER="$SCRIPT_DIR/resolve-swarm-engine.py"
if [ ! -x /usr/bin/python3 ] || [ ! -f "$ENGINE_RESOLVER" ] || [ -L "$ENGINE_RESOLVER" ]; then
  echo "adversarial-directive-review: ADVISORY-DOWN — trusted engine resolver is unavailable" >&2
  exit 3
fi
resolver_args=("$ENGINE_RESOLVER" "$SWARM_ROOT/swarm.conf" "$(pwd -P)")
[ -z "$ENGINE" ] || resolver_args+=("$ENGINE")
ACTUAL_ENGINE="$(/usr/bin/python3 -I -B "${resolver_args[@]}" 2>&1)"
resolve_rc=$?
if [ "$resolve_rc" -eq 4 ]; then
  ACTUAL_ENGINE="${ENGINE:-claude}"
elif [ "$resolve_rc" -ne 0 ]; then
  echo "adversarial-directive-review: ADVISORY-DOWN — $ACTUAL_ENGINE" >&2
  exit 3
fi
if [ -n "$ENGINE" ] && [ "$ENGINE" != "$ACTUAL_ENGINE" ]; then
  echo "adversarial-directive-review: ADVISORY-DOWN — requested engine '$ENGINE' does not match registered engine '$ACTUAL_ENGINE'" >&2
  exit 3
fi
ENGINE="$ACTUAL_ENGINE"

case "$ENGINE" in
  claude)
    REVIEWER="$SCRIPT_DIR/codex-review.sh"
    [ -f "$REVIEWER" ] && [ ! -L "$REVIEWER" ] || {
      echo "adversarial-directive-review: missing trusted Codex directive reviewer: $REVIEWER" >&2
      exit 3
    }
    args=(--directive)
    [ "$CHECK" -eq 1 ] && args+=(--check)
    [ -n "$INPUT" ] && args+=(--directive-file "$INPUT")
    exec /usr/bin/env SWARM_HOME="$SWARM_ROOT" /bin/bash "$REVIEWER" "${args[@]}"
    ;;
  codex)
    REVIEWER="$SCRIPT_DIR/claude-review.sh"
    [ -f "$REVIEWER" ] && [ ! -L "$REVIEWER" ] || {
      echo "adversarial-directive-review: missing Claude/Fable reviewer: $REVIEWER" >&2
      exit 3
    }
    args=(--directive)
    [ "$CHECK" -eq 1 ] && args+=(--check)
    [ -n "$INPUT" ] && args+=(--directive-file "$INPUT")
    exec /usr/bin/env SWARM_HOME="$SWARM_ROOT" /bin/bash "$REVIEWER" "${args[@]}"
    ;;
  *)
    echo "adversarial-directive-review: --engine must be exactly claude or codex" >&2
    exit 2
    ;;
esac
