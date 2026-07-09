#!/usr/bin/env bash
# swarm-login-relay.sh — USER-ASSISTED re-auth: run `/login` in a swarm's live
# Claude TUI pane, relay the OAuth URL to the operator over Discord, wait for
# the operator to authenticate in their browser, then resume the session and
# VERIFY the credential. This replaces the blob-swap credential model
# (swarm-credswap-keychain.sh) for deployments where credential blobs cannot be
# provisioned out-of-band — Claude Code auth requires the interactive `/login`
# browser flow, so the OPERATOR is the credential source.
#
# ── THE MODEL ────────────────────────────────────────────────────────────────
# ONE swarm pane is enough. The fleet's default account is SHARED keychain
# state (~/.claude): re-authing in one pane re-auths the credential fleet-wide.
# Default target pane: the `qofi-product` swarm (override with the positional
# arg or SWARM_LOGIN_RELAY_SWARM). There is deliberately NO per-account /
# multi-swarm relay logic (v2 if ever needed).
#
# Observed `/login` behavior this is built against (falsifiable — if the TUI
# shows something else, STOP and escalate rather than guess):
#   1. `/login` + Enter in a live `claude` TUI prints a login URL to the pane
#      (possibly after a method-picker menu — subscription vs console account —
#      where one Enter accepts the default).
#   2. The operator opens the URL in a browser and authenticates.
#   3. After browser auth completes, the pane only needs ENTER pressed to
#      finish and resume the session. No code paste-back is required.
#
# ── STALE-CONTENT DISCIPLINE (the pane is only SEMI-trusted) ─────────────────
# capture-pane returns the WHOLE visible pane — including conversation content
# from before /login was sent (old URLs, old "Login successful" lines, prose
# that happens to contain a pattern word). Pattern-matching that stale content
# mis-drives the flow: a stray picker-Enter, a stale/foreign URL posted to the
# operator, or a false login-success. So every detector here is FRESHNESS-
# gated against a BASELINE frame captured immediately BEFORE /login is sent:
#   - URL: only a URL that does NOT appear in the baseline counts, and the
#     BOTTOM-most fresh match wins (the login UI renders at the pane bottom).
#   - picker/success: fire only when the count of pattern-matching lines
#     EXCEEDS the baseline's count (position-independent, survives scrolling).
# This also closes the phishing angle where pre-existing pane text (model
# output is semi-untrusted) plants a look-alike oauth URL for the relay to
# forward to the operator: pre-existing == in the baseline == never posted.
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
# shared-keychain credential.
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
#   3. Post the URL to the swarm's Discord channel (direct REST curl with the
#      swarm's own bot token — the exact swarm-watch.sh pattern). If the post
#      fails the operator never sees the link: Escape out of the login UI and
#      exit LOUD (never leave a login modal open that nobody knows about).
#   4. Poll the pane for FRESH login success (long timeout — the operator is
#      a human). On success send Enter to resume the session. On timeout:
#      post a timeout notice to the channel, Escape, exit non-zero.
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
#   SWARM_LOGIN_URL_TIMEOUT     seconds to wait for the URL to render. Default 45.
#   SWARM_LOGIN_AUTH_TIMEOUT    seconds to wait for the OPERATOR to finish the
#                               browser auth. Default 900 (15 min).
#   SWARM_LOGIN_IDLE_TIMEOUT    seconds to wait (step 6) for the fleet to hit a
#                               clean boundary before handing control back to
#                               rotate's relaunch. Default 900. 0 disables the
#                               re-check.
#   SWARM_LOGIN_POLL_INTERVAL   seconds between capture-pane polls. Default 2.
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
#   2 — refused / config error: bad usage, unknown swarm, session absent,
#       missing channel/token wiring, bad timeout/interval value, or another
#       relay instance holds the lock. Nothing was sent to the pane.
#   3 — REFUSED: pane is WORKING (or unverifiable) and --force absent. Nothing
#       was sent to the pane. (Mirrors swarm-rotate's clean-boundary exit 3;
#       under rotation it surfaces as rotate's generic "swap failed" — see the
#       mapping nuance above.)
#   4 — VERIFY failed: the pane reported login success but the auth probe did
#       NOT authenticate. Loud; manual attention.
#   5 — login URL never rendered within SWARM_LOGIN_URL_TIMEOUT. Pane backed
#       out (Escape).
#   6 — Discord post of the URL FAILED. Pane backed out (Escape) — we never
#       leave a login modal open that the operator doesn't know about.
#   8 — operator did not complete the browser auth within
#       SWARM_LOGIN_AUTH_TIMEOUT. Timeout notice posted, pane backed out.
#   (Any non-0/non-7 code reads as "swap failed" to swarm-rotate → its exit 5,
#   fleet NOT relaunched. That is the correct fail-safe.)
#
# SECRET DISCIPLINE: this script never prints/logs a token value and never puts
# a secret on argv beyond what the existing swarm-watch.sh curl pattern already
# does (the Authorization header of the in-process curl call).
#
# Usage:
#   swarm-login-relay.sh                    # re-auth via the default swarm's pane
#   swarm-login-relay.sh <swarm>            # re-auth via a specific swarm's pane
#   swarm-login-relay.sh --force [<swarm>]  # proceed even if the pane is mid-turn
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

