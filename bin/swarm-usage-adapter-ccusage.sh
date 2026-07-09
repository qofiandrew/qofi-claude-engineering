#!/usr/bin/env bash
# swarm-usage-adapter-ccusage.sh — emit the swarm-usage-poll PROBE SCHEMA from
# the ONLY real usage source on this host: ccusage parsing Claude Code's local
# JSONL transcripts in ~/.claude/projects/. This is an ADAPTER behind the poll
# script's swappable SWARM_USAGE_PROBE seam — swarm-usage-poll.sh is UNCHANGED.
#
# ── WHY AN ADAPTER (the ground truth) ────────────────────────────────────────
# swarm-usage-poll.sh reads usage through one documented seam (SWARM_USAGE_PROBE:
# a command whose STDOUT is the usage JSON) and owns a STABLE schema. It does NOT
# know or care HOW usage is read. On this deployment there is NO Grafana, NO
# usage exporter, NO ~/.config/swarm/usage.json, and the authoritative Max
# 5-hour / weekly RATE-LIMIT cap % is NOT exposed by any pinned endpoint. The
# only real usage signal present is Claude Code's local transcripts — exactly
# what `ccusage` parses. This adapter turns ccusage's token accounting into the
# poll script's schema so the rotation TRIGGER has a real (if estimated) number
# to compare against, instead of nothing.
#
# ── HONEST ESTIMATE, NOT THE CAP % (read this) ───────────────────────────────
# IMPORTANT: ccusage reports TOKENS USED, not the percentage of your Max
# rate-limit you have consumed. Anthropic does not expose the authoritative
# 5h/weekly cap % anywhere we can read. So `used_pct` here is a DERIVED,
# DOCUMENTED ESTIMATE:
#
#     used_pct = tokens_used_in_window / OPERATOR_CONFIGURED_TOKEN_BUDGET * 100
#
# It is only as good as the budget the operator sets. It is a token-burn proxy
# for "am I about to get capped?", NOT a measurement of the real cap. Treat a
# NEAR/AT verdict derived from it as "rotate soon by my own budget policy", not
# "Anthropic says you are at N%". If/when a real authoritative cap-% source
# appears, write a new adapter that emits the same schema and swap the probe —
# nothing in swarm-usage-poll.sh changes.
#   Falsifier for this whole approach: an endpoint that returns the true Max
#   cap % would make the budget-ratio estimate obsolete (replace, don't extend).
#
# ── OPERATOR WIRING (the seam) ───────────────────────────────────────────────
#   export SWARM_USAGE_PROBE='bash /path/to/bin/swarm-usage-adapter-ccusage.sh'
#   export SWARM_5H_TOKEN_BUDGET=200000000       # tokens you treat as "full" per 5h block
#   export SWARM_WEEKLY_TOKEN_BUDGET=2000000000  # tokens you treat as "full" per week
# then swarm-usage-poll.sh reads this adapter's stdout and applies its threshold.
#
# ── ENV (all overridable; tests inject these) ────────────────────────────────
#   SWARM_CCUSAGE_CMD       Command used to run ccusage. Default: `ccusage` if on
#                           PATH, else `npx --yes ccusage`. Tests point this at a
#                           fixture-emitting stub. The adapter appends the
#                           subcommand + args, e.g. "<cmd> blocks --active --json".
#   SWARM_5H_TOKEN_BUDGET   REQUIRED. Tokens that count as 100% of a 5h block.
#   SWARM_WEEKLY_TOKEN_BUDGET REQUIRED. Tokens that count as 100% of a week.
#                           (Either budget may be omitted ONLY IF you also do not
#                           want that window reported — but at least one budget
#                           must be set, else we emit nothing and fail UNKNOWN.)
#   SWARM_USAGE_ACCOUNT     Optional. The "account" string to stamp into the
#                           payload when ccusage does not expose one. Default
#                           "unknown".
#   CLAUDE_CONFIG_DIR /     ccusage's own env for locating transcripts; passed
#   ccusage flags           through untouched. We never read transcripts directly.
#
# ── FAIL-SAFE CONTRACT (non-negotiable) ──────────────────────────────────────
# This adapter NEVER prints a guessed used_pct. If ccusage is unavailable, the
# required budget(s) are unset/invalid, or ccusage output cannot be parsed, we
# print NOTHING to stdout and exit NON-ZERO. swarm-usage-poll.sh treats empty /
# failed probe output as UNKNOWN (its exit 3) — which by design NEVER trips a
# rotation. A probe failure must never fabricate a number that swaps credentials.
#
# ── SECRETS ──────────────────────────────────────────────────────────────────
# Read-only usage accounting. This script reads NO OAuth/keychain credential,
# prints no token, and puts no secret on argv. ccusage parses local transcripts
# only. (Per repo §Secrets: usage reads are read-only; never log a token.)
#
# Usage:
#   swarm-usage-adapter-ccusage.sh        # emit one JSON line (the probe schema)
#   swarm-usage-adapter-ccusage.sh -h | --help
#
# Exit codes:
#   0 — emitted a valid payload to stdout.
#   1 — fail-safe: ccusage missing, budgets unset/invalid, or parse failed.
#       NOTHING printed to stdout (diagnostics go to stderr only).
#
# bash 3.2-safe (macOS default). python3 is the only non-shell dep (already
# required across the swarm scripts, same as swarm-usage-poll.sh).

