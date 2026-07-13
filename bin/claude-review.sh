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
#   bin/claude-review.sh --directive [--directive-file <path>] [--check]
#     --range   diff range to review (default: dev..HEAD, else HEAD~1..HEAD)
#     --directive review a CPO directive from stdin instead of a Git diff
#     --directive-file read that directive from a file (implies --directive)
#     --check   run the auth guard + print the plan; do NOT invoke claude
#
# Env:
#   CLAUDE_REVIEW_MODEL   model for the review (default: claude-fable-5)
#   CLAUDE_REVIEW_PROMPT  override the review instruction
#
# Bash 3.2-safe.

set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW_RUNNER="$SCRIPT_DIR/review-runner.py"
TRUSTED_CLI="$SCRIPT_DIR/trusted-cli.py"
PYTHON_BIN="/usr/bin/python3"
MODEL="${CLAUDE_REVIEW_MODEL:-claude-fable-5}"
RANGE=""
CHECK=0
MODE="diff"
DIRECTIVE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || { echo "claude-review: --range requires a value" >&2; exit 2; }; RANGE="$2"; shift 2 ;;
    --directive) MODE="directive"; shift ;;
    --directive-file) [ $# -ge 2 ] || { echo "claude-review: --directive-file requires a value" >&2; exit 2; }; MODE="directive"; DIRECTIVE_FILE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "claude-review: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "directive" ] && [ -n "$RANGE" ]; then
  echo "claude-review: --range cannot be combined with --directive" >&2
  exit 2
fi

advisory_down() {  # reason
  echo "claude-review: ADVISORY-DOWN — $1" >&2
  echo "  The contrarian lane is OFF for this run (no Claude input). This is NOT a" >&2
  echo "  gate: proceed with your own review. Claude is a voice, not a veto." >&2
  exit 3
}

if [ -n "${CLAUDE_BIN+x}" ]; then
  advisory_down "CLAUDE_BIN overrides are not accepted; production resolves a fixed trusted host CLI."
fi
[ -x "$PYTHON_BIN" ] || advisory_down "trusted python is missing: $PYTHON_BIN"
[ -f "$TRUSTED_CLI" ] && [ ! -L "$TRUSTED_CLI" ] || advisory_down "trusted CLI resolver missing: $TRUSTED_CLI"
[ -f "$REVIEW_RUNNER" ] && [ ! -L "$REVIEW_RUNNER" ] || advisory_down "bounded review runner missing: $REVIEW_RUNNER"
CLAUDE_PLAN="$($PYTHON_BIN -I -B "$TRUSTED_CLI" exec-plan claude 2>&1)"
resolver_rc=$?
[ "$resolver_rc" -eq 0 ] || advisory_down "$CLAUDE_PLAN"
old_ifs="$IFS"; IFS=$'\t'; set -f; set -- $CLAUDE_PLAN; set +f; IFS="$old_ifs"
[ $# -ge 1 ] || advisory_down "trusted Claude execution plan was empty"
CLAUDE_CMD=("$@")
CLI_PATH="$(dirname "${CLAUDE_CMD[0]}"):/usr/bin:/bin:/usr/sbin:/sbin"
REAL_HOME="$($PYTHON_BIN -I -B -c 'import os,pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))')" || advisory_down "could not resolve the account home"
USER_NAME="$(/usr/bin/id -un)" || advisory_down "could not resolve the account name"
CLAUDE_HOME_DIR="$REAL_HOME/.claude"
if ! "$PYTHON_BIN" -I -B - "$CLAUDE_HOME_DIR" <<'PY' >/dev/null 2>&1
import os, stat, sys
s = os.lstat(sys.argv[1])
assert stat.S_ISDIR(s.st_mode) and not stat.S_ISLNK(s.st_mode)
assert s.st_uid == os.getuid() and not (s.st_mode & 0o022)
PY
then
  advisory_down "Claude home must be a real current-user directory with no group/world write: $CLAUDE_HOME_DIR"
fi

# --- HARD money-path floor: subscription auth only, never metered -----------
# 1) No metered API credential may be present in the environment. Either var
#    routes the claude CLI to per-token API billing instead of the operator's
#    subscription — exactly the flip the floor forbids.
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  if [ -n "${!k:-}" ]; then
    advisory_down "$k is set — that routes Claude to METERED billing (unapproved Type-2 spend). Unset it; this lane is subscription-only."
  fi
done
# Provider-routing variables can override the otherwise valid Claude.ai login.
for k in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
         ANTHROPIC_BASE_URL ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL; do
  if [ -n "${!k:-}" ]; then
    advisory_down "$k is set — the review lane permits only the verified Claude.ai subscription route."
  fi
done
# All Claude invocations run outside the reviewed repository. Print mode skips
# the trust dialog; invoking it in an editable repo would otherwise load that
# repo's settings, hooks, plugins, commands, agents, and MCP configuration.
REVIEW_TMP_ROOT="$CLAUDE_HOME_DIR/qofi-review-tmp"
if [ -L "$REVIEW_TMP_ROOT" ]; then
  advisory_down "refusing symlinked review temp root: $REVIEW_TMP_ROOT"
fi
( umask 077; mkdir -p "$REVIEW_TMP_ROOT" ) || advisory_down "could not create private review temp root"
chmod 700 "$REVIEW_TMP_ROOT" 2>/dev/null || advisory_down "could not secure private review temp root"
review_owner="$(stat -f '%u' "$REVIEW_TMP_ROOT" 2>/dev/null || stat -c '%u' "$REVIEW_TMP_ROOT" 2>/dev/null || true)"
if [ -z "$review_owner" ] || [ "$review_owner" != "$(id -u)" ]; then
  advisory_down "review temp root is not owned by the current user: $REVIEW_TMP_ROOT"
fi
SAFE_REVIEW_CWD="$(mktemp -d "$REVIEW_TMP_ROOT/run.XXXXXX")" || advisory_down "could not create isolated review directory"
cleanup_review_cwd() {
  /bin/rm -rf -- "$SAFE_REVIEW_CWD"
}
trap cleanup_review_cwd EXIT INT TERM

auth_json="$(printf '' | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$SAFE_REVIEW_CWD" \
  --timeout 10 --max-input 1024 --max-output 65536 --clean-env \
  --set-env "HOME=$REAL_HOME" --set-env "PATH=$CLI_PATH" \
  --set-env "USER=$USER_NAME" --set-env "LOGNAME=$USER_NAME" \
  --pass-env CLAUDE_CODE_OAUTH_TOKEN -- \
  "${CLAUDE_CMD[@]}" auth status --json 2>&1)"
auth_rc=$?
if [ "$auth_rc" -ne 0 ]; then
  advisory_down "claude auth status failed — log in with a Claude subscription."
fi
if ! printf '%s' "$auth_json" | "$PYTHON_BIN" -I -B -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("loggedIn") is True
assert d.get("authMethod") == "claude.ai"
assert d.get("apiProvider") == "firstParty"
assert isinstance(d.get("subscriptionType"), str) and d["subscriptionType"].strip()
' >/dev/null 2>&1; then
  advisory_down "claude auth status is not a recognized Claude.ai subscription session."
fi
# --- end money-path floor ---------------------------------------------------

ORIGINAL_CWD="$(pwd -P)"
if [ "$MODE" = "directive" ]; then
  if [ -n "$DIRECTIVE_FILE" ]; then
    PAYLOAD="$(printf '' | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$SAFE_REVIEW_CWD" --timeout 10 \
      --max-input 5000000 --max-output 5000001 \
      --input-root "$ORIGINAL_CWD" --input-file "$DIRECTIVE_FILE" -- /bin/cat 2>&1)"
  else
    PAYLOAD="$("$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$SAFE_REVIEW_CWD" --timeout 10 \
      --max-input 5000000 --max-output 5000001 -- /bin/cat 2>&1)"
  fi
  capture_rc=$?
  if [ "$capture_rc" -ne 0 ]; then
    capture_detail="$(printf '%s' "$PAYLOAD" | tail -c 4096)"
    advisory_down "directive input could not be bounded to 5000000 bytes: $capture_detail"
  fi
  if [ -z "$PAYLOAD" ]; then
    echo "claude-review: empty directive — nothing to review." >&2
    exit 0
  fi
  INPUT_LABEL="DRAFT DIRECTIVE"
  PLAN_LABEL="bounded directive"
  PROMPT="${CLAUDE_REVIEW_PROMPT:-You are an adversarial reviewer from a different model family. Review this draft directive from a Chief Product Officer to an engineering CTO. Attack the plan, not the prose: name missing requirements, unstated assumptions, ambiguity, sequencing errors, and under- or over-specified scope. Be specific and concise; if you find nothing material, say so.}"
