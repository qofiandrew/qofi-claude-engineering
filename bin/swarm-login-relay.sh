#!/usr/bin/env bash
# swarm-login-relay.sh — USER-ASSISTED re-auth: run `/login` in a swarm's live
# Claude TUI pane, expose its OAuth URL through an owner-only ephemeral Discord
# interaction, wait for browser authentication, then resume the session and
# VERIFY the credential. This replaces the blob-swap credential model
# (swarm-credswap-keychain.sh) for deployments where credential blobs cannot be
# provisioned out-of-band — Claude Code auth requires the interactive `/login`
# browser flow, so the OPERATOR is the credential source.
#
# ── THE MODEL ────────────────────────────────────────────────────────────────
# ONE swarm pane is enough. The fleet's default account is SHARED keychain
# state (~/.claude): re-authing in one pane re-auths the credential fleet-wide.
# Default target pane: the `qofi-product` swarm (override with the positional
# arg or SWARM_LOGIN_RELAY_SWARM). The selected Claude swarm MUST therefore
# have an EMPTY ACCOUNT field in swarm.conf. A labeled ACCOUNT is an isolated
# per-account lane, not the shared ~/.claude keychain; it is refused before any
# tmux or Discord-control effect, in both default and --dedicated modes. Use the
# per-account failover/account tooling for labeled lanes. There is deliberately
# NO per-account / multi-swarm relay logic here (v2 if ever needed).
#
# Observed `/login` behavior this is built against (falsifiable — if the TUI
# shows something else, STOP and escalate rather than guess):
#   1. `/login` + Enter in a live `claude` TUI prints a login URL to the pane
#      (possibly after a method-picker menu — subscription vs console account —
#      where one Enter accepts the default).
#   2. The operator opens the URL in a browser and authenticates.
#   3. If that browser can reach Claude Code's localhost callback, success is
#      automatic and the pane only needs Enter to resume. If it cannot (phone,
#      SSH/container/other host), the browser displays an authorization#state
#      value. The canonical owner submits that value through a Discord modal;
#      the bridge writes it once to private host state and this relay pipes it
#      into the fresh TUI prompt through `tmux load-buffer -` stdin.
#
# ── STALE-CONTENT DISCIPLINE (the pane is only SEMI-trusted) ─────────────────
# capture-pane returns the WHOLE visible pane — including conversation content
# from before /login was sent (old URLs, old "Login successful" lines, prose
# that happens to contain a pattern word). Pattern-matching that stale content
# mis-drives the flow: a stray picker-Enter, a stale/foreign URL exposed to the
# operator, or a false login-success. So every detector here is FRESHNESS-
# gated against a BASELINE frame captured immediately BEFORE /login is sent:
#   - URL: only a URL that does NOT appear in the baseline counts, and the
#     BOTTOM-most fresh match wins (the login UI renders at the pane bottom).
#   - picker/success: fire only when the count of pattern-matching lines
#     EXCEEDS the baseline's count (position-independent, survives scrolling).
# This also closes the phishing angle where pre-existing pane text (model
# output is semi-untrusted) plants a look-alike oauth URL for the relay to
# expose to the operator: pre-existing == in the baseline == never used.
#
# ── HOW swarm-rotate CALLS US (the credswap seam contract) ───────────────────
# This script drops into swarm-rotate.sh's existing SWARM_CREDSWAP_CMD seam
# with ZERO changes to swarm-rotate.sh / swarm-rotate-tick.sh:
#
#     export SWARM_CREDSWAP_CMD="$SWARM_HOME/bin/swarm-login-relay.sh"
#
# Wire it WITHOUT a "$1" suffix (unlike the keychain adapter). swarm-rotate
# runs the hook as `SWARM_ROTATE_TO_ACCOUNT=<next> sh -c "$CMD" _ <next>`; our
# positional arg is a SWARM name, not an account handle, so the handle must
# arrive via the env only. The handle is received and LOGGED, but the ACCOUNT
# CHOICE happens in the operator's browser — whatever account they log into IS
# the next active account. Rotation then becomes: checkpoint → login-relay
# (operator authenticates the next account) → fleet relaunch on the fresh
# shared-keychain credential. The target swarm row must have ACCOUNT blank;
# this relay never writes or authenticates ~/.claude-accounts/<label>.
#
# Known mapping nuance (documented, accepted): rotate's hook contract only
# distinguishes 0 / 7 / other, so our clean-boundary refusal (exit 3) surfaces
# in rotate's log as "credential swap FAILED (exit 3)" and tick exit 4 — the
# stderr lines this script prints just above rotate's message tell the truth
# ("pane is WORKING"). Non-destructive either way: nothing was sent to the
# pane and the fleet is not relaunched.
#
# Also runnable standalone for a manual re-auth:
#     bin/swarm-login-relay.sh qofi-product
#
# ── SINGLE INSTANCE (mkdir lock, the swarm-watch.sh idiom) ───────────────────
# The operator-auth wait stretches this script's runtime to minutes. launchd
# serializes rotate ticks per label, but nothing stops a MANUAL relay (or a
# manual rotate) from being started while a tick's relay is mid-wait — and the
# second relay's pane guard cannot see the first one (an open /login UI has no
# "esc to interrupt" footer, so the pane reads idle). Two relays interleaving
# keys into one login UI is a wedge, so exactly one instance may run:
# $SWARM_STATE_DIR/swarm-login-relay.lock, atomic mkdir, PID-alive staleness
# recovery, released on exit. Contention REFUSES loud (exit 2).
#
# ── FLOW (fail loud, fail safe — never leave the pane wedged in a login UI) ──
#   1. Resolve the swarm's row from swarm.conf (tmux session, bot-token var,
#      channel id); take the single-instance lock. Fail loud if the session
#      doesn't exist. CLEAN-BOUNDARY guard: `/login` interrupts the TUI, so if
#      pane_working says the pane is mid-turn we REFUSE unless --force (same
#      discipline as swarm-rotate.sh). An UNVERIFIABLE pane (capture failed or
#      empty) also refuses — fail closed.
#   2. Capture the BASELINE frame, send `/login` + Enter, poll capture-pane
#      for a FRESH login URL. If a method-picker renders (fresh), send Enter
#      ONCE to accept the default and keep polling. Timeout → send Escape to
#      back out of the login UI, exit non-zero.
#   3. Post only a generic nonce-bound button to the channel. The updated bridge
#      validates the exact owner/channel/bot/message/expiry and reveals the URL
#      ephemerally. Old bridges have no fresh readiness marker, so we refuse
#      before `/login` instead of falling back to ordinary chat.
#   4. Poll for FRESH login success and the FRESH paste-code prompt. Automatic
#      callback success wins. A modal response is accepted only at the fresh
#      prompt, consumed once, and never enters Discord history/model ingress,
#      shell argv/env, tmux argv, or logs. Timeout posts a notice and Escapes.
#   5. VERIFY via the auth probe and map to the credswap exit-code contract
#      (see EXIT CODES).
#   6. On the success (exit-0) path only: re-check the CLEAN BOUNDARY fleet-
#      wide (the same repo_activity signal swarm-rotate's own guard uses)
#      before returning — rotate relaunches the whole fleet the moment we exit
#      0, and its guard ran BEFORE the minutes-long operator wait, so a lead
#      that started a turn mid-wait would otherwise be torn down mid-turn. We
#      wait up to SWARM_LOGIN_IDLE_TIMEOUT for the fleet to idle; on timeout
#      we WARN loud and proceed (the re-auth is real; failing here would lie
#      to rotate). Then post the confirmation to the channel.
#
# ── EVERY EXTERNAL EFFECT IS AN OVERRIDABLE SEAM (testability) ───────────────
#   SWARM_LOGIN_RELAY_SWARM     default target swarm when no positional arg is
#                               given. Default: "qofi-product".
#   SWARM_TMUX_BIN              tmux binary. Default: "tmux".
#   SWARM_TMUX_PREFIX           session prefix. Default: "swarm" (session is
#                               "<prefix>-<swarm>").
#   SWARM_STATE_DIR             state dir for the single-instance lock.
#                               Default: "$HOME/.config/swarm".
#   SWARM_TOKENS_ENV            the bot-token env file. Default:
#                               "$SWARM_HOME/tokens.env". The token is resolved
#                               by VAR NAME inside a scoped subshell and is
#                               never echoed, logged, or exported here.
#   SWARM_DISCORD_API           REST base. Default: "https://discord.com/api/v10".
#   SWARM_LOGIN_POST_CMD        full override of the Discord post. Run via
#                               `sh -c "$cmd" _ <channel-id> <content>`; exit 0
#                               = delivered. When set, the built-in curl (and
#                               the tokens file) is not used at all.
#   SWARM_LOGIN_CURL_TIMEOUT    --max-time for the built-in curl. Default: 10.
#   SWARM_LOGIN_URL_REGEX       extended regex that extracts the login URL from
#                               a pane capture. Default:
#                               'https://[A-Za-z0-9./?=&_%:~#+-]*oauth[A-Za-z0-9./?=&_%:~#+-]*'
#                               (URL-charset-bounded so adjacent TUI chrome —
#                               box-drawing borders etc. — is never swallowed
#                               into the posted link).
#   SWARM_LOGIN_PICKER_PATTERNS method-picker detection: pipe- or newline-
#                               separated case-insensitive fixed strings.
#                               Default: "select login method" (deliberately
#                               NARROW — a broad word like "subscription" also
#                               appears in ordinary conversation content).
#   SWARM_LOGIN_SUCCESS_PATTERNS login-success detection, same format. Default:
#                               "login successful|successfully logged in"
#                               (deliberately excludes bare "logged in", which
#                               substring-matches "NOT logged in" and ordinary
#                               prose).
#   SWARM_LOGIN_PASTE_PATTERNS  paste-code prompt detector, same format. Default:
#                               "Paste code here if prompted".
#   SWARM_LOGIN_CONTROL_POST_CMD / SWARM_LOGIN_CONTROL_DELETE_CMD
#                               test seams for creating/removing the generic
#                               Discord component message. Production uses REST.
#   SWARM_LOGIN_CONTROL_BOT_ID  test seam for the posting bot identity.
#                               Production resolves `/users/@me` using the same
#                               row token that posts the button.
#   SWARM_LOGIN_URL_TIMEOUT     seconds to wait for the URL to render. Default 45.
#   SWARM_LOGIN_AUTH_TIMEOUT    seconds to wait for the OPERATOR to finish the
#                               browser auth. Default 900 (15 min).
#   SWARM_LOGIN_IDLE_TIMEOUT    seconds to wait (step 6) for the fleet to hit a
#                               clean boundary before handing control back to
#                               rotate's relaunch. Default 900. 0 disables the
#                               re-check.
#   SWARM_LOGIN_POLL_INTERVAL   seconds between capture-pane polls. Default 2.
#   SWARM_LOGIN_VERIFY_ATTEMPTS maximum post-login auth-probe attempts. Default
#                               5. Only exit 1 (credential not verified) is retried;
#                               capped (75) and unexpected verdicts are immediate.
#   SWARM_LOGIN_VERIFY_INTERVAL seconds between those attempts. Default 2.
#   SWARM_LOGIN_AUTHCHECK_CMD   the post-login verify, run via `sh -c`. Default:
#                               bin/swarm-auth-probe.sh (3-way: 0 good / 75
#                               capped / other bad). Its verdict maps to the
#                               credswap contract below.
#   SWARM_STALE_SECONDS         the step-6 boundary window (same signal and
#                               default — 300 — as swarm-rotate/swarm-restart).
#
# ── EXIT CODES (superset of the credswap contract swarm-rotate branches on) ──
#   0 — re-auth complete AND the auth probe authenticates. swarm-rotate treats
#       this as "swap good" and proceeds to the fleet relaunch.
#   7 — re-auth complete, probe says authed-BUT-RATE-LIMITED (probe exit 75).
#       The ring-exhaustion signal, identical to swarm-credswap-keychain.sh
#       exit 7 — swarm-rotate maps it to its own exit 6 and does NOT relaunch.
#   2 — refused / config error: bad usage, unknown swarm, nonempty ACCOUNT
#       (labeled lanes are outside this shared-default-keychain actuator),
#       session absent, missing channel/token wiring, bad timeout/interval
#       value, or another relay instance holds the lock. Nothing was sent to
#       the pane.
#   3 — REFUSED: pane is WORKING (or unverifiable) and --force absent. Nothing
#       was sent to the pane. (Mirrors swarm-rotate's clean-boundary exit 3;
#       under rotation it surfaces as rotate's generic "swap failed" — see the
#       mapping nuance above.)
#   4 — VERIFY failed: the pane reported login success but the auth probe did
#       NOT authenticate. Loud; manual attention.
#   5 — login URL never rendered within SWARM_LOGIN_URL_TIMEOUT. Pane backed
#       out (Escape).
#   6 — secure Discord control publication FAILED. Pane backed out (Escape).
#   8 — operator did not complete the browser auth within
#       SWARM_LOGIN_AUTH_TIMEOUT. Timeout notice posted, pane backed out.
#   9 — re-auth completed, but swarm.conf became malformed during the operator
#       window. Credential is valid; fleet relaunch is held for explicit repair.
#   10 — a private response failed validation or stdin-buffer injection.
#   (Any non-0/non-7 code reads as "swap failed" to swarm-rotate → its exit 5,
#   fleet NOT relaunched. That is the correct fail-safe.)
#
# SECRET DISCIPLINE: OAuth URLs live only in a private 0600 request and an
# owner-only ephemeral interaction. Paste-back values live only in a private
# atomic 0600 response and the pipe to `tmux load-buffer -`; they never become a
# shell variable, process argument/environment, ordinary message, model event,
# or log. The Discord bot Authorization header follows the existing watcher REST
# pattern and is the only credential present in an in-process curl argv.
#
# ── DEDICATED MODE (--dedicated) — the no-restart re-auth model ──────────────
# --dedicated (or SWARM_LOGIN_RELAY_DEDICATED=1) runs /login in an ISOLATED
# throwaway session (SWARM_LOGIN_PROBE_SESSION, default "swarm-login-probe"): a
# plain `claude` on the DEFAULT account, in a trusted cwd, created tall, reused
# across rotations. Because that session does NO CTO work and NO fleet relaunch
# follows a re-auth, the two CTO-pane guards are SKIPPED: the step-1 clean-
# boundary guard (nothing to interrupt) and the step-6 fleet-idle re-check
# (nothing to relaunch). A generic secure-control button posts to the swarm's
# channel; its URL remains ephemeral. This is how swarm-reauth.sh drives us: a
# re-auth that re-authes the shared keychain WITHOUT restarting a single lead.
# The stuck-pane safety net (a lead that didn't adopt the fresh credential) is
# swarm-reauth-verify.sh, run standing by the tick — not this script's concern.
#
# Usage:
#   swarm-login-relay.sh                    # re-auth via the default swarm's CTO pane
#   swarm-login-relay.sh <swarm>            # re-auth via a specific swarm's CTO pane
#   swarm-login-relay.sh --force [<swarm>]  # proceed even if the pane is mid-turn
#   swarm-login-relay.sh --dedicated        # re-auth via the ISOLATED login-probe
#                                           #   session (no CTO pane, no guards)
#   swarm-login-relay.sh -h | --help
#
# Bash 3.2-safe (macOS default). CWD-independent. python3 (JSON + repo_activity)
# and curl are the only non-shell deps, same as swarm-watch.sh.

