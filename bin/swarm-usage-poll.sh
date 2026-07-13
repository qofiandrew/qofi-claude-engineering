#!/usr/bin/env bash
# swarm-usage-poll.sh — poll the ACTIVE Max account's usage and decide whether
# it is NEARING its 5-hour / weekly cap. This is the ROTATION TRIGGER.
#
# THE MODEL (single active account + rotation as a DURATION mechanism). This
# deployment runs ONE Max account at a time on macOS — there is no concurrency,
# no per-account config-dir isolation. To extend the wall-clock the fleet can
# run before it stalls on a cap, we ROTATE: when the active account is about to
# hit its 5h or weekly limit we swap to the next account's credentials and
# relaunch the fleet (see swarm-rotate.sh). This poller is the part that detects
# "about to hit" — it does NOT rotate. It is a pure DETECTOR with one job: read
# usage, compare against a threshold, print a verdict, and exit with a code the
# caller (a cron tick, the watcher, or a human) can branch on.
#
# Exit codes (the verdict — fail-SAFE: "don't know" never trips a rotation):
#   0 — OK            usage is comfortably below the threshold; no action.
#   10 — NEAR-LIMIT   usage has crossed the rotation threshold on the 5h OR the
#                     weekly window; the caller SHOULD rotate at the next clean
#                     phase boundary (see swarm-rotate.sh).
#   20 — AT-LIMIT     usage is at/over 100% on either window (already capped or
#                     within rounding of it) — rotate now / the fleet is already
#                     stalling. Distinct from NEAR so the caller can treat an
#                     already-capped account more urgently.
#   3 — UNKNOWN       the usage probe failed, returned nothing, or returned
#                     unparseable output. NEVER reported as NEAR/AT — a probe
#                     failure must not silently swap credentials. Fail loud,
#                     do nothing destructive. (Matches the repo's "fail-safe is
#                     silence" convention — pane_state rc=4, swarmstatus.js null.)
#   2 — usage/config error (bad threshold, bad probe spec) — refuse.
#
# ── THE USAGE PROBE (swappable credential/usage interface) ──────────────────
# We do NOT hardcode how usage is read, and we NEVER read the operator's real
# OAuth credentials from this script. Instead usage arrives through a single,
# documented, OVERRIDABLE seam — exactly the pattern swarm-provision-tokens.sh
# uses for secrets (SWARM_VAULT_FETCH):
#
#   SWARM_USAGE_PROBE   A command run via `sh -c`. Its STDOUT must be the usage
#                       payload (JSON — see the schema below). Examples:
#                         export SWARM_USAGE_PROBE='cat /tmp/usage.json'
#                         export SWARM_USAGE_PROBE='claude-usage --json'   # hypothetical
#                         export SWARM_USAGE_PROBE='curl -fsS "$USAGE_URL"'
#                       Unset → we fall back to reading SWARM_USAGE_FILE.
#   SWARM_USAGE_FILE    A file whose contents are the usage payload. Default
#                       "$SWARM_STATE_DIR/usage.json". Used only when
#                       SWARM_USAGE_PROBE is unset. This is the zero-network,
#                       zero-credential default: some out-of-band collector (a
#                       launchd job the operator owns) writes the snapshot here.
#
# ASSUMPTION (documented, falsifiable). The repo does not pin Claude Code's Max
# usage endpoint, and probing the keychain/OAuth creds from here is out of
# scope by design. So the poller is built around the swappable probe above and
# a STABLE payload schema it owns; wiring the probe to the real endpoint is a
# one-line operator/integration step (set SWARM_USAGE_PROBE). If/when the real
# endpoint shape is known, only an adapter that emits this schema is needed —
# nothing in this script changes. Falsifier: a usage source that cannot be
# shaped into the schema below would force a rewrite of parse_usage().
#
# ── USAGE PAYLOAD SCHEMA (this script's contract) ───────────────────────────
# A JSON object. Percentages are 0..100 numbers; either window may be absent
# (absent = treated as 0% / "plenty left"). Reset hints are free-form strings
# echoed through for the operator (never parsed for logic).
#
#   {
#     "five_hour":  { "used_pct": 82, "reset_hint": "resets 11pm" },
#     "weekly":     { "used_pct": 40, "reset_hint": "resets Sun" },
#     "account":    "max-a"            // optional: which account this is
#   }
#
# Back-compat aliases accepted (first present wins per window):
#   five_hour | 5h | five_hour_pct           weekly | week | weekly_pct
#   used_pct  | pct | percent | utilization
#
# ── THRESHOLD ───────────────────────────────────────────────────────────────
#   SWARM_ROTATE_THRESHOLD_PCT   default 95. NEAR fires when either window's
#                                used_pct >= this. AT fires at >= 100.
#
# Usage:
#   swarm-usage-poll.sh                 # poll once, print verdict, exit per codes above
#   swarm-usage-poll.sh --quiet         # exit code only, no stdout
#   swarm-usage-poll.sh --json          # emit the parsed verdict as one JSON line
#   swarm-usage-poll.sh -h | --help
#
# Bash 3.2-safe (macOS default). python3 is the only non-shell dep (already
# required across the swarm scripts). Read-only: this script NEVER swaps a
# credential or restarts anything — that is swarm-rotate.sh's job.

