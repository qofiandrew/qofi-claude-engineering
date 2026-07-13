#!/usr/bin/env bash
# swarm-up.sh — run one persistent Agent Teams lead per repo in tmux on the
# always-on host (Mac mini), each with its own Discord bot identity, supervised.
#
# Avoids bash-4 features so it runs on macOS's default bash 3.2 (brew bash is fine too).
#
# Config: $SWARM_HOME/swarm.conf — one repo per line, pipe-separated, eight fields:
#     session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID | GUILD_ID | ACCOUNT | ENGINE | CODEX_AUTH_POOL
#   TOKEN_VAR_NAME names an env var (defined in $SWARM_HOME/tokens.env) holding
#   that repo's DISCORD_BOT_TOKEN. CHANNEL_ID is the Discord channel this swarm is
#   bound to. GUILD_ID is optional Discord deep-link metadata. ACCOUNT selects a
#   Claude account partition. ENGINE is blank/claude for Claude Code or codex for
#   the Codex bridge; Codex launch binds and validates CHANNEL_ID directly.
#   CODEX_AUTH_POOL is independent from ACCOUNT and selects a named ordered
#   Codex profile pool; blank resolves to `default`.
#   Blank lines and #-comments are ignored.
#
# Usage:
#   swarm-up.sh up       # start any sessions not already running
#   swarm-up.sh down     # stop all swarm sessions
#   swarm-up.sh status   # list running swarm sessions
#   swarm-up.sh watch    # foreground supervisor: relaunch dead leads (Ctrl-C to stop)
#   swarm-up.sh attach <name>   # attach the terminal to a running swarm to watch /
#                               # interact live; Ctrl-b d detaches without stopping it.

set -euo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-up: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi
CONF="$SWARM_HOME/swarm.conf"
TOKENS="$SWARM_HOME/tokens.env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_VIEW="${SWARM_VIEW_BIN:-$SCRIPT_DIR/swarm-view.sh}"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # swarm_conf_parse_line
PREFIX="swarm"                              # tmux session name prefix (no ':' allowed)
SWARM_UP_PARTIAL_CODEX_SESSION=""
SWARM_UP_LAUNCH_LOCK_DIR=""
SWARM_UP_LAUNCH_LOCK_EVIDENCE=""
SWARM_UP_LAUNCH_LOCK_HELPER=""

swarm_up_launch_lock_acquire() {  # validated swarm name
  local name="$1" root lock helper conf_parent conf_base
  case "$name" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$CONF" in
    */*) conf_parent="${CONF%/*}"; conf_base="${CONF##*/}"; [ -n "$conf_parent" ] || conf_parent="/" ;;
    *) conf_parent="."; conf_base="$CONF" ;;
  esac
  conf_parent="$(cd "$conf_parent" 2>/dev/null && pwd -P)" || return 1
  root="${conf_parent%/}/$conf_base.launch.locks"
  if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then return 1; fi
  (umask 077; mkdir -p "$root") || return 1
  lock="$root/$name"
  helper="$(swarm_atomic_lock_helper_path)" || return 1
  if ! printf '%s\n' "$$" | /usr/bin/python3 -I -B \
       "$helper" "$lock" owner 2>/dev/null; then
    # A dead owner may have left a partial same-name tmux generation. PID
    # death alone is not permission to delete the only incomplete-launch
    # signal and accept that pane as healthy; explicit audit/recovery is safer.
    return 1
  fi
  SWARM_UP_LAUNCH_LOCK_EVIDENCE="$(/usr/bin/python3 -I -B - "$lock" <<'PY'
import hashlib, os, stat, sys
lock=sys.argv[1]; owner=os.path.join(lock, 'owner')
l=os.lstat(lock); o=os.lstat(owner)
if (not stat.S_ISDIR(l.st_mode) or stat.S_ISLNK(l.st_mode) or stat.S_IMODE(l.st_mode) != 0o700
        or not stat.S_ISREG(o.st_mode) or stat.S_ISLNK(o.st_mode) or stat.S_IMODE(o.st_mode) != 0o600
        or l.st_uid != os.getuid() or o.st_uid != os.getuid()): raise SystemExit(2)
fd=os.open(owner, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
try:
    before=os.fstat(fd); raw=os.read(fd, 16385); after=os.fstat(fd)
finally: os.close(fd)
if (len(raw) > 16384 or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) !=
        (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)):
    raise SystemExit(2)
print(l.st_dev,l.st_ino,o.st_dev,o.st_ino,hashlib.sha256(raw).hexdigest())
PY
)" || {
    echo "swarm-up: published launch owner could not be bound; lock retained for audited recovery" >&2
    return 1
  }
  SWARM_UP_LAUNCH_LOCK_DIR="$lock"
  SWARM_UP_LAUNCH_LOCK_HELPER="$helper"
  return 0
}

swarm_up_launch_lock_release() {
  [ -n "$SWARM_UP_LAUNCH_LOCK_DIR" ] || return 0
  local _ld _li _od _oi _hash _rc=0
  read -r _ld _li _od _oi _hash <<EOF
$SWARM_UP_LAUNCH_LOCK_EVIDENCE
EOF
  if [ -z "$_hash" ] || [ -z "$SWARM_UP_LAUNCH_LOCK_HELPER" ] || \
      ! /usr/bin/python3 -I -B "$SWARM_UP_LAUNCH_LOCK_HELPER" release \
      "$SWARM_UP_LAUNCH_LOCK_DIR" owner "$_ld" "$_li" "$_od" "$_oi" "$_hash" -; then
    echo "swarm-up: CRITICAL — exact launch lock release failed; retained for audited recovery" >&2
    _rc=1
  fi
  SWARM_UP_LAUNCH_LOCK_DIR=""
  SWARM_UP_LAUNCH_LOCK_EVIDENCE=""
  SWARM_UP_LAUNCH_LOCK_HELPER=""
  return "$_rc"
}

cleanup_swarm_up() {
  if [ -n "$SWARM_UP_PARTIAL_CODEX_SESSION" ]; then
    tmux kill-session -t "$SWARM_UP_PARTIAL_CODEX_SESSION" 2>/dev/null || true
    SWARM_UP_PARTIAL_CODEX_SESSION=""
  fi
  swarm_up_launch_lock_release
  while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
}
trap cleanup_swarm_up EXIT
# Custom-marketplace channel plugin. Research-preview channels require the dev flag
# (a marketplace you publish yourself is not on Anthropic's approved allowlist), and
# the plugin must be fully qualified with @<marketplace>.
PLUGIN="${SWARM_PLUGIN:-plugin:discord-b2b@qofi-swarm}"

# Poll the pane for `pattern` until it appears or `timeout` seconds elapse.
# Used to wait for prompts/states instead of fixed-duration sleeps. bash 3.2-safe.
_wait_for() {  # session pattern timeout
  local sess="$1" pat="$2" tmo="${3:-15}" i=0 snapshot
  while [ "$i" -lt "$tmo" ]; do
    snapshot="$(tmux capture-pane -t "$sess" -p 2>/dev/null)" || return 1
    printf '%s' "$snapshot" | grep -qF -- "$pat" && return 0
    [ "$(tmux display-message -p -t "$sess" '#{pane_dead}' 2>/dev/null)" != "1" ] || return 1
    sleep 1; i=$((i+1))
  done
  return 1
}

# Press Enter until `pattern` DISAPPEARS from the pane (or timeout). The inverse
# of _wait_for: used to clear a prompt where a single blind Enter can race the
# TUI (observed: the dev-channels prompt swallowing the first Enter, which then
# desynced everything typed after it — effort + brief landed into the wrong UI
# state and the lead never received its doctrine brief). Re-sending Enter while
# the prompt is still visible is idempotent; returns 0 once the prompt is gone.
_enter_until_gone() {  # session pattern timeout
  local sess="$1" pat="$2" tmo="${3:-15}" i=0 snapshot
  while [ "$i" -lt "$tmo" ]; do
    snapshot="$(tmux capture-pane -t "$sess" -p 2>/dev/null)" || return 1
    if ! printf '%s' "$snapshot" | grep -qF -- "$pat"; then
      return 0
    fi
    tmux send-keys -t "$sess" Enter
    sleep 1; i=$((i+1))
  done
  return 1
}

# Submit already-typed input and verify Claude actually started processing it:
# after a real submission the running footer ("esc to interrupt") appears. A
# lost Enter leaves the text sitting in the input box — in that case re-press
# Enter and re-check, up to `tries`. This is the submission guarantee for the
# effort command and the launch brief; without it a swallowed Enter meant the
# lead silently never read its doctrine.
_submit_verified() {  # session tries
  local sess="$1" tries="${2:-3}" t=0
  while [ "$t" -lt "$tries" ]; do
    tmux send-keys -t "$sess" Enter
    if _wait_for "$sess" "esc to interrupt" 10; then
      return 0
    fi
    t=$((t+1))
  done
  return 1
}

[ -f "$CONF" ] || { echo "swarm-up: missing $CONF" >&2; exit 1; }
# F1 token isolation (ADR-0018): the launcher must NOT source the shared vault into
# its OWN process. tokens.env uses `export`, so `. '$TOKENS'` would export every
# swarm's BOT_* and every account's OAUTH_TOKEN_* into swarm-up — and on a COLD
# start `tmux new-session` begins the server as a CHILD of this process, so every
# pane would INHERIT the whole vault (the leak F1 closes). Each token is instead
# read in a SCOPED subshell at the one point it is needed (the per-swarm token
# pre-check below, and the pane env line in launch_one), so the launcher's env —
# and any tmux server it spawns — never holds a sibling's token.