else
  bounded_git() {
    printf '' | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" \
      --timeout 30 --max-input 1024 --max-output 5000001 -- /usr/bin/env -i \
      HOME="$REAL_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" USER="$USER_NAME" LOGNAME="$USER_NAME" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
      GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
      /usr/bin/git --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
  }

  # Only commit-to-commit ranges are accepted. A one-revision `git diff HEAD`
  # consults the worktree and can execute a repo-configured clean filter before
  # the no-tools reviewer starts.
  if [ -z "$RANGE" ]; then
    if bounded_git show-ref --verify --quiet refs/heads/dev >/dev/null 2>&1 && \
       [ "$(bounded_git symbolic-ref --short -q HEAD 2>/dev/null)" != "dev" ]; then
      RANGE="dev..HEAD"
    else
      RANGE="HEAD~1..HEAD"
    fi
  fi
  RANGE_PLAN="$("$PYTHON_BIN" -I -B - "$RANGE" <<'PY'
import re, sys
value = sys.argv[1]
if not (1 <= len(value) <= 512):
    raise SystemExit(2)
atom = r'[A-Za-z0-9][A-Za-z0-9._/@{}~^:+-]{0,200}'
match = re.fullmatch(r'(%s)(\.\.\.?)(%s)' % (atom, atom), value)
if not match or '..' in match.group(1) or '..' in match.group(3):
    raise SystemExit(2)
