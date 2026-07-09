#!/usr/bin/env bash
# claude-review.sh — Claude (Fable) contrarian review lane (ADVISORY, never gating).
#
# The mirror of codex-review.sh for CODEX-engine swarms: pipes the integrated
# diff to Claude Code headless (`claude -p`) for a foreign-model second opinion
# on Codex-authored work. A different model family decorrelates the blind spots
# a same-family reviewer shares with the code's author — identical rationale to
# the Claude-engine lane, with the families swapped. Findings are INPUT TO THE
# LEAD'S JUDGMENT, never a gate: Claude gets a voice, not a veto.
#
# HARD MONEY-PATH FLOOR (same tier as codex-review.sh). This lane runs on the
# operator's Claude subscription (Max / keychain or CLAUDE_CODE_OAUTH_TOKEN).
# It must NEVER fall back to metered API-key billing — that flip would be
# unapproved Type-2 spend (CLAUDE.md §Real spend & money movement). So before
# invoking claude it REFUSES to run if ANTHROPIC_API_KEY or
# ANTHROPIC_AUTH_TOKEN is set (either routes billing to the metered API), and
# it goes ADVISORY-DOWN (loud notice, non-zero exit, no spend) if the claude
# CLI is absent. Advisory-down means "no contrarian input this run" — NOT a
# block; the lead proceeds with its own review.
#
# Usage:
#   bin/claude-review.sh [--range <git-range>] [--check]
#     --range   diff range to review (default: dev..HEAD, else HEAD~1..HEAD)
#     --check   run the auth guard + print the plan; do NOT invoke claude
#
# Env:
#   CLAUDE_BIN            claude binary (default: claude) — overridable for tests
#   CLAUDE_REVIEW_MODEL   model for the review (default: claude-fable-5)
#   CLAUDE_REVIEW_PROMPT  override the review instruction
#
# Bash 3.2-safe.

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${CLAUDE_REVIEW_MODEL:-claude-fable-5}"
RANGE=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || { echo "claude-review: --range requires a value" >&2; exit 2; }; RANGE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "claude-review: unknown arg: $1" >&2; exit 2 ;;
  esac
done

advisory_down() {  # reason
  echo "claude-review: ADVISORY-DOWN — $1" >&2
  echo "  The contrarian lane is OFF for this run (no Claude input). This is NOT a" >&2
  echo "  gate: proceed with your own review. Claude is a voice, not a veto." >&2
  exit 3
}

# --- HARD money-path floor: subscription auth only, never metered -----------
# 1) No metered API credential may be present in the environment. Either var
#    routes the claude CLI to per-token API billing instead of the operator's
#    subscription — exactly the flip the floor forbids.
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  if [ -n "${!k:-}" ]; then
    advisory_down "$k is set — that routes Claude to METERED billing (unapproved Type-2 spend). Unset it; this lane is subscription-only."
  fi
done
# 2) Claude CLI must be present. (Auth is the keychain login or
#    CLAUDE_CODE_OAUTH_TOKEN — both subscription credentials; a logged-out CLI
#    fails loudly on invocation without spending, which degrades to
#    advisory-down at the call site below.)
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || advisory_down "claude CLI not found (\$CLAUDE_BIN=$CLAUDE_BIN)."
# --- end money-path floor ---------------------------------------------------

# Resolve the diff range (same logic as codex-review.sh).
if [ -z "$RANGE" ]; then
  if git rev-parse --verify -q dev >/dev/null 2>&1 && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "dev" ]; then
    RANGE="dev..HEAD"
  else
    RANGE="HEAD~1..HEAD"
  fi
fi
DIFF="$(git diff "$RANGE" 2>/dev/null || true)"
if [ -z "$DIFF" ]; then
  echo "claude-review: empty diff for range '$RANGE' — nothing to review." >&2
  exit 0
fi

PROMPT="${CLAUDE_REVIEW_PROMPT:-You are a contrarian code reviewer from a different model family. Review this diff adversarially: name correctness bugs, security issues, and risky assumptions a same-family reviewer might share. Be specific and concise; if you find nothing material, say so.}"

if [ "$CHECK" -eq 1 ]; then
  echo "claude-review: auth OK (subscription); would review range '$RANGE' ($(printf '%s' "$DIFF" | grep -c '' | tr -d ' ') diff lines) via '$CLAUDE_BIN -p --model $MODEL'."
  exit 0
fi

# Invoke claude headless on the subscription (verified above). Diff + prompt on
# stdin; -p (print mode) runs one turn and exits. No tool permissions are
# granted (default deny-all in -p without flags), so the reviewer READS the
# diff from stdin and cannot touch the tree — a review, not an agent run.
out="$(printf '%s\n\n--- DIFF (%s) ---\n%s\n' "$PROMPT" "$RANGE" "$DIFF" \
  | "$CLAUDE_BIN" -p --model "$MODEL" 2>&1)" || advisory_down "claude invocation failed (logged out?): $out"
printf '%s\n' "$out"
echo ""
echo "claude-review: advisory output above — input to your judgment, NEVER a gate. Disagreement escalates to the operator; it never loops."
exit 0
