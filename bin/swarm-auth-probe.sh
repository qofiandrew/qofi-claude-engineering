#!/usr/bin/env bash
# swarm-auth-probe.sh — a REAL, cheap auth probe for the credential-swap VERIFY
# step. It is the default SWARM_CREDSWAP_AUTHCHECK_CMD: after swarm-credswap
# installs the next account's blob, this probe answers ONE question with THREE
# possible answers — and that 3-way answer is what keeps restore-on-failure from
# being hollow.
#
# ── WHY `claude --version` IS NOT ENOUGH (the hole this closes) ──────────────
# The old default authcheck was `claude --version`. That only proves the BINARY
# runs; it never touches the credential. A swap to a bad/expired blob would pass
# `--version` and the fleet would boot on dead auth — the restore-on-failure path
# would never fire. This probe instead makes a CREDENTIAL-EXERCISING call so a
# bad credential actually FAILS the verify, and the credswap rolls back.
#
# ── THE THREE OUTCOMES (this is the whole point) ─────────────────────────────
#   (a) AUTHENTICATES        exit 0   The credential is good and has headroom.
#                                     swarm-credswap proceeds; the swap is real.
#   (b) AUTH FAILS           exit 1   Bad/expired/invalid credential — the probe
#                                     could NOT authenticate. swarm-credswap must
#                                     RESTORE the prior blob and fail loud. This
#                                     is the proof the build review owed.
#   (c) AUTHED-BUT-CAPPED     exit 75  The credential authenticates FINE, but the
#                                     account it points at is itself rate-limited
#                                     (429 / usage-limit). This is NOT a swap
#                                     failure: restoring would just thrash back to
#                                     the prior (also-capped) account. So we DO
#                                     NOT restore — we signal "this rotate target
#                                     is also capped" so the caller can detect
#                                     ring exhaustion (see swarm-rotate-tick.sh's
#                                     ring-exhaustion terminal state). 75 ==
#                                     EX_TEMPFAIL (sysexits.h): "transient, not a
#                                     hard failure" — exactly the semantics.
#
# (b) vs (c) is the crux. A bad credential and a capped-but-good credential look
# superficially similar (the probe call doesn't "succeed normally" in either),
# but they demand OPPOSITE handling: (b) → roll back; (c) → keep the swap, escalate
# ring exhaustion. We separate them by inspecting the probe's OUTPUT for a known
# rate-limit signal (the same limit substrings pane_state/swarm-watch trust),
# falling back to the probe's own exit code.
#
# ── THE PROBE CALL (overridable seam; default exercises the credential) ──────
# We do not hardcode a single `claude` invocation — the exact cheapest
# credential-exercising call differs by `claude` version, and tests must inject a
# synthetic one. So the actual call is a seam:
#
#   SWARM_AUTH_PROBE_CMD   A command run via `sh -c`. Its EXIT CODE and its
#                          combined stdout+stderr are classified below. Default:
#                          a cheap `claude` call that round-trips the credential
#                          (see DEFAULT_PROBE). Tests point this at a synthetic
#                          stub that emits a chosen outcome deterministically.
#
# Classification rules (applied to the probe's exit code + captured output):
#   1. If the output matches a known RATE-LIMIT substring  → (c) capped, exit 75.
#      (Checked FIRST: a 429 can ride on a zero OR non-zero probe exit depending
#      on how `claude` surfaces it; the limit signal is authoritative either way —
#      it means the credential DID authenticate far enough to be told "you're
#      capped", which is precisely (c).)
#   2. Else if the probe exited 0                          → (a) good,   exit 0.
#   3. Else (non-zero, no limit signal)                    → (b) bad,    exit 1.
#
# Rate-limit substrings are the SAME set pane_state uses, sourced from swarm-lib.sh
# so there is one definition of "this looks like a usage cap" in the repo. They
# are overridable via SWARM_LIMIT_PATTERNS (newline- or pipe-separated, case-
# insensitive fixed strings) — identical to pane_state's knob.
#
# ── AUTH-FAIL substrings (belt-and-suspenders for outcome (b)) ───────────────
# A `claude` that exits 0 even on an auth error (some CLIs print the error and
# still exit 0) would be misread as (a). So we ALSO scan for explicit auth-failure
# signals; a match forces (b) even on a zero exit — UNLESS a rate-limit signal is
# also present (rate-limit wins; a capped-but-authed account is not an auth fail).
# Overridable via SWARM_AUTH_FAIL_PATTERNS.
#
# Usage:
#   swarm-auth-probe.sh            # run the probe, classify, exit 0|1|75
#   swarm-auth-probe.sh --explain  # also print which outcome and why (to stderr)
#   swarm-auth-probe.sh -h | --help
#
# Exit codes:
#   0  — (a) authenticates: credential is good. Swap proceeds.
#   1  — (b) auth FAILED: bad/expired credential. Caller RESTORES.
#   75 — (c) authenticated BUT rate-limited: NOT a swap failure; do NOT restore;
#            signal ring-exhaustion. (EX_TEMPFAIL)
#   2  — usage/config error (bad flag). Never confused with an auth verdict.
#
# This script NEVER reads, prints, or logs a credential VALUE. It only runs the
# (operator-/test-supplied) probe command and classifies its surface output.
#
# Bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-auth-probe"
usage() { sed -n '1,96p' "$0"; exit "${1:-0}"; }

EXPLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1; shift ;;
    -h|--help) usage 0 ;;
    --*) echo "$PROG: unknown flag: $1" >&2; usage 2 ;;
    *)   echo "$PROG: unexpected arg: $1" >&2; usage 2 ;;
  esac
done