set -uo pipefail

PROG="swarm-login-relay"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

CONF="$SWARM_HOME/swarm.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"   # swarm_conf_parse_line, pane_working, repo_activity, swarm_account_resolve

usage() { sed -n '2,204p' "$0"; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
FORCE=0
SWARM=""
# --dedicated (or SWARM_LOGIN_RELAY_DEDICATED=1): run /login in an ISOLATED
# throwaway session instead of the swarm's CTO pane. See the DEDICATED-MODE
# block below. The flag wins over the env either way (explicit intent).
DEDICATED="${SWARM_LOGIN_RELAY_DEDICATED:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --force)     FORCE=1; shift ;;
    --dedicated) DEDICATED=1; shift ;;
    -h|--help)   usage 0 ;;
    --*)         echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)           if [ -z "$SWARM" ]; then SWARM="$1"; shift; else echo "$PROG: unexpected arg: $1" >&2; usage 2; fi ;;
  esac
done
[ -z "$SWARM" ] && SWARM="${SWARM_LOGIN_RELAY_SWARM:-qofi-product}"
# Normalize the env toggle: the OFF spellings an operator would plausibly write
# (empty/0/false/no/off, any case) mean OFF; anything else means ON. Without
# this, SWARM_LOGIN_RELAY_DEDICATED=false would silently ENABLE dedicated mode.
case "$(printf '%s' "$DEDICATED" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|off) DEDICATED=0 ;;
  *)                 DEDICATED=1 ;;
esac

TMUX_BIN="${SWARM_TMUX_BIN:-tmux}"
PREFIX="${SWARM_TMUX_PREFIX:-swarm}"
API="${SWARM_DISCORD_API:-https://discord.com/api/v10}"
TOKENS="${SWARM_TOKENS_ENV:-$SWARM_HOME/tokens.env}"
STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
CURL_MAX_TIME="${SWARM_LOGIN_CURL_TIMEOUT:-10}"
# URL-charset-bounded (NOT [^[:space:]]): the login URL renders inside TUI
# chrome, and a permissive class would swallow an adjacent box-drawing border
# into the posted link. Chars beyond this set end the match.
URL_REGEX="${SWARM_LOGIN_URL_REGEX:-https://[A-Za-z0-9./?=&_%:~#+-]*oauth[A-Za-z0-9./?=&_%:~#+-]*}"
# COMPLETENESS gate: a regex match can still be a WIDTH-TRUNCATED fragment (the
# TUI hard-wraps long URLs into separate rows that -J cannot rejoin; a clipped
# link 404s in the operator's browser with "Missing state parameter"). A
# candidate URL must contain this substring — on the observed OAuth shape,
# state= is the LAST parameter, so its presence implies the whole URL survived.
# A truncated candidate is treated as not-yet-rendered: the relay keeps polling
# and, if nothing complete ever renders, times out LOUD (Escape, exit 5) rather
# than posting a broken link. Set empty to disable.
URL_REQUIRE="${SWARM_LOGIN_URL_REQUIRE-state=}"
# NARROW pattern defaults on purpose. Broad words ("subscription", bare
# "logged in") appear in ordinary conversation content that is still visible in
# the capture; the freshness gate below reduces that exposure but the defaults
# must not invite it. Both remain seams.
PICKER_PATTERNS="${SWARM_LOGIN_PICKER_PATTERNS:-select login method}"
SUCCESS_PATTERNS="${SWARM_LOGIN_SUCCESS_PATTERNS:-login successful|successfully logged in}"
PASTE_PATTERNS="${SWARM_LOGIN_PASTE_PATTERNS:-Paste code here if prompted}"
URL_TIMEOUT="${SWARM_LOGIN_URL_TIMEOUT:-45}"
AUTH_TIMEOUT="${SWARM_LOGIN_AUTH_TIMEOUT:-900}"
IDLE_TIMEOUT="${SWARM_LOGIN_IDLE_TIMEOUT:-900}"
POLL_INTERVAL="${SWARM_LOGIN_POLL_INTERVAL:-2}"
VERIFY_ATTEMPTS="${SWARM_LOGIN_VERIFY_ATTEMPTS:-5}"
VERIFY_INTERVAL="${SWARM_LOGIN_VERIFY_INTERVAL:-2}"
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"
AUTHCHECK="${SWARM_LOGIN_AUTHCHECK_CMD:-$SCRIPT_DIR/swarm-auth-probe.sh}"
# Optional explicit host override. When absent, the private access.json owner
# record is authoritative; an upgraded file with exactly one numeric top-level
# principal is accepted as an unambiguous migration fallback.
OWNER_ID="${SWARM_OWNER_DISCORD_ID:-}"
LOGIN_CONTROL_READY_MAX_AGE="${SWARM_LOGIN_CONTROL_READY_MAX_AGE:-90}"
CONTROL_POST_CMD="${SWARM_LOGIN_CONTROL_POST_CMD:-}"
CONTROL_DELETE_CMD="${SWARM_LOGIN_CONTROL_DELETE_CMD:-}"