# _preflight_check NAME REPO CHANNEL
#
# Hard-refuse to launch a swarm that hasn't been fully configured. Four
# cheap-read gates run sequentially; first failure prints a one-line
# remediation pointing at swarm-add and returns 1. All four pass → 0.
#
# Background: this mini's first standup produced silent half-launches
# where swarm-up brought the bot online but swarm-add had never run for
# the repo (or the env block was missing). The bot looked healthy in
# Discord and ignored everything because
# (a) enabledPlugins["discord-b2b@qofi-swarm"] wasn't true so the bridge
# MCP never spawned, (b) access.json had no group for the channel so the
# ACL silently dropped traffic, (c) the doctrine triad wasn't stamped so
# the CTO had no operating manual, and (d) the env block lacked
# CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 so the lead launched but could
# not spawn teammates — same silent-failure shape as the other three.
# The gates below detect each of those states from disk before we burn a
# tmux session + claude start on a swarm that can't do work.
#
# Gate (a): repo's .claude/settings.json has
#           enabledPlugins["discord-b2b@qofi-swarm"] === true
# Gate (b): ~/.claude/channels/discord/access.json has a groups.<CHANNEL>
#           entry. Skipped (with a notice) if CHANNEL is empty — that's
#           a legacy 3-col swarm.conf row, not a misconfig.
# Gate (c): repo has all three of CLAUDE.md / ESCALATION.md / TEAM_LEAD.md
#           at the top level (doctrine stamp).
# Gate (d): repo's .claude/settings.json has
#           env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS === "1". Without it,
#           Agent Teams (teammate spawning) is silently disabled — the
#           lead runs but the team never materializes.
#
# Override: SWARM_UP_SKIP_SANITY=1 in the caller's env bypasses all four
# (the "I know what I'm doing" case — e.g., bringing up a swarm for the
# first time inside a test harness, or intentionally launching a non-
# Discord-backed lead).
_preflight_check() {
  local name="$1" repo="$2" channel="$3" account="${4:-}"
  local sess="${PREFIX}-${name}"
  local remediation="run: bin/swarm-add.sh $name $repo --skip-walkthrough"

  # Gate (a) — enabledPlugins.
  local settings="$repo/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    echo "  ERROR: $sess: $repo/.claude/settings.json missing — $remediation" >&2
    echo "         (gate: enabledPlugins; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi
  if ! /usr/bin/python3 -I -B - "$settings" <<'PY' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
except Exception:
    sys.exit(1)
ep = s.get("enabledPlugins") or {}
sys.exit(0 if ep.get("discord-b2b@qofi-swarm") is True else 1)
PY
  then
    echo "  ERROR: $sess: enabledPlugins[\"discord-b2b@qofi-swarm\"] not true in $settings — $remediation" >&2
    echo "         (gate: enabledPlugins; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi

  # Gate (b) — access.json group for this swarm's channel. The access.json
  # path is resolved through the account resolver (swarm-lib.sh): an empty
  # account → the DEFAULT account, byte-identical to today (the resolver
  # honors the prior SWARM_ACCESS_FILE override and the $HOME/.claude default);
  # a labeled account → that account's isolated access.json. This is the SOLE
  # constructor of the path — never hand-build a $HOME/.claude path here.
  # A rejected resolve (malformed label) leaves the globals stale, so check rc
  # explicitly and fail the gate with a clear message rather than letting set -e
  # abort the run or checking a stale access path. (For the default/empty
  # account the resolver always succeeds → byte-identical to today.)
  if ! swarm_account_resolve "$account"; then
    echo "  ERROR: $sess: invalid account label '$account' in swarm.conf (field 6)." >&2
    echo "         Account labels must start with a letter and contain only [A-Za-z0-9_-]." >&2
    echo "         Fix the ACCOUNT field, or clear it to use the default account." >&2
    return 1
  fi
  local access="$SWARM_ACCT_ACCESS_FILE"
  if [ -z "$channel" ]; then
    echo "  NOTE:  $sess: no channel in swarm.conf — skipping access.json gate" >&2
  elif [ ! -f "$access" ]; then
    echo "  ERROR: $sess: $access missing — $remediation" >&2
    echo "         (gate: access.json; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  else
    if ! /usr/bin/python3 -I -B - "$access" "$channel" <<'PY' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f:
        a = json.load(f)
except Exception:
    sys.exit(1)
groups = a.get("groups") or {}
sys.exit(0 if sys.argv[2] in groups else 1)
PY
    then
      echo "  ERROR: $sess: access.json has no groups.$channel entry — $remediation" >&2
      echo "         (gate: access.json; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
      return 1
    fi
  fi

  # Gate (c) — doctrine stamp. The required-doctrine set is per-archetype
  # (swarm_required_doctrine in swarm-lib.sh); engineering-cto needs the
  # full triad, cpo needs only CLAUDE+ESCALATION, future types extend the
  # data-driven dispatch there. Unknown / future markers fall back to the
  # engineering triad — a misclassified swarm is REFUSED here with a
  # clear "TEAM_LEAD.md missing" error rather than silently launching
  # with no doctrine.
  local repo_type
  repo_type="$(swarm_type_of "$repo")"
  local missing=""
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$repo/$f" ] || missing="$missing $f"
  done < <(swarm_required_doctrine "$repo_type")
  if [ -n "$missing" ]; then
    echo "  ERROR: $sess: doctrine missing in $repo (type=$repo_type) —$missing — $remediation" >&2
    echo "         (gate: doctrine-stamp; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi

  # Gate (d) — Agent Teams experimental flag in the env block. Without
  # this, claude launches but teammate spawning is silently disabled —
  # the lead boots, Discord shows it online, and the team that
  # TEAM_LEAD.md instructs the CTO to spawn never materializes. Same
  # silent-failure shape as (a)/(b)/(c); same loud-refuse treatment.
  if ! /usr/bin/python3 -I -B - "$settings" <<'PY' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
except Exception:
    sys.exit(1)
env = s.get("env") or {}
sys.exit(0 if env.get("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS") == "1" else 1)
PY
  then
    echo "  ERROR: $sess: missing CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in .claude/settings.json — Agent Teams (teammate spawning) will be silently disabled. Re-run swarm-add, or add the env block." >&2
    echo "         (gate: agent-teams-env; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi

  # Gate (e) — harness-audit. The stamped security FLOOR must be intact before
  # we launch. A permission gate that is missing, empty, tampered (no longer
  # denies `git push`), or unregistered in settings.json means the swarm would
  # run WITHOUT its floor — refuse, loudly. This audits the stamped harness
  # itself, the gap the earlier gates left (they prove config keys exist; this
  # proves the floor that actually runs is the real one). Disabled QUALITY gates
  # (the QOFI_* runtime controls) are surfaced LOUDLY here but are NON-FATAL: an
  # operator may pick a fast profile; it just must never be silent. The
  # permission floor itself is never switchable — see the quality hooks'
  # runtime-control block and tests/test-hook-runtime-controls.sh.
  local pg="$repo/.claude/hooks/permission-gate.sh"
  if [ ! -s "$pg" ]; then
    echo "  ERROR: $sess: permission gate missing or empty: $pg — the security floor is not stamped. $remediation" >&2
    echo "         (gate: harness-audit; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi
  # The floor must actually DENY the archetype's operator-only push — proven by
  # RUNNING the stamped gate against a synthetic PermissionRequest, not by
  # grepping for a string (a string surviving only in a comment can't satisfy a
  # behavioral check, and a neutralized rule is caught). Archetype-aware:
  # engineering-cto denies plain `git push`; the cpo archetype intentionally
  # ALLOWS its vision-repo push and denies only destructive pushes, so it is
  # probed with a force-push. repo_type was resolved for gate (c) above.
  local probe
  case "$repo_type" in
    cpo) probe='git push --force origin main' ;;
    *)   probe='git push origin main' ;;
  esac
  local gate_event gate_out
  gate_event="$(/usr/bin/python3 -I -B -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$probe" "$repo" 2>/dev/null)"
  gate_out="$(printf '%s' "$gate_event" | bash "$pg" 2>/dev/null)"
  if ! printf '%s' "$gate_out" | grep -qF '"behavior":"deny"'; then
    echo "  ERROR: $sess: permission gate does NOT deny '$probe' (tampered, stale, or wrong-archetype floor): $pg — $remediation" >&2
    echo "         (gate: harness-audit; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi
  if ! /usr/bin/python3 -I -B - "$settings" <<'PY' >/dev/null 2>&1
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
blocks = (s.get("hooks") or {}).get("PermissionRequest") or []
cmds = [h.get("command", "") for b in blocks for h in (b.get("hooks") or [])]
sys.exit(0 if any("permission-gate.sh" in c for c in cmds) else 1)
PY
  then
    echo "  ERROR: $sess: permission-gate.sh not registered on PermissionRequest in $settings — the floor won't run. $remediation" >&2
    echo "         (gate: harness-audit; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi
  # Loud (non-fatal) surfacing of disabled QUALITY gates configured in settings env.
  local qofi_note
  qofi_note="$(/usr/bin/python3 -I -B - "$settings" <<'PY' 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
env = s.get("env") or {}
prof = (env.get("QOFI_HOOK_PROFILE") or "").strip()
dis = (env.get("QOFI_DISABLED_HOOKS") or "").strip()
notes = []
if prof in ("minimal", "fast", "off"):
    notes.append("QOFI_HOOK_PROFILE=%s (all quality gates off)" % prof)
if dis:
    notes.append("QOFI_DISABLED_HOOKS=%s" % dis)
print("; ".join(notes))
PY
)"
  if [ -n "$qofi_note" ]; then
    echo "  WARN:  $sess: quality gates DISABLED via settings env — $qofi_note" >&2
    echo "         (harness-audit: non-fatal; the permission FLOOR is always on)" >&2
  fi

  return 0
}

# Codex has a different enforcement/runtime surface. Do not pretend Claude's
# enabled-plugin, Agent Teams, account access.json, or PermissionRequest hooks
# protect a `codex exec` lead. Its launch gate is deliberately small and true:
# the archetype doctrine must be stamped, and subscription auth must verify.
_preflight_check_codex_doctrine() {  # name repo
  local name="$1" repo="$2" sess="${PREFIX}-$1"
  local repo_type missing="" f
  repo_type="$(swarm_type_of "$repo")"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$repo/$f" ] || missing="$missing $f"
  done < <(swarm_required_doctrine "$repo_type")
  if [ -n "$missing" ]; then
    echo "  ERROR: $sess: Codex doctrine missing in $repo (type=$repo_type) —$missing" >&2
    echo "         Re-run swarm-add/swarm-init; bypass doctrine only with SWARM_UP_SKIP_SANITY=1." >&2
    return 1
  fi
  if ! swarm_codex_managed_surfaces_check "$repo"; then
    echo "  ERROR: $sess: Codex adoption surfaces are missing, drifted, or not exactly ledger-owned." >&2
    echo "         Run swarm-init/swarm-sync through the configured Codex engine before launch." >&2
    return 1
  fi
  return 0
}

_codex_project_config_preflight() {  # session repo
  local sess="$1" repo="$2" config="$2/.codex/config.toml" checker
  # `-f` follows symlinks and ignores FIFOs/devices. Treat every directory
  # entry, including a broken symlink, as a config that must pass the shared
  # O_NOFOLLOW bounded reader; only true ENOENT means no project config.
  [ -e "$config" ] || [ -L "$config" ] || return 0
  checker="$SWARM_HOME/bin/codex-project-config-check.ts"
  [ -f "$checker" ] || {
    echo "  ERROR: $sess: Codex project-config checker missing: $checker" >&2
    return 1
  }
  [ -n "${SWARM_CODEX_TRUSTED_BUN_REAL:-}" ] || {
    echo "  ERROR: $sess: trusted Bun path was not established before reviewing $config" >&2
    return 1
  }
  # Do not let a hostile invocation cwd, repo `.env`, bunfig preload, or ambient
  # Bun/Node loader option execute before the validator. The checker imports the
  # daemon's shared validator; this shell gate supplies only a clean, explicit
  # environment and the immutable codex-bridge directory as Bun's cwd.
  if ! /usr/bin/env -i \
      HOME="$SWARM_CODEX_CANONICAL_HOME" \
      CODEX_HOME="$SWARM_CODEX_CANONICAL_CODEX_HOME" \
      PATH="$SWARM_CODEX_TOOL_PATH" LANG=C LC_ALL=C \
      "$SWARM_CODEX_TRUSTED_BUN_REAL" \
      --no-env-file --config=/dev/null --no-install --no-addons --no-macros \
      --cwd="$SWARM_HOME/codex-bridge" "$checker" "$config"; then
    echo "  ERROR: $sess: refusing capability-bearing or unreviewable $config" >&2
    echo "         Keep only the explicitly allowlisted restrictive/display settings; every unreviewed top-level or nested key is refused." >&2
    return 1
  fi
  return 0
}

_codex_attention_binding_preflight() {  # session name primary-channel repo
  local sess="$1" name="$2" channel="$3" repo="$4" raw
  case "$name" in
    [A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9_-]*) ;;
    *) echo "  ERROR: $sess: Codex attention binding requires a [A-Za-z0-9][A-Za-z0-9_-]* swarm name" >&2; return 1 ;;
  esac
  [ "${#name}" -le 64 ] || {
    echo "  ERROR: $sess: Codex attention swarm name exceeds 64 characters" >&2
    return 1
  }
  case "$channel" in
    ''|*[!0-9]*) echo "  ERROR: $sess: Codex attention binding requires a numeric primary CHANNEL_ID" >&2; return 1 ;;
  esac
  [ "${#channel}" -le 32 ] || {
    echo "  ERROR: $sess: Codex attention CHANNEL_ID exceeds 32 digits" >&2
    return 1
  }
  # This is a narrow host-write capability. Never let ambient SWARM_STATE_DIR
  # choose its destination for the unattended Codex lane; bind it to the
  # operator account's canonical state path established by host preflight.
  raw="$SWARM_CODEX_CANONICAL_HOME/.config/swarm"
  SWARM_CODEX_ATTENTION_STATE_DIR="$(/usr/bin/python3 -I -B - "$raw" "$SWARM_CODEX_CANONICAL_HOME" "$repo" "$SWARM_HOME" <<'PY'
import os, stat, sys
raw,home,repo,swarm_home=sys.argv[1:5]
uid=os.getuid()
if not os.path.isabs(raw):
    raise SystemExit('attention state dir must be absolute')
requested=os.path.normpath(raw)
if requested != os.path.join(home,'.config','swarm'):
    raise SystemExit('attention state dir is not the fixed canonical path')

def inside(root,candidate):
    try: return os.path.commonpath([root,candidate]) == root
    except ValueError: return False

repo=os.path.realpath(repo); swarm_home=os.path.realpath(swarm_home)
temp_roots={os.path.realpath(x) for x in ('/tmp','/private/tmp','/var/tmp',os.environ.get('TMPDIR','')) if x and os.path.exists(x)}
for root in (repo,swarm_home,*temp_roots):
    if inside(root,requested) or inside(requested,root):
        raise SystemExit('attention state overlaps workspace, SWARM_HOME, or temporary storage')

current='/'
for part in requested.split('/')[1:]:
    current=os.path.join(current,part)
    try: st=os.lstat(current)
    except FileNotFoundError:
        if not inside(home,current): raise
        os.mkdir(current,0o700); st=os.lstat(current)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid not in (0,uid) or st.st_mode & 0o022):
        raise SystemExit('unsafe attention-state path component: '+current)
if os.path.realpath(requested) != requested:
    raise SystemExit('attention state path contains symlink indirection')