print('|'.join((match.group(2), match.group(1), match.group(3))))
PY
)"; range_rc=$?
  [ "$range_rc" -eq 0 ] || { echo "claude-review: --range must be a bounded A..B or A...B commit range" >&2; exit 2; }
  IFS='|' read -r RANGE_KIND LEFT_REF RIGHT_REF <<EOF
$RANGE_PLAN
EOF
  LEFT_HASH="$(bounded_git rev-parse --verify --end-of-options "${LEFT_REF}^{commit}" 2>&1)"; left_rc=$?
  RIGHT_HASH="$(bounded_git rev-parse --verify --end-of-options "${RIGHT_REF}^{commit}" 2>&1)"; right_rc=$?
  if [ "$left_rc" -ne 0 ] || [ "$right_rc" -ne 0 ] || \
     ! printf '%s\n' "$LEFT_HASH" | /usr/bin/grep -Eq '^[0-9a-f]{40,64}$' || \
     ! printf '%s\n' "$RIGHT_HASH" | /usr/bin/grep -Eq '^[0-9a-f]{40,64}$'; then
    advisory_down "git range endpoints did not resolve to exact commits: $RANGE"
  fi
  if [ "$RANGE_KIND" = "..." ]; then
    DIFF_LEFT="$(bounded_git merge-base "$LEFT_HASH" "$RIGHT_HASH" 2>&1)"; merge_rc=$?
    [ "$merge_rc" -eq 0 ] && printf '%s\n' "$DIFF_LEFT" | /usr/bin/grep -Eq '^[0-9a-f]{40,64}$' || \
      advisory_down "git merge-base failed for range '$RANGE'"
  else
    DIFF_LEFT="$LEFT_HASH"
  fi
  PAYLOAD="$(bounded_git diff --no-ext-diff --no-textconv "$DIFF_LEFT" "$RIGHT_HASH" -- 2>&1)"
  diff_rc=$?
  if [ "$diff_rc" -ne 0 ]; then
    diff_detail="$(printf '%s' "$PAYLOAD" | tail -c 4096)"
    case "$diff_rc" in
      125) advisory_down "diff for range '$RANGE' exceeded the bound; advisory input is limited to 5000000 bytes." ;;
      *) advisory_down "git diff failed for range '$RANGE': $diff_detail" ;;
    esac
  fi
  if [ -z "$PAYLOAD" ]; then
    echo "claude-review: empty diff for range '$RANGE' — nothing to review." >&2
    exit 0
  fi
  diff_bytes="$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')"
  if [ "$diff_bytes" -gt 5000000 ]; then
    advisory_down "diff for range '$RANGE' is ${diff_bytes} bytes; bounded advisory input is limited to 5000000 bytes."
  fi
  INPUT_LABEL="DIFF ($RANGE)"
  PLAN_LABEL="bounded commit diff for range '$RANGE'"
  PROMPT="${CLAUDE_REVIEW_PROMPT:-You are a contrarian code reviewer from a different model family. Review this diff adversarially: name correctness bugs, security issues, and risky assumptions a same-family reviewer might share. Be specific and concise; if you find nothing material, say so.}"
fi

if [ "$CHECK" -eq 1 ]; then
  echo "claude-review: auth OK (Claude.ai subscription); would review $PLAN_LABEL with model '$MODEL' from an isolated cwd with safe mode, no tools, no project settings/hooks/plugins/MCP/browser, and no persistence."
  exit 0
fi

# Diff + prompt are the only reviewed-repo input. Safe mode disables all
# customizations, the empty tool set prevents filesystem/shell access, strict
# empty MCP config closes ambient servers, and the run is not persisted.
out="$({ printf '%s\n\n--- %s ---\n%s\n' "$PROMPT" "$INPUT_LABEL" "$PAYLOAD"; } \
  | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$SAFE_REVIEW_CWD" \
      --timeout 180 --max-input 5242880 --max-output 1048576 --clean-env --sanitize-terminal \
      --set-env "HOME=$REAL_HOME" --set-env "PATH=$CLI_PATH" \
      --set-env "USER=$USER_NAME" --set-env "LOGNAME=$USER_NAME" \
      --set-env "TMPDIR=$SAFE_REVIEW_CWD" --pass-env CLAUDE_CODE_OAUTH_TOKEN -- \
      "${CLAUDE_CMD[@]}" -p --model "$MODEL" --safe-mode --tools "" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --disable-slash-commands --no-chrome --no-session-persistence \
        --permission-mode dontAsk --output-format text 2>&1)"
claude_rc=$?
if [ "$claude_rc" -ne 0 ]; then
  advisory_down "claude invocation failed (exit $claude_rc); no advisory result was produced."
fi
printf '%s\n' "$out"
echo ""
echo "claude-review: advisory output above — input to your judgment, NEVER a gate. Disagreement escalates to the operator; it never loops."
exit 0
