#!/usr/bin/env bash
# swarm-up.sh — run one persistent Agent Teams lead per repo in tmux on the
# always-on host (Mac mini), each with its own Discord bot identity, supervised.
#
# Avoids bash-4 features so it runs on macOS's default bash 3.2 (brew bash is fine too).
#
# Config: $SWARM_HOME/swarm.conf — one repo per line, pipe-separated, FOUR fields:
#     session_name | /path/to/repo | TOKEN_VAR_NAME | CHANNEL_ID
#   TOKEN_VAR_NAME names an env var (defined in $SWARM_HOME/tokens.env) holding
#   that repo's DISCORD_BOT_TOKEN. CHANNEL_ID is the Discord channel this swarm is
#   bound to (used by swarm-watch.sh for the per-channel heartbeat; swarm-up itself
#   doesn't need it, but it must be present so the field is parsed cleanly).
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
# shellcheck source=swarm-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/swarm-lib.sh"   # swarm_conf_parse_line
PREFIX="swarm"                              # tmux session name prefix (no ':' allowed)
# Custom-marketplace channel plugin. Research-preview channels require the dev flag
# (a marketplace you publish yourself is not on Anthropic's approved allowlist), and
# the plugin must be fully qualified with @<marketplace>.
PLUGIN="${SWARM_PLUGIN:-plugin:discord-b2b@qofi-swarm}"

# Poll the pane for `pattern` until it appears or `timeout` seconds elapse.
# Used to wait for prompts/states instead of fixed-duration sleeps. bash 3.2-safe.
_wait_for() {  # session pattern timeout
  local sess="$1" pat="$2" tmo="${3:-15}" i=0
  while [ "$i" -lt "$tmo" ]; do
    tmux capture-pane -t "$sess" -p 2>/dev/null | grep -qF -- "$pat" && return 0
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
  local sess="$1" pat="$2" tmo="${3:-15}" i=0
  while [ "$i" -lt "$tmo" ]; do
    if ! tmux capture-pane -t "$sess" -p 2>/dev/null | grep -qF -- "$pat"; then
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
  if ! python3 - "$settings" <<'PY' >/dev/null 2>&1
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
    if ! python3 - "$access" "$channel" <<'PY' >/dev/null 2>&1
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
  if ! python3 - "$settings" <<'PY' >/dev/null 2>&1
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
  gate_event="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$probe" "$repo" 2>/dev/null)"
  gate_out="$(printf '%s' "$gate_event" | bash "$pg" 2>/dev/null)"
  if ! printf '%s' "$gate_out" | grep -qF '"behavior":"deny"'; then
    echo "  ERROR: $sess: permission gate does NOT deny '$probe' (tampered, stale, or wrong-archetype floor): $pg — $remediation" >&2
    echo "         (gate: harness-audit; bypass with SWARM_UP_SKIP_SANITY=1)" >&2
    return 1
  fi
  if ! python3 - "$settings" <<'PY' >/dev/null 2>&1
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
  qofi_note="$(python3 - "$settings" <<'PY' 2>/dev/null
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
_launch_codex_lead() {  # name repo sess channel
  local name="$1" repo="$2" sess="$3" channel="$4"
  local state_dir="$HOME/.codex/channels/discord-$name"

  if ! command -v bun >/dev/null 2>&1; then
    echo "  ERROR: $sess: engine=codex needs bun on PATH (codex-bridge daemon runtime)" >&2
    return 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    echo "  ERROR: $sess: engine=codex but codex CLI not found — install it and run 'codex login'" >&2
    return 1
  fi
  # node_modules is gitignored — install deps on first launch from a fresh clone.
  if [ ! -d "$SWARM_HOME/codex-bridge/node_modules" ]; then
    echo "  installing codex-bridge deps (first launch)"
    (cd "$SWARM_HOME/codex-bridge" && bun install --no-summary) || {
      echo "  ERROR: $sess: bun install failed in codex-bridge/" >&2
      return 1
    }
  fi

  # Seed the per-swarm state dir (idempotent). Copy the shared Claude-side
  # access.json on first launch; always ensure this swarm's channel group.
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  if [ ! -f "$state_dir/access.json" ] && [ -f "$HOME/.claude/channels/discord/access.json" ]; then
    cp "$HOME/.claude/channels/discord/access.json" "$state_dir/access.json"
    echo "  seeded $state_dir/access.json from the shared Claude-side access.json"
  fi
  if [ -n "$channel" ]; then
    python3 - "$state_dir/access.json" "$channel" <<'PY' || echo "  WARN: could not ensure channel group in $state_dir/access.json" >&2
import json, sys, os
path, chan = sys.argv[1], sys.argv[2]
try:
    a = json.load(open(path))
except Exception:
    a = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}