# ── DEDICATED-MODE knobs (only consulted when DEDICATED=1) ────────────────────
# The isolated login session mirrors swarm-usage-adapter-tui.sh's probe: a plain
# `claude` on the DEFAULT account (shared keychain), in a claude-TRUSTED cwd,
# created tall, reused across rotations, recreated if unhealthy. It is NEVER in
# swarm.conf, so watchers/guards ignore it. (A no-arg `swarm-up down` DOES
# glob-kill every `swarm-*` session including this probe — harmless: it is a
# stateless throwaway, recreated on demand.) Because it does no CTO work and no
# relaunch follows a re-auth, the CTO-pane clean-boundary guard (step 1) and
# the fleet-idle re-check (step 6) are SKIPPED in this mode.
PROBE_SESSION="${SWARM_LOGIN_PROBE_SESSION:-swarm-login-probe}"
PROBE_CWD="${SWARM_LOGIN_PROBE_CWD:-$SWARM_HOME}"
PROBE_LAUNCH="${SWARM_LOGIN_PROBE_LAUNCH:-claude}"
PROBE_BROWSER_POLICY="discord-only-v1"
PROBE_READY_PAT="${SWARM_LOGIN_PROBE_READY_PAT:-for agents|for shortcuts|auto mode}"
PROBE_TRUST_PAT="${SWARM_LOGIN_PROBE_TRUST_PAT:-trust the files|Do you trust|Yes, proceed}"
PROBE_LAUNCH_TIMEOUT="${SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT:-40}"
PROBE_ROWS="${SWARM_LOGIN_PROBE_ROWS:-60}"
# COLS must exceed the OAuth URL's length: the TUI HARD-wraps a too-long URL
# into separate drawn rows (not tmux soft-wraps — `-J` cannot rejoin them), and
# a width-clipped URL is a broken link. The live drill 2026-07-10 posted a
# 200-char fragment of a ~450-char URL ("Missing state parameter") from a
# 200-col pane. 800 is ~2x the observed URL; the URL_REQUIRE gate below fails
# loud if a future URL outgrows even this.
PROBE_COLS="${SWARM_LOGIN_PROBE_COLS:-800}"

# Timeouts feed $((...)) arithmetic — a non-integer would blow up mid-flow (or
# worse, after we already opened the login UI). The poll interval feeds sleep —
# a bad value makes sleep fail instantly and turns both poll loops into hot
# loops (thousands of capture-pane spawns) for up to AUTH_TIMEOUT. Refuse all
# of them up front: config error.
for _tv in "$URL_TIMEOUT" "$AUTH_TIMEOUT" "$IDLE_TIMEOUT" "$STALE_SECONDS"; do
  case "$_tv" in
    ''|*[!0-9]*) echo "$PROG: timeout values must be plain integers (got '$_tv') — check SWARM_LOGIN_URL_TIMEOUT / SWARM_LOGIN_AUTH_TIMEOUT / SWARM_LOGIN_IDLE_TIMEOUT / SWARM_STALE_SECONDS" >&2; exit 2 ;;
  esac
done
case "$VERIFY_ATTEMPTS" in
  ''|*[!0-9]*) echo "$PROG: SWARM_LOGIN_VERIFY_ATTEMPTS must be a plain integer from 1 through 30 (got '$VERIFY_ATTEMPTS')" >&2; exit 2 ;;
esac
if [ "$VERIFY_ATTEMPTS" -lt 1 ] || [ "$VERIFY_ATTEMPTS" -gt 30 ]; then
  echo "$PROG: SWARM_LOGIN_VERIFY_ATTEMPTS must be from 1 through 30 (got '$VERIFY_ATTEMPTS')" >&2
  exit 2
fi
case "$POLL_INTERVAL" in
  ''|.|*[!0-9.]*|*.*.*) echo "$PROG: SWARM_LOGIN_POLL_INTERVAL must be a number in seconds (got '$POLL_INTERVAL')" >&2; exit 2 ;;
esac
case "$VERIFY_INTERVAL" in
  ''|.|*[!0-9.]*|*.*.*) echo "$PROG: SWARM_LOGIN_VERIFY_INTERVAL must be a number in seconds (got '$VERIFY_INTERVAL')" >&2; exit 2 ;;
esac
# The dedicated-session knobs feed $((...)) / tmux geometry only in --dedicated
# mode; validate them there so a bad value fails loud BEFORE we create anything.
if [ "$DEDICATED" = "1" ]; then
  for _dv in "$PROBE_LAUNCH_TIMEOUT" "$PROBE_ROWS" "$PROBE_COLS"; do
    case "$_dv" in
      ''|*[!0-9]*) echo "$PROG: dedicated-mode geometry/timeout values must be plain integers (got '$_dv') — check SWARM_LOGIN_PROBE_LAUNCH_TIMEOUT / SWARM_LOGIN_PROBE_ROWS / SWARM_LOGIN_PROBE_COLS" >&2; exit 2 ;;
    esac
  done
fi

# The rotate handle is informational ONLY — the operator's browser login decides
# the actual account (see header). Logged so the rotate flow is traceable.
if [ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ]; then
  echo "$PROG: invoked as a credswap (SWARM_ROTATE_TO_ACCOUNT='$SWARM_ROTATE_TO_ACCOUNT')."
  echo "$PROG: NOTE — the handle is logged only; the ACCOUNT CHOICE happens in the operator's browser."
fi

# ---------------------------------------------------------------------------
# Resolve the swarm's row: session name, bot-token var (field 3), channel (4).
# ---------------------------------------------------------------------------
swarm_login_validate_config() {
  local _line _trimmed
  while IFS= read -r _line || [ -n "$_line" ]; do
    _trimmed="$(_swarm_trim "$_line")"
    case "$_trimmed" in ''|'#'*) continue ;; esac
    if ! swarm_conf_parse_line "$_line"; then
      echo "$PROG: REFUSED — malformed swarm.conf row makes a shared credential handoff unsafe." >&2
      return 1
    fi
  done < "$CONF"
  return 0
}

swarm_login_validate_config || exit 2

TOKVAR=""
CHANNEL=""
ENGINE=""
ACCOUNT=""
FOUND=0
while IFS= read -r _line || [ -n "$_line" ]; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$SWARM" ]; then
    TOKVAR="$SWARM_CONF_F_TOKVAR"
    CHANNEL="$SWARM_CONF_F_CHANNEL"
    ENGINE="$SWARM_CONF_F_ENGINE"
    ACCOUNT="$SWARM_CONF_F_ACCOUNT"
    FOUND=$((FOUND + 1))
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$FOUND" -eq 0 ]; then
  echo "$PROG: REFUSED — no swarm named '$SWARM' in $CONF." >&2
  if [ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ] && [ "$SWARM" = "${SWARM_ROTATE_TO_ACCOUNT:-}" ]; then
    echo "$PROG: it matches SWARM_ROTATE_TO_ACCOUNT — SWARM_CREDSWAP_CMD is probably wired with a \"\$1\"" >&2
    echo "$PROG: suffix. This relay takes a SWARM name, not an account handle: wire it WITHOUT \"\$1\":" >&2
    echo "$PROG:     export SWARM_CREDSWAP_CMD='\$SWARM_HOME/bin/swarm-login-relay.sh'" >&2
  fi
  exit 2
fi
if [ "$FOUND" -ne 1 ]; then
  echo "$PROG: REFUSED — swarm.conf has $FOUND rows named '$SWARM'; shared re-auth is ambiguous." >&2
  exit 2
fi
if [ "$ENGINE" = "codex" ]; then
  echo "$PROG: REFUSED — swarm '$SWARM' uses engine=codex; /login and Claude Max credential rotation do not apply. Choose a Claude-engine swarm for the login relay." >&2
  exit 2
fi
# This actuator authenticates only Claude Code's shared DEFAULT keychain
# (~/.claude). A labeled row is a different credential/config partition under
# ~/.claude-accounts/<label>; accepting it here would bind the control surface
# to one lane while `/login` (especially the plain dedicated probe) changes
# another. Refuse before resolving access state, checking/creating a tmux
# session, taking the relay lock, publishing control state, or posting Discord.
if [ -n "$ACCOUNT" ]; then
  echo "$PROG: REFUSED — swarm '$SWARM' has ACCOUNT='$ACCOUNT', but this relay only re-authenticates the shared default Claude keychain." >&2
  echo "$PROG: ACCOUNT must be empty; use the per-account failover/account tooling for labeled lanes. No pane or Discord control was touched." >&2
  exit 2