st=os.lstat(requested)
if st.st_uid != uid: raise SystemExit('attention state dir has the wrong owner')
if stat.S_IMODE(st.st_mode) != 0o700:
    # Safe historical narrowing (for an owned real non-writable directory).
    os.chmod(requested,0o700)
print(requested)
PY
)" || {
    echo "  ERROR: $sess: could not prepare private Codex attention state dir '$raw'" >&2
    return 1
  }
  export SWARM_CODEX_ATTENTION_STATE_DIR
  return 0
}

_codex_role_binding_preflight() {  # session archetype primary-channel
  local sess="$1" archetype="$2" channel="$3" bus=""
  case "$archetype" in
    engineering-cto) ;;
    cpo) bus="${SWARM_BUS_CHANNEL:-1510301812434141194}" ;;
    *) echo "  ERROR: $sess: unsupported Codex bridge archetype '$archetype'" >&2; return 1 ;;
  esac
  case "$channel" in ''|*[!0-9]*) echo "  ERROR: $sess: Codex operator channel must be numeric" >&2; return 1 ;; esac
  if [ "$archetype" = "cpo" ]; then
    case "$bus" in ''|*[!0-9]*) echo "  ERROR: $sess: CPO bus channel must be numeric" >&2; return 1 ;; esac
    [ "$bus" != "$channel" ] || { echo "  ERROR: $sess: CPO operator and bus channels must be distinct" >&2; return 1; }
  fi
  SWARM_CODEX_ARCHETYPE="$archetype"
  SWARM_CODEX_OPERATOR_CHANNEL="$channel"
  SWARM_CODEX_BUS_CHANNEL="$bus"
  export SWARM_CODEX_ARCHETYPE SWARM_CODEX_OPERATOR_CHANNEL SWARM_CODEX_BUS_CHANNEL
}

_codex_pid_is_expected() {  # pid daemon|child — 0 means alive expected/unknown
  local pid="$1" kind="$2" command
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(/bin/ps -p "$pid" -o command= 2>/dev/null)"
  # If process inspection is unavailable, fail safe and treat the live PID as
  # relevant. When visible, ignore a reused PID that cannot be this runtime.
  [ -n "$command" ] || return 0
  case "$kind:$command" in
    daemon:*codex-bridge/daemon.ts*) return 0 ;;
    child:*codex*)                  return 0 ;;
  esac
  return 1
}

# Return one machine-readable state for the exact daemon singleton:
#   absent|
#   live|PID
#   dead|LOCK_DEV:LOCK_INO:OWNER_DEV:OWNER_INO:OWNER_SHA256
#   release|RELEASE_RECEIPT
# Any malformed/symlinked/ACL-bearing/in-flight boundary returns nonzero. The
# dead evidence is later re-proved immediately before exact exchange release.
# A valid interrupted exchange is receipt-bound and completed by the same
# helper; an unrecognized artifact remains a hard launch refusal.
_codex_daemon_lock_state() {  # /absolute/state/daemon.lock
  local release_state release_rc release_kind release_owner release_pid release_receipt helper
  helper="$(swarm_atomic_lock_helper_path)" || return 2
  if release_state="$(/usr/bin/python3 -I -B "$helper" \
      inspect-release "$1" owner.json codex-daemon 2>/dev/null)"; then
    IFS='|' read -r release_kind release_owner release_pid release_receipt <<EOF
$release_state
EOF
    [ "$release_kind" = release ] || return 2
    case "$release_receipt" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#release_receipt}" -eq 64 ] || return 2 ;;
      *) return 2 ;;
    esac
    case "$release_owner" in
      live)
        case "$release_pid" in ''|*[!0-9]*) return 2 ;; esac
        printf 'live|%s\n' "$release_pid"
        ;;
      dead|removed) printf 'release|%s\n' "$release_receipt" ;;
      *) return 2 ;;
    esac
    return 0
  else
    release_rc=$?
    [ "$release_rc" -eq 4 ] || return 2
  fi
  /usr/bin/python3 -I -B - "$1" <<'PY'
import ctypes, errno, hashlib, json, os, re, stat, sys, uuid

path=sys.argv[1]; uid=os.getuid()
def fail(): raise SystemExit(2)
def no_acl(p, is_dir):
    if sys.platform != 'darwin': return
    flags=os.O_RDONLY | getattr(os,'O_NOFOLLOW',0)
    if is_dir: flags |= getattr(os,'O_DIRECTORY',0)
    fd=os.open(p,flags)
    try:
        libc=ctypes.CDLL(None,use_errno=True)
        get_acl=libc.acl_get_fd_np; get_acl.argtypes=[ctypes.c_int,ctypes.c_int]; get_acl.restype=ctypes.c_void_p
        free_acl=libc.acl_free; free_acl.argtypes=[ctypes.c_void_p]
        ctypes.set_errno(0); acl=get_acl(fd,0x00000100)
        if acl:
            free_acl(acl); fail()
        if ctypes.get_errno() not in (0,errno.ENOENT): fail()
    finally: os.close(fd)
def alive(pid):
    try: os.kill(pid,0); return True
    except PermissionError: return True
    except ProcessLookupError: return False
    except OSError as exc: return exc.errno != errno.ESRCH

try: lock=os.lstat(path)
except FileNotFoundError:
    print('absent|'); raise SystemExit(0)
if (not stat.S_ISDIR(lock.st_mode) or stat.S_ISLNK(lock.st_mode)
        or lock.st_uid != uid or stat.S_IMODE(lock.st_mode) != 0o700): fail()
no_acl(path,True)
if os.listdir(path) != ['owner.json']: fail()
owner_path=os.path.join(path,'owner.json'); before=os.lstat(owner_path)
if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
        or before.st_uid != uid or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_size > 16384): fail()
no_acl(owner_path,False)
fd=os.open(owner_path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
try:
    opened=os.fstat(fd)
    if (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns) != \
       (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns): fail()
    raw=os.read(fd,16385)
    after=os.fstat(fd)
    if (len(raw)>16384 or (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns) !=
       (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns)): fail()
finally: os.close(fd)
try: value=json.loads(raw.decode('utf-8','strict'))
except Exception: fail()
if (not isinstance(value,dict) or set(value) != {'schema','pid','token','started_at'}
        or value.get('schema') != 'codex-bridge-lock/v1'
        or type(value.get('pid')) is not int or value['pid'] <= 0
        or not isinstance(value.get('token'),str)
        or not isinstance(value.get('started_at'),str)): fail()
try: token=uuid.UUID(value['token'])
except (ValueError,AttributeError): fail()
if str(token) != value['token'] or token.version != 4: fail()
if alive(value['pid']): print('live|%d' % value['pid'])
else:
    evidence='%d:%d:%d:%d:%s' % (
        lock.st_dev,lock.st_ino,before.st_dev,before.st_ino,hashlib.sha256(raw).hexdigest())
    print('dead|'+evidence)
PY
}

_codex_remove_dead_daemon_lock_exact() {  # lock evidence
  local lock="$1" evidence="$2" receipt helper
  helper="$(swarm_atomic_lock_helper_path)" || return 2
  case "$evidence" in
    release:*)
      receipt="${evidence#release:}"
      case "$receipt" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#receipt}" -eq 64 ] || return 2 ;;
        *) return 2 ;;
      esac
      /usr/bin/python3 -I -B "$helper" \
        recover-release "$lock" owner.json "$receipt" codex-daemon
      return $?
      ;;
    dead:*) evidence="${evidence#dead:}" ;;
    *) return 2 ;;
  esac
  /usr/bin/python3 -I -B - "$lock" "$evidence" "$helper" <<'PY'
import datetime as dt
import errno, hashlib, json, os, stat, subprocess, sys, uuid
path,evidence,helper=sys.argv[1:]
try:
    lock_dev,lock_ino,owner_dev,owner_ino,owner_hash=evidence.split(':')
    expected=(int(lock_dev),int(lock_ino),int(owner_dev),int(owner_ino),owner_hash)
except Exception: raise SystemExit(2)
parent,name=os.path.split(path)
flags=os.O_RDONLY|getattr(os,'O_DIRECTORY',0)|getattr(os,'O_NOFOLLOW',0)
pfd=os.open(parent,flags)
def alive(pid):
    try: os.kill(pid,0); return True
    except PermissionError: return True
    except ProcessLookupError: return False
    except OSError as exc: return exc.errno != errno.ESRCH
try:
    current=os.stat(name,dir_fd=pfd,follow_symlinks=False)
    if (not stat.S_ISDIR(current.st_mode) or (current.st_dev,current.st_ino) != expected[:2]):
        raise RuntimeError('daemon lock inode changed')
    qfd=os.open(name,flags,dir_fd=pfd)
    try:
        locked=os.fstat(qfd)
        if (locked.st_dev,locked.st_ino) != expected[:2] or os.listdir(qfd) != ['owner.json']:
            raise RuntimeError('daemon lock changed before release')
        owner=os.stat('owner.json',dir_fd=qfd,follow_symlinks=False)
        if (not stat.S_ISREG(owner.st_mode) or (owner.st_dev,owner.st_ino) != expected[2:4]
                or owner.st_uid != os.getuid() or stat.S_IMODE(owner.st_mode) != 0o600
                or owner.st_size > 16384): raise RuntimeError('daemon owner inode changed')
        ofd=os.open('owner.json',os.O_RDONLY|getattr(os,'O_NOFOLLOW',0),dir_fd=qfd)
        try:
            opened=os.fstat(ofd); raw=os.read(ofd,16385); after=os.fstat(ofd)
            if ((opened.st_dev,opened.st_ino)!=(owner.st_dev,owner.st_ino)
                    or (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns) !=
                       (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns)
                    or len(raw)>16384 or hashlib.sha256(raw).hexdigest()!=expected[4]):
                raise RuntimeError('daemon owner evidence changed')
        finally: os.close(ofd)
        value=json.loads(raw.decode('utf-8','strict'))
        if (not isinstance(value,dict) or set(value) != {'schema','pid','token','started_at'}
                or value.get('schema') != 'codex-bridge-lock/v1'
                or type(value.get('pid')) is not int or value['pid'] <= 0
                or not isinstance(value.get('token'),str)
                or not isinstance(value.get('started_at'),str)):
            raise RuntimeError('daemon owner is malformed')
        token=uuid.UUID(value['token']); dt.datetime.fromisoformat(value['started_at'].replace('Z','+00:00'))
        if str(token) != value['token'] or token.version != 4:
            raise RuntimeError('daemon owner token is malformed')
        if alive(value['pid']): raise RuntimeError('daemon owner is live')
    finally: os.close(qfd)
except Exception as exc:
    print('stale daemon lock exact recovery refused: %s' % exc,file=sys.stderr)
    raise SystemExit(2)
finally: os.close(pfd)
result=subprocess.run(
    ['/usr/bin/python3','-I','-B',helper,'release',path,'owner.json',
     str(expected[0]),str(expected[1]),str(expected[2]),str(expected[3]),expected[4],value['token']],
    text=True,capture_output=True,timeout=10,
    env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'},
)
if result.returncode != 0:
    print('stale daemon exact exchange release refused: '+(result.stderr or result.stdout).strip(),file=sys.stderr)
    raise SystemExit(2)
PY
}

_codex_finish_interrupted_daemon_release() {  # name session
  local name="$1" sess="$2" state_dir release_state release_rc candidate found=0 finalized=0 helper
  helper="$(swarm_atomic_lock_helper_path)" || return 1
  state_dir="$(swarm_codex_state_dir "$name")"
  [ -L "$state_dir" ] && return 0
  [ -d "$state_dir" ] || return 0
  for candidate in "$state_dir"/.daemon.lock.released.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    finalized=1
    break
  done
  if [ "$finalized" -eq 1 ] && \
     ! /usr/bin/python3 -I -B "$helper" \
         cleanup-finalized "$state_dir/daemon.lock" owner.json codex-daemon; then
    echo "  ERROR: $sess: finalized daemon release artifact is malformed; retained for audit" >&2
    return 1
  fi
  if [ -f "$state_dir/daemon.lock/release.json" ]; then
    found=1
  else
    for candidate in "$state_dir"/.daemon.lock.release.*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      found=1
      break
    done
  fi
  [ "$found" -eq 1 ] || return 0
  if release_state="$(/usr/bin/python3 -I -B "$helper" \
      inspect-release "$state_dir/daemon.lock" owner.json codex-daemon 2>/dev/null)"; then
    :
  else
    release_rc=$?
    [ "$release_rc" -eq 4 ] && return 0
    echo "  ERROR: $sess: interrupted daemon release boundary is malformed; retained for audit" >&2
    return 1
  fi
  _codex_quiescence_preflight "$name" "$sess" || return 1
  if [ "${SWARM_CODEX_QUIESCENT_STALE_LOCK:-0}" -ne 1 ] || \
     [ -z "${SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE:-}" ] || \
     ! _codex_remove_dead_daemon_lock_exact \
         "$state_dir/daemon.lock" "$SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE"; then
    echo "  ERROR: $sess: interrupted daemon release changed before exact completion" >&2
    return 1
  fi
  return 0
}

