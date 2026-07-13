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
#   swarm-view                supported Codex operator view; takes <name>
#   swarm-view-<name>         scrollable native Codex TUI behind the managed
#                             read-only facade; persisted event/status fallback
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
#   cto-watcher (the Discord CPO<->CTO relay daemon, pm2-managed):
#   watcher-up                start the relay (pm2)
#   watcher-down              STOP the relay (disable for this session; pm2)
#   watcher-restart           restart after a config/code change
#   watcher-status            pm2 status for the relay
#   watcher-log               tail the relay's logs (Ctrl-C to stop)
#   watcher-smoke             read-only pre-flight (verify channel access; posts nothing)
#   watcher-disable           stop AND persist stopped state (won't come back on reboot)
#   watcher-enable            start AND persist (survives reboot, with `pm2 startup` set once)
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
alias swarm-view="$_swarm_bin/swarm-view.sh"
alias swarm-up="$_swarm_bin/swarm-up.sh up"
alias swarm-down="$_swarm_bin/swarm-up.sh down"
alias swarm-status="$_swarm_bin/swarm-up.sh status"
alias swarm-sync="$_swarm_bin/swarm-sync.sh"
alias swarm-restart="$_swarm_bin/swarm-restart.sh"
alias swarm-update="$_swarm_bin/swarm-update.sh"
alias swarm-update-all="$_swarm_bin/swarm-update.sh --all"
alias swarm-watch-log="tail -F $HOME/.config/swarm/watch.log $HOME/.config/swarm/watch.err"

# cto-watcher (Discord CPO<->CTO relay daemon, pm2-managed). Names mirror the
# swarm verbs. start uses the ecosystem's absolute path so it works from any
# dir; the rest target the app by name (cwd-independent). "disable" persists the
# stopped state via pm2 save so a reboot/resurrect won't bring it back running.
alias watcher-up="pm2 start $SWARM_HOME/cto-watcher/ecosystem.config.cjs"
alias watcher-down="pm2 stop cto-watcher"
alias watcher-restart="pm2 restart cto-watcher"
alias watcher-status="pm2 describe cto-watcher"
alias watcher-log="pm2 logs cto-watcher"
alias watcher-smoke="node $SWARM_HOME/cto-watcher/smoke.js"
alias watcher-disable="pm2 stop cto-watcher && pm2 save"
alias watcher-enable="pm2 start $SWARM_HOME/cto-watcher/ecosystem.config.cjs && pm2 save"

# Per-swarm aliases generated from swarm.conf — for every row, THREE aliases:
#   swarm-<name>          attach-or-launch
#   swarm-restart-<name>  down + up (safety-railed)
#   swarm-update-<name>   sync + restart (the "fully current" bundle)
# Codex rows additionally get `swarm-view-<name>`, the managed scrollable native
# TUI behind a read-only facade (with a truthful persisted fallback); their
# primary pane remains a daemon.
# Re-source this file after swarm-add.sh to pick up new swarms.
if [ -f "$SWARM_HOME/swarm.conf" ]; then
  while IFS='|' read -r _swarm_name _swarm_repo _swarm_tok _swarm_channel _swarm_guild _swarm_account _swarm_engine _swarm_rest; do
    _swarm_name="$(echo "${_swarm_name:-}" | xargs)"
    _swarm_engine="$(echo "${_swarm_engine:-}" | xargs)"
    [ -z "$_swarm_name" ] && continue
    alias "swarm-restart-$_swarm_name=$_swarm_bin/swarm-restart.sh $_swarm_name"
    alias "swarm-update-$_swarm_name=$_swarm_bin/swarm-update.sh $_swarm_name"
    if [ "$_swarm_engine" = "codex" ]; then
      # Keep the primary alias's documented attach-or-launch contract.  The
      # attach helper launches a missing daemon, then engine-dispatches Codex
      # to the separate navigation-enabled native viewer behind its read-only
      # facade; it never exposes the daemon pane.  `swarm-view-*` remains the
      # explicit view-only/fallback command.
      alias "swarm-$_swarm_name=$_swarm_bin/swarm-attach.sh $_swarm_name"
      alias "swarm-view-$_swarm_name=$_swarm_bin/swarm-view.sh $_swarm_name"
    else
      alias "swarm-$_swarm_name=$_swarm_bin/swarm-attach.sh $_swarm_name"
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$SWARM_HOME/swarm.conf")
  unset _swarm_name _swarm_repo _swarm_tok _swarm_channel _swarm_guild _swarm_account _swarm_engine _swarm_rest
fi

unset _swarm_bin