set -uo pipefail

usage() { sed -n '1,90p' "$0"; exit "${1:-0}"; }

case "${1:-}" in
  -h|--help) usage 0 ;;
  "") : ;;
  *) echo "swarm-usage-adapter-ccusage: unknown arg: $1" >&2; usage 1 ;;
esac

# fail — stderr diagnostic, NO stdout, non-zero exit. The single fail-safe path.
fail() {
  echo "swarm-usage-adapter-ccusage: $1" >&2
  exit 1
}

# ── Resolve the ccusage invocation (injectable for tests) ────────────────────
# Prefer an explicit SWARM_CCUSAGE_CMD. Else use `ccusage` if it is on PATH.
# Else fall back to `npx --yes ccusage`. We DO NOT verify npx can actually fetch
# ccusage here (that would require network); instead, if ccusage produces no
# usable output below, we fail-safe. The command is split on whitespace into an
# argv prefix (no eval), so a stub like "bash /tmp/stub.sh" works.
CCUSAGE_CMD="${SWARM_CCUSAGE_CMD:-}"
if [ -z "$CCUSAGE_CMD" ]; then
  if command -v ccusage >/dev/null 2>&1; then
    CCUSAGE_CMD="ccusage"
  elif command -v npx >/dev/null 2>&1; then
    CCUSAGE_CMD="npx --yes ccusage"
  else
    fail "ccusage not found (no SWARM_CCUSAGE_CMD, no ccusage on PATH, no npx) — emitting nothing -> poll resolves UNKNOWN"
  fi
fi

# run_ccusage SUBCMD... — invoke the resolved ccusage command with the given
# subcommand/args, capturing stdout. Returns ccusage's exit status. The command
# prefix is intentionally word-split (argv), never `eval`'d, so no injection.
run_ccusage() {
  # shellcheck disable=SC2086
  set -- $CCUSAGE_CMD "$@"
  "$@" 2>/dev/null
}

# ── Validate that at least one window budget is set & a positive integer ──────
# A budget is the denominator of the honest estimate; without one there is no
# defensible used_pct, so we fail-safe rather than guess a denominator.
is_pos_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }

FH_BUDGET="${SWARM_5H_TOKEN_BUDGET:-}"
WK_BUDGET="${SWARM_WEEKLY_TOKEN_BUDGET:-}"
have_fh=0; have_wk=0
if [ -n "$FH_BUDGET" ]; then
  is_pos_int "$FH_BUDGET" || fail "SWARM_5H_TOKEN_BUDGET must be a positive integer (got '$FH_BUDGET')"
  have_fh=1