_codex_quiescence_preflight() {  # name session
  local name="$1" sess="$2" timeout="${SWARM_CODEX_QUIESCE_TIMEOUT:-15}"
  local state_dir runtime lock waited=0 pids daemon_pid child_pid busy="" detail="" lock_state="" lock_kind="" lock_detail=""
  SWARM_CODEX_QUIESCENT_STALE_LOCK=0
  SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE=""
  case "$timeout" in ''|*[!0-9]*) timeout=15 ;; esac
  state_dir="$(swarm_codex_state_dir "$name")"
  runtime="$state_dir/runtime.json"
  lock="$state_dir/daemon.lock"

  while :; do
    daemon_pid=""; child_pid=""; busy=""; detail=""; lock_state=""; lock_kind=""; lock_detail=""
    if [ -f "$runtime" ]; then
      pids="$(/usr/bin/python3 -I -B - "$runtime" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    if d.get('schema') != 'codex-bridge-runtime/v1': raise ValueError()
    pid=d.get('pid'); child=d.get('child_pid')
    pid = str(pid) if type(pid) is int and pid > 0 else ''
    child = str(child) if type(child) is int and child > 0 else ''
    print('ok|' + pid + '|' + child)
except Exception:
    print('bad||')
PY
)"
      if [ "${pids%%|*}" != "ok" ]; then
        busy="${busy:+$busy, }runtime-unreadable"
      else
        pids="${pids#*|}"
        daemon_pid="${pids%%|*}"
        child_pid="${pids#*|}"
      fi
    fi
    if [ -n "$daemon_pid" ] && _codex_pid_is_expected "$daemon_pid" daemon; then
      busy="daemon=$daemon_pid"
    fi
    if [ -n "$child_pid" ] && _codex_pid_is_expected "$child_pid" child; then
      busy="${busy:+$busy, }child=$child_pid"
    fi
    if ! lock_state="$(_codex_daemon_lock_state "$lock" 2>/dev/null)"; then
      busy="${busy:+$busy, }lock-unsafe-or-initializing"
    else
      lock_kind="${lock_state%%|*}"; lock_detail="${lock_state#*|}"
      case "$lock_kind" in
        live) busy="${busy:+$busy, }lock-owner=$lock_detail" ;;
        dead|release) ;;
        absent) ;;
        *) busy="${busy:+$busy, }lock-unsafe-or-initializing" ;;
      esac
    fi
    if [ -z "$busy" ]; then
      # Tell the serialized cleanup step whether THIS successful snapshot saw
      # a dead-owner lock. If it saw no lock, cleanup must remain a no-op: a
      # live daemon can atomically create the path immediately after return.
      if [ "$lock_kind" = dead ] || [ "$lock_kind" = release ]; then
        SWARM_CODEX_QUIESCENT_STALE_LOCK=1
        SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE="$lock_kind:$lock_detail"
      fi
      return 0
    fi
    detail="waiting for $busy"
    if [ "$waited" -ge "$timeout" ]; then
      echo "  ERROR: $sess: prior Codex runtime is not quiescent after ${timeout}s ($detail)." >&2
      echo "         Do not overlap daemons. Inspect bin/swarm-view.sh $name and the PIDs/daemon.lock in $state_dir; retry after shutdown completes." >&2
      return 1
    fi
    /bin/sleep 1
    waited=$((waited + 1))
  done
}

_codex_acl_reconcile() {  # name channel archetype
  local name="$1" channel="$2" archetype="${3:-}" state_dir dest bound_channels
  if ! swarm_codex_state_validate "$name" prepare; then
    echo "  ERROR: ${PREFIX}-${name}: unsafe Codex state path; ACL reconciliation refused" >&2
    return 1
  fi
  state_dir="$SWARM_CODEX_STATE_DIR"
  dest="$state_dir/access.json"
  bound_channels="$(swarm_bound_channels "$name" "$channel" "$archetype")"
  if [ -z "$bound_channels" ]; then
    echo "  ERROR: ${PREFIX}-${name}: engine=codex requires a bound guild CHANNEL_ID" >&2
    return 1
  fi
  swarm_account_resolve "" || return 1
  if [ ! -f "$SWARM_ACCT_ACCESS_FILE" ]; then
    echo "  ERROR: ${PREFIX}-${name}: canonical Discord ACL missing: $SWARM_ACCT_ACCESS_FILE" >&2
    return 1
  fi
  SWARM_CODEX_CANONICAL_ACCESS_FILE="$(/usr/bin/python3 -I -B - "$SWARM_ACCT_ACCESS_FILE" <<'PY'
import ctypes, errno, os, stat, sys
p=sys.argv[1]
if not os.path.isabs(p):
    raise SystemExit(1)
if stat.S_ISLNK(os.lstat(p).st_mode):
    raise SystemExit(1)
real=os.path.realpath(p); st=os.lstat(real); parent=os.path.dirname(real); pst=os.lstat(parent)
if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022
        or not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != os.getuid() or pst.st_mode & 0o077):
    raise SystemExit(1)

if sys.platform == 'darwin':
    libc=ctypes.CDLL(None,use_errno=True)
    get_acl=libc.acl_get_fd_np
    get_acl.argtypes=[ctypes.c_int,ctypes.c_int]
    get_acl.restype=ctypes.c_void_p
    free_acl=libc.acl_free
    free_acl.argtypes=[ctypes.c_void_p]
    for checked,is_dir in ((real,False),(parent,True)):
      flags=os.O_RDONLY | getattr(os,'O_NOFOLLOW',0)
      if is_dir: flags |= getattr(os,'O_DIRECTORY',0)
      fd=os.open(checked,flags)
      try:
        ctypes.set_errno(0)
        acl=get_acl(fd,0x00000100)
        if acl:
            free_acl(acl)
            raise SystemExit(f'canonical access boundary must not have an extended ACL: {checked}; run chmod -N')
        if ctypes.get_errno() not in (0,errno.ENOENT):
            raise SystemExit(f'could not inspect canonical access ACL: {checked}')
      finally:
        os.close(fd)
# Historical Claude access files were commonly 0644 inside a private 0700
# parent. The Codex daemon deliberately requires the sensitive file itself to
# be owner-private too. This is a safe narrowing migration only after proving
# the file is a current-user regular non-symlink in that private parent.
if stat.S_IMODE(st.st_mode) != 0o600:
    os.chmod(real, 0o600)
print(real)
PY
)" || {
    echo "  ERROR: ${PREFIX}-${name}: canonical Discord ACL must be an owner-controlled regular file in a private parent: $SWARM_ACCT_ACCESS_FILE" >&2
    return 1
  }
  export SWARM_CODEX_CANONICAL_ACCESS_FILE
  # Canonical group policy (including revocations) wins on EVERY launch. Keep
  # Codex-local DM pairing/pending and delivery preferences intact; only the
  # bound guild group's policy is synchronized. Fail closed unless allowFrom is
  # a non-empty list — an empty group means "any channel member" in the bridge.
  if ! /usr/bin/python3 -I -B - "$SWARM_CODEX_CANONICAL_ACCESS_FILE" "$dest" "$bound_channels" <<'PY'
import copy, json, os, sys
src_path, dest_path, channels_raw = sys.argv[1:4]
channels = [value for value in channels_raw.splitlines() if value]
try:
    canonical = json.load(open(src_path))
except Exception as e:
    sys.stderr.write("canonical ACL unreadable: %s\n" % e)
    raise SystemExit(2)
groups = canonical.get("groups") or {}
canonical_allow = canonical.get("allowFrom")
if (not isinstance(canonical_allow, list) or not canonical_allow
        or not all(isinstance(x, str) and x.strip() for x in canonical_allow)):
    sys.stderr.write("canonical top-level allowFrom must identify at least one explicit operator\n")
    raise SystemExit(3)
selected = {}
for channel in channels:
    group = groups.get(channel)
    allow = group.get("allowFrom") if isinstance(group, dict) else None
    if not isinstance(allow, list) or not allow or not all(isinstance(x, str) and x.strip() for x in allow):
        sys.stderr.write("canonical group %s must have nonempty string allowFrom\n" % channel)
        raise SystemExit(3)
    selected[channel] = copy.deepcopy(group)
try:
    current = json.load(open(dest_path))
    if not isinstance(current, dict):
        raise ValueError("not an object")
except Exception:
    current = copy.deepcopy(canonical)
current_groups = current.setdefault("groups", {})
current["allowFrom"] = copy.deepcopy(canonical_allow)
if not isinstance(current_groups, dict):
    raise SystemExit(4)
for channel, group in selected.items():
    current_groups[channel] = group
current.setdefault("pending", {})
tmp = dest_path + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(current, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, dest_path)
PY
  then
    echo "  ERROR: ${PREFIX}-${name}: Codex ACL reconciliation refused effective channels (canonical allowFrom must be nonempty for each): $(printf '%s' "$bound_channels" | tr '\n' ',')" >&2
    return 1
  fi
  echo "  reconciled $dest effective groups $(printf '%s' "$bound_channels" | tr '\n' ',') from canonical Claude ACL"
  return 0
}