# Sysexits EX_TEMPFAIL — "temporary failure, retry/route elsewhere". We reuse it
# as the (c) authed-but-capped signal so it is impossible to confuse with the
# generic auth-fail (1) or success (0).
EX_RATELIMITED=75

# ── Source the repo's limit-pattern definition (one source of truth) ─────────
# swarm-lib.sh owns _swarm_default_limit_patterns (used by pane_state). We reuse
# it so "looks like a usage cap" means the same thing here as in the watcher.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
if [ -f "$SCRIPT_DIR/swarm-lib.sh" ]; then
  # Only need the pattern helper; sourcing is cheap and side-effect-light.
  . "$SCRIPT_DIR/swarm-lib.sh"
fi

# Rate-limit substrings: operator override wins, else the repo default, else a
# small built-in fallback (in case swarm-lib.sh wasn't sourceable for any reason).
limit_patterns() {
  if [ -n "${SWARM_LIMIT_PATTERNS:-}" ]; then
    printf '%s' "$SWARM_LIMIT_PATTERNS" | tr '|' '\n'
    return 0
  fi
  if command -v _swarm_default_limit_patterns >/dev/null 2>&1; then
    _swarm_default_limit_patterns
    return 0
  fi
  printf '%s\n' "usage limit"
  printf '%s\n' "5-hour limit"
  printf '%s\n' "limit reached"
  printf '%s\n' "rate limit"
  printf '%s\n' "approaching usage"
}

# Auth-failure substrings: signals that the credential itself is bad/expired even
# if the CLI exits 0. Overridable. These are deliberately auth-specific so they do
# NOT collide with rate-limit phrasing.
auth_fail_patterns() {
  if [ -n "${SWARM_AUTH_FAIL_PATTERNS:-}" ]; then
    printf '%s' "$SWARM_AUTH_FAIL_PATTERNS" | tr '|' '\n'
    return 0
  fi
  printf '%s\n' "invalid api key"
  printf '%s\n' "authentication_error"
  printf '%s\n' "authentication failed"
  printf '%s\n' "unauthorized"
  printf '%s\n' "not authenticated"
  printf '%s\n' "please run /login"
  printf '%s\n' "invalid bearer token"
  printf '%s\n' "oauth token has expired"
  printf '%s\n' "credentials are invalid"
}

# ── The probe call (overridable; default exercises the credential) ───────────
# DEFAULT_PROBE is a cheap credential round-trip. `claude -p` with a one-token
# request authenticates and returns near-instantly; it is the cheapest call that
# actually touches the credential (unlike `--version`, which does not). If your
# `claude` exposes an even cheaper auth ping (e.g. a `whoami`), wire
# SWARM_AUTH_PROBE_CMD to it. The point is only that the call FAILS on a dead
# credential and surfaces a limit message on a capped one.
DEFAULT_PROBE='claude -p "ping" --max-turns 1 >/dev/null'

PROBE="${SWARM_AUTH_PROBE_CMD:-}"
if [ -z "$PROBE" ]; then
  if command -v claude >/dev/null 2>&1; then
    PROBE="$DEFAULT_PROBE"
  else
    # No probe wired AND no `claude` on PATH → we cannot verify. This is the same
    # stance the credswap takes: an unverifiable swap is not a safe swap. We exit
    # 1 (auth-fail) — fail CLOSED, so the caller RESTORES rather than booting on
    # an unverifiable credential. (Distinct from config-error 2, which is a usage
    # bug, not a verdict.)
    [ "$EXPLAIN" -eq 1 ] && echo "$PROG: no SWARM_AUTH_PROBE_CMD and no 'claude' on PATH — cannot verify; failing closed (treat as auth-fail so the swap is restored)." >&2
    exit 1
  fi
fi

# Run the probe, capturing combined output (we classify the SURFACE, never a
# secret). The probe's own command is responsible for not echoing the credential
# value — our default does not. We `2>&1` because limit/auth messages land on
# either stream depending on the CLI's mood.
OUT="$(sh -c "$PROBE" 2>&1)"; prc=$?

matches() {  # haystack  pattern-producer-fn
  local hay="$1" fn="$2"
  printf '%s' "$hay" | grep -i -F -q -f <("$fn") 2>/dev/null
}

verdict=""
why=""
if matches "$OUT" limit_patterns; then
  # (c) The account authenticated far enough to be told it's capped. NOT a swap
  # failure — restoring would thrash to the (also-capped) prior account.
  verdict="$EX_RATELIMITED"
  why="authenticated BUT rate-limited (known usage-limit signal in probe output) — NOT a swap failure; do not restore; signal ring-exhaustion"
elif matches "$OUT" auth_fail_patterns; then
  # (b) Explicit auth-failure signal, even if the CLI exited 0.
  verdict=1
  why="auth FAILED (auth-error signal in probe output) — bad/expired credential; caller must RESTORE"
elif [ "$prc" -eq 0 ]; then
  # (a) Clean success, no limit, no auth error.
  verdict=0
  why="authenticates (probe exited 0, no limit/auth-error signal) — swap is good"
else
  # (b) Non-zero probe exit, nothing more specific → treat as auth failure. Fail
  # CLOSED so a credential we couldn't confirm gets ROLLED BACK, not booted on.
  verdict=1
  why="auth FAILED (probe exit $prc, no limit signal) — credential did not authenticate; caller must RESTORE"
fi

if [ "$EXPLAIN" -eq 1 ]; then
  case "$verdict" in
    0)  echo "$PROG: OUTCOME (a) AUTHENTICATES — $why" >&2 ;;
    1)  echo "$PROG: OUTCOME (b) AUTH-FAIL — $why" >&2 ;;
    75) echo "$PROG: OUTCOME (c) AUTHED-BUT-CAPPED — $why" >&2 ;;
  esac
fi

exit "$verdict"