set -uo pipefail

usage() { sed -n '1,90p' "$0"; exit "${1:-0}"; }

QUIET=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --json)  JSON=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "swarm-usage-poll: unknown arg: $1" >&2; usage 2 ;;
  esac
done

STATE_DIR="${SWARM_STATE_DIR:-$HOME/.config/swarm}"
USAGE_FILE="${SWARM_USAGE_FILE:-$STATE_DIR/usage.json}"
THRESHOLD="${SWARM_ROTATE_THRESHOLD_PCT:-95}"

# Validate the threshold is a plain integer in (0,100]. A bad threshold is a
# config error, not a reason to silently never/always rotate.
case "$THRESHOLD" in
  ''|*[!0-9]*) echo "swarm-usage-poll: SWARM_ROTATE_THRESHOLD_PCT must be an integer 1..100 (got '$THRESHOLD')" >&2; exit 2 ;;
esac
if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
  echo "swarm-usage-poll: SWARM_ROTATE_THRESHOLD_PCT out of range 1..100 (got '$THRESHOLD')" >&2
  exit 2
fi

# ── Acquire the raw usage payload via the swappable probe ────────────────────
# Probe path takes precedence; else read the file. A probe that exits non-zero,
# or a missing file, yields EMPTY — which parse_usage classifies as UNKNOWN (3).
acquire_usage() {
  local probe="${SWARM_USAGE_PROBE:-}"
  if [ -n "$probe" ]; then
    sh -c "$probe" 2>/dev/null || return 0   # empty stdout on failure → UNKNOWN
    return 0
  fi
  [ -f "$USAGE_FILE" ] && cat "$USAGE_FILE" 2>/dev/null
  return 0
}

RAW="$(acquire_usage)"

# ── Parse + classify in python3 (the repo's one non-shell dep) ───────────────
# Prints two lines to stdout:
#   line 1: VERDICT word   (OK | NEAR | AT | UNKNOWN)
#   line 2: a human/JSON detail string
# Exits 0 always; the shell maps the VERDICT word to this script's exit code so
# parsing and exit-mapping stay in one place (the word is the single source).
# The raw payload is passed as argv[3] (NOT stdin) because the `<<'PY'` heredoc
# itself occupies python3's stdin — reading the payload from stdin would read
# the script source instead.
VERDICT_OUT="$(python3 - "$THRESHOLD" "$JSON" "$RAW" <<'PY'
import json, sys

threshold = int(sys.argv[1])
want_json = sys.argv[2] == "1"
raw = sys.argv[3] if len(sys.argv) > 3 else ""

def emit(verdict, detail):
    print(verdict)
    print(detail)
    raise SystemExit(0)