fi
if [ -z "$CHANNEL" ]; then
  echo "$PROG: REFUSED — swarm '$SWARM' has no CHANNEL_ID in swarm.conf; cannot relay a login URL nobody would see." >&2
  exit 2
fi
case "$CHANNEL" in ''|*[!0-9]*) echo "$PROG: REFUSED — channel id for '$SWARM' must be numeric for secure login control." >&2; exit 2 ;; esac

if ! swarm_account_resolve ""; then
  echo "$PROG: REFUSED — could not resolve the shared default Claude account for swarm '$SWARM'." >&2
  exit 2
fi
LOGIN_ACCESS_FILE="${SWARM_LOGIN_ACCESS_FILE:-$SWARM_ACCT_ACCESS_FILE}"
# The bridge pins login control immediately beside the canonical access file.
# Do not accept a second ambient path override: it could split the relay from
# the bridge or redirect OAuth material into a model-readable repository.
LOGIN_CONTROL_DIR="$(dirname "$LOGIN_ACCESS_FILE")/login-control"

# The canonical owner must be pinned by private host state (or supplied by the
# host and agree with it) and present in BOTH ACL layers. A watcher/bot that is
# allowed to speak in the channel is not the human credential principal.
resolve_login_control_owner() {
  /usr/bin/python3 -I -B - "$LOGIN_ACCESS_FILE" "$CHANNEL" "$OWNER_ID" <<'PY'
import json, os, stat, subprocess, sys
path, channel, requested = sys.argv[1:]
def reject_symlinked_ancestors(candidate):
    allowed={'/var':'/private/var','/tmp':'/private/tmp','/etc':'/private/etc'} if sys.platform=='darwin' else {}
    cursor=os.path.abspath(candidate)
    while True:
        try: st=os.lstat(cursor)
        except FileNotFoundError: st=None
        if st is not None and stat.S_ISLNK(st.st_mode):
            if cursor not in allowed or os.path.abspath(os.path.realpath(cursor))!=allowed[cursor]:
                raise ValueError()
        parent=os.path.dirname(cursor)
        if parent==cursor: break
        cursor=parent
try:
    if requested and not requested.isdigit(): raise ValueError()
    before=os.lstat(path); parent=os.path.dirname(path); pst=os.lstat(parent)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1 or before.st_size > 65536): raise ValueError()
    if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
            or pst.st_uid != os.getuid() or stat.S_IMODE(pst.st_mode) & 0o022): raise ValueError()
    # Reject both a redirected state leaf and a symlinked account/config
    # ancestor while tolerating macOS's fixed root aliases.
    reject_symlinked_ancestors(parent)
    expected_parent=os.path.join(os.path.realpath(os.path.dirname(parent)),os.path.basename(parent))
    if os.path.realpath(parent)!=expected_parent: raise ValueError()
    if sys.platform=='darwin':
        for p in (path,parent):
            if subprocess.check_output(['/bin/ls','-lde',p],text=True).split()[0].endswith('+'): raise ValueError()
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        opened=os.fstat(fd); raw=os.read(fd,65537); after=os.fstat(fd)
    finally: os.close(fd)
    if ((opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_uid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_ctime_ns)
            or (after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_nlink,after.st_ctime_ns,after.st_mtime_ns)!=(opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns,opened.st_mtime_ns)
            or len(raw)>65536): raise ValueError()
    cfg=json.loads(raw)
    if not isinstance(cfg,dict): raise ValueError()
    top=cfg.get('allowFrom'); groups=cfg.get('groups'); pinned=cfg.get('loginControlOwnerId')
    if (not isinstance(top,list) or not all(isinstance(v,str) for v in top)
            or not isinstance(groups,dict)): raise ValueError()
    if pinned is not None:
        if not isinstance(pinned,str) or not pinned.isdigit() or pinned not in top: raise ValueError()
        owner=pinned
    elif requested:
        owner=requested
    else:
        candidates=list(dict.fromkeys(v for v in top if v.isdigit()))
        if len(candidates)!=1: raise ValueError()
        owner=candidates[0]
    if requested and requested!=owner: raise ValueError()
    group=groups.get(channel)
    if owner not in top: raise ValueError()
    if not isinstance(group,dict) or owner not in (group.get('allowFrom') or []): raise ValueError()
    print(owner)
except Exception: raise SystemExit(1)
PY
}
OWNER_ID="$(resolve_login_control_owner)"
_owner_rc=$?
if [ "$_owner_rc" -ne 0 ] || [ -z "$OWNER_ID" ]; then
  echo "$PROG: REFUSED — canonical Discord ACL has no unambiguous login-control owner bound to channel $CHANNEL ($LOGIN_ACCESS_FILE)." >&2
  exit 2
fi

# In dedicated mode the target is the ISOLATED login-probe session, NOT the
# swarm's CTO pane — but CHANNEL/TOKVAR still come from the swarm row above, so
# the login URL lands in that swarm's Discord channel (default qofi-product).
if [ "$DEDICATED" = "1" ]; then
  SESS="$PROBE_SESSION"
else
  SESS="${PREFIX}-${SWARM}"
fi

# ---------------------------------------------------------------------------
# Discord post (the swarm-watch.sh pattern). Token resolved by VAR NAME inside
# a scoped subshell — never exported into this process, never echoed. Returns
# non-zero if the message was not delivered.
# ---------------------------------------------------------------------------
post_discord() {  # content -> 0 delivered / 1 not
  local content="$1"
  if [ -n "${SWARM_LOGIN_POST_CMD:-}" ]; then
    sh -c "$SWARM_LOGIN_POST_CMD" _ "$CHANNEL" "$content"
    return $?
  fi
  (
    [ -f "$TOKENS" ] || { echo "$PROG: tokens file not found: $TOKENS" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "$TOKENS"
    _token="${!TOKVAR:-}"
    [ -z "$_token" ] && { echo "$PROG: no token in \$$TOKVAR ($TOKENS)" >&2; exit 1; }
    _payload="$(printf '%s' "$content" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')" || exit 1
    _code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bot $_token" -H "Content-Type: application/json" \
      -d "$_payload" "$API/channels/$CHANNEL/messages")"
    case "$_code" in
      200|201) exit 0 ;;
      *) echo "$PROG: Discord POST failed for channel $CHANNEL (HTTP $_code)" >&2; exit 1 ;;
    esac
  )
}

# Resolve the Discord bot identity from the same private token that will create
# the login-control message.  Readiness is keyed by channel+bot, so a different
# bot bound to the same channel cannot satisfy this relay's capability check.
discord_bot_id() {
  (
    . "$TOKENS" >/dev/null 2>&1 || exit 1
    _token="${!TOKVAR:-}"; [ -n "$_token" ] || exit 1
    _body="$(curl --max-time "$CURL_MAX_TIME" -sS \
      -H "Authorization: Bot $_token" "$API/users/@me")" || exit 1
    printf '%s' "$_body" | /usr/bin/python3 -I -B -c '
import json,sys
try:
    value=json.load(sys.stdin); ident=value.get("id")
    if not isinstance(ident,str) or not ident.isdigit(): raise ValueError()
    print(ident)
except Exception: raise SystemExit(1)
' 2>/dev/null
  )
}

login_control_ready() {
  /usr/bin/python3 -I -B - "$LOGIN_CONTROL_DIR" "$CHANNEL" "$DISCORD_BOT_ID" "$LOGIN_CONTROL_READY_MAX_AGE" <<'PY'
import json, os, re, stat, subprocess, sys, time
root, channel, bot, max_age = sys.argv[1:]
try:
    max_age=int(max_age)
    if max_age < 1 or max_age > 600: raise ValueError()
    rst=os.lstat(root); parent=os.path.dirname(root); pst=os.lstat(parent)
    if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
            or rst.st_uid != os.getuid() or stat.S_IMODE(rst.st_mode) != 0o700): raise ValueError()
    if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
            or pst.st_uid != os.getuid() or stat.S_IMODE(pst.st_mode) & 0o022): raise ValueError()
    expected_parent=os.path.join(os.path.realpath(os.path.dirname(parent)),os.path.basename(parent))
    expected_root=os.path.join(os.path.realpath(parent),os.path.basename(root))
    if os.path.realpath(parent)!=expected_parent or os.path.realpath(root)!=expected_root: raise ValueError()
    if sys.platform=='darwin':
        for p in (root,parent):
            if subprocess.check_output(['/bin/ls','-lde',p],text=True).split()[0].endswith('+'): raise ValueError()
    name='ready-%s-%s.json' % (channel,bot); path=os.path.join(root,name)
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1 or before.st_size > 4096): raise ValueError()
    if sys.platform=='darwin' and subprocess.check_output(['/bin/ls','-lde',path],text=True).split()[0].endswith('+'): raise ValueError()
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        opened=os.fstat(fd); raw=os.read(fd,4097); after=os.fstat(fd)
    finally: os.close(fd)
    if ((opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_uid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_ctime_ns)
            or (after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_nlink,after.st_ctime_ns,after.st_mtime_ns)!=(opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns,opened.st_mtime_ns)
            or len(raw)>4096): raise ValueError()
    value=json.loads(raw); now=int(time.time())
    if (value.get('schema')!='qofi-login-control-ready/v1' or value.get('protocol')!=1
            or value.get('channel_id')!=channel or value.get('bot_user_id')!=bot
            or not re.fullmatch(r'[a-f0-9]{32}',value.get('instance',''))): raise ValueError()
    pid=value.get('pid'); updated=value.get('updated_at')
    if not isinstance(pid,int) or pid < 2 or not isinstance(updated,int): raise ValueError()
    if updated > now+5 or now-updated > max_age: raise ValueError()
    os.kill(pid,0)
except Exception: raise SystemExit(1)
PY
}

