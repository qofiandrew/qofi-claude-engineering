#!/usr/bin/env bash
# swarm-launchd-install.sh — render the launchd plist TEMPLATES for THIS
# machine and (re)load the agents.
#
# WHY THIS EXISTS. launchd does not expand $VARS or ~ inside plist path
# strings — ProgramArguments / StandardOutPath / EnvironmentVariables must be
# absolute literals. So a single committed plist cannot be username- or
# host-agnostic. We commit TEMPLATES (launchd/*.plist.template) with @@…@@
# placeholders and render the real plists here, per machine, at install time.
# The repo therefore carries ZERO hardcoded /Users/<name> paths, and every
# Mac mini in the fleet renders its own copy (sharding-correct by construction).
#
# Substitutions:
#   @@SWARM_HOME@@     -> $SWARM_HOME
#   @@HOME@@           -> $HOME
#   @@TMUX_BIN@@       -> $SWARM_TMUX_BIN if set, else `command -v tmux`
#   @@TICK_INTERVAL@@  -> $SWARM_TICK_INTERVAL if set, else 300 (seconds between
#                         rotation-orchestrator ticks; only the rotate-tick plist
#                         uses it — harmless no-op for templates without it)
#
# Usage:
#   swarm-launchd-install.sh                 # render to ~/Library/LaunchAgents + (re)load
#   swarm-launchd-install.sh --render-only DIR   # render into DIR, no launchctl (tests/dry-run)
#   swarm-launchd-install.sh -h | --help
#
# Idempotent: safe to re-run after a template edit or a SWARM_HOME move — it
# bootout's the old agent and bootstrap's the freshly rendered one.
#
# bash 3.2-safe. CWD-independent.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-launchd-install: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

usage() { sed -n '2,33p' "$0"; exit "${1:-0}"; }

RENDER_ONLY_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --render-only) RENDER_ONLY_DIR="${2:-}"; [ -z "$RENDER_ONLY_DIR" ] && { echo "swarm-launchd-install: --render-only needs a DIR" >&2; exit 1; }; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)             echo "swarm-launchd-install: unknown arg: $1" >&2; usage 1 ;;
  esac
done

# Resolve tmux's absolute path (launchd's PATH is minimal). Allow an override
# so render-only/test runs don't depend on tmux being installed.
TMUX_BIN="${SWARM_TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
if [ -z "$TMUX_BIN" ]; then
  echo "swarm-launchd-install: tmux not found on PATH — 'brew install tmux' or set SWARM_TMUX_BIN" >&2
  exit 1
fi

# Cadence for the rotation-orchestrator tick (StartInterval, seconds). Only the
# rotate-tick template carries @@TICK_INTERVAL@@; for every other template the
# substitution below finds nothing to replace. Validate it's a positive integer
# so we never render a malformed StartInterval into the plist.
TICK_INTERVAL="${SWARM_TICK_INTERVAL:-300}"
case "$TICK_INTERVAL" in
  ''|*[!0-9]*) echo "swarm-launchd-install: SWARM_TICK_INTERVAL must be a positive integer (seconds); got '$TICK_INTERVAL'" >&2; exit 1 ;;
esac
if [ "$TICK_INTERVAL" -lt 1 ]; then
  echo "swarm-launchd-install: SWARM_TICK_INTERVAL must be >= 1 second; got '$TICK_INTERVAL'" >&2
  exit 1
fi

TEMPLATE_DIR="$SWARM_HOME/launchd"
shopt -s nullglob 2>/dev/null || true
TEMPLATES=( "$TEMPLATE_DIR"/*.plist.template )
if [ "${#TEMPLATES[@]}" -eq 0 ]; then
  echo "swarm-launchd-install: no *.plist.template in $TEMPLATE_DIR" >&2
  exit 1
fi

# Decide output dir.
if [ -n "$RENDER_ONLY_DIR" ]; then
  OUT_DIR="$RENDER_ONLY_DIR"
  mkdir -p "$OUT_DIR" || { echo "swarm-launchd-install: cannot create $OUT_DIR" >&2; exit 1; }
else
  OUT_DIR="$HOME/Library/LaunchAgents"
  # The agents write logs here; create it now so a first launch doesn't fail.
  mkdir -p "$HOME/.config/swarm" "$OUT_DIR" || { echo "swarm-launchd-install: mkdir failed" >&2; exit 1; }
fi

render_one() {  # template_path -> renders to $OUT_DIR/<basename minus .template>
  local tmpl="$1"
  local base out
  base="$(basename "$tmpl")"; base="${base%.template}"
  out="$OUT_DIR/$base"
  # sed with '#' delimiters since the values are paths containing '/'.
  sed -e "s#@@SWARM_HOME@@#${SWARM_HOME}#g" \
      -e "s#@@HOME@@#${HOME}#g" \
      -e "s#@@TMUX_BIN@@#${TMUX_BIN}#g" \
      -e "s#@@TICK_INTERVAL@@#${TICK_INTERVAL}#g" \
      "$tmpl" > "$out" || { echo "swarm-launchd-install: render failed for $base" >&2; return 1; }

  # Belt-and-suspenders: no placeholder may survive, and the result must be a
  # valid plist. Either failure means a malformed agent — refuse to load it.
  # Match the actual @@NAME@@ placeholder shape (not a bare '@@', so prose can
  # mention the delimiters without false-tripping).
  if grep -qE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$out"; then
    echo "swarm-launchd-install: unsubstituted placeholder left in $out" >&2
    grep -nE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$out" >&2
    return 1
  fi
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$out" >/dev/null || { echo "swarm-launchd-install: $out failed plutil -lint" >&2; return 1; }
  fi
  echo "  rendered: $out"
}

label_of() {  # basename com.qofi.swarm-watch.plist -> com.qofi.swarm-watch
  local b="$1"; b="$(basename "$b")"; echo "${b%.plist}"
}

rc=0
for tmpl in "${TEMPLATES[@]}"; do
  render_one "$tmpl" || rc=1
done
[ "$rc" -ne 0 ] && { echo "swarm-launchd-install: one or more templates failed to render — not loading." >&2; exit 1; }

if [ -n "$RENDER_ONLY_DIR" ]; then
  echo "swarm-launchd-install: render-only complete ($OUT_DIR) — launchctl skipped."
  exit 0
fi

# (Re)load each rendered agent. bootout is best-effort (it errors if the agent
# isn't currently loaded, which is fine on a first install).
DOMAIN="gui/$(id -u)"
for tmpl in "${TEMPLATES[@]}"; do
  base="$(basename "$tmpl")"; base="${base%.template}"
  out="$OUT_DIR/$base"
  label="$(label_of "$base")"
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  if launchctl bootstrap "$DOMAIN" "$out" 2>/dev/null; then
    echo "  loaded:   $label"
  else
    # Older macOS lacks bootstrap; fall back to load -w.
    if launchctl load -w "$out" 2>/dev/null; then
      echo "  loaded:   $label (via load -w)"
    else
      echo "swarm-launchd-install: failed to load $label — check 'launchctl print $DOMAIN/$label'" >&2
      rc=1
    fi
  fi
done

echo ""
echo "swarm-launchd-install: done. Verify with:  launchctl list | grep com.qofi"
exit "$rc"