usage() { sed -n '1,195p' "$0"; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------
FORCE=0
SWARM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)         if [ -z "$SWARM" ]; then SWARM="$1"; shift; else echo "$PROG: unexpected arg: $1" >&2; usage 2; fi ;;
  esac
done
[ -z "$SWARM" ] && SWARM="${SWARM_LOGIN_RELAY_SWARM:-qofi-product}"

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
# NARROW pattern defaults on purpose. Broad words ("subscription", bare
# "logged in") appear in ordinary conversation content that is still visible in
# the capture; the freshness gate below reduces that exposure but the defaults
# must not invite it. Both remain seams.
PICKER_PATTERNS="${SWARM_LOGIN_PICKER_PATTERNS:-select login method}"
SUCCESS_PATTERNS="${SWARM_LOGIN_SUCCESS_PATTERNS:-login successful|successfully logged in}"
URL_TIMEOUT="${SWARM_LOGIN_URL_TIMEOUT:-45}"
AUTH_TIMEOUT="${SWARM_LOGIN_AUTH_TIMEOUT:-900}"
IDLE_TIMEOUT="${SWARM_LOGIN_IDLE_TIMEOUT:-900}"
POLL_INTERVAL="${SWARM_LOGIN_POLL_INTERVAL:-2}"
STALE_SECONDS="${SWARM_STALE_SECONDS:-300}"
AUTHCHECK="${SWARM_LOGIN_AUTHCHECK_CMD:-$SCRIPT_DIR/swarm-auth-probe.sh}"

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
case "$POLL_INTERVAL" in
  ''|.|*[!0-9.]*|*.*.*) echo "$PROG: SWARM_LOGIN_POLL_INTERVAL must be a number in seconds (got '$POLL_INTERVAL')" >&2; exit 2 ;;
esac

# The rotate handle is informational ONLY — the operator's browser login decides
# the actual account (see header). Logged so the rotate flow is traceable.
if [ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ]; then
  echo "$PROG: invoked as a credswap (SWARM_ROTATE_TO_ACCOUNT='$SWARM_ROTATE_TO_ACCOUNT')."
  echo "$PROG: NOTE — the handle is logged only; the ACCOUNT CHOICE happens in the operator's browser."
fi

# ---------------------------------------------------------------------------
# Resolve the swarm's row: session name, bot-token var (field 3), channel (4).
# ---------------------------------------------------------------------------
TOKVAR=""
CHANNEL=""
FOUND=0
while IFS= read -r _line; do
  swarm_conf_parse_line "$_line" || continue
  if [ "$SWARM_CONF_F_NAME" = "$SWARM" ]; then
    TOKVAR="$SWARM_CONF_F_TOKVAR"
    CHANNEL="$SWARM_CONF_F_CHANNEL"
    FOUND=1
    break
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

if [ "$FOUND" -ne 1 ]; then
  echo "$PROG: REFUSED — no swarm named '$SWARM' in $CONF." >&2
  if [ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ] && [ "$SWARM" = "${SWARM_ROTATE_TO_ACCOUNT:-}" ]; then
    echo "$PROG: it matches SWARM_ROTATE_TO_ACCOUNT — SWARM_CREDSWAP_CMD is probably wired with a \"\$1\"" >&2
    echo "$PROG: suffix. This relay takes a SWARM name, not an account handle: wire it WITHOUT \"\$1\":" >&2
    echo "$PROG:     export SWARM_CREDSWAP_CMD='\$SWARM_HOME/bin/swarm-login-relay.sh'" >&2
  fi
  exit 2
fi
if [ -z "$CHANNEL" ]; then
  echo "$PROG: REFUSED — swarm '$SWARM' has no CHANNEL_ID in swarm.conf; cannot relay a login URL nobody would see." >&2
  exit 2
fi

SESS="${PREFIX}-${SWARM}"

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

# Pre-flight the post path BEFORE touching the pane: if we could never relay
# the URL, opening the login UI would only wedge the pane for nobody. With the
# override seam set we trust the operator's transport; otherwise the tokens
# file must exist and the swarm's var must be non-empty (checked in a scoped
# subshell — the value never enters this process).
if [ -z "${SWARM_LOGIN_POST_CMD:-}" ]; then
  if [ ! -f "$TOKENS" ]; then
    echo "$PROG: REFUSED — tokens file not found ($TOKENS); could not relay a login URL. Not touching the pane." >&2
    exit 2
  fi
  if ! ( . "$TOKENS"; [ -n "${!TOKVAR:-}" ] ) 2>/dev/null; then
    echo "$PROG: REFUSED — no token in \$$TOKVAR ($TOKENS); could not relay a login URL. Not touching the pane." >&2
    exit 2
  fi