# Pre-flight the post path BEFORE touching the pane: if we could never relay
# the URL, opening the login UI would only wedge the pane for nobody. With the
# override seam set we trust the operator's transport; otherwise the tokens
# file must exist and the swarm's var must be non-empty (checked in a scoped
# subshell — the value never enters this process).
if [ -z "${SWARM_LOGIN_POST_CMD:-}" ] || [ -z "$CONTROL_POST_CMD" ]; then
  if [ ! -f "$TOKENS" ]; then
    echo "$PROG: REFUSED — tokens file not found ($TOKENS); could not relay a login URL. Not touching the pane." >&2
    exit 2
  fi
  if ! ( . "$TOKENS"; [ -n "${!TOKVAR:-}" ] ) 2>/dev/null; then
    echo "$PROG: REFUSED — no token in \$$TOKVAR ($TOKENS); could not relay a login URL. Not touching the pane." >&2
    exit 2
  fi
fi

case "$LOGIN_CONTROL_READY_MAX_AGE" in ''|*[!0-9]*) echo "$PROG: REFUSED — SWARM_LOGIN_CONTROL_READY_MAX_AGE must be an integer." >&2; exit 2 ;; esac
DISCORD_BOT_ID="${SWARM_LOGIN_CONTROL_BOT_ID:-}"
if [ -z "$DISCORD_BOT_ID" ]; then
  if ! DISCORD_BOT_ID="$(discord_bot_id)"; then
    echo "$PROG: REFUSED — could not resolve the Discord bot identity for secure login control. Not touching the pane." >&2
    exit 2
  fi
fi
case "$DISCORD_BOT_ID" in ''|*[!0-9]*) echo "$PROG: REFUSED — secure login-control bot id must be numeric." >&2; exit 2 ;; esac
if ! login_control_ready; then
  echo "$PROG: REFUSED — fresh v1 Discord login-control readiness is not live for channel $CHANNEL and bot $DISCORD_BOT_ID." >&2
  echo "$PROG: restart the Claude swarm so the updated bridge is active; no OAuth URL or paste-back code will be sent through ordinary chat." >&2
  exit 2
fi

post_login_control() { # nonce -> prints message_id|bot_id|channel_id
  local nonce="$1" content result response code payload
  content="🔐 **Secure re-auth ready** (swarm '$SWARM'). Only the configured owner can open the private login interaction. The OAuth URL and any paste-back code are never posted to this channel or sent to the swarm."
  if [ -n "$CONTROL_POST_CMD" ]; then
    result="$(sh -c "$CONTROL_POST_CMD" _ "$CHANNEL" "$content" "qofi-login:open:v1:$nonce")" || return 1
  else
    response="$(mktemp "$LOGIN_CONTROL_DIR/.post.XXXXXX")" || return 1
    payload="$(printf '%s\n%s\n' "$content" "qofi-login:open:v1:$nonce" | /usr/bin/python3 -I -B -c '
import json,sys
content=sys.stdin.readline().rstrip("\n"); custom=sys.stdin.readline().rstrip("\n")
print(json.dumps({"content":content,"allowed_mentions":{"parse":[]},"components":[{"type":1,"components":[{"type":2,"style":1,"label":"Open secure login","custom_id":custom}]}]}))
')" || { rm -f "$response"; return 1; }
    code="$(
      (
      . "$TOKENS" >/dev/null 2>&1 || exit 1
      _token="${!TOKVAR:-}"; [ -n "$_token" ] || exit 1
      curl --max-time "$CURL_MAX_TIME" -sS -o "$response" -w '%{http_code}' -X POST \
        -H "Authorization: Bot $_token" -H "Content-Type: application/json" \
        -d "$payload" "$API/channels/$CHANNEL/messages"
      )
    )" || { rm -f "$response"; return 1; }
    case "$code" in 200|201) : ;; *) rm -f "$response"; return 1 ;; esac
    result="$(/usr/bin/python3 -I -B - "$response" "$CHANNEL" "$DISCORD_BOT_ID" <<'PY'
import json,sys
try:
    value=json.load(open(sys.argv[1])); mid=value.get('id'); channel=value.get('channel_id')
    author=(value.get('author') or {}).get('id')
    if not all(isinstance(v,str) and v.isdigit() for v in (mid,channel,author)): raise ValueError()
    if channel!=sys.argv[2] or author!=sys.argv[3]: raise ValueError()
    print('%s|%s|%s' % (mid,author,channel))
except Exception: raise SystemExit(1)
PY
)" || { rm -f "$response"; return 1; }
    rm -f "$response"
  fi
  printf '%s\n' "$result" | /usr/bin/python3 -I -B -c '
import json,re,sys
raw=sys.stdin.read().strip()
try:
    if raw.startswith("{"):
        v=json.loads(raw); vals=(v.get("id"),(v.get("author") or {}).get("id"),v.get("channel_id"))
    else: vals=tuple(raw.split("|"))
    if len(vals)!=3 or not all(isinstance(x,str) and x.isdigit() for x in vals): raise ValueError()
    print("|".join(vals))
except Exception: raise SystemExit(1)
' 2>/dev/null
}

write_login_control_request() { # URL on stdin; nonce message bot expires args
  /usr/bin/python3 -I -B - "$LOGIN_CONTROL_DIR" "$1" "$OWNER_ID" "$CHANNEL" "$2" "$3" "$4" 3<&0 <<'PY'
import json, os, re, stat, sys
root, nonce, owner, channel, message, bot, expires = sys.argv[1:]
url=os.fdopen(3,encoding='utf-8').read()
dfd=None; tmp=None
try:
    expires=int(expires)
    if not re.fullmatch(r'[a-f0-9]{32}',nonce): raise ValueError()
    if not all(v.isdigit() for v in (owner,channel,message,bot)): raise ValueError()
    if len(url)<20 or len(url)>8192 or not url.startswith('https://'): raise ValueError()
    rst=os.lstat(root)
    if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
            or rst.st_uid!=os.getuid() or stat.S_IMODE(rst.st_mode)!=0o700): raise ValueError()
    value={'schema':'qofi-login-control-request/v1','protocol':1,'nonce':nonce,
           'owner_id':owner,'channel_id':channel,'message_id':message,'bot_user_id':bot,
           'expires_at':expires,'oauth_url':url}
    name='request-%s.json' % nonce; tmp='.request-%s.%d.tmp' % (nonce,os.getpid())
    dfd=os.open(root,os.O_RDONLY|getattr(os,'O_DIRECTORY',0))
    flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)
    fd=os.open(tmp,flags,0o600,dir_fd=dfd)
    try:
        data=memoryview((json.dumps(value,separators=(',',':'))+'\n').encode())
        while data:
            written=os.write(fd,data)
            if written <= 0: raise OSError('short login-control request write')
            data=data[written:]
        os.fsync(fd)
    finally: os.close(fd)
    os.rename(tmp,name,src_dir_fd=dfd,dst_dir_fd=dfd)
    try: os.fsync(dfd)
    except OSError: pass
except Exception:
    raise SystemExit(1)
finally:
    if dfd is not None:
        if tmp is not None:
            try: os.unlink(tmp,dir_fd=dfd)
            except FileNotFoundError: pass
            except OSError: pass
        os.close(dfd)
PY
}

delete_login_control_message() {
  local message="$1"
  [ -z "$message" ] && return 0
  if [ -n "$CONTROL_DELETE_CMD" ]; then
    sh -c "$CONTROL_DELETE_CMD" _ "$CHANNEL" "$message" >/dev/null 2>&1 || return 1
    return 0
  fi
  (
    . "$TOKENS" >/dev/null 2>&1 || exit 1
    _token="${!TOKVAR:-}"; [ -n "$_token" ] || exit 1
    _code="$(curl --max-time "$CURL_MAX_TIME" -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bot $_token" "$API/channels/$CHANNEL/messages/$message")"
    case "$_code" in 200|204) exit 0 ;; *) exit 1 ;; esac
  )
}

# ---------------------------------------------------------------------------
# Single-instance lock (the swarm-watch.sh mkdir idiom). Two relays driving
# one login UI interleave keys into a wedge, and the pane guard cannot see a
# sibling relay (an open /login UI reads as "idle"). Contention refuses LOUD —
# unlike the watcher's silent skip, a second relay is an operator error worth
# reporting.
# ---------------------------------------------------------------------------
LOCK="$STATE_DIR/swarm-login-relay.lock"
mkdir -p "$STATE_DIR" 2>/dev/null || true
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  local owner=""
  [ -f "$LOCK/pid" ] && owner="$(tr -d '[:space:]' < "$LOCK/pid" 2>/dev/null)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    return 1   # honest contention — a live relay owns the pane
  fi
  # Stale lock (owner dead or never wrote a PID). Clean and retry once.
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  return 1   # lost the cleanup race; bail
}
if ! acquire_lock; then
  echo "$PROG: REFUSED — another swarm-login-relay is already running (lock: $LOCK)." >&2
  echo "$PROG: a second relay would double-drive the same login UI. If you are sure none is running," >&2
  echo "$PROG: remove the lock dir and re-run." >&2
  exit 2
fi
CONTROL_NONCE=""
CONTROL_MESSAGE_ID=""
cleanup_login_control() {
  if [ -n "$CONTROL_NONCE" ]; then
    rm -f "$LOGIN_CONTROL_DIR/request-$CONTROL_NONCE.json" \
      "$LOGIN_CONTROL_DIR/response-$CONTROL_NONCE.json" 2>/dev/null || true
  fi
  if [ -n "$CONTROL_MESSAGE_ID" ]; then
    delete_login_control_message "$CONTROL_MESSAGE_ID" >/dev/null 2>&1 || true
  fi
}
relay_cleanup() {
  cleanup_login_control
  rm -rf "$LOCK"
}
trap relay_cleanup EXIT

