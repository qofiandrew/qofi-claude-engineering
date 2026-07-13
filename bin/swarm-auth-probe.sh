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
# but they demand OPPOSITE handling — and the two directions are NOT equally safe:
#   (b) RESTORE  → reinstall the known-good PRIOR blob: reversible, the safe way.
#   (c) KEEP     → discard the prior, keep the NEW blob: the dangerous, less-
#                  reversible direction (a good prior credential is thrown away).
# Because (c) is the irreversible one, it must require a CLEAR usage-cap signal AND
# the ABSENCE of any auth-fail signal. Anything ambiguous falls to (b) RESTORE.
# We separate them by inspecting the probe's OUTPUT: an AUTH-FAIL signal is checked
# FIRST and is authoritative (a dead/expired credential is bad regardless of any
# coincidental "rate limit"-type substring in its error text). Only with NO auth-
# fail signal do we then consider a CAP-SPECIFIC limit signal for (c).
#
# ── THE PROBE CALL (overridable seam; default exercises the credential) ──────
# We do not hardcode a single `claude` invocation — the exact cheapest
# credential-exercising call differs by `claude` version, and tests must inject a
# synthetic one. So the actual call is a seam:
#
#   SWARM_AUTH_PROBE_CMD   A command run via `sh -c`. Its EXIT CODE and its
#                          combined stdout+stderr are classified below. Default:
#                          a cheap `claude` call that round-trips the credential
#                          (see the default probe below). Tests point this at a synthetic
#                          stub that emits a chosen outcome deterministically.
#   SWARM_CLAUDE_BIN       Optional absolute path to Claude Code for the default
#                          probe. This is useful under launchd, whose minimal PATH
#                          commonly omits the native install at
#                          ~/.local/bin/claude. When unset we first resolve
#                          `claude` on PATH, then use that native-install path.
#
# Classification rules (applied to the probe's exit code + captured output), IN
# THIS PRECEDENCE — auth-fail WINS over a limit substring:
#   1. If the output matches an AUTH-FAIL substring         → (b) bad, exit 1.
#      (Checked FIRST. A dead/expired/invalid credential is bad REGARDLESS of any
#      coincidental limit-looking substring in its error text — "exceeded the rate
#      limit for login attempts", "connection limit reached", a 401 that also
#      mentions a usage-limit policy. The safe, reversible direction (RESTORE) must
#      win whenever auth itself is in question.)
#   2. Else if the output matches a CAP-SPECIFIC limit substring → (c) capped,
#      exit 75. (Only reached when NO auth-fail signal is present. A 429/usage-cap
#      can ride a zero OR non-zero probe exit; with auth confirmed-not-failed, the
#      cap signal means the credential authenticated far enough to be told "you're
#      capped" — precisely (c). This KEEPS the new blob and discards the prior, so
#      it must be a CAP-SPECIFIC phrasing, not a generic "rate limit" substring.)
#   3. Else if the probe exited 0                           → (a) good, exit 0.
#   4. Else (non-zero, no limit signal)                     → (b) bad, exit 1
#      (fail CLOSED — an unconfirmed credential is RESTORED, not booted on).
#
# ── CAP-SPECIFIC limit substrings (the (c) verdict set) ──────────────────────
# The (c) set is DELIBERATELY NARROW — cap-specific phrasings ONLY — because (c)
# is the irreversible direction (keeps new, discards known-good prior). It is NOT
# pane_state's broad set: bare "rate limit" / "limit reached" / "approaching usage"
# also appear in auth-lockout, connection, and login-attempt errors, so they are
# DROPPED here. Defaults: "usage limit", "usage limit reached", "5-hour limit",
# "5h limit", "weekly limit", "claude usage limit". Overridable via
# SWARM_LIMIT_PATTERNS (newline- or pipe-separated, case-insensitive fixed
# strings) — note this override is the CAP-SPECIFIC set for THIS probe's (c)
# verdict, not pane_state's broad watcher set.
#
# ── AUTH-FAIL substrings (outcome (b), checked FIRST) ────────────────────────
# A `claude` that exits 0 even on an auth error (some CLIs print the error and
# still exit 0) would be misread as (a). We scan for explicit auth-failure signals
# and a match forces (b) even on a zero exit — and, per the precedence above, it
# WINS over any limit substring (a dead credential whose error text happens to
# contain a limit word is still bad). Overridable via SWARM_AUTH_FAIL_PATTERNS.
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
usage() { sed -n '1,109p' "$0"; exit "${1:-0}"; }

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# CAP-SPECIFIC limit substrings for the (c) verdict. This is INTENTIONALLY NOT
# swarm-lib.sh's broad pane_state set: (c) keeps the new blob and discards the
# known-good prior (the irreversible direction), so it must fire ONLY on a clear
# usage-cap phrasing. Generic substrings like "rate limit", "limit reached", and
# "approaching usage" are DROPPED because they also appear in auth-lockout,
# connection, and login-attempt errors — using them here would misclassify a dead
# credential as merely capped and brick the slot. Operator override
# (SWARM_LIMIT_PATTERNS) is honored and is documented as the cap-specific set for
# this probe's (c) verdict.
cap_patterns() {
  if [ -n "${SWARM_LIMIT_PATTERNS:-}" ]; then
    printf '%s' "$SWARM_LIMIT_PATTERNS" | tr '|' '\n'
    return 0
  fi
  printf '%s\n' "usage limit"
  printf '%s\n' "usage limit reached"
  printf '%s\n' "5-hour limit"
  printf '%s\n' "5h limit"
  printf '%s\n' "weekly limit"
  printf '%s\n' "claude usage limit"
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
# The default is a cheap credential round-trip. `claude -p` with a one-token
# request authenticates and returns near-instantly; it is the cheapest call that
# actually touches the credential (unlike `--version`, which does not). If your
# `claude` exposes an even cheaper auth ping (e.g. a `whoami`), wire
# SWARM_AUTH_PROBE_CMD to it. The point is only that the call FAILS on a dead
# credential and surfaces a limit message on a capped one.
#
# NOTE: we do NOT redirect the probe's stdout to /dev/null. The classifier reads
# the probe's COMBINED stdout+stderr (OUT=$(... 2>&1)), and `claude` can surface a
# usage-limit/auth message on stdout — discarding it would starve the classifier
# and thrash-restore a capped-but-valid account. OUT is captured and never
# printed, so there is no scrollback/secret concern (the default `ping` reply is a
# short "pong"-ish ack, never the credential value).
PROBE="${SWARM_AUTH_PROBE_CMD:-}"
PROBE_BIN=""
if [ -z "$PROBE" ]; then
  if [ -n "${SWARM_CLAUDE_BIN:-}" ]; then
    case "$SWARM_CLAUDE_BIN" in
      /*) PROBE_BIN="$SWARM_CLAUDE_BIN" ;;
      *)
        [ "$EXPLAIN" -eq 1 ] && echo "$PROG: SWARM_CLAUDE_BIN must be an absolute executable path; failing closed." >&2
        exit 1
        ;;
    esac
    if [ ! -x "$PROBE_BIN" ]; then
      [ "$EXPLAIN" -eq 1 ] && echo "$PROG: SWARM_CLAUDE_BIN is not executable; failing closed." >&2
      exit 1
    fi
  elif command -v claude >/dev/null 2>&1; then
    PROBE_BIN="$(command -v claude)"
  elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/claude" ]; then
    # Anthropic's native installer places Claude Code here. launchd does not
    # inherit the interactive shell PATH, so resolving only with `command -v`
    # makes a successful browser login look like an auth failure during the
    # post-login verify. Invoke the known user-local executable directly.
    PROBE_BIN="$HOME/.local/bin/claude"
  else
    # No probe wired AND no `claude` on PATH → we cannot verify. This is the same
    # stance the credswap takes: an unverifiable swap is not a safe swap. We exit
    # 1 (auth-fail) — fail CLOSED, so the caller RESTORES rather than booting on
    # an unverifiable credential. (Distinct from config-error 2, which is a usage
    # bug, not a verdict.)
    [ "$EXPLAIN" -eq 1 ] && echo "$PROG: no SWARM_AUTH_PROBE_CMD and no Claude Code executable on PATH or at ~/.local/bin/claude — cannot verify; failing closed (treat as auth-fail so the swap is restored)." >&2
    exit 1
  fi
fi

# Run the probe, capturing combined output (we classify the SURFACE, never a
# secret). The probe's own command is responsible for not echoing the credential
# value — our default does not. We `2>&1` because limit/auth messages land on
# either stream depending on the CLI's mood.
if [ -n "$PROBE" ]; then
  OUT="$(sh -c "$PROBE" 2>&1)"; prc=$?
else
  # Keep the resolved executable out of a shell command string: paths with
  # spaces remain one argv element and cannot become shell syntax.
  OUT="$("$PROBE_BIN" -p "ping" --max-turns 1 2>&1)"; prc=$?
fi

matches() {  # haystack  pattern-producer-fn
  local hay="$1" fn="$2"
  # STRIP blank/whitespace-only lines from the producer before grep -f: a blank
  # pattern line makes `grep -F -f` match EVERYTHING (so a good credential would
  # read as capped/failed). A blank-yielding override like SWARM_LIMIT_PATTERNS='|'
  # produces exactly such an empty line; this guard makes it inert.
  printf '%s' "$hay" | grep -i -F -q -f <("$fn" | grep -v '^[[:space:]]*$') 2>/dev/null
}

# Classification — PRECEDENCE matters (see header). Auth-fail is checked FIRST and
# WINS over any limit substring: a dead/expired credential is bad regardless of a
# coincidental limit word in its error text, and RESTORE (reversible) is the safe
# direction. Only with NO auth-fail signal does a CAP-SPECIFIC limit signal yield
# the (c) keep-the-new-blob verdict.
verdict=""
why=""
if matches "$OUT" auth_fail_patterns; then
  # (b) Explicit auth-failure signal, even if the CLI exited 0. Authoritative —
  # this beats any limit substring (a bricked/expired cred whose error mentions a
  # "rate limit"/"limit reached" is still a bad credential).
  verdict=1
  why="auth FAILED (auth-error signal in probe output) — bad/expired credential; caller must RESTORE (auth-fail wins over any limit substring)"
elif matches "$OUT" cap_patterns; then
  # (c) No auth-fail signal, AND a CAP-SPECIFIC usage-limit signal: the account
  # authenticated far enough to be told it's capped. NOT a swap failure — restoring
  # would thrash to the (also-capped) prior account.
  verdict="$EX_RATELIMITED"
  why="authenticated BUT rate-limited (cap-specific usage-limit signal, no auth-fail signal) — NOT a swap failure; do not restore; signal ring-exhaustion"
elif [ "$prc" -eq 0 ]; then
  # (a) Clean success, no auth error, no cap signal.
  verdict=0
  why="authenticates (probe exited 0, no auth-error/cap signal) — swap is good"
else
  # (b) Non-zero probe exit, nothing more specific → treat as auth failure. Fail
  # CLOSED so a credential we couldn't confirm gets ROLLED BACK, not booted on.
  verdict=1
  why="auth FAILED (probe exit $prc, no cap signal) — credential did not authenticate; caller must RESTORE"
fi

if [ "$EXPLAIN" -eq 1 ]; then
  case "$verdict" in
    0)  echo "$PROG: OUTCOME (a) AUTHENTICATES — $why" >&2 ;;
    1)  echo "$PROG: OUTCOME (b) AUTH-FAIL — $why" >&2 ;;
    75) echo "$PROG: OUTCOME (c) AUTHED-BUT-CAPPED — $why" >&2 ;;
  esac
fi

exit "$verdict"