a.setdefault("groups", {})
if chan not in a["groups"]:
    a["groups"][chan] = {"requireMention": False, "allowFrom": []}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(a, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
  fi

  # Doctrine brief, injected into the first turn of every Codex thread by the
  # daemon. NO apostrophes/single quotes in this text — it rides inside a
  # single-quoted send-keys export below.
  local doctrine="SWARM DOCTRINE: You are the engineering lead for this repo. Before any other work in a new conversation, read CLAUDE.md, ESCALATION.md, and PROJECT_SPEC.md at the repo root and operate per them. Tests are part of every feature; never merge red; never push main (operator-only). Before merging substantive work to dev, run the adversarial review lane: \$SWARM_HOME/bin/adversarial-review.sh (a Claude reviewer from a different model family; advisory, never gating)."

  tmux send-keys -t "$sess" "export DISCORD_STATE_DIR='$state_dir'; export CODEX_BRIDGE_CWD='$repo'; export CODEX_BRIDGE_PREAMBLE_EXTRA='$doctrine'; bun '$SWARM_HOME/codex-bridge/daemon.ts'" C-m

  if _wait_for "$sess" "gateway connected" 30; then
    echo "  codex lead up: $sess (state: $state_dir)"
  else
    echo "  WARN: $sess: codex-bridge did not report 'gateway connected' in 30s — check the pane (token? bun install?)" >&2
  fi
}