fi

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
trap 'rm -rf "$LOCK"' EXIT

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
# Step 1/6 — session + clean-boundary guard.
# ---------------------------------------------------------------------------
echo "$PROG: step 1/6 — target swarm '$SWARM' (session '$SESS', channel $CHANNEL)"

if ! command -v "$TMUX_BIN" >/dev/null 2>&1; then
  echo "$PROG: REFUSED — tmux binary '$TMUX_BIN' not found." >&2
  exit 2
fi
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

# ---------------------------------------------------------------------------
# Step 2/6 — baseline, send /login, scrape a FRESH URL.
# ---------------------------------------------------------------------------
# BASELINE: everything visible in the pane BEFORE /login is stale by
# definition. Detectors below fire only on content that goes BEYOND it —
# see "STALE-CONTENT DISCIPLINE" in the header.
BASELINE_FRAME="$(pane_capture)"
BASE_URLS="$(printf '%s\n' "$BASELINE_FRAME" | grep -oE "$URL_REGEX" 2>/dev/null || true)"
PICKER_BASE_N="$(count_pattern_lines "$BASELINE_FRAME" "$PICKER_PATTERNS")"
SUCCESS_BASE_N="$(count_pattern_lines "$BASELINE_FRAME" "$SUCCESS_PATTERNS")"

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
_deadline=$((SECONDS + URL_TIMEOUT))
while :; do
  _frame="$(pane_capture)"
  URL="$(extract_fresh_url "$_frame")"
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
# Step 3/6 — relay the URL to the operator over Discord.
# ---------------------------------------------------------------------------
echo "$PROG: step 3/6 — posting the login URL to Discord channel $CHANNEL"
_rotmsg=""
[ -n "${SWARM_ROTATE_TO_ACCOUNT:-}" ] && _rotmsg=" Rotation target handle: '$SWARM_ROTATE_TO_ACCOUNT' — the ACTUAL account is whichever you log into."
if ! post_discord "🔐 **Re-auth needed** (swarm '$SWARM') — open this link in your browser and authenticate: $URL
After the browser flow completes, the session resumes automatically — no paste-back needed.${_rotmsg} (Waiting up to $((AUTH_TIMEOUT / 60)) min.)"; then
  echo "$PROG: FAILED — could not post the login URL to Discord. The operator never saw the link," >&2
  echo "$PROG: so we are NOT leaving the pane wedged in a login modal: backing out (Escape) and failing loud." >&2
  back_out
  exit 6
fi
echo "$PROG:   posted — waiting for the operator to authenticate in the browser"

# ---------------------------------------------------------------------------
# Step 4/6 — wait for the operator to complete the browser auth.
# ---------------------------------------------------------------------------
# Freshness-gated like the picker: success fires only when the pane shows MORE
# success-pattern lines than the baseline did, so a stale "Login successful"
# from a previous run (or prose containing a success phrase) cannot end the
# operator's window early.
echo "$PROG: step 4/6 — polling for login success (timeout ${AUTH_TIMEOUT}s)"
_ok=0
_deadline=$((SECONDS + AUTH_TIMEOUT))
while :; do
  _frame="$(pane_capture)"
  if [ "$(count_pattern_lines "$_frame" "$SUCCESS_PATTERNS")" -gt "$SUCCESS_BASE_N" ]; then
    _ok=1
    break
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
sh -c "$AUTHCHECK"; probe_rc=$?
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
    swarm_conf_parse_line "$_line" || continue
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

if [ "$IDLE_TIMEOUT" -gt 0 ]; then
  echo "$PROG: step 6/6 — re-checking the clean boundary before handing back to rotate (timeout ${IDLE_TIMEOUT}s)"
  _deadline=$((SECONDS + IDLE_TIMEOUT))
  _working="$(fleet_working)"
  while [ -n "$_working" ]; do
    if [ "$SECONDS" -ge "$_deadline" ]; then
      echo "$PROG: WARNING — fleet still WORKING after ${IDLE_TIMEOUT}s:$_working" >&2
      echo "$PROG: proceeding anyway (the re-auth is real and rotate owns the relaunch), but the relaunch" >&2
      echo "$PROG: may interrupt those swarms mid-turn. Uncommitted post-checkpoint work there is at risk." >&2
      break
    fi
    echo "$PROG:   waiting for a clean boundary — working:$_working"
    sleep "$POLL_INTERVAL"
    _working="$(fleet_working)"
  done
else
  echo "$PROG: step 6/6 — boundary re-check disabled (SWARM_LOGIN_IDLE_TIMEOUT=0)"
fi

echo "$PROG: DONE — re-auth complete; credential verified. (swarm-rotate proceeds to relaunch.)"
post_discord "✅ **Re-auth complete** (swarm '$SWARM') — credential verified; session resumed. Rotation proceeds." \
  || echo "$PROG: WARNING — success confirmation failed to post (re-auth itself is DONE)." >&2
exit 0