# Launch a CODEX-engine lead: the pane runs codex-bridge/daemon.ts. Called
# from launch_one after the engine-neutral pane env line has been sent.
#
# Per-swarm state dir (~/.codex/channels/discord-<name>): unlike the Claude
# bridge plugin (shared access.json, per-message re-read), each codex daemon
# also WRITES sessions.json — sharing one dir across daemons would let their
# atomic renames clobber each other. Isolation per swarm removes the race.
# On first launch the shared Claude-side access.json is copied in when
# present, so allowFrom (operator + watcher/CPO ids) and channel groups carry
# over without re-pairing; the swarm's own channel group is then ensured.
#
# Doctrine: CODEX_BRIDGE_PREAMBLE_EXTRA carries the launch brief (Codex has no
# SessionStart hooks; AGENTS.md -> CLAUDE.md auto-load is the belt, this is
# the suspenders). The adversarial review lane flips for this engine: Claude
# (Fable) reviews Codex work via bin/adversarial-review.sh.
_launch_codex_lead() {  # name repo sess channel repo_type
  local name="$1" repo="$2" sess="$3" channel="$4" repo_type="$5"
  local state_dir
  state_dir="$(swarm_codex_state_dir "$name")"

  if [ -z "${SWARM_CODEX_TRUSTED_BUN_REAL:-}" ] || [ -z "${SWARM_CODEX_TRUSTED_BIN_REAL:-}" ]; then
    echo "  ERROR: $sess: trusted Codex/Bun host paths were not established" >&2
    return 1
  fi
  # Verify/reconcile the lockfile on every launch. `node_modules` existing is
  # not evidence that it matches the current frozen dependency graph.
  echo "  verifying codex-bridge deps (frozen lockfile)"
  (cd "$SWARM_HOME/codex-bridge" && "$SWARM_CODEX_TRUSTED_BUN_REAL" install --frozen-lockfile --no-summary) || {
    echo "  ERROR: $sess: frozen bun install failed in codex-bridge/" >&2
    return 1
  }
  # The first Codex launch starts one global App Server manager only after the
  # full host authority proof and frozen dependency check have passed.  Later
  # swarms attest the same ready manager; they never launch workspace manager
  # source or expose its upstream stdio transport directly.
  if ! swarm_codex_manager_ensure; then
    echo "  ERROR: $sess: shared Codex App Server manager is unavailable" >&2
    return 1
  fi

  # Revalidate immediately before writing launch.sh. Never chmod/follow an
  # untrusted pre-existing path into acceptability.
  if ! swarm_codex_state_validate "$name" prepare; then
    echo "  ERROR: $sess: Codex state path became unsafe before launcher write" >&2
    return 1
  fi
  state_dir="$SWARM_CODEX_STATE_DIR"

  # Dependency verification and ACL reconciliation leave a real race window
  # after the first process-boundary check. Re-check only after this launcher
  # has won tmux serialization and immediately before stale-lock cleanup. A
  # raw daemon that acquired the singleton in the meantime must keep its lock
  # and make this launch fail; it must never be unlinked underneath a live
  # owner.
  _codex_quiescence_preflight "$name" "$sess" || return 1

  # If a dead-owner lock (or a helper-authored interrupted release marker)
  # existed throughout the final check, re-prove its receipt/inodes and finish
  # the exact exchange-release protocol. The canonical name denotes either the
  # old owner or a durable tombstone until release linearizes. Never run an
  # unconditional pathname `rm -rf`: an ABA replacement or raw daemon wins and
  # makes this launch fail without losing its singleton.
  if [ "${SWARM_CODEX_QUIESCENT_STALE_LOCK:-0}" -eq 1 ]; then
    if [ -z "${SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE:-}" ] || \
       ! _codex_remove_dead_daemon_lock_exact \
           "$state_dir/daemon.lock" "$SWARM_CODEX_QUIESCENT_STALE_LOCK_EVIDENCE"; then
      echo "  ERROR: $sess: verified stale daemon boundary changed before exact exchange release" >&2
      return 1
    fi
  fi

  if [ ! -d "$state_dir/tool-tmp" ]; then
    ( umask 077; /bin/mkdir "$state_dir/tool-tmp" ) || {
      echo "  ERROR: $sess: could not create private daemon temp root" >&2
      return 1
    }
  fi
  if ! swarm_codex_state_validate "$name" prepare; then
    echo "  ERROR: $sess: Codex state path became unsafe before clean daemon exec" >&2
    return 1
  fi

  # Use the SAME archetype brief as Claude launch. This is load-bearing: the
  # engineering brief names TEAM_LEAD.md; the CPO brief names its own product
  # doctrine and explicitly refuses engineering work.
  local doctrine
  doctrine="$(swarm_launch_brief "$repo_type")"

  # NEVER type a long command into the pane: with the doctrine inline the
  # launch line was ~800 chars, and the pane tty mangled it (observed live
  # 2026-07-11: the export echoed interleaved with itself, the command never
  # executed, the daemon never started). The program belongs in a FILE; the
  # tty gets one short line. The launcher carries NO secret (DISCORD_BOT_TOKEN
  # is exported by the engine-neutral pane line before this) and lives in the
  # 700-mode state dir. Sourced — not run — so its exec replaces the pane
  # shell with the daemon, same shape as the Claude lane's exec claude.
  local q_state q_repo q_doctrine q_daemon q_launcher q_codex_bin q_codex_prefix q_bun q_home q_codex_home q_runtime_path
  local q_manager_socket
  local q_archetype q_operator_channel q_bus_channel q_token_file q_tool_tmp q_bun_cwd q_swarm_name
  local bound_channels="" effective_channel q_bound_channels
  local bus_channel_line bus_env_line
  local q_attention_channel q_attention_swarm q_attention_state q_canonical_access
  q_state="$(shell_quote "$state_dir")"
  q_repo="$(shell_quote "$repo")"
  q_doctrine="$(shell_quote "$doctrine")"
  q_daemon="$(shell_quote "$SWARM_HOME/codex-bridge/daemon.ts")"
  q_launcher="$(shell_quote "$state_dir/launch.sh")"
  q_codex_bin="$(shell_quote "$SWARM_CODEX_TRUSTED_BIN_REAL")"
  q_codex_prefix="$(shell_quote "$SWARM_CODEX_ARGV_PREFIX")"
  q_bun="$(shell_quote "$SWARM_CODEX_TRUSTED_BUN_REAL")"
  q_home="$(shell_quote "$SWARM_CODEX_CANONICAL_HOME")"
  q_codex_home="$(shell_quote "$SWARM_CODEX_CANONICAL_CODEX_HOME")"
  q_runtime_path="$(shell_quote "$SWARM_CODEX_TOOL_PATH")"
  q_attention_channel="$(shell_quote "$channel")"
  q_attention_swarm="$(shell_quote "$name")"
  q_attention_state="$(shell_quote "$SWARM_CODEX_ATTENTION_STATE_DIR")"
  q_canonical_access="$(shell_quote "$SWARM_CODEX_CANONICAL_ACCESS_FILE")"
  q_archetype="$(shell_quote "$SWARM_CODEX_ARCHETYPE")"
  q_operator_channel="$(shell_quote "$SWARM_CODEX_OPERATOR_CHANNEL")"
  q_bus_channel="$(shell_quote "$SWARM_CODEX_BUS_CHANNEL")"
  q_token_file="$(shell_quote "$state_dir/discord-token")"
  q_tool_tmp="$(shell_quote "$state_dir/tool-tmp")"
  q_bun_cwd="$(shell_quote "$SWARM_HOME/codex-bridge")"
  q_swarm_name="$(shell_quote "$name")"
  q_manager_socket="$(shell_quote "$SWARM_CODEX_MANAGER_SOCKET")"
  # Build the daemon response boundary from the already validated role set,
  # not the legacy name-based binding fallback. This makes the clean launcher
  # environment exactly operator-only for engineering and operator+bus for CPO.
  for effective_channel in "$SWARM_CODEX_OPERATOR_CHANNEL" "$SWARM_CODEX_BUS_CHANNEL"; do
    [ -z "$effective_channel" ] && continue
    case "$effective_channel" in
      *[!0-9]*)
        echo "  ERROR: $sess: effective Discord channel binding is not numeric" >&2
        return 1
        ;;
    esac
    bound_channels="${bound_channels:+$bound_channels,}$effective_channel"
  done
  [ -n "$bound_channels" ] || {
    echo "  ERROR: $sess: effective Discord channel binding is empty" >&2
    return 1
  }
  q_bound_channels="$(shell_quote "$bound_channels")"
  if [ -n "$SWARM_CODEX_BUS_CHANNEL" ]; then
    bus_channel_line="export CODEX_BRIDGE_BUS_CHANNEL=$q_bus_channel"
    bus_env_line="  \"CODEX_BRIDGE_BUS_CHANNEL=\$CODEX_BRIDGE_BUS_CHANNEL\" \\"
  else
    bus_channel_line="unset CODEX_BRIDGE_BUS_CHANNEL"
    bus_env_line="  \"CODEX_BRIDGE_BUS_CHANNEL=\" \\"
  fi
  /bin/cat > "$state_dir/launch.sh" <<EOF
# generated by swarm-up.sh — per-swarm codex-bridge launcher
unset OPENAI_API_KEY CODEX_API_KEY
unset CODEX_MODEL CODEX_PROFILE CODEX_SANDBOX
unset CODEX_SCRIPT
unset CODEX_BRIDGE_ENV_ALLOWLIST CODEX_BRIDGE_TRUST_PROJECT_HOOKS
unset BUN_OPTIONS BUN_CONFIG NODE_OPTIONS NODE_PATH
export HOME=$q_home
export CODEX_HOME=$q_codex_home
export CODEX_BRIDGE_CODEX_HOME=$q_codex_home
export CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET=$q_manager_socket
export PATH=$q_runtime_path
export CODEX_BIN=$q_codex_bin
export CODEX_BRIDGE_CODEX_ARGV_PREFIX=$q_codex_prefix
export CODEX_TURN_TIMEOUT_MS=4500000
export CODEX_BRIDGE_INGRESS_LIMIT=100
export CODEX_BRIDGE_QUEUE_LIMIT=25
export CODEX_BRIDGE_ATTENTION_CHANNEL=$q_attention_channel
export CODEX_BRIDGE_ATTENTION_SWARM=$q_attention_swarm
export CODEX_BRIDGE_ATTENTION_STATE_DIR=$q_attention_state
export CODEX_BRIDGE_CANONICAL_ACCESS_FILE=$q_canonical_access
export CODEX_BRIDGE_ARCHETYPE=$q_archetype
export CODEX_BRIDGE_SWARM_NAME=$q_swarm_name
export CODEX_BRIDGE_OPERATOR_CHANNEL=$q_operator_channel
$bus_channel_line
export DISCORD_BOUND_CHANNEL=$q_bound_channels
export DISCORD_STATE_DIR=$q_state
export CODEX_BRIDGE_CWD=$q_repo
export CODEX_BRIDGE_PREAMBLE_EXTRA=$q_doctrine
export CODEX_BRIDGE_DISCORD_TOKEN_FILE=$q_token_file
token_tmp=$q_token_file.tmp.\$\$
if [ -z "\${DISCORD_BOT_TOKEN:-}" ] || [ -e "\$token_tmp" ] || [ -L "\$token_tmp" ]; then
  echo "codex launcher: missing token or unsafe token temp path" >&2
  return 70
fi
( umask 077; set -C; command printf '%s' "\$DISCORD_BOT_TOKEN" > "\$token_tmp" ) || return 70
/bin/chmod 600 "\$token_tmp" || return 70
/bin/mv -f "\$token_tmp" $q_token_file || return 70
unset DISCORD_BOT_TOKEN
exec /usr/bin/env -i \
  "HOME=\$HOME" \
  "CODEX_HOME=\$CODEX_HOME" \
  "PATH=\$PATH" \
  TMPDIR=$q_tool_tmp \
  LANG=C LC_ALL=C \
  "CODEX_BIN=\$CODEX_BIN" \
  "CODEX_BRIDGE_CODEX_ARGV_PREFIX=\$CODEX_BRIDGE_CODEX_ARGV_PREFIX" \
  "CODEX_BRIDGE_CODEX_HOME=\$CODEX_BRIDGE_CODEX_HOME" \
  "CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET=\$CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET" \
  "CODEX_BRIDGE_OPERATOR_CANARY_VALUE=\${CODEX_BRIDGE_OPERATOR_CANARY_VALUE:-}" \
  "CODEX_TURN_TIMEOUT_MS=\$CODEX_TURN_TIMEOUT_MS" \
  "CODEX_BRIDGE_INGRESS_LIMIT=\$CODEX_BRIDGE_INGRESS_LIMIT" \
  "CODEX_BRIDGE_QUEUE_LIMIT=\$CODEX_BRIDGE_QUEUE_LIMIT" \
  "CODEX_BRIDGE_ATTENTION_CHANNEL=\$CODEX_BRIDGE_ATTENTION_CHANNEL" \
  "CODEX_BRIDGE_ATTENTION_SWARM=\$CODEX_BRIDGE_ATTENTION_SWARM" \
  "CODEX_BRIDGE_ATTENTION_STATE_DIR=\$CODEX_BRIDGE_ATTENTION_STATE_DIR" \
  "CODEX_BRIDGE_CANONICAL_ACCESS_FILE=\$CODEX_BRIDGE_CANONICAL_ACCESS_FILE" \
  "CODEX_BRIDGE_ARCHETYPE=\$CODEX_BRIDGE_ARCHETYPE" \
  "CODEX_BRIDGE_SWARM_NAME=\$CODEX_BRIDGE_SWARM_NAME" \
  "CODEX_BRIDGE_OPERATOR_CHANNEL=\$CODEX_BRIDGE_OPERATOR_CHANNEL" \
$bus_env_line
  "DISCORD_BOUND_CHANNEL=\$DISCORD_BOUND_CHANNEL" \
  "DISCORD_STATE_DIR=\$DISCORD_STATE_DIR" \
  "CODEX_BRIDGE_CWD=\$CODEX_BRIDGE_CWD" \
  "CODEX_BRIDGE_PREAMBLE_EXTRA=\$CODEX_BRIDGE_PREAMBLE_EXTRA" \
  "CODEX_BRIDGE_DISCORD_TOKEN_FILE=\$CODEX_BRIDGE_DISCORD_TOKEN_FILE" \
  $q_bun --no-env-file --config=/dev/null --no-install --no-addons --no-macros --cwd=$q_bun_cwd $q_daemon
EOF
  /bin/chmod 700 "$state_dir/launch.sh"
  tmux send-keys -t "$sess" C-u ". $q_launcher" C-m

  # A cold dedicated-runtime start proves every detected tool and each negative
  # isolation boundary before opening Discord. On macOS, each sandbox seatbelt
  # handoff can spend >10s starting system preference helpers, so 75s can expire
  # while a healthy hardened preflight is still running. Keep the override for
  # operators/tests, but make the production default cover the bounded proof.
  if _wait_for "$sess" "gateway connected" "${SWARM_CODEX_GATEWAY_TIMEOUT:-300}"; then
    tmux set-window-option -t "$sess" remain-on-exit off >/dev/null 2>&1 || true
    echo "  codex lead up: $sess (state: $state_dir)"
  else
    local startup_diagnostic
    startup_diagnostic="$(tmux capture-pane -t "$sess" -p -S -80 2>/dev/null \
      | /usr/bin/awk '/^(codex-bridge:|codex launcher:)/ { line=$0 } END { print line }' \
      | /usr/bin/cut -c 1-1000)"
    echo "  ERROR: $sess: codex-bridge did not report 'gateway connected' before timeout — launch failed" >&2
    [ -z "$startup_diagnostic" ] || echo "         $startup_diagnostic" >&2
    return 1
  fi
  return 0
}