# ---------------------------------------------------------------------------
# Pane helpers.
# ---------------------------------------------------------------------------
# -J joins wrapped lines so a long OAuth URL that soft-wraps in the TUI is
# captured as ONE line the URL regex can match.
pane_capture() { "$TMUX_BIN" capture-pane -p -J -t "$SESS" 2>/dev/null; }
pane_send()    { "$TMUX_BIN" send-keys -t "$SESS" "$@"; }
# back_out — leave the pane OUT of the login UI on every failure path. Never
# lets its own failure mask the primary error.
back_out()     { pane_send Escape >/dev/null 2>&1 || true; }

consume_login_control_response() { # take|discard; take prints code only
  local action="$1"
  /usr/bin/python3 -I -B - "$LOGIN_CONTROL_DIR" "$CONTROL_NONCE" "$OWNER_ID" "$CHANNEL" \
    "$CONTROL_MESSAGE_ID" "$DISCORD_BOT_ID" "$action" <<'PY'
import json, os, re, stat, subprocess, sys, time
root, nonce, owner, channel, message, bot, action=sys.argv[1:]
name='response-%s.json' % nonce; path=os.path.join(root,name)
if action not in ('take','discard'): raise SystemExit(2)
try: before=os.lstat(path)
except FileNotFoundError: raise SystemExit(1)
try:
    if (not re.fullmatch(r'[a-f0-9]{32}',nonce) or not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.getuid()
            or stat.S_IMODE(before.st_mode)!=0o600 or before.st_nlink!=1
            or before.st_size<1 or before.st_size>8192): raise ValueError()
    if sys.platform=='darwin' and subprocess.check_output(['/bin/ls','-lde',path],text=True).split()[0].endswith('+'): raise ValueError()
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        opened=os.fstat(fd); raw=os.read(fd,8193); after=os.fstat(fd)
    finally: os.close(fd)
    if ((opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_uid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_ctime_ns)
            or (after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_nlink,after.st_ctime_ns,after.st_mtime_ns)!=(opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink,opened.st_ctime_ns,opened.st_mtime_ns)
            or len(raw)>8192): raise ValueError()
    value=json.loads(raw); code=value.get('code')
    expected={'schema','protocol','nonce','owner_id','channel_id','message_id','bot_user_id','created_at','expires_at','code'}
    if (set(value)!=expected or value.get('schema')!='qofi-login-control-response/v1' or value.get('protocol')!=1
            or value.get('nonce')!=nonce or value.get('owner_id')!=owner
            or value.get('channel_id')!=channel or value.get('message_id')!=message
            or value.get('bot_user_id')!=bot or not isinstance(value.get('created_at'),int)
            or not isinstance(value.get('expires_at'),int) or value['created_at']>int(time.time())+5
            or value['created_at']>value['expires_at'] or value['expires_at'] < int(time.time()) or not isinstance(code,str)
            or len(code)>2000
            or not re.fullmatch(r'[A-Za-z0-9._~+/=%:-]{1,1900}#[A-Za-z0-9._~+/=%:-]{1,1900}',code)):
        raise ValueError()
    current=os.lstat(path)
    if (current.st_dev,current.st_ino)!=(before.st_dev,before.st_ino): raise ValueError()
    os.unlink(path)
    if action=='take': sys.stdout.write(code)
except Exception:
    raise SystemExit(2)
PY
}

pane_take_and_paste_secret() { # response -> tmux stdin; never a shell variable/argv/log
  local buffer="qofi-login-$CONTROL_NONCE" take_rc load_rc
  local -a pipe_status
  consume_login_control_response take | "$TMUX_BIN" load-buffer -b "$buffer" -
  pipe_status=("${PIPESTATUS[@]}")
  take_rc=${pipe_status[0]}; load_rc=${pipe_status[1]}
  if [ "$take_rc" -ne 0 ] || [ "$load_rc" -ne 0 ]; then
    "$TMUX_BIN" delete-buffer -b "$buffer" >/dev/null 2>&1 || true
    [ "$take_rc" -ne 0 ] && return "$take_rc"
    return 3
  fi
  if ! "$TMUX_BIN" paste-buffer -b "$buffer" -d -t "$SESS"; then
    "$TMUX_BIN" delete-buffer -b "$buffer" >/dev/null 2>&1 || true
    return 1
  fi
  pane_send Enter
}

# pat_lines PATTERNS — normalize a pipe- or newline-separated pattern set to
# one per line, blank lines stripped (a blank pattern line makes grep -f match
# EVERYTHING — same guard as swarm-auth-probe.sh).
pat_lines() { printf '%s' "$1" | tr '|' '\n' | grep -v '^[[:space:]]*$'; }

# count_pattern_lines FRAME PATTERNS — number of FRAME lines containing any of
# the case-insensitive fixed-string PATTERNS. Always prints an integer (grep -c
# prints 0 on no match; anything unparseable clamps to 0).
count_pattern_lines() {
  local n
  n="$(printf '%s\n' "$1" | grep -i -F -c -f <(pat_lines "$2") 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Dedicated-session lifecycle (mirrors swarm-usage-adapter-tui.sh). Only used
# when DEDICATED=1. A plain `claude` on the DEFAULT account in a trusted cwd —
# isolated from every CTO pane, so /login here interrupts nothing.
# ---------------------------------------------------------------------------
probe_match_pat() { printf '%s' "$1" | grep -q -i -E "$2" 2>/dev/null; }

# probe_session_ready — the dedicated session exists AND shows an idle claude
# prompt (ready marker present, not mid-turn). A crashed/exited claude (bare
# shell) fails this, triggering recreation.
probe_session_ready() {
  "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null || return 1
  # A probe created before the Discord-only policy may still let Claude open a
  # local browser. Never reuse it: the probe is stateless, so recreation is the
  # safe migration boundary.
  [ "$("$TMUX_BIN" show-options -qv -t "$SESS" @qofi_login_browser_policy 2>/dev/null)" = "$PROBE_BROWSER_POLICY" ] \
    || return 1
  local frame; frame="$(pane_capture)"
  [ -z "$frame" ] && return 1
  probe_match_pat "$frame" "$PROBE_READY_PAT" || return 1
  printf '%s' "$frame" | grep -qF 'esc to interrupt' && return 1   # mid-turn: not ready
  return 0
}

# create_probe_session — (re)create the dedicated login-probe session: a plain
# claude on the default account, in a trusted cwd, at PROBE_ROWS height. Returns
# 0 when the TUI is idle-ready, 1 otherwise (and kills the half-built session).
create_probe_session() {
  "$TMUX_BIN" kill-session -t "$SESS" 2>/dev/null || true
  "$TMUX_BIN" new-session -d -s "$SESS" -x "$PROBE_COLS" -y "$PROBE_ROWS" 2>/dev/null \
    || { echo "$PROG: could not create login-probe session '$SESS'" >&2; return 1; }
  if ! "$TMUX_BIN" set-option -t "$SESS" @qofi_login_browser_policy "$PROBE_BROWSER_POLICY" 2>/dev/null; then
    echo "$PROG: could not bind the Discord-only browser policy to login-probe session '$SESS'" >&2
    "$TMUX_BIN" kill-session -t "$SESS" 2>/dev/null || true
    return 1
  fi
  # API keys unset so the probe uses the Max keychain (default account) — the
  # fleet's shared credential, which is exactly what /login here re-auths.
  # Browser launching is deliberately refused: the owner opens the ephemeral
  # OAuth interaction from Discord, never from this unattended Mac. BROWSER is
  # the standard launcher override; NO_BROWSER also pins the intent for clients
  # that support the explicit convention. exec replaces the shell.
  "$TMUX_BIN" send-keys -t "$SESS" "cd $(printf '%q' "$PROBE_CWD") && unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN && export BROWSER=/usr/bin/false NO_BROWSER=1 && exec $PROBE_LAUNCH" Enter 2>/dev/null || true

  local _deadline=$((SECONDS + PROBE_LAUNCH_TIMEOUT)) _trusted=0 _frame
  while :; do
    _frame="$(pane_capture)"
    if probe_match_pat "$_frame" "$PROBE_READY_PAT" && ! printf '%s' "$_frame" | grep -qF 'esc to interrupt'; then
      return 0
    fi
    if [ "$_trusted" -eq 0 ] && probe_match_pat "$_frame" "$PROBE_TRUST_PAT"; then
      # Accept a one-time trust/confirm prompt (default option is "Yes, proceed").
      "$TMUX_BIN" send-keys -t "$SESS" Enter 2>/dev/null || true
      _trusted=1
    else
      # A freshly-created DETACHED session often captures BLANK until a redraw;
      # Ctrl-L at the prompt is a harmless repaint nudge (never submits input).
      "$TMUX_BIN" send-keys -t "$SESS" C-l 2>/dev/null || true
    fi
    if [ "$SECONDS" -ge "$_deadline" ]; then
      echo "$PROG: login-probe session '$SESS' did not become idle-ready within ${PROBE_LAUNCH_TIMEOUT}s." >&2
      "$TMUX_BIN" kill-session -t "$SESS" 2>/dev/null || true
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# ensure_probe_session — reuse a healthy login-probe session, else (re)create it.
ensure_probe_session() {
  probe_session_ready && return 0
  create_probe_session
}

# ---------------------------------------------------------------------------
# Step 1/6 — session + clean-boundary guard.
# ---------------------------------------------------------------------------
if ! command -v "$TMUX_BIN" >/dev/null 2>&1; then
  echo "$PROG: REFUSED — tmux binary '$TMUX_BIN' not found." >&2
  exit 2
fi

if [ "$DEDICATED" = "1" ]; then
  # DEDICATED: drive an ISOLATED throwaway session — never a CTO pane. There is
  # NO clean-boundary guard here: the probe session does no CTO work, so /login
  # interrupts nothing, and no fleet relaunch follows a re-auth (see step 6).
  echo "$PROG: step 1/6 — DEDICATED mode: isolated login session '$SESS' (secure control → swarm '$SWARM' channel $CHANNEL)"
  if ! ensure_probe_session; then
    echo "$PROG: REFUSED — could not stand up a healthy isolated login session '$SESS'. Nothing sent." >&2
    exit 2
  fi
else
  echo "$PROG: step 1/6 — target swarm '$SWARM' (session '$SESS', channel $CHANNEL)"
  if ! "$TMUX_BIN" has-session -t "$SESS" 2>/dev/null; then
    echo "$PROG: REFUSED — tmux session '$SESS' does not exist. Bring the swarm up first (swarm-up.sh up $SWARM)." >&2
    exit 2
  fi
  # `/login` interrupts the TUI, so it must fire at a clean boundary — the same
  # discipline swarm-rotate.sh enforces. pane_working: 0=working, 1=idle,
  # 2=uncertain. Working refuses; UNCERTAIN also refuses (fail closed — we will
  # not interrupt a pane we cannot read). --force overrides both.
  pane_working "$SESS" "$TMUX_BIN"; pw_rc=$?
  case "$pw_rc" in
    1) : ;;  # idle at the prompt — the clean boundary we want
    0)
      if [ "$FORCE" -eq 1 ]; then
        echo "$PROG: WARNING — pane is mid-turn; proceeding because --force (/login interrupts the turn)." >&2
      else
        echo "$PROG: REFUSED — pane '$SESS' is WORKING (mid-turn). /login would interrupt it." >&2
        echo "$PROG: wait for the turn to finish or pass --force." >&2
        exit 3
      fi
      ;;
    *)
      if [ "$FORCE" -eq 1 ]; then
        echo "$PROG: WARNING — pane state UNVERIFIABLE (capture failed/empty); proceeding because --force." >&2
      else
        echo "$PROG: REFUSED — cannot verify pane state for '$SESS' (capture failed or empty). Fail closed: not sending /login blind. Pass --force to override." >&2
        exit 3
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Step 2/6 — baseline, send /login, scrape a FRESH URL.
# ---------------------------------------------------------------------------
# BASELINE: everything visible in the pane BEFORE /login is stale by
# definition. Detectors below fire only on content that goes BEYOND it —
# see "STALE-CONTENT DISCIPLINE" in the header.
if [ "$DEDICATED" = "1" ]; then
  # A freshly-created detached probe session can capture BLANK until a redraw,
  # which would make the baseline miss pre-existing content. Ctrl-L is a harmless
  # repaint at the idle prompt (never submits input).
  pane_send C-l >/dev/null 2>&1 || true
  sleep "$POLL_INTERVAL"
