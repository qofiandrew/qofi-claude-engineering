#!/usr/bin/env bash
# codex-directive-review.sh — Codex adversarial review of a CPO buildout
# directive (ADVISORY, never gating).
#
# CPO counterpart of the CTO's contrarian diff lane (bin/codex-review.sh in the
# swarm home; engineering-cto/TEAM_LEAD.md §Codex contrarian review lane). Pipes
# a DRAFT buildout-initiating directive to the OpenAI Codex CLI for a
# foreign-model second opinion BEFORE it ships on the bus. A different model
# family decorrelates the blind spots a Claude-authored plan shares with the
# Claude CTO that will execute it. Findings are INPUT TO THE CPO'S JUDGMENT,
# never a gate: Codex gets a voice, not a veto.
#
# HARD MONEY-PATH FLOOR (operator-ratified 2026-06-12, same floor as the CTO
# lane). This lane runs on a Codex SUBSCRIPTION (`codex login`). It must NEVER
# fall back to metered API-key billing — that flip would be unapproved Type-2
# spend (CLAUDE.md §Real spend & money movement). So before invoking codex it
# REFUSES to run if:
#   - OPENAI_API_KEY / CODEX_API_KEY is set in the environment — that routes
#     codex to metered billing; or
#   - codex is absent, or not logged in, or `codex login status` reports an
#     API-key / metered session rather than a subscription.
# On any such condition it goes ADVISORY-DOWN: prints a loud notice and exits
# non-zero WITHOUT calling codex. Advisory-down means "no adversarial input for
# this directive" — NOT a block. The CPO ships the directive without the
# review; this lane never stalls the bus.
#
# Usage:
#   .claude/bin/codex-directive-review.sh [--check] [FILE]
#     FILE      the draft directive to review; '-' or omitted = stdin
#     --check   run the auth guard + print the plan; do NOT invoke codex
#
# Env:
#   CODEX_BIN            codex binary (default: codex) — overridable for tests
#   CODEX_REVIEW_PROMPT  override the review instruction
#   CODEX_EXEC_ARGS      override the codex subcommand+args (default: "exec")

set -uo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
CHECK=0
INPUT="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) [ "$1" = "-" ] && { INPUT="-"; shift; continue; }
        echo "codex-directive-review: unknown arg: $1" >&2; exit 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done

advisory_down() {  # reason
  echo "codex-directive-review: ADVISORY-DOWN — $1" >&2
  echo "  The adversarial lane is OFF for this directive (no Codex input). This is" >&2
  echo "  NOT a block: ship the directive and continue. Codex is a voice, not a veto." >&2
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

# Read the draft directive.
if [ "$INPUT" = "-" ]; then
  DRAFT="$(cat)"
else
  [ -f "$INPUT" ] || { echo "codex-directive-review: no such file: $INPUT" >&2; exit 2; }
  DRAFT="$(cat "$INPUT")"
fi
if [ -z "$DRAFT" ]; then
  echo "codex-directive-review: empty draft — nothing to review." >&2
  exit 0
fi

PROMPT="${CODEX_REVIEW_PROMPT:-You are an adversarial reviewer from a different model family. This is a draft directive a Chief Product Officer is about to hand an engineering CTO to initiate build work. Attack the plan, not the prose: name missing requirements, unstated assumptions, ambiguities the executor will resolve wrong, scope that is under- or over-specified, sequencing errors, and risks a same-family reviewer would share. Be specific and concise; if you find nothing material, say so.}"

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
  echo "codex-directive-review: auth OK (subscription); would review draft ($(printf '%s' "$DRAFT" | grep -c '' | tr -d ' ') lines) via '$CODEX_BIN ${CODEX_EXEC_ARGS:-exec} --ignore-user-config -c model_reasoning_effort=xhigh'."
  exit 0
fi

# Invoke codex non-interactively on a subscription (verified above). The draft +
# prompt go in on stdin; we NEVER pass --with-api-key, and --ignore-user-config
# neutralizes a config.toml / CODEX_HOME model_provider redirect to a metered
# endpoint (auth still uses the subscription). Because --ignore-user-config also
# skips the user's effort pin, reasoning effort is pinned to MAX (xhigh)
# explicitly here — the review lane always runs at full depth.
printf '%s\n\n--- DRAFT DIRECTIVE ---\n%s\n' "$PROMPT" "$DRAFT" \
  | "$CODEX_BIN" ${CODEX_EXEC_ARGS:-exec} --ignore-user-config -c model_reasoning_effort=xhigh 2>&1
echo ""
echo "codex-directive-review: advisory output above — input to your judgment, NEVER a gate (CLAUDE.md §Codex adversarial review of buildout directives). One round: fold in what's right, ship; never loop draft-review-draft."
exit 0