if not raw.strip():
    emit("UNKNOWN", "no usage payload (probe failed / file missing / empty)")

try:
    data = json.loads(raw)
except Exception as e:
    emit("UNKNOWN", "unparseable usage payload: %s" % e)

if not isinstance(data, dict):
    emit("UNKNOWN", "usage payload is not a JSON object")

def window(*keys):
    """Return the first present window object among aliases, or None."""
    for k in keys:
        v = data.get(k)
        if isinstance(v, dict):
            return v
    return None

def pct_of(win):
    """Extract a 0..100 percent from a window object, trying alias keys.
    Returns None if absent/unparseable (absent window == plenty left)."""
    if win is None:
        return None
    for k in ("used_pct", "pct", "percent", "utilization"):
        if k in win:
            try:
                return float(win[k])
            except (TypeError, ValueError):
                return None
    return None

def reset_of(win):
    if win is None:
        return ""
    v = win.get("reset_hint") or win.get("reset") or win.get("resets") or ""
    return str(v) if v else ""

# Some payloads may put a bare percent directly under the alias key (e.g.
# {"five_hour_pct": 90}); accept that too.
def scalar_pct(*keys):
    for k in keys:
        if k in data and not isinstance(data.get(k), dict):
            try:
                return float(data[k])
            except (TypeError, ValueError):
                pass
    return None

fh_win = window("five_hour", "5h")
wk_win = window("weekly", "week")
fh = pct_of(fh_win)
wk = pct_of(wk_win)
if fh is None:
    fh = scalar_pct("five_hour_pct", "5h_pct")
if wk is None:
    wk = scalar_pct("weekly_pct", "week_pct")

fh_eff = fh if fh is not None else 0.0
wk_eff = wk if wk is not None else 0.0
worst = max(fh_eff, wk_eff)
account = data.get("account")

# Classify. AT (>=100 on either window) is the urgent case; NEAR (>=threshold)
# is the rotate-at-next-boundary case; otherwise OK.
if fh_eff >= 100.0 or wk_eff >= 100.0:
    verdict = "AT"
elif worst >= threshold:
    verdict = "NEAR"
else:
    verdict = "OK"

which = "5h" if fh_eff >= wk_eff else "weekly"
fh_s = ("%.0f%%" % fh_eff) if fh is not None else "n/a"
wk_s = ("%.0f%%" % wk_eff) if wk is not None else "n/a"
acct_s = (" account=%s" % account) if account else ""

if want_json:
    detail = json.dumps({
        "verdict": verdict,
        "five_hour_pct": fh,
        "weekly_pct": wk,
        "worst_pct": worst,
        "worst_window": which,
        "threshold_pct": threshold,
        "account": account,
        "five_hour_reset_hint": reset_of(fh_win) or None,
        "weekly_reset_hint": reset_of(wk_win) or None,
    })
else:
    detail = "5h=%s weekly=%s (threshold %d%%, worst=%s)%s" % (fh_s, wk_s, threshold, which, acct_s)

emit(verdict, detail)
PY
)"

VERDICT="$(printf '%s\n' "$VERDICT_OUT" | sed -n '1p')"
DETAIL="$(printf '%s\n' "$VERDICT_OUT" | sed -n '2,$p')"

# Map the verdict word to a label + exit code. ONE place owns the mapping.
case "$VERDICT" in
  OK)      label="OK";         code=0  ;;
  NEAR)    label="NEAR-LIMIT";  code=10 ;;
  AT)      label="AT-LIMIT";    code=20 ;;
  UNKNOWN) label="UNKNOWN";     code=3  ;;
  *)       label="UNKNOWN";     code=3; DETAIL="internal: unrecognized verdict '$VERDICT'" ;;
esac

if [ "$QUIET" -ne 1 ]; then
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$DETAIL"
  else
    printf 'swarm-usage-poll: %s — %s\n' "$label" "$DETAIL"
  fi
fi

exit "$code"
