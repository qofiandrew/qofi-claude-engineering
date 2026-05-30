# swarm-aliases.sh — operator convenience aliases for the swarm tooling.
#
# Sourced, not executed. Works in zsh (primary) and bash.
#
# Install:
#   Add this line to ~/.zshrc (or ~/.bashrc):
#       source /Users/aschettino/qofirepos/qofi-claude-engineering/bin/swarm-aliases.sh
#   Open a new terminal (or `source ~/.zshrc`) and the aliases below are ready.
#
# Aliases:
#   swarm-<name>              attach (or launch-then-attach) that specific
#                             swarm (one per row in swarm.conf, generated)
#   swarm-restart-<name>      cycle ONE swarm: down + up (no sync; reload
#                             session from disk). Safety-railed: refuses
#                             without --force if the swarm is WORKING.
#   swarm-update-<name>       sync THEN restart ONE swarm — the "make this
#                             swarm fully current with templates" bundle.
#                             Same safety rail.
#   swarm-attach              same as swarm-<name> but takes <name> as arg
#   swarm-restart             same as swarm-restart-<name> but takes arg
#   swarm-update              same as swarm-update-<name> but takes arg
#   swarm-update-all          sync + restart EVERY swarm (resilient: one
#                             failure doesn't stop the rest). Add --force to
#                             skip the busy-swarm safety rail.
#   swarm-up                  bring up all configured swarms
#   swarm-down                stop all swarm sessions
#   swarm-status              list running swarm sessions
#   swarm-sync                propagate doctrine from templates into each repo
#   swarm-watch-log           tail the launchd watcher logs
#
# When you add a swarm via swarm-add.sh, re-source this file to get the new
# per-swarm alias: `source ~/.zshrc` (or just open a new terminal).
#
# Self-locating: this file derives its own path so it works whether or not
# SWARM_HOME is already exported. If SWARM_HOME is exported (e.g. by
# ~/.zshenv or the launchd plists), we honor it; otherwise we set it from
# this file's location.

if [ -n "${ZSH_VERSION:-}" ]; then
  _swarm_aliases_src="${(%):-%x}"        # zsh: this file's path when sourced
else
  _swarm_aliases_src="${BASH_SOURCE[0]:-$0}"
fi
SWARM_HOME="${SWARM_HOME:-$(cd "$(dirname "$_swarm_aliases_src")/.." && pwd)}"
export SWARM_HOME
_swarm_bin="$SWARM_HOME/bin"
unset _swarm_aliases_src

# Generic helpers.
alias swarm-attach="$_swarm_bin/swarm-attach.sh"
alias swarm-up="$_swarm_bin/swarm-up.sh up"
alias swarm-down="$_swarm_bin/swarm-up.sh down"
alias swarm-status="$_swarm_bin/swarm-up.sh status"
alias swarm-sync="$_swarm_bin/swarm-sync.sh"
alias swarm-restart="$_swarm_bin/swarm-restart.sh"
alias swarm-update="$_swarm_bin/swarm-update.sh"
alias swarm-update-all="$_swarm_bin/swarm-update.sh --all"
alias swarm-watch-log="tail -F $HOME/.config/swarm/watch.log $HOME/.config/swarm/watch.err"

# Per-swarm aliases generated from swarm.conf — for every row, THREE aliases:
#   swarm-<name>          attach-or-launch
#   swarm-restart-<name>  down + up (safety-railed)
#   swarm-update-<name>   sync + restart (the "fully current" bundle)
# Re-source this file after swarm-add.sh to pick up new swarms.
if [ -f "$SWARM_HOME/swarm.conf" ]; then
  while IFS='|' read -r _swarm_name _; do
    _swarm_name="$(echo "${_swarm_name:-}" | xargs)"
    [ -z "$_swarm_name" ] && continue
    alias "swarm-$_swarm_name=$_swarm_bin/swarm-attach.sh $_swarm_name"
    alias "swarm-restart-$_swarm_name=$_swarm_bin/swarm-restart.sh $_swarm_name"
    alias "swarm-update-$_swarm_name=$_swarm_bin/swarm-update.sh $_swarm_name"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$SWARM_HOME/swarm.conf")
  unset _swarm_name
fi

unset _swarm_bin