fi
BASELINE_FRAME="$(pane_capture)"
BASE_URLS="$(printf '%s\n' "$BASELINE_FRAME" | grep -oE "$URL_REGEX" 2>/dev/null || true)"
PICKER_BASE_N="$(count_pattern_lines "$BASELINE_FRAME" "$PICKER_PATTERNS")"
SUCCESS_BASE_N="$(count_pattern_lines "$BASELINE_FRAME" "$SUCCESS_PATTERNS")"
PASTE_BASE_N="$(count_pattern_lines "$BASELINE_FRAME" "$PASTE_PATTERNS")"

# extract_fresh_url FRAME — the BOTTOM-most URL-regex match that is not one of
# the baseline's matches (the login UI renders at the pane bottom; anything
# already visible pre-/login is stale or foreign). The sentinel keeps the
# grep -f pattern file non-empty when the baseline had no URLs.
extract_fresh_url() {
  printf '%s\n' "$1" | grep -oE "$URL_REGEX" 2>/dev/null \
    | grep -v -x -F -f <(printf '%s\n' "$BASE_URLS" '__swarm-login-relay-url-sentinel__') 2>/dev/null \
    | tail -n 1
}

echo "$PROG: step 2/6 — sending /login to '$SESS' and waiting for the login URL (timeout ${URL_TIMEOUT}s)"
# C-u first: clear any half-typed prompt content so "/login" lands clean.
if ! pane_send C-u "/login" Enter; then
  echo "$PROG: FAILED — could not send keys to '$SESS'." >&2
  exit 2
fi

URL=""
PICKER_SENT=0
TRUNC_WARNED=0
PASTE_READY=0
_deadline=$((SECONDS + URL_TIMEOUT))
while :; do
  _frame="$(pane_capture)"
  if [ "$(count_pattern_lines "$_frame" "$PASTE_PATTERNS")" -gt "$PASTE_BASE_N" ]; then
    PASTE_READY=1
  fi
  URL="$(extract_fresh_url "$_frame")"
  # COMPLETENESS gate (see URL_REQUIRE above): a width-truncated fragment must
  # never be posted — treat it as not-yet-rendered and keep polling; the
  # timeout path fails loud instead of shipping a broken link.
  if [ -n "$URL" ] && [ -n "$URL_REQUIRE" ] && ! printf '%s' "$URL" | grep -qF -- "$URL_REQUIRE"; then
    if [ "$TRUNC_WARNED" -eq 0 ]; then
      echo "$PROG: WARNING — candidate URL (${#URL} chars) lacks '$URL_REQUIRE'; likely WIDTH-TRUNCATED by the pane. Not publishing it to private control state. Widen SWARM_LOGIN_PROBE_COLS (or the target pane) if this persists to timeout." >&2
      TRUNC_WARNED=1
    fi
    URL=""
  fi
  [ -n "$URL" ] && break
  # Method-picker (subscription vs console account): accept the default with
  # ONE Enter, once, and keep polling for the URL. Freshness-gated so stale
  # pane text can never burn the once-flag before the real picker renders.
  if [ "$PICKER_SENT" -eq 0 ] && [ "$(count_pattern_lines "$_frame" "$PICKER_PATTERNS")" -gt "$PICKER_BASE_N" ]; then
    echo "$PROG:   method-picker detected — sending Enter once to accept the default"
    pane_send Enter || true
    PICKER_SENT=1
  fi
  if [ "$SECONDS" -ge "$_deadline" ]; then
    echo "$PROG: FAILED — no fresh login URL rendered within ${URL_TIMEOUT}s. Backing out of the login UI (Escape)." >&2
    echo "$PROG: if the TUI showed something unexpected (code paste-back, different layout), capture the pane and escalate — do not guess." >&2
    back_out
    exit 5
  fi
  sleep "$POLL_INTERVAL"
done
echo "$PROG:   fresh login URL captured (${#URL} chars)"

# ---------------------------------------------------------------------------
# Step 3/6 — publish a generic control button; keep the URL private.
# ---------------------------------------------------------------------------
echo "$PROG: step 3/6 — publishing the secure login control to Discord channel $CHANNEL (OAuth URL remains private)"
_rotmsg=""
[ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ] && _rotmsg=" Rotation target handle: '$SWARM_ROTATE_TO_ACCOUNT'."
CONTROL_NONCE="$(/usr/bin/python3 -I -B -c 'import secrets; print(secrets.token_hex(16))')" || CONTROL_NONCE=""
case "$CONTROL_NONCE" in *[!a-f0-9]*) CONTROL_NONCE="" ;; esac
if [ "${#CONTROL_NONCE}" -ne 32 ]; then
  echo "$PROG: FAILED — could not create a 128-bit login-control nonce." >&2
  back_out
  exit 6
fi
CONTROL_EXPIRES=$(( $(date +%s) + AUTH_TIMEOUT ))
if ! _control_binding="$(post_login_control "$CONTROL_NONCE")"; then
  echo "$PROG: FAILED — could not post the generic secure login control. The operator never received a private interaction," >&2
  echo "$PROG: so we are NOT leaving the pane wedged in a login modal: backing out (Escape) and failing loud." >&2
  back_out
  exit 6
fi
IFS='|' read -r CONTROL_MESSAGE_ID _control_bot _control_channel <<EOF
$_control_binding
EOF
if [ "$_control_bot" != "$DISCORD_BOT_ID" ] || [ "$_control_channel" != "$CHANNEL" ]; then
  echo "$PROG: FAILED — Discord login-control response did not bind the expected bot/channel." >&2
  back_out
  exit 6
fi
if ! printf '%s' "$URL" | write_login_control_request "$CONTROL_NONCE" "$CONTROL_MESSAGE_ID" "$DISCORD_BOT_ID" "$CONTROL_EXPIRES"; then
  echo "$PROG: FAILED — could not publish the private nonce-bound login request; removing the generic control and backing out." >&2
  back_out
  exit 6
fi
URL="" # never retain the OAuth URL past private handoff publication
echo "$PROG:   secure control posted — waiting for owner authentication (automatic callback or private modal paste-back)"