# Refuse any active same-checkout pairing that includes Codex. The standalone
# Codex daemon performs startup sandbox canaries and permission reconciliation
# before its turn lease exists, so even two Codex daemons cannot safely share a
# live checkout. Existing Claude/Claude behavior and historical Claude path
# aliases remain unchanged. This runs while the fleet config lock is held, so
# two managed launches cannot pass one another before tmux session creation.
_mixed_engine_repo_preflight() {  # name repo engine
  local target_name="$1" target_repo="$2" target_engine="$3"
  local target_identity="" other_identity="" other_name other_repo other_engine _line _trimmed
  local includes_codex=0 lease_root="" lease_signal="" _lease_rc=0
  local _tmux="${SWARM_TMUX_BIN:-tmux}"
  target_identity="$(/usr/bin/python3 -I -B - "$target_repo" <<'PY'
import os, stat, sys
path=sys.argv[1]
if not os.path.isabs(path):
    raise SystemExit(2)
st=os.stat(path, follow_symlinks=True)
if not stat.S_ISDIR(st.st_mode): raise SystemExit(2)
print('%d:%d' % (st.st_dev, st.st_ino))
PY
)" || {
    echo "  ERROR: ${PREFIX}-${target_name}: could not bind the configured repository identity" >&2
    return 1
  }
  [ "$target_engine" = codex ] && includes_codex=1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_line"; then
      echo "  ERROR: ${PREFIX}-${target_name}: malformed swarm.conf row prevents mixed-engine overlap proof" >&2
      return 1
    fi
    other_name="$SWARM_CONF_F_NAME"
    other_repo="$SWARM_CONF_F_REPO"
    other_engine="$SWARM_CONF_F_ENGINE"
    [ "$other_name" = "$target_name" ] && continue
    # An inactive configured Codex sibling still tells us which physical
    # checkout's retained lease namespace can block a Claude launch after a
    # daemon/pane crash. Resolve aliases only for identity comparison; Codex's
    # own launch path separately requires its configured path to be canonical.
    if [ "$target_engine" = claude ] && [ "$other_engine" = codex ]; then
      other_identity="$(/usr/bin/python3 -I -B - "$other_repo" <<'PY'
import os, stat, sys
path=sys.argv[1]
if not os.path.isabs(path): raise SystemExit(2)
st=os.stat(path, follow_symlinks=True)
if not stat.S_ISDIR(st.st_mode): raise SystemExit(2)
print('%d:%d' % (st.st_dev, st.st_ino))
PY
)" || {
        echo "  ERROR: ${PREFIX}-${target_name}: configured Codex row '$other_name' has an unverifiable repository" >&2
        return 1
      }
      [ "$other_identity" = "$target_identity" ] && includes_codex=1
    fi
    [ "$other_engine" = claude ] && [ "$target_engine" = claude ] && continue
    "$_tmux" has-session -t "${PREFIX}-${other_name}" 2>/dev/null || continue
    other_identity="$(/usr/bin/python3 -I -B - "$other_repo" <<'PY'
import os, stat, sys
path=sys.argv[1]
if not os.path.isabs(path):
    raise SystemExit(2)
st=os.stat(path, follow_symlinks=True)
if not stat.S_ISDIR(st.st_mode): raise SystemExit(2)
print('%d:%d' % (st.st_dev, st.st_ino))
PY
)" || {
      echo "  ERROR: ${PREFIX}-${target_name}: active opposite-engine row '$other_name' has an unverifiable repository" >&2
      return 1
    }
    if [ "$other_identity" = "$target_identity" ]; then
      echo "  ERROR: ${PREFIX}-${target_name}: refusing Codex checkout overlap with active ${PREFIX}-${other_name} on the same physical repository" >&2
      echo "         Stop ${PREFIX}-${other_name} before launching engine=$target_engine for this checkout." >&2
      return 1
    fi
  done < "$CONF"

  # A repo lease deliberately survives daemon death because it may represent
  # an interrupted startup, turn, or Git transaction. Tmux absence is therefore
  # not clearance. Check the exact inode-derived namespace for every engine:
  # a removed Codex row can still leave an authority-bearing lease that must
  # block a later Claude-only configuration. Only audited recovery may clear it.
  lease_root="${SWARM_CODEX_HOME_EFFECTIVE:-$HOME/.codex}/channels/repo-locks"
  lease_signal="$(/usr/bin/python3 -I -B - "$lease_root" "$target_identity" "$includes_codex" <<'PY'
import os, re, stat, sys
root, identity, configured_codex = sys.argv[1:]
if not re.fullmatch(r'[0-9]+:[0-9]+', identity): raise SystemExit(2)
if not os.path.lexists(root): raise SystemExit(0)
before=os.lstat(root)
base=identity.replace(':','-') + '.lock'
if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o700
        or os.path.realpath(root) != root):
    # A valid managed lease can never be created beneath this boundary. Keep
    # Claude-only fleets compatible unless the exact canonical signal exists;
    # configured Codex still requires the complete private root.
    if os.path.lexists(os.path.join(root, base)):
        print(base)
        raise SystemExit(4)
    if configured_codex == '1':
        print('unsafe repo-lock root')
        raise SystemExit(3)
    raise SystemExit(0)
names=os.listdir(root)
if len(names) > 4096:
    print('repo-lock root exceeds its audit bound')
    raise SystemExit(3)
pattern=re.compile(r'^\.' + re.escape(base) + r'\.(?:release|recover)\.[A-Za-z0-9.]+$')
matches=sorted(name for name in names if name == base or pattern.fullmatch(name))
after=os.lstat(root)
if (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_dev, after.st_ino, after.st_mtime_ns, after.st_ctime_ns):
    print('repo-lock root changed during inspection')
    raise SystemExit(3)
if matches:
    print(matches[0])
    raise SystemExit(4)
PY
)"; _lease_rc=$?
  if [ "$_lease_rc" -ne 0 ]; then
    echo "  ERROR: ${PREFIX}-${target_name}: retained Codex repository lease blocks this checkout${lease_signal:+ ($lease_signal)}" >&2
    echo "         Stop the fleet and use bin/swarm-recover.sh audit repo-lease '$target_repo'; never delete the signal by hand." >&2
    return 1
  fi
  return 0
}