launch_one() {  # name repo tokvar [channel] [account] [engine]
  local name="$1" repo="$2" tokvar="$3" channel="${4:-}" account="${5:-}" engine="${6:-claude}"
  local sess="${PREFIX}-${name}"
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "  running: $sess"; return 0
  fi
  [ -d "$repo" ] || { echo "  ERROR: repo not found: $repo" >&2; return 1; }
  # SCOPED token pre-check (F1): read just this swarm's token in a subshell that
  # sources the vault and exits, so the launcher's own env never holds the vault.
  # tokvar is a validated identifier (swarm_conf_parse_line blanks a non-identifier),
  # so the ${!tokvar} indirect deref is safe.
  local token; token="$([ -f "$TOKENS" ] && . "$TOKENS" >/dev/null 2>&1; printf '%s' "${!tokvar:-}")"
  [ -z "$token" ] && { echo "  ERROR: no token in \$$tokvar (check tokens.env)" >&2; return 1; }

  # ---- preflight gates ---------------------------------------------------
  # Refuse to launch a swarm that hasn't been fully configured. Each gate
  # is a cheap read; collectively they turn the three silent half-launches
  # we hit on this mini's first standup into loud refusals with one
  # remediation: re-run swarm-add. Bypass for the "I know what I'm doing"
  # case via SWARM_UP_SKIP_SANITY=1.
  if [ "${SWARM_UP_SKIP_SANITY:-0}" != "1" ]; then
    if ! _preflight_check "$name" "$repo" "$channel" "$account"; then
      return 1
    fi
  fi

  echo "  launching: $sess  ($repo)"
  tmux new-session -d -s "$sess" -c "$repo"
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
  bound_exports="$(swarm_bound_exports "$name" "$channel")"
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
  # A labeled account is a CLAUDE auth partition (CLAUDE_CODE_OAUTH_TOKEN /
  # CLAUDE_CONFIG_DIR). Codex auth is its own `codex login` on the host — a
  # label is meaningless there, so ignore it loudly rather than half-apply it.
  if [ "$engine" = "codex" ] && [ -n "$account" ]; then
    echo "  WARN: $sess: ACCOUNT '$account' ignored — engine=codex uses the host's codex login, not a Claude account partition" >&2
    account=""
  fi
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
  tmux send-keys -t "$sess" "unset ANTHROPIC_API_KEY; export SWARM_HOME='$SWARM_HOME'; $bound_exports; unset IFS; for v in \$(env | sed -n 's/^\(BOT_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(OAUTH_TOKEN_[A-Za-z0-9_]*\)=.*/\1/p'); do unset \"\$v\"; done; export DISCORD_BOT_TOKEN=\"\$(. '$TOKENS' >/dev/null 2>&1; printf '%s' \"\$$tokvar\")\"$acct_env" C-m

  # ---- engine dispatch ----------------------------------------------------
  # engine=codex: the pane runs the codex-bridge DAEMON instead of the Claude
  # Code TUI. Codex CLI has no channels capability, so Discord I/O goes
  # through codex-bridge/daemon.ts (gateway -> gate -> codex exec per message,
  # one resumed Codex thread per chat). Everything above — pane env, token
  # isolation, DISCORD_BOUND_CHANNEL — is engine-neutral and already set.
  if [ "$engine" = "codex" ]; then
    _launch_codex_lead "$name" "$repo" "$sess" "$channel"
    return $?
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
  local repo_type
  repo_type="$(swarm_type_of "$repo")"
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
  local filter="${1:-}"
  while IFS= read -r _line; do
    swarm_conf_parse_line "$_line" || continue
    name="$SWARM_CONF_F_NAME"
    [ -z "$name" ] && continue
    [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
    repo="$SWARM_CONF_F_REPO"
    tokvar="$SWARM_CONF_F_TOKVAR"
    channel="$SWARM_CONF_F_CHANNEL"
    account="$SWARM_CONF_F_ACCOUNT"
    engine="$SWARM_CONF_F_ENGINE"
    launch_one "$name" "$repo" "$tokvar" "$channel" "$account" "$engine" || true
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
}

cmd_down() {  # [name]
  # Optional name filter, symmetric to cmd_up. No-arg = kill all swarm-*
  # sessions (the original behavior); with a name = kill ONLY that one
  # swarm's session. Used by swarm-restart.sh / swarm-update.sh to cycle
  # a single swarm without taking siblings down as a side effect.
  local filter="${1:-}"
  local pattern="^${PREFIX}-"
  [ -n "$filter" ] && pattern="^${PREFIX}-${filter}\$"
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$pattern" | while read -r s; do
    echo "  killing: $s"; tmux kill-session -t "$s" 2>/dev/null || true
  done
}

cmd_status() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}-" || echo "  (no swarm sessions running)"
}

cmd_attach() {  # [name]
  local name="${1:-}"
  if [ -z "$name" ]; then
    {
      echo "running swarm sessions:"
      cmd_status
      echo "usage: swarm-up.sh attach <name>"
    } >&2
    exit 1
  fi
  local sess="${PREFIX}-${name}"
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "swarm-up: no running swarm '$sess' — start it with swarm-up.sh up" >&2
    exit 1
  fi
  exec tmux attach -t "$sess"
}

cmd_watch() {
  echo "Supervising swarm (Ctrl-C to stop). Checking every 30s."
  echo "Note: teammates do NOT survive a relaunch — a respawned lead recreates them per TEAM_LEAD.md."
  echo "Liveness = tmux session exists; when claude exits the pane closes the session, so this is a fair proxy."
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
