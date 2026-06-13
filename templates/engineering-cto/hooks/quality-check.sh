#!/usr/bin/env bash
# quality-check.sh — PostToolUse hook. After an Edit/Write/MultiEdit to a source
# file, runs a fast per-file quality check (lint/typecheck) on the edited file and
# surfaces any findings to the model as additionalContext. PostToolUse CANNOT
# block (the edit already happened) — this is a NUDGE that puts lint/type errors
# in front of the model on the next turn, not a gate. The blocking quality floor
# is the TaskCompleted test-gate.
#
# Wired in settings.json under hooks.PostToolUse (matcher Edit|Write|MultiEdit).
# Contract: hook JSON on stdin. ALWAYS exits 0 (non-blocking). When the check
# finds problems it prints a PostToolUse additionalContext JSON to stdout.
#
# Resolving the check command, in priority order:
#   1) $QOFI_QUALITY_CMD   2) .claude/quality-cmd file   3) auto-detect (eslint).
# The command may contain the token {file}; it is replaced with the edited file's
# path. With no token, the file path is appended as the final argument. This keeps
# the hook stack-agnostic — a repo wires its own checker; the auto-detect is just
# the TS/Node default. Fail-OPEN: no toolchain resolved → exit 0 silently.

set -uo pipefail

EVENT="$(cat 2>/dev/null || true)"

# --- QOFI quality-hook runtime control (see test-gate.sh for the rationale) -
__qofi_hook="quality-check"
__qofi_disabled() {
  case "${QOFI_HOOK_PROFILE:-default}" in
    minimal|fast|off) return 0 ;;
  esac
  local _l="${QOFI_DISABLED_HOOKS:-}"; _l="${_l//,/ }"
  local _h
  for _h in $_l; do
    { [ "$_h" = "$__qofi_hook" ] || [ "$_h" = "all" ]; } && return 0
  done
  return 1
}
if __qofi_disabled; then
  echo "${__qofi_hook}: SKIPPED — disabled (QOFI_HOOK_PROFILE=${QOFI_HOOK_PROFILE:-default}, QOFI_DISABLED_HOOKS='${QOFI_DISABLED_HOOKS:-}')" >&2
  exit 0
fi
# --- end QOFI quality-hook runtime control ---------------------------------

# Extract the edited file path from the PostToolUse payload.
FILE="$(printf '%s' "$EVENT" | python3 -c '
import json, sys
try:
    e = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
ti = e.get("tool_input") or {}
print(ti.get("file_path") or ti.get("path") or "")
' 2>/dev/null)"

[ -z "$FILE" ] && exit 0          # nothing to check
[ -f "$FILE" ] || exit 0          # file gone (e.g. a delete) — nothing to lint

# Only handle source files a per-file lint/typecheck makes sense for. Extend the
# case as more stacks earn an auto-detect path.
case "$FILE" in
  *.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.mjs|*.cjs) : ;;
  *) exit 0 ;;
esac

# Resolve the work tree (worktree-topology fix — same as test-gate.sh).
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  cd "$ROOT" 2>/dev/null || exit 0
else
  ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
  cd "$ROOT" 2>/dev/null || exit 0
fi

# Resolve the check command.
CMD="${QOFI_QUALITY_CMD:-}"
if [ -z "$CMD" ] && [ -f .claude/quality-cmd ]; then
  CMD="$(cat .claude/quality-cmd)"
fi
if [ -z "$CMD" ]; then
  # Auto-detect: eslint over the single edited file, only if an eslint binary
  # AND a config are both present (else we'd error on every edit).
  if [ -x node_modules/.bin/eslint ] && ls .eslintrc* eslint.config.* >/dev/null 2>&1; then
    CMD="node_modules/.bin/eslint {file}"
  fi
fi
[ -z "$CMD" ] && exit 0            # no toolchain → fail-open nudge

# Build the run string from the OPERATOR-supplied CMD (trusted, exactly like
# test-gate.sh's $CLAUDE_TEST_CMD). The edited path is UNTRUSTED — the model
# chooses the filename — so it is NEVER interpolated into the command text: it is
# bound as positional $1 and the command refers to it via "$1". A {file} token is
# replaced with the literal reference "$1" (not the value). A metacharacter-laden
# filename therefore stays a single bound argument and cannot inject. (A raw
# interpolation here was a command-injection hole; parameter-expansion results are
# not re-scanned for command substitution, which is what closes it.)
set -- "$FILE"
case "$CMD" in
  *'{file}'*) RUN="${CMD//\{file\}/\"\$1\"}" ;;
  *)          RUN="$CMD \"\$1\"" ;;
esac

OUT="$(eval "$RUN" 2>&1)"; STATUS=$?
[ "$STATUS" -eq 0 ] && exit 0      # clean → say nothing

# Surface findings to the model as additionalContext (PostToolUse can't block).
printf '%s' "$OUT" | python3 -c '
import json, sys
out = sys.stdin.read().splitlines()
if len(out) > 40:
    out = out[:40] + ["... (%d more lines)" % (len(out) - 40)]
msg = "quality-check found issues in the file just edited:\n" + "\n".join(out)
print(json.dumps({
  "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}
}))
' 2>/dev/null || true
exit 0