# Shared runtime-upgrade quarantine. Adoption is deliberately explicit while
# ADR-0023 remains implemented/tested-not-live. The enabled lane is check-only:
# a fixed no-argument root broker resolves the registered swarm and the atomic
# Claude+Codex conformance manifest. Neither this mutable launcher nor a worker
# can mint or select a receipt, executable, argv prefix, or suite digest.
_runtime_conformance_gate() {  # claude|codex swarm
  local _runtime="$1" _swarm="$2" _enabled="${SWARM_RUNTIME_CONFORMANCE_ENFORCE:-0}"
  local _broker="/Library/PrivilegedHelperTools/qofi-harness-lifecycle-broker"
  local _binary="" _prefix="" _admitted=""

  case "$_enabled" in
    0|'') return 0 ;;
    1) ;;
    *) echo "  ERROR: SWARM_RUNTIME_CONFORMANCE_ENFORCE must be 0 or 1" >&2; return 1 ;;
  esac
  case "$_runtime" in
    claude)
      echo "  ERROR: native interactive Claude is not a supervised lifecycle boundary" >&2
      echo "         Runtime-conformance adoption requires the root harness claude -p lane." >&2
      return 1
      ;;
    codex)
      _binary="${SWARM_CODEX_TRUSTED_BIN_REAL:-}"
      _prefix="${SWARM_CODEX_ARGV_PREFIX:-}"
      ;;
    *) echo "  ERROR: unsupported runtime conformance target: $_runtime" >&2; return 1 ;;
  esac
  if [ "$_runtime" = "codex" ]; then
    case "$_binary" in
      /*) ;;
      *) echo "  ERROR: codex CLI has no root-attested absolute executable path" >&2; return 1 ;;
    esac
    case "$_prefix" in
      /*) ;;
      *) echo "  ERROR: codex CLI has no root-attested absolute argv prefix" >&2; return 1 ;;
    esac
  fi

  # Construct the canonical request, invoke only the fixed no-argument sudo
  # capability, and validate its exact unnormalized response in one process.
  # Keeping the trailing newline inside Python avoids shell command
  # substitution normalizing a noncanonical root decision into acceptance.
  if ! _admitted="$(/usr/bin/python3 -I -B -c '
import json,re,subprocess,sys
runtime,swarm,expected_path,expected_prefix,broker=sys.argv[1:]
request={"schema":"qofi-harness-broker-request/v1","operation":"conformance-check","runtime":runtime,"swarm":swarm,"payload":{}}
request_raw=(json.dumps(request,sort_keys=True,separators=(",",":"))+"\n").encode()
try:
    result=subprocess.run(
        ["/usr/bin/sudo","-n","--",broker],input=request_raw,
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30,check=False,
        env={"PATH":"/usr/bin:/bin","LANG":"C","LC_ALL":"C"},
    )
except (OSError,subprocess.SubprocessError): raise SystemExit(2)
if result.returncode != 0 or result.stderr: raise SystemExit(2)
raw=result.stdout
if not 2 <= len(raw) <= 65536: raise SystemExit(2)
try: value=json.loads(raw.decode("utf-8","strict"))
except (UnicodeDecodeError,ValueError): raise SystemExit(2)
canonical=(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
if raw != canonical or not isinstance(value,dict) or set(value) != {"schema","allowed","reason_code","manifest_sha256","execution"}: raise SystemExit(2)
if value.get("schema") != "qofi-harness-conformance-decision/v1" or value.get("allowed") is not True or value.get("reason_code") != "attested-parity-pass": raise SystemExit(2)
if not re.fullmatch(r"[0-9a-f]{64}",str(value.get("manifest_sha256",""))): raise SystemExit(2)
execution=value.get("execution")
if not isinstance(execution,dict) or set(execution) != {"path","size","mode","sha256","version","argv_prefix"}: raise SystemExit(2)
path=execution.get("path"); prefix=execution.get("argv_prefix")
if not isinstance(path,str) or not path.startswith("/") or any(ord(c)<32 or ord(c)==127 for c in path): raise SystemExit(2)
if not isinstance(execution.get("size"),int) or execution["size"] < 1 or not isinstance(execution.get("mode"),int): raise SystemExit(2)
if not re.fullmatch(r"[0-9a-f]{64}",str(execution.get("sha256",""))): raise SystemExit(2)
if not isinstance(execution.get("version"),str) or any(ord(c)<32 or ord(c)==127 for c in execution["version"]): raise SystemExit(2)
if runtime != "codex" or path != expected_path or prefix != [expected_prefix]: raise SystemExit(2)
sys.stdout.write(path)
' "$_runtime" "$_swarm" "$_binary" "$_prefix" "$_broker")"; then
    echo "  ERROR: root runtime conformance decision was absent, denied, or malformed" >&2
    return 1
  fi
  _binary="$_admitted"
  return 0
}

launch_one() {  # name repo tokvar [channel] [account] [engine]
  local name="$1" repo="$2" tokvar="$3" channel="${4:-}" account="${5:-}" engine="${6:-claude}"
  local sess="${PREFIX}-${name}"
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "  running: $sess"; return 0
  fi
  [ -d "$repo" ] || { echo "  ERROR: repo not found: $repo" >&2; return 1; }
  _mixed_engine_repo_preflight "$name" "$repo" "$engine" || return 1
  # SCOPED token pre-check (F1): read just this swarm's token in a subshell that
  # sources the vault and exits, so the launcher's own env never holds the vault.
  # tokvar is a validated identifier (swarm_conf_parse_line blanks a non-identifier),
  # so the ${!tokvar} indirect deref is safe.
  local token; token="$([ -f "$TOKENS" ] && . "$TOKENS" >/dev/null 2>&1; printf '%s' "${!tokvar:-}")"
  [ -z "$token" ] && { echo "  ERROR: no token in \$$tokvar (check tokens.env)" >&2; return 1; }

  local repo_type
  repo_type="$(swarm_type_of "$repo")"

  # ACCOUNT partitions Claude auth only. Clear it BEFORE Codex preflight so a
  # labeled Claude access path cannot veto a Codex row that uses host Codex auth.
  if [ "$engine" = "codex" ] && [ -n "$account" ]; then
    echo "  WARN: $sess: ACCOUNT '$account' ignored — engine=codex uses the host's Codex subscription login" >&2
    account=""
  fi

  # ---- preflight gates ---------------------------------------------------
  # Refuse to launch a swarm that hasn't been fully configured. Each gate
  # is a cheap read; collectively they turn the three silent half-launches
  # we hit on this mini's first standup into loud refusals with one
  # remediation: re-run swarm-add. Bypass for the "I know what I'm doing"
  # case via SWARM_UP_SKIP_SANITY=1.
  if [ "$engine" = "codex" ]; then
    # Subscription auth is a money-path floor and is never bypassed. The escape
    # hatch skips only the on-disk doctrine check, mirroring its stated purpose.
    if ! swarm_codex_manager_host_preflight "$repo"; then
      echo "  ERROR: $sess: trusted bounded Codex host/auth preflight failed" >&2
      return 1
    fi
    # The strict state-tree walker rejects unknown directories. Before asking
    # it to walk, finish only a helper-authored, receipt-bound release that was
    # already in progress when this launch began. This never starts release of
    # an ordinary stale lock; that remains behind the tmux launch-winner gate.
    # Malformed or live-owner boundaries remain authoritative and block here.
    _codex_finish_interrupted_daemon_release "$name" "$sess" || return 1
    if ! swarm_codex_state_validate "$name" prepare; then
      echo "  ERROR: $sess: Codex state path is not a private canonical tree" >&2
      return 1
    fi
    if [ "${SWARM_UP_SKIP_SANITY:-0}" != "1" ] && ! _preflight_check_codex_doctrine "$name" "$repo"; then
      return 1
    fi
    _codex_project_config_preflight "$sess" "$repo" || return 1
    _codex_attention_binding_preflight "$sess" "$name" "$channel" "$repo" || return 1
    _codex_role_binding_preflight "$sess" "$repo_type" "$channel" || return 1
    _codex_quiescence_preflight "$name" "$sess" || return 1
    _codex_acl_reconcile "$name" "$channel" "$repo_type" || return 1
  elif [ "${SWARM_UP_SKIP_SANITY:-0}" != "1" ]; then
    if ! _preflight_check "$name" "$repo" "$channel" "$account"; then
      return 1
    fi
  fi
  if ! _runtime_conformance_gate "$engine" "$name"; then
    echo "  ERROR: $sess: $engine conformance quarantine blocked launch" >&2
    return 1
  fi

  echo "  launching: $sess  ($repo)"
  local session_created=0
  if [ "$engine" = "codex" ]; then
    case "${SWARM_CODEX_OPERATOR_CANARY_VALUE:-}" in
      ''|*[!A-Za-z0-9_.:-]*)
        echo "  ERROR: $sess: validated operator isolation canary handoff is unavailable" >&2
        return 1
        ;;
    esac
    # The terminal which ran swarm-up has the current launchd/audit context;
    # a long-lived tmux server may not. tmux 3.7's per-session environment
    # hands the root-attested non-secret witness to this pane only, without
    # changing the global tmux environment or disrupting Claude sessions.
    tmux new-session -d -s "$sess" -c "$repo" \
      -e "CODEX_BRIDGE_OPERATOR_CANARY_VALUE=$SWARM_CODEX_OPERATOR_CANARY_VALUE" \
      && session_created=1
  else
    tmux new-session -d -s "$sess" -c "$repo" && session_created=1
  fi
  if [ "$session_created" -ne 1 ]; then
    # Session creation is the atomic launch-winner gate. A concurrent `up` may
    # have won after the initial has-session check; the loser must return before
    # sending pane input or clearing daemon.lock. Other failures remain errors.
    if tmux has-session -t "$sess" 2>/dev/null; then
      echo "  running: $sess (concurrent launcher won)"
      return 0
    fi
    echo "  ERROR: could not create tmux session $sess" >&2
    return 1
  fi
  if [ "$engine" = "codex" ] && \
     ! tmux set-environment -u -t "$sess" CODEX_BRIDGE_OPERATOR_CANARY_VALUE >/dev/null; then
    echo "  ERROR: $sess: could not erase the startup canary from tmux session state" >&2
    tmux kill-session -t "$sess" 2>/dev/null || true
    return 1
  fi
  # The live session now pins engine migration: swarm-add refuses to cross it.
  # Release the fleet-wide config lock before Claude prompt handling or the
  # Codex gateway wait so unrelated lifecycle operations and emergency down
  # are never blocked for tens of seconds. Until Codex reports ready, retain an
  # EXIT cleanup marker so SIGINT/SIGTERM cannot strand a false "running" pane.
  if [ "$engine" = "codex" ]; then
    SWARM_UP_PARTIAL_CODEX_SESSION="$sess"
    # Preserve a startup-crashed pane long enough to expose its bounded
    # fail-closed diagnostic. Readiness disables this again so a later daemon
    # exit still removes the session and remains visible to supervision.
    if ! tmux set-window-option -t "$sess" remain-on-exit on >/dev/null; then
      echo "  ERROR: $sess: could not arm startup diagnostic retention" >&2
      tmux kill-session -t "$sess" 2>/dev/null || true
      SWARM_UP_PARTIAL_CODEX_SESSION=""
      return 1
    fi
  fi
  swarm_conf_lock_release
  # CRITICAL: unset ANTHROPIC_API_KEY so the lead bills against Max, not metered API.
  # Source tokens.env INSIDE the pane and dereference by var name so the literal
  # token value never appears on the command line / pane scrollback.
  # Export SWARM_HOME into the pane so the CTO can invoke
  # "$SWARM_HOME/bin/swarm-attention.sh" portably (the canonical form pinned
  # in templates/_base/ESCALATION.md §Attention flag — composed into every
  # archetype's ESCALATION.md). The helper self-locates as
  # belt-and-suspenders, but the env var makes the doctrine form work
  # without hardcoding the host path.
  # DISCORD_BOUND_CHANNEL scopes the bridge to this swarm's own channel: the bot
  # may be a MEMBER of sibling channels (needed so it can resolve the source name
  # of forwarded messages) but it only RESPONDS in its bound channel(s). Without
  # it, the shared access.json — which lists a group for every swarm's channel —
  # lets a bot answer in any channel it's been added to. Empty channel (legacy
  # 3-col swarm.conf row) → unset, preserving prior single-channel behavior.
  #
  # swarm_bound_exports (swarm-lib.sh) derives the binding: every swarm is
  # single-bound to its own channel EXCEPT the CPO swarm, which is bound to
  # operator+bus and also gets DISCORD_OPERATOR_CHANNEL / DISCORD_BUS_CHANNEL for
  # register-by-channel. Deriving it there keeps every CTO swarm untouched (no bus).
  bound_exports="$(swarm_bound_exports "$name" "$channel" "$repo_type")"
  # ---- multi-account partition (ADR-0018) -------------------------------
  # Resolve this swarm's account label to its isolated config dir + vault
  # token-var via the resolver (swarm-lib.sh) — the SOLE constructor of any
  # $HOME/.claude path, never hand-built here. Two fragments fall out and are
  # spliced into the send-keys lines below:
  #   acct_env — EXTRA pane-env exports for a LABELED account (prefixed "; "
  #              so it appends cleanly onto the existing env line). Empty for
  #              the default account.
  #   acct_rc  — the --remote-control flag fragment. DEFAULT account keeps
  #              " --remote-control $name" (byte-identical to today); a
  #              LABELED account drops it ENTIRELY (token-auth is incompatible
  #              with remote-control).
  # The EMPTY-account (default) path is byte-identical to the pre-partition
  # script: acct_env="" and acct_rc=" --remote-control $name", so both
  # send-keys strings below reproduce exactly. The whole labeled delta is
  # gated on [ -n "$account" ]; the inert all-empty fleet is unchanged.
  local acct_env="" acct_rc=" --remote-control $name"
  if [ -n "$account" ]; then
    # A non-empty label that the resolver REJECTS is malformed (bad chars / not
    # starting with a letter). Fail loud and refuse to launch this swarm rather
    # than fall through to the default-account env (which would silently boot it
    # on the WRONG, keychain-auth account). Explicit check + friendly message;
    # without it set -e would still abort, but abruptly and without context.
    if ! swarm_account_resolve "$account"; then
      echo "  ERROR: $sess: invalid account label '$account' in swarm.conf (field 6)." >&2
      echo "         Account labels must start with a letter and contain only [A-Za-z0-9_-]." >&2
      echo "         Fix the ACCOUNT field, or clear it to use the default account. Skipping this swarm." >&2
      return 1
    fi
    # Deref the OAUTH token by NAME at RUNTIME inside the pane via a SCOPED
    # subshell source (F1, ADR-0018): `$(. '$TOKENS'; printf '%s' "$<VAR>")`
    # sources the vault inside a subshell that emits ONLY this account's token
    # value and then exits — discarding every OTHER vault var, so the pane never
    # holds another account's OAUTH token or another swarm's bot token. The literal
    # token never enters the script or the command line / scrollback (the value is
    # captured by the `VAR="$(...)"` assignment, never echoed). unset
    # ANTHROPIC_AUTH_TOKEN alongside ANTHROPIC_API_KEY so neither metered API path
    # can shadow the OAuth token. CLAUDE_CONFIG_DIR points claude at the account's
    # isolated config dir.
    acct_env="; unset ANTHROPIC_AUTH_TOKEN; export CLAUDE_CONFIG_DIR='$SWARM_ACCT_CONFIG_DIR'; export CLAUDE_CODE_OAUTH_TOKEN=\"\$(. '$TOKENS' >/dev/null 2>&1; printf '%s' \"\$$SWARM_ACCT_TOKEN_VAR\")\""
    # Token-auth is incompatible with remote-control — drop the flag.
    acct_rc=""
  fi
  # F1 token isolation (ADR-0018). Two layers, both in this one pane env line:
  #
  # (1) SCRUB inherited vault vars. A tmux pane inherits the env of the server, and
  #     on a COLD start that server is a child of swarm-up — so if anything ever
  #     left the vault in an ancestor's env (a contaminated server, an operator
  #     shell that sourced tokens.env), the pane would inherit every BOT_* and
  #     OAUTH_TOKEN_*. We unset them FIRST (shell-agnostic: env|sed lists the var
  #     NAMES, the pane shell may be bash or zsh). `unset IFS` first so the var-name
  #     list word-splits on the DEFAULT separator even if a shell rc set a hostile
  #     IFS (an unset IFS == space/tab/newline; POSIX, robust in bash/zsh/sh). This
  #     neutralizes inheritance so the property holds at the PANE regardless of how
  #     the server's env was built. It cannot touch the tokens we set next:
  #     DISCORD_BOT_TOKEN / CLAUDE_CODE_OAUTH_TOKEN don't match the ^BOT_ /
  #     ^OAUTH_TOKEN_ name patterns. (Extend the patterns if a future vault ever
  #     holds a secret under a different prefix.)
  # (2) DERIVE only this swarm's own tokens via a SCOPED subshell source:
  #     `$(. '$TOKENS' >/dev/null 2>&1; printf '%s' "$<tokvar>")` sources the vault
  #     inside a subshell that emits the ONE value and exits, discarding every other
  #     vault var; the `>/dev/null` drops any stray source-time stdout. A labeled
  #     account adds only its own CLAUDE_CODE_OAUTH_TOKEN via $acct_env, scoped the
  #     same way. The literal token is computed in-pane and captured by the
  #     assignment — it never appears in this send-keys string or the scrollback.
  #     tokvar is a validated identifier (swarm_conf_parse_line), so the deref is
  #     injection-safe. Default (empty account): the pane gets DISCORD_BOT_TOKEN only.
  local codex_key_scrub=""
  [ "$engine" = "codex" ] && codex_key_scrub="unset OPENAI_API_KEY CODEX_API_KEY; "
  tmux send-keys -t "$sess" "${codex_key_scrub}unset ANTHROPIC_API_KEY; export SWARM_HOME='$SWARM_HOME'; $bound_exports; unset IFS; for v in \$(env | /usr/bin/sed -n 's/^\(BOT_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(OAUTH_TOKEN_[A-Za-z0-9_]*\)=.*/\1/p'); do unset \"\$v\"; done; export DISCORD_BOT_TOKEN=\"\$(. '$TOKENS' >/dev/null 2>&1; printf '%s' \"\$$tokvar\")\"$acct_env" C-m

  # ---- engine dispatch ----------------------------------------------------
  # engine=codex: the pane runs the codex-bridge DAEMON instead of the Claude
  # Code TUI. Codex CLI has no channels capability, so Discord I/O goes
  # through codex-bridge/daemon.ts (gateway -> gate -> codex exec per message,
  # one resumed Codex thread per chat). Everything above — pane env, token
  # isolation, DISCORD_BOUND_CHANNEL — is engine-neutral and already set.
  if [ "$engine" = "codex" ]; then
    if ! _launch_codex_lead "$name" "$repo" "$sess" "$channel" "$repo_type"; then
      # Any partial Codex launch is unusable. Remove the pane immediately so a
      # later `up` retries instead of short-circuiting on a stale shell session.
      tmux kill-session -t "$sess" 2>/dev/null || true
      SWARM_UP_PARTIAL_CODEX_SESSION=""
      return 1
    fi
    SWARM_UP_PARTIAL_CODEX_SESSION=""
    return 0
  fi
  # CRITICAL: --dangerously-load-development-channels (not --channels) because the
  # qofi-swarm marketplace is self-published, not on Anthropic's approved allowlist.
  # --permission-mode auto: guarantees auto mode on every launch regardless of any
  # prior session state or settings.json permissionMode. Without this, a session
  # could start in plan or default mode (e.g. if a prior session changed the mode
  # and that state persisted, or if a repo's settings.json specifies a different
  # mode) — the CTO would boot but silently refuse to execute work. This flag is
  # a launch-time pin; it also keeps the "auto mode" footer readiness gate (below)
  # reliable: the gate checks for the "auto mode" string, which appears when this
  # flag is in effect, so it can't be fooled by a different mode taking effect first.
  # --remote-control "$name" enables Remote Control and NAMES the remote session
  # after the swarm/repo (e.g. "qofi-product"), so it shows up by that name at
  # claude.ai/code and in the mobile app — the operator can drive any swarm
  # remotely. Passing an explicit name skips the hostname-prefixed auto-naming
  # (--remote-control-session-name-prefix). This is a launch flag (not a send-keys
  # slash command like /effort): it's enabled from turn one and the footer still
  # reaches the "auto mode" readiness marker below, so the gate is unaffected.
  # Lives in launch_one, the single launch path, so `up`, `restart`, and
  # `update` all inherit it. $name is the swarm.conf session name == repo name.
  # acct_rc carries the --remote-control fragment: kept for the default
  # account, dropped for a LABELED (token-auth) account — see above.
  tmux send-keys -t "$sess" "claude --dangerously-load-development-channels $PLUGIN$acct_rc --permission-mode auto" C-m

  # --dangerously-load-development-channels opens an interactive warning prompt:
  #   ❯ 1. I am using this for local development
  #     2. Exit
  # Option 1 is preselected; a single Enter accepts it. Wait for the prompt to
  # render rather than guessing how long the CLI takes to start.
  if ! _wait_for "$sess" "I am using this for local development" 20; then
    echo "  WARN: dev-channels prompt didn't appear in 20s — lead may not start" >&2
  fi
  # Press Enter until the prompt actually clears — a single blind Enter here
  # raced the TUI and, when swallowed, desynced everything sent after it (the
  # effort command and the doctrine brief landed into the wrong UI state).
  if ! _enter_until_gone "$sess" "I am using this for local development" 15; then
    echo "  WARN: dev-channels prompt did not clear after repeated Enter — launch sequence may be desynced" >&2
  fi

  # After accepting, claude needs a moment to load plugins and render the main
  # input prompt. The "auto mode" hint in the footer is a reliable readiness marker.
  if ! _wait_for "$sess" "auto mode" 20; then
    echo "  WARN: main input didn't render in 20s — brief may not land" >&2
  fi

  # Set the per-archetype effort level for this session, BEFORE the brief so the
  # first substantive task runs under it. Effort is SESSION-ONLY — ultracode
  # can't live in settings.json, has no env var, and is rejected by
  # --effort/CLAUDE_CODE_EFFORT_LEVEL — so it must be re-sent on every launch.
  # Sent here as the documented user-facing /effort command rather than a
  # launch-time `--settings` flag: both work and both are session-only, but the
  # in-session command avoids JSON-escaping nested inside this tmux/shell
  # send-keys string and leaves a visible record in the pane scrollback. (Note:
  # the "auto mode" readiness marker above is the permission/edit mode,
  # independent of effort, so the launch-flag form would NOT have broken that
  # gate.) The level is per-archetype (swarm_effort_for in swarm-lib.sh): the CPO
  # swarm launches at /effort medium; every CTO swarm (and any unknown/future type)
  # stays on ultracode. Resolve the archetype ONCE here and reuse it for the
  # brief below. Send text and Enter as separate calls (same idiom as the brief).
  tmux send-keys -t "$sess" "$(swarm_effort_for "$repo_type")"
  sleep 1
  tmux send-keys -t "$sess" Enter
  # Belt for a swallowed Enter: a slash command gives no "esc to interrupt"
  # footer to verify against, so send a second Enter after a beat — if the
  # first submitted, this lands on an empty input box and is a no-op; if the
  # first was swallowed, this is the submit.
  sleep 1
  tmux send-keys -t "$sess" Enter

  # Send the brief, then submit. A trailing C-m on the same send-keys call gets
  # absorbed into the input (treated as part of the paste) and does NOT fire
  # submission — observed empirically. Send text and Enter as separate calls.
  # The brief itself is per-archetype (swarm_launch_brief in swarm-lib.sh) —
  # engineering-cto and cpo have fundamentally different roles, so each
  # gets the orientation that matches its doctrine. Unknown markers fall
  # back to the engineering brief (a known-good orientation).
  local brief
  brief="$(swarm_launch_brief "$repo_type")"
  tmux send-keys -t "$sess" "$brief"
  sleep 1
  # VERIFIED submit: the brief is the doctrine-read instruction — a swallowed
  # Enter here is exactly the "swarm never read its doctrine" failure. After a
  # real submission Claude starts processing and the running footer ("esc to
  # interrupt") appears; retry Enter until it does. The stamped SessionStart
  # hook (session-doctrine.sh) is the harness-level backstop if even this
  # fails, but the brief carries the full orientation so its delivery is
  # verified, not assumed.
  if ! _submit_verified "$sess" 3; then
    echo "  WARN: $sess: launch brief may not have submitted — check the pane" >&2
    echo "        (tmux attach -t $sess; press Enter if the brief sits in the input box)" >&2
  fi
}