# ---------------------------------------------------------------------------
# Step 4/6 — wait for the operator to complete the browser auth.
# ---------------------------------------------------------------------------
# Freshness-gated like the picker: success fires only when the pane shows MORE
# success-pattern lines than the baseline did, so a stale "Login successful"
# from a previous run (or prose containing a success phrase) cannot end the
# operator's window early.
echo "$PROG: step 4/6 — polling for login success (timeout ${AUTH_TIMEOUT}s)"
_ok=0
_code_injected=0
_deadline=$((SECONDS + AUTH_TIMEOUT))
while :; do
  _frame="$(pane_capture)"
  # The automatic localhost callback wins every race.  If an unused modal
  # response exists at the same time, discard it without ever injecting it.
  if [ "$(count_pattern_lines "$_frame" "$SUCCESS_PATTERNS")" -gt "$SUCCESS_BASE_N" ]; then
    consume_login_control_response discard >/dev/null 2>&1 || true
    _ok=1
    break
  fi
  if [ "$(count_pattern_lines "$_frame" "$PASTE_PATTERNS")" -gt "$PASTE_BASE_N" ]; then
    PASTE_READY=1
  fi
  if [ "$PASTE_READY" -eq 1 ] && [ "$_code_injected" -eq 0 ]; then
    pane_take_and_paste_secret; _take_rc=$?
    case "$_take_rc" in
      0)
        _code_injected=1
        echo "$PROG:   private paste-back received and injected into the fresh Claude prompt"
        ;;
      1) : ;; # no response yet
      2)
        echo "$PROG: FAILED — private paste-back response failed its owner/channel/nonce/expiry/file boundary." >&2
        back_out
        exit 10
        ;;
      *)
        echo "$PROG: FAILED — secure paste-back was received but exact tmux stdin-buffer injection failed." >&2
        back_out
        exit 10
        ;;
    esac
  fi
  if [ "$SECONDS" -ge "$_deadline" ]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done
if [ "$_ok" -ne 1 ]; then
  echo "$PROG: FAILED — login not completed within ${AUTH_TIMEOUT}s. Posting a timeout notice, backing out (Escape)." >&2
  post_discord "⏰ **Re-auth timed out** (swarm '$SWARM') — the login link expired unused after $((AUTH_TIMEOUT / 60)) min. The login UI was backed out; the pane is NOT stuck. Re-run bin/swarm-login-relay.sh when you're ready." \
    || echo "$PROG: WARNING — the timeout notice ALSO failed to post; operator is unnotified." >&2
  back_out
  exit 8
fi

# Login succeeded in the browser; the console only needs Enter to finish and
# resume the session (observed behavior — see header).
echo "$PROG:   login success detected — sending Enter to resume the session"
pane_send Enter || true

# ---------------------------------------------------------------------------
# Step 5/6 — VERIFY and map to the credswap exit contract.
# ---------------------------------------------------------------------------
echo "$PROG: step 5/6 — verifying the fresh credential (auth probe)"
probe_attempt=1
sh -c "$AUTHCHECK"; probe_rc=$?
while [ "$probe_rc" -eq 1 ] && [ "$probe_attempt" -lt "$VERIFY_ATTEMPTS" ]; do
  echo "$PROG:   credential not yet verified (probe attempt $probe_attempt/$VERIFY_ATTEMPTS); retrying in ${VERIFY_INTERVAL}s"
  sleep "$VERIFY_INTERVAL"
  probe_attempt=$((probe_attempt + 1))
  sh -c "$AUTHCHECK"; probe_rc=$?
done
if [ "$probe_rc" -eq 0 ] && [ "$probe_attempt" -gt 1 ]; then
  echo "$PROG:   fresh credential verified on probe attempt $probe_attempt/$VERIFY_ATTEMPTS"
fi
case "$probe_rc" in
  0) : ;;  # good — proceed to the boundary re-check + confirmation below
  75)
    echo "$PROG: authed-but-CAPPED — the account the operator logged into authenticates but is RATE-LIMITED." >&2
    echo "$PROG: exiting 7 (ring-exhaustion signal, credswap contract) — the caller must escalate, not relaunch." >&2
    post_discord "⚠️ **Re-auth landed on a CAPPED account** (swarm '$SWARM') — the credential works but the account is rate-limited. Rotation will stop loud (ring exhaustion); log into an account with headroom." \
      || echo "$PROG: WARNING — capped notice failed to post." >&2
    exit 7
    ;;
  *)
    echo "$PROG: VERIFY FAILED — the pane reported login success but the auth probe did not authenticate (probe exit $probe_rc)." >&2
    echo "$PROG: manual attention needed; exiting 4." >&2
    post_discord "❌ **Re-auth verify FAILED** (swarm '$SWARM') — the pane showed login success but the auth probe still fails (exit $probe_rc). Manual attention needed." \
      || echo "$PROG: WARNING — verify-failure notice failed to post." >&2
    exit 4
    ;;
esac

# ---------------------------------------------------------------------------
# Step 6/6 — clean-boundary RE-CHECK, then confirm and hand back to rotate.
# ---------------------------------------------------------------------------
# swarm-rotate ran its fleet-wide clean-boundary guard BEFORE this hook, but
# the operator wait above can last minutes — a Discord directive landing
# mid-wait puts a lead mid-turn, and rotate relaunches (fleet down+up) the
# moment we exit 0 with NO re-check. So we re-verify the SAME signal rotate's
# guard uses (repo_activity per swarm.conf row, live sessions only) and wait —
# bounded by SWARM_LOGIN_IDLE_TIMEOUT — for the fleet to idle. On timeout we
# WARN loud and proceed: the re-auth is real, and exiting non-zero here would
# lie to rotate ("swap failed") and strand a good credential.
fleet_working() {  # -> prints " name(ages)" for each WORKING swarm; empty = idle
  local out=""
  while IFS= read -r _line; do
    if ! swarm_conf_parse_line "$_line"; then
      return 2
    fi
    [ "$SWARM_CONF_F_ENGINE" = "codex" ] && continue
    [ -z "$SWARM_CONF_F_NAME" ] && continue
    [ -z "$SWARM_CONF_F_REPO" ] && continue
    "$TMUX_BIN" has-session -t "${PREFIX}-${SWARM_CONF_F_NAME}" 2>/dev/null || continue
    if ! swarm_account_resolve "$SWARM_CONF_F_ACCOUNT"; then
      # Same fail-direction as swarm-rotate's guard: an unresolvable account
      # means we cannot probe — treat as WORKING so we never wave a relaunch
      # through blind.
      out="$out ${SWARM_CONF_F_NAME}(bad-account)"
      continue
    fi
    [ -d "$SWARM_ACCT_PROJECTS_DIR" ] || continue
    _act="$(repo_activity "$SWARM_CONF_F_REPO" "$SWARM_ACCT_PROJECTS_DIR" "$STALE_SECONDS")"
    _age="${_act%%|*}"
    case "$_age" in ''|*[!0-9]*) _age="$SWARM_NO_TRANSCRIPT_AGE" ;; esac
    if [ "$_age" -ne "$SWARM_NO_TRANSCRIPT_AGE" ] && [ "$_age" -le "$STALE_SECONDS" ]; then
      out="$out ${SWARM_CONF_F_NAME}(${_age}s)"
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  printf '%s' "$out"
}

post_auth_config_hold() {
  echo "$PROG: POST-AUTH HOLD — swarm.conf became malformed after authentication; the credential changed, but no fleet relaunch is safe." >&2
  post_discord "⚠️ **Re-auth completed, relaunch HELD** (swarm '$SWARM') — swarm.conf changed or became malformed during login. Repair the config and relaunch explicitly." \
    || echo "$PROG: WARNING — post-auth hold notice failed to post." >&2
  exit 9
}

if [ "$DEDICATED" = "1" ]; then
  # No fleet re-check: nothing restarts after a dedicated-session re-auth, so
  # there is no relaunch to protect a mid-turn lead from. The panes keep running
  # untouched; the stuck-pane safety net lives in swarm-reauth-verify.sh.
  echo "$PROG: step 6/6 — DEDICATED mode: no fleet re-check (no relaunch follows a re-auth)."
elif [ "$IDLE_TIMEOUT" -gt 0 ]; then
  echo "$PROG: step 6/6 — re-checking the clean boundary before handing back to rotate (timeout ${IDLE_TIMEOUT}s)"
  _deadline=$((SECONDS + IDLE_TIMEOUT))
  swarm_login_validate_config || post_auth_config_hold
  if ! _working="$(fleet_working)"; then post_auth_config_hold; fi
  while [ -n "$_working" ]; do
    if [ "$SECONDS" -ge "$_deadline" ]; then
      echo "$PROG: WARNING — fleet still WORKING after ${IDLE_TIMEOUT}s:$_working" >&2
      echo "$PROG: proceeding anyway (the re-auth is real and rotate owns the relaunch), but the relaunch" >&2
      echo "$PROG: may interrupt those swarms mid-turn. Uncommitted post-checkpoint work there is at risk." >&2
      break
    fi
    echo "$PROG:   waiting for a clean boundary — working:$_working"
    sleep "$POLL_INTERVAL"
    if ! _working="$(fleet_working)"; then post_auth_config_hold; fi
  done
else
  echo "$PROG: step 6/6 — boundary re-check disabled (SWARM_LOGIN_IDLE_TIMEOUT=0)"
fi

# Bind the successful handoff to one final fully parseable fleet snapshot. The
# caller also revalidates before teardown; this closes the relay's own long
# operator-auth window without pretending a completed credential change failed.
swarm_login_validate_config || post_auth_config_hold

if [ "$DEDICATED" = "1" ]; then
  echo "$PROG: DONE — re-auth complete; credential verified (isolated session; no fleet restart)."
  post_discord "✅ **Re-auth complete** (swarm '$SWARM') — credential verified via the isolated login session. Running leads keep their state; no restart." \
    || echo "$PROG: WARNING — success confirmation failed to post (re-auth itself is DONE)." >&2
else
  echo "$PROG: DONE — re-auth complete; credential verified. (swarm-rotate proceeds to relaunch.)"
  post_discord "✅ **Re-auth complete** (swarm '$SWARM') — credential verified; session resumed. Rotation proceeds." \
    || echo "$PROG: WARNING — success confirmation failed to post (re-auth itself is DONE)." >&2
fi
exit 0
