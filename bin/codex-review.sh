#!/usr/bin/env bash
# codex-review.sh — Codex contrarian review lane (ADVISORY, never gating).
#
# Pipes the integrated diff to the OpenAI Codex CLI for a foreign-model second
# opinion on the highest-stakes diffs (TEAM_LEAD.md §Codex contrarian review
# lane). A different model family decorrelates the blind spots a Claude reviewer
# shares with Claude-authored code — that is the entire point. Its findings are
# INPUT TO THE CTO'S JUDGMENT, never a gate: Codex gets a voice, not a veto.
#
# HARD MONEY-PATH FLOOR (operator-ratified 2026-06-12). This lane runs on a Codex
# SUBSCRIPTION (`codex login`). It must NEVER fall back to metered API-key
# billing — that flip would be unapproved Type-2 spend (CLAUDE.md §Real spend &
# money movement). So before invoking codex it REFUSES to run if:
#   - OPENAI_API_KEY / CODEX_API_KEY is set in the environment — that routes
#     codex to metered billing; or
#   - codex is absent, or not logged in, or `codex login status` reports an
#     API-key / metered session rather than a subscription.
# On any such condition it goes ADVISORY-DOWN: prints a loud notice and exits
# non-zero WITHOUT calling codex. Advisory-down means "no contrarian input this
# run" — NOT a block. The CTO proceeds with the Claude-side review; this lane
# never gates done.
#
# Usage:
#   bin/codex-review.sh [--range <git-range>] [--check]
#     --range   diff range to review (default: dev..HEAD, else HEAD~1..HEAD)
#     --check   run the auth guard + print the plan; do NOT invoke codex
#
# Env:
#   CODEX_BIN            codex binary (default: codex) — overridable for tests
#   CODEX_REVIEW_PROMPT  override the review instruction
#   CODEX_EXEC_ARGS      override the codex subcommand+args (default: "exec")
#
# NOTE ON THE CODEX INVOCATION: the safety-critical part — the subscription-only
# money-path guard — is fully tested (tests/test-codex-review.sh) without ever
# spending. The exact codex subcommand form (`exec` vs `review`, stdin vs arg,
# sandbox flags) is intentionally a single overridable line below; the CTO
# validates/tunes it on first real run. Because the lane is advisory, a
# mis-tuned invocation degrades to advisory-down, never to a wrong gate.

set -uo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
RANGE=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || { echo "codex-review: --range requires a value" >&2; exit 2; }; RANGE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "codex-review: unknown arg: $1" >&2; exit 2 ;;
  esac
done

advisory_down() {  # reason
  echo "codex-review: ADVISORY-DOWN — $1" >&2
  echo "  The contrarian lane is OFF for this run (no Codex input). This is NOT a" >&2
  echo "  gate: proceed with the Claude-side review. Codex is a voice, not a veto." >&2
  exit 3
}

# --- HARD money-path floor: subscription auth only, never metered -----------
# 1) No metered API key may be present in the environment.
for k in OPENAI_API_KEY CODEX_API_KEY; do
  if [ -n "${!k:-}" ]; then
    advisory_down "$k is set — that routes Codex to METERED billing (unapproved Type-2 spend). Unset it; this lane is subscription-only."
  fi
done
# 2) Codex must be present and logged in with a subscription.
command -v "$CODEX_BIN" >/dev/null 2>&1 || advisory_down "codex CLI not found (\$CODEX_BIN=$CODEX_BIN)."
status="$("$CODEX_BIN" login status 2>&1)" || advisory_down "codex is not logged in — run 'codex login' (subscription). status: $status"
if printf '%s' "$status" | grep -qiE 'api[ -]?key|metered'; then
  advisory_down "codex login status reports an API-key/metered session — subscription auth required. status: $status"
fi
# --- end money-path floor ---------------------------------------------------

# Resolve the diff range.
if [ -z "$RANGE" ]; then
  if git rev-parse --verify -q dev >/dev/null 2>&1 && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "dev" ]; then
    RANGE="dev..HEAD"
  else
    RANGE="HEAD~1..HEAD"
  fi
fi
DIFF="$(git diff "$RANGE" 2>/dev/null || true)"
if [ -z "$DIFF" ]; then
  echo "codex-review: empty diff for range '$RANGE' — nothing to review." >&2
  exit 0
fi

PROMPT="${CODEX_REVIEW_PROMPT:-You are a contrarian code reviewer from a different model family. Review this diff adversarially: name correctness bugs, security issues, and risky assumptions a same-family reviewer might share. Be specific and concise; if you find nothing material, say so.}"

# Validate the (overridable) codex subcommand — the money-path floor must hold
# even if CODEX_EXEC_ARGS is set. Allow only exec|review, and never a login /
# api-key / access-token form that would route to METERED billing or a key login.
set -- ${CODEX_EXEC_ARGS:-exec}
case "${1:-}" in
  exec|review) : ;;
  *) advisory_down "CODEX_EXEC_ARGS subcommand '${1:-}' not allowed (must be exec or review)." ;;
esac
for __t in "$@"; do
  case "$__t" in
    login|--with-api-key|--with-access-token|--api-key|--with-*)
      advisory_down "CODEX_EXEC_ARGS contains a forbidden token '$__t' (would enable metered/login auth)." ;;
  esac
done

if [ "$CHECK" -eq 1 ]; then
  echo "codex-review: auth OK (subscription); would review range '$RANGE' ($(printf '%s' "$DIFF" | grep -c '' | tr -d ' ') diff lines) via '$CODEX_BIN ${CODEX_EXEC_ARGS:-exec} --ignore-user-config -c model_reasoning_effort=xhigh'."
  exit 0
fi

# Invoke codex non-interactively on a subscription (verified above). The diff +
# prompt go in on stdin; we NEVER pass --with-api-key, and --ignore-user-config
# neutralizes a config.toml / CODEX_HOME model_provider redirect to a metered
# endpoint (auth still uses the subscription). Because --ignore-user-config also
# skips the user's effort pin, reasoning effort is pinned to MAX (xhigh)
# explicitly here — the review lane always runs at full depth. This is the one
# line the CTO validates on first real run (see header note).
printf '%s\n\n--- DIFF (%s) ---\n%s\n' "$PROMPT" "$RANGE" "$DIFF" \
  | "$CODEX_BIN" ${CODEX_EXEC_ARGS:-exec} --ignore-user-config -c model_reasoning_effort=xhigh 2>&1
echo ""
echo "codex-review: advisory output above — input to your judgment, NEVER a gate (TEAM_LEAD.md §Codex contrarian review lane). Disagreement escalates to the operator; it never loops."
exit 0
