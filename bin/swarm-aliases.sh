# swarm-aliases.sh — operator convenience aliases for the swarm tooling.
#
# Sourced, not executed. Works in zsh (primary) and bash.
#
# Install:
#   Add this line to ~/.zshrc (or ~/.bashrc):
#       source /Users/aschettino/qofirepos/qofi-claude-engineering/bin/swarm-aliases.sh
#   Open a new terminal (or `source ~/.zshrc`) and the aliases below are ready.
#
# Self-locating: this file derives its own path so it works whether or not
# SWARM_HOME is already exported. If SWARM_HOME is exported (e.g. by ~/.zshenv
# or the launchd plists), we honor it; otherwise we set it from this file's
# location. Each swarm script still validates SWARM_HOME on entry, so a mis-
# rooted source will fail loudly, not silently.

if [ -n "${ZSH_VERSION:-}" ]; then
  _swarm_aliases_src="${(%):-%x}"        # zsh: this file's path when sourced
else
  _swarm_aliases_src="${BASH_SOURCE[0]:-$0}"
fi
SWARM_HOME="${SWARM_HOME:-$(cd "$(dirname "$_swarm_aliases_src")/.." && pwd)}"
export SWARM_HOME
_swarm_bin="$SWARM_HOME/bin"
unset _swarm_aliases_src

# Attach helpers. `swarm-attach` with no arg attaches the single swarm if
# there's only one configured; otherwise it lists and asks for a name.
alias swarm-attach="$_swarm_bin/swarm-attach.sh"
alias swarm-reserve="$_swarm_bin/swarm-attach.sh reserve-backend-2"

# Lifecycle.
alias swarm-up="$_swarm_bin/swarm-up.sh up"
alias swarm-down="$_swarm_bin/swarm-up.sh down"
alias swarm-status="$_swarm_bin/swarm-up.sh status"

# Doctrine propagation (re-stamps templates into each registered repo,
# commits per repo, prints the SYNC ≠ LIVE restart reminder).
alias swarm-sync="$_swarm_bin/swarm-sync.sh"

# Watch the heartbeat/typing logs (launchd's StandardOut/Err for the watcher).
# tail -F survives log rotation; pass both files so a stderr line is obvious.
alias swarm-watch-log="tail -F $HOME/.config/swarm/watch.log $HOME/.config/swarm/watch.err"

unset _swarm_bin