fi
if [ -n "$WK_BUDGET" ]; then
  is_pos_int "$WK_BUDGET" || fail "SWARM_WEEKLY_TOKEN_BUDGET must be a positive integer (got '$WK_BUDGET')"
  have_wk=1
fi
if [ "$have_fh" -eq 0 ] && [ "$have_wk" -eq 0 ]; then
  fail "no token budget set (need SWARM_5H_TOKEN_BUDGET and/or SWARM_WEEKLY_TOKEN_BUDGET) — emitting nothing -> poll resolves UNKNOWN"
fi

# ── Collect raw ccusage output for each window we have a budget for ───────────
# 5h: `blocks --active --json` -> the active 5-hour block's totalTokens.
# weekly: `weekly --json` -> the most-recent week bucket's totalTokens.
BLOCKS_JSON=""
WEEKLY_JSON=""
if [ "$have_fh" -eq 1 ]; then
  BLOCKS_JSON="$(run_ccusage blocks --active --json)" || true
fi
if [ "$have_wk" -eq 1 ]; then
  WEEKLY_JSON="$(run_ccusage weekly --json)" || true
fi

ACCOUNT_DEFAULT="${SWARM_USAGE_ACCOUNT:-unknown}"

# ── Parse + derive in python3 (the repo's one non-shell dep) ─────────────────
# We pass everything as argv (NOT stdin — the heredoc occupies python's stdin,
# same idiom as swarm-usage-poll.sh). python prints the final JSON payload to
# stdout and exits 0 on success; on ANY parse/structure failure it prints
# nothing to stdout and exits non-zero, which we propagate as the fail-safe.
PAYLOAD="$(python3 - "$have_fh" "$FH_BUDGET" "$BLOCKS_JSON" \
                     "$have_wk" "$WK_BUDGET" "$WEEKLY_JSON" \
                     "$ACCOUNT_DEFAULT" <<'PY'
import json, sys, datetime

have_fh   = sys.argv[1] == "1"
fh_budget = sys.argv[2]
blocks_j  = sys.argv[3]
have_wk   = sys.argv[4] == "1"
wk_budget = sys.argv[5]
weekly_j  = sys.argv[6]
account_default = sys.argv[7]

def die(msg):
    # NOTHING on stdout — that is the fail-safe contract. Diagnostic to stderr.
    sys.stderr.write("swarm-usage-adapter-ccusage: %s\n" % msg)
    raise SystemExit(1)

def block_total(active_block):
    """Tokens consumed in the active 5h block. Prefer the block's own
    totalTokens; else sum tokenCounts (input+output+cache, all real usage)."""
    tt = active_block.get("totalTokens")
    if isinstance(tt, (int, float)):
        return float(tt)
    tc = active_block.get("tokenCounts")
    if isinstance(tc, dict):
        s = 0.0
        for k in ("inputTokens", "outputTokens",
                  "cacheCreationInputTokens", "cacheReadInputTokens",
                  "cacheCreationTokens", "cacheReadTokens"):
            v = tc.get(k)
            if isinstance(v, (int, float)):
                s += float(v)
        return s
    return None

def account_of(active_block):
    """ccusage's blocks shape does not currently carry an account handle. If a
    future version adds one (account / accountId / email), echo it; else None."""
    for k in ("account", "accountId", "email", "user"):
        v = active_block.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None

out = {}
account = None