cmd_up() {  # [name]
  # Optional name filter: when set, only the matching swarm is launched.
  # Used by swarm-attach.sh's attach-or-launch path so it doesn't drag
  # unrelated down swarms up as a side effect.
  local filter="${1:-}" codex_failed=0 filtered_failed=0 lifecycle_failed=0 matched=0 _result=0
  while IFS= read -r _line; do
    if ! swarm_conf_parse_line "$_line"; then
      # The process-substitution input already excludes comments/blanks, so a
      # parser failure here is a malformed data row. A fleet-wide `up` must not
      # report success after silently omitting it. A filtered launch retains its
      # historical scope: an unrelated malformed row does not veto that one
      # explicitly named swarm, while a malformed target remains unmatched and
      # returns the existing filtered error below.
      [ -z "$filter" ] && lifecycle_failed=1
      continue
    fi
    name="$SWARM_CONF_F_NAME"
    [ -z "$name" ] && continue
    [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
    matched=1
    repo="$SWARM_CONF_F_REPO"
    tokvar="$SWARM_CONF_F_TOKVAR"
    channel="$SWARM_CONF_F_CHANNEL"
    account="$SWARM_CONF_F_ACCOUNT"
    engine="$SWARM_CONF_F_ENGINE"
    if ! swarm_up_launch_lock_acquire "$name"; then
      echo "swarm-up: REFUSED — launch for '$name' is already in progress; no replacement session was created." >&2
      lifecycle_failed=1
      [ "$engine" = "codex" ] && codex_failed=1
      [ -n "$filter" ] && filtered_failed=1
      continue
    fi
    if ! swarm_conf_lock_acquire "$CONF"; then
      echo "swarm-up: REFUSED — swarm lifecycle mutation is in progress; no session was launched for $name." >&2
      lifecycle_failed=1
      [ "$engine" = "codex" ] && codex_failed=1
      [ -n "$filter" ] && filtered_failed=1
      swarm_up_launch_lock_release
      continue
    fi
    if ! /usr/bin/python3 -I -B - "$CONF" "$name" "$_line" <<'PY'
import sys
path,name,expected=sys.argv[1:4]
matches=[]
with open(path,newline='') as f:
  for raw in f:
    body=raw[:-2] if raw.endswith('\r\n') else (raw[:-1] if raw.endswith('\n') else raw)
    if not body.strip() or body.lstrip().startswith('#'): continue
    if body.split('|',1)[0].strip()==name: matches.append(body)
raise SystemExit(0 if matches==[expected] else 1)
PY
    then
      echo "swarm-up: REFUSED — configured row for '$name' changed before launch; retry." >&2
      swarm_conf_lock_release
      lifecycle_failed=1
      [ "$engine" = "codex" ] && codex_failed=1
      [ -n "$filter" ] && filtered_failed=1
      swarm_up_launch_lock_release
      continue
    fi
    if ! launch_one "$name" "$repo" "$tokvar" "$channel" "$account" "$engine"; then
      # Preserve historical Claude fleet behavior (continue + successful
      # aggregate command), while making the new Codex path observable to
      # restart/rotation/automation callers.
      [ "$engine" = "codex" ] && codex_failed=1
      [ -n "$filter" ] && filtered_failed=1
    fi
    while [ "${SWARM_CONF_LOCK_DEPTH:-0}" -gt 0 ]; do swarm_conf_lock_release; done
    swarm_up_launch_lock_release
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  if [ -n "$filter" ] && [ "$matched" -eq 0 ]; then
    echo "swarm-up: no configured swarm named '$filter' in $CONF" >&2
    _result=1
  fi
  [ "$filtered_failed" -eq 0 ] || _result=1
  [ "$codex_failed" -eq 0 ] || _result=1
  [ "$lifecycle_failed" -eq 0 ] || _result=1
  return "$_result"
}

cmd_down() {  # [name]
  # Optional name filter, symmetric to cmd_up. No-arg = kill all swarm-*
  # sessions (the original behavior); with a name = kill ONLY that one
  # swarm's session. Used by swarm-restart.sh / swarm-update.sh to cycle
  # a single swarm without taking siblings down as a side effect.
  local filter="${1:-}" _sessions
  local pattern="^${PREFIX}-"
  command -v tmux >/dev/null 2>&1 || {
    echo "swarm-up: REFUSED — tmux is unavailable; no session was stopped." >&2
    return 1
  }
  [ -n "$filter" ] && pattern="^${PREFIX}-${filter}\$"
  _sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$pattern" || true)"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "  killing: $s"; tmux kill-session -t "$s" 2>/dev/null || true
  done <<< "$_sessions"
  return 0
}

cmd_status() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}-" || echo "  (no swarm sessions running)"
}

cmd_attach() {  # [name]
  local name="${1:-}" engine="" found=0 _line session_before="" session_target=""
  if [ -z "$name" ]; then
    {
      echo "running swarm sessions:"
      cmd_status
      echo "usage: swarm-up.sh attach <name>"
    } >&2
    exit 1
  fi
  local sess="${PREFIX}-${name}"
  session_before="$(tmux display-message -p -t "$sess" '#{session_id}' 2>/dev/null || true)"
  while IFS= read -r _line || [ -n "$_line" ]; do
    swarm_conf_parse_line "$_line" || continue
    if [ "$SWARM_CONF_F_NAME" = "$name" ]; then
      engine="$SWARM_CONF_F_ENGINE"; found=$((found + 1))
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  if [ "$found" -ne 1 ]; then
    echo "swarm-up: no configured swarm '$name'" >&2
    exit 1
  fi
  session_target="$(tmux display-message -p -t "$sess" '#{session_id}' 2>/dev/null || true)"
  case "$session_before:$session_target" in \$[0-9]*:\$[0-9]*) ;; *) echo "swarm-up: no stable running swarm '$sess'" >&2; exit 1 ;; esac
  [ "$session_before" = "$session_target" ] || { echo "swarm-up: session '$sess' was replaced while resolving its engine; retry" >&2; exit 1; }
  if [ "$engine" = "codex" ]; then
    echo "swarm-up: '$name' uses engine=codex — routing attach to the supported operator view" >&2
    exec "$SWARM_VIEW" "$name"
  fi
  exec tmux attach -t "$session_target"
}

cmd_watch() {
  echo "Supervising swarm (Ctrl-C to stop). Checking every 30s."
  echo "Note: in-process workers do NOT survive a lead relaunch; each engine rebuilds from its persisted repo/runtime state."
  echo "Liveness = tmux session exists; when a lead runtime exits the pane closes the session, so this is a fair proxy."
  while true; do cmd_up >/dev/null 2>&1 || true; sleep 30; done
}

case "${1:-}" in
  up)     cmd_up "${2:-}" ;;
  down)   cmd_down "${2:-}" ;;
  status) cmd_status ;;
  watch)  cmd_watch ;;
  attach) cmd_attach "${2:-}" ;;
  *) echo "usage: swarm-up.sh {up [name]|down [name]|status|watch|attach <name>}" >&2; exit 1 ;;
esac