# ---- 5-hour window from `blocks --active --json` -----------------------------
if have_fh:
    if not (blocks_j or "").strip():
        die("ccusage produced no `blocks --active --json` output (unavailable?) — fail-safe")
    try:
        bd = json.loads(blocks_j)
    except Exception as e:
        die("unparseable ccusage blocks JSON: %s" % e)
    blocks = bd.get("blocks") if isinstance(bd, dict) else None
    if not isinstance(blocks, list):
        die("ccusage blocks JSON has no 'blocks' array")
    # The active block: isActive true and not a gap. Fall back to the last
    # non-gap block if no explicit active flag is present.
    active = None
    for b in blocks:
        if isinstance(b, dict) and b.get("isActive") and not b.get("isGap"):
            active = b
            break
    if active is None:
        for b in reversed(blocks):
            if isinstance(b, dict) and not b.get("isGap"):
                active = b
                break
    if active is None:
        # No active 5h block means zero usage in the current block — that is a
        # VALID 0%, not a failure. (A fresh window before any activity.)
        used = 0.0
    else:
        used = block_total(active)
        if used is None:
            die("active ccusage block has no token totals to read")
        a = account_of(active)
        if a:
            account = a
    pct = used / float(fh_budget) * 100.0
    out["five_hour"] = {
        "used_pct": round(pct, 2),
        # Operator-facing breadcrumbs (echoed, never parsed by the poll script).
        "tokens_used": int(used),
        "token_budget": int(fh_budget),
        "estimate": "tokens/budget (NOT authoritative Max cap %)",
    }

# ---- weekly window from `weekly --json` --------------------------------------
if have_wk:
    if not (weekly_j or "").strip():
        die("ccusage produced no `weekly --json` output (unavailable?) — fail-safe")
    try:
        wd = json.loads(weekly_j)
    except Exception as e:
        die("unparseable ccusage weekly JSON: %s" % e)
    weeks = wd.get("weekly") if isinstance(wd, dict) else None
    if not isinstance(weeks, list) or not weeks:
        # No weekly buckets at all == no usage this week == valid 0%.
        used = 0.0
    else:
        # Select the bucket for the CURRENT (most recent) week. ccusage orders
        # weekly[] chronologically; the current week is the entry whose `period`
        # (week-start date) is the latest. We compare ISO dates lexically (safe
        # for YYYY-MM-DD) and fall back to the last element if periods are absent.
        cur = None
        best_period = None
        for w in weeks:
            if not isinstance(w, dict):
                continue
            p = w.get("period")
            if isinstance(p, str):
                if best_period is None or p > best_period:
                    best_period = p
                    cur = w
        if cur is None:
            cur = weeks[-1] if isinstance(weeks[-1], dict) else None
        if cur is None:
            die("ccusage weekly JSON had no usable week bucket")
        tt = cur.get("totalTokens")
        if isinstance(tt, (int, float)):
            used = float(tt)
        else:
            # Sum component token fields if totalTokens is absent.
            used = 0.0
            seen = False
            for k in ("inputTokens", "outputTokens",
                      "cacheCreationTokens", "cacheReadTokens"):
                v = cur.get(k)
                if isinstance(v, (int, float)):
                    used += float(v); seen = True
            if not seen:
                die("current week bucket has no token totals to read")
    pct = used / float(wk_budget) * 100.0
    out["weekly"] = {
        "used_pct": round(pct, 2),
        "tokens_used": int(used),
        "token_budget": int(wk_budget),
        "estimate": "tokens/budget (NOT authoritative Max cap %)",
    }

# Account: prefer one surfaced by ccusage; else the operator-configured/unknown.
out["account"] = account if account else account_default

# Defensive: never emit an empty object (would read as "plenty left" / 0% and
# could quietly suppress a needed rotation). If somehow neither window populated,
# fail-safe instead.
if "five_hour" not in out and "weekly" not in out:
    die("no window could be derived — emitting nothing -> poll resolves UNKNOWN")

sys.stdout.write(json.dumps(out))
PY
)"
rc=$?

# Propagate the fail-safe: if python failed (non-zero) OR produced no stdout,
# emit nothing and exit non-zero so swarm-usage-poll.sh resolves UNKNOWN.
if [ "$rc" -ne 0 ] || [ -z "$PAYLOAD" ]; then
  exit 1
fi

printf '%s\n' "$PAYLOAD"
exit 0
