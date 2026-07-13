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
#   bin/codex-review.sh --directive [--directive-file <path>] [--check]
#     --range   diff range to review (default: dev..HEAD, else HEAD~1..HEAD)
#     --directive review a CPO directive from stdin instead of a Git diff
#     --directive-file read that directive from a repo file
#     --check   run the auth guard + print the plan; do NOT invoke codex
#
# Env:
#   CODEX_EXEC_ARGS      compatibility knob; only the literal "exec" is accepted
#
# NOTE ON THE CODEX INVOCATION: this advisory lane is mechanically read-only.
# It prefers the dedicated hidden-UID runner. To preserve the historical Claude
# review lane on hosts that have only a normal Codex subscription login, it has
# a separately attested current-user compatibility route with every model tool
# disabled and an empty private cwd. Environment overrides cannot weaken either
# command shape, load operator configuration, or bypass approvals.

set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_HOME_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REVIEW_RUNNER="$SCRIPT_DIR/review-runner.py"
HOST_PREFLIGHT="$SCRIPT_DIR/codex-host-preflight.py"
MANAGER_CONTROL="$SCRIPT_DIR/codex-manager-control.py"
MANAGER_SOCKET="${HOME:-}/.codex/app-server-manager/control.sock"
PYTHON_BIN="/usr/bin/python3"
RANGE=""
CHECK=0
MODE="diff"
DIRECTIVE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || { echo "codex-review: --range requires a value" >&2; exit 2; }; RANGE="$2"; shift 2 ;;
    --directive) MODE="directive"; shift ;;
    --directive-file) [ $# -ge 2 ] || { echo "codex-review: --directive-file requires a value" >&2; exit 2; }; MODE="directive"; DIRECTIVE_FILE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "codex-review: unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ "$MODE" = "directive" ] && [ -n "$RANGE" ]; then
  echo "codex-review: --range cannot be combined with --directive" >&2
  exit 2
fi

advisory_down() {  # reason
  echo "codex-review: ADVISORY-DOWN — $1" >&2
  echo "  The contrarian lane is OFF for this run (no Codex input). This is NOT a" >&2
  echo "  gate: proceed with the Claude-side review. Codex is a voice, not a veto." >&2
  exit 3
}

if [ -n "${CODEX_BIN+x}" ] || [ -n "${CODEX_REVIEW_PROMPT+x}" ]; then
  advisory_down "CODEX_BIN/CODEX_REVIEW_PROMPT overrides are not accepted; production resolves a fixed trusted CLI and prompt."
fi
[ -x "$PYTHON_BIN" ] || advisory_down "trusted python is missing: $PYTHON_BIN"
[ -f "$REVIEW_RUNNER" ] && [ ! -L "$REVIEW_RUNNER" ] || advisory_down "bounded review runner missing: $REVIEW_RUNNER"
ORIGINAL_CWD="$(pwd -P)"
USER_NAME="$(/usr/bin/id -un)" || advisory_down "could not resolve the account name"

# --- HARD money-path floor: subscription auth only, never metered -----------
# 1) No metered API key may be present in the environment.
for k in OPENAI_API_KEY CODEX_API_KEY; do
  if [ -n "${!k:-}" ]; then
    advisory_down "$k is set — that routes Codex to METERED billing (unapproved Type-2 spend). Unset it; this lane is subscription-only."
  fi
done
# Prefer the already-running global App Server manager. Its review endpoint
# serializes the operation, reaps the shared App Server, and invokes the exact
# tool-less hidden-runtime root-runner command before later restoring the shared
# generation. A present-but-unhealthy endpoint is fail-closed; only an absent
# socket permits the historical dedicated/operator review route below.
HOST_CHECK_MODE="--review-check"
HOST_EXEC_MODE="--review-exec"
REVIEW_ROUTE="dedicated hidden-runtime"
MANAGER_REVIEW=0
DEDICATED_ERROR=""
if [ -e "$MANAGER_SOCKET" ] || [ -L "$MANAGER_SOCKET" ]; then
  [ -f "$MANAGER_CONTROL" ] && [ ! -L "$MANAGER_CONTROL" ] || \
    advisory_down "manager endpoint exists but its bounded control helper is missing"
  MANAGER_PLAN="$(/usr/bin/env -i HOME="${HOME:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
    "$PYTHON_BIN" -I -B "$MANAGER_CONTROL" --socket "$MANAGER_SOCKET" ready 2>&1)"
  manager_rc=$?
  [ "$manager_rc" -eq 0 ] || advisory_down "App Server manager endpoint exists but is not ready: $MANAGER_PLAN"
  MANAGER_REVIEW=1
  REVIEW_ROUTE="dedicated App Server manager"
  REAL_HOME="${HOME:-}"
else
  [ -f "$HOST_PREFLIGHT" ] && [ ! -L "$HOST_PREFLIGHT" ] || \
    advisory_down "dedicated-runtime host preflight missing: $HOST_PREFLIGHT"
  HOST_PLAN="$(/usr/bin/env -i HOME="${HOME:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
    "$PYTHON_BIN" -I -B "$HOST_PREFLIGHT" "$HOST_CHECK_MODE" "$ORIGINAL_CWD" "$SWARM_HOME_ROOT" 2>&1)"
  host_rc=$?
  if [ "$host_rc" -ne 0 ]; then
    DEDICATED_ERROR="$HOST_PLAN"
    HOST_CHECK_MODE="--operator-review-check"
    HOST_EXEC_MODE="--operator-review-exec"
    REVIEW_ROUTE="hardened current-user compatibility"
    HOST_PLAN="$(/usr/bin/env -i HOME="${HOME:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
      "$PYTHON_BIN" -I -B "$HOST_PREFLIGHT" "$HOST_CHECK_MODE" "$ORIGINAL_CWD" "$SWARM_HOME_ROOT" 2>&1)"
    host_rc=$?
    [ "$host_rc" -eq 0 ] || advisory_down "dedicated route: $DEDICATED_ERROR; current-user review route: $HOST_PLAN"
    echo "codex-review: dedicated runtime unavailable; using the tool-less current-user compatibility review route." >&2
  fi
  # Strip any ambient export attribute before parsing this parent-only witness.
  # It validates the host plan and is erased below; review child tools never
  # receive it in argv or environment.
  unset OPERATOR_CANARY_VALUE
  OPERATOR_CANARY_VALUE=""
  IFS='|' read -r CODEX_BIN_PATH BUN_PATH REAL_HOME CODEX_HOME_DIR CODEX_VERSION \
    CODEX_SCRIPT CLI_PATH RUNTIME_UID RUNTIME_USER RUNTIME_HOME RUNTIME_CODEX_HOME \
    RUNTIME_GID RUNTIME_GROUP ROOT_RUNNER RUNTIME_SCHEMA OPERATOR_CANARY_VALUE <<EOF
$HOST_PLAN
EOF
  if [ -z "$CODEX_BIN_PATH" ] || [ -z "$REAL_HOME" ] || [ -z "$CODEX_HOME_DIR" ] || \
     [ -z "$CODEX_VERSION" ] || [ -z "$CLI_PATH" ] || [ -z "$RUNTIME_UID" ] || \
     [ -z "$RUNTIME_USER" ] || [ -z "$RUNTIME_HOME" ] || \
     [ -z "$RUNTIME_CODEX_HOME" ] || [ -z "$RUNTIME_GID" ] || \
     [ -z "$RUNTIME_GROUP" ] || [ -z "$ROOT_RUNNER" ] || [ -z "$RUNTIME_SCHEMA" ]; then
    advisory_down "review host preflight returned an incomplete authority contract"
  fi
  case "$RUNTIME_SCHEMA:$REVIEW_ROUTE" in
    qofi-codex-runtime/v2:dedicated\ hidden-runtime)
      case "$OPERATOR_CANARY_VALUE" in
        ''|*[!A-Za-z0-9_.:-]*)
          advisory_down "review host preflight returned an invalid dedicated canary witness" ;;
      esac
      if [ "${#OPERATOR_CANARY_VALUE}" -lt 16 ] || [ "${#OPERATOR_CANARY_VALUE}" -gt 256 ]; then
        advisory_down "review host preflight returned an invalid dedicated canary witness"
      fi ;;
    qofi-codex-operator-review/v1:hardened\ current-user\ compatibility)
      [ -z "$OPERATOR_CANARY_VALUE" ] || \
        advisory_down "current-user review preflight unexpectedly returned a dedicated canary witness" ;;
    *) advisory_down "host preflight returned an unexpected review authority schema: $RUNTIME_SCHEMA" ;;
  esac
  OPERATOR_CANARY_VALUE=""
fi
# --- end money-path floor ---------------------------------------------------

bounded_git() {
  printf '' | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" \
    --timeout 30 --max-input 1024 --max-output 5000001 -- /usr/bin/env -i \
    HOME="$REAL_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" USER="$USER_NAME" LOGNAME="$USER_NAME" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
    /usr/bin/git --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

if [ "$MODE" = "directive" ]; then
  if [ -n "$DIRECTIVE_FILE" ]; then
    PAYLOAD="$(printf '' | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" --timeout 10 \
      --max-input 5000000 --max-output 5000001 \
      --input-root "$ORIGINAL_CWD" --input-file "$DIRECTIVE_FILE" -- /bin/cat 2>&1)"
  else
    PAYLOAD="$("$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" --timeout 10 \
      --max-input 5000000 --max-output 5000001 -- /bin/cat 2>&1)"
  fi
  capture_rc=$?
  [ "$capture_rc" -eq 0 ] || advisory_down "directive input could not be bounded to 5000000 bytes: $(printf '%s' "$PAYLOAD" | tail -c 4096)"
  if [ -z "$PAYLOAD" ]; then
    echo "codex-review: empty directive — nothing to review." >&2
    exit 0
  fi
  INPUT_LABEL="DRAFT DIRECTIVE"
  PLAN_LABEL="bounded directive"
  PROMPT="You are an adversarial reviewer from a different model family. Review this draft directive from a Chief Product Officer to an engineering CTO. Attack the plan, not the prose: name missing requirements, unstated assumptions, ambiguity, sequencing errors, and under- or over-specified scope. Be specific and concise; if you find nothing material, say so."
else
  # Resolve the diff range.
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
pattern = r'(%s)(\.\.\.?)(%s)' % (atom, atom)
m = re.fullmatch(pattern, value)
if not m or '..' in m.group(1) or '..' in m.group(3):
    raise SystemExit(2)
print('|'.join((m.group(2),m.group(1),m.group(3))))
PY
)"; range_rc=$?
  [ "$range_rc" -eq 0 ] || { echo "codex-review: --range must be a bounded A..B or A...B commit range" >&2; exit 2; }
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
  # Hash-to-hash tree diff with terminal `--` never consults the worktree and
  # therefore cannot execute repo-configured clean/smudge filters. External
  # diff drivers and textconv are independently disabled.
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
    echo "codex-review: empty diff for range '$RANGE' — nothing to review." >&2
    exit 0
  fi
  diff_bytes="$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')"
  if [ "$diff_bytes" -gt 5000000 ]; then
    advisory_down "diff for range '$RANGE' is ${diff_bytes} bytes; bounded advisory input is limited to 5000000 bytes."
  fi
  INPUT_LABEL="DIFF ($RANGE)"
  PLAN_LABEL="bounded diff for range '$RANGE'"
  PROMPT="You are a contrarian code reviewer from a different model family. Review this diff adversarially: name correctness bugs, security issues, and risky assumptions a same-family reviewer might share. Be specific and concise; if you find nothing material, say so."
fi

# Historical versions exposed a free-form CODEX_EXEC_ARGS escape hatch. Keep
# accepting the harmless default for compatibility, but reject every argument
# or alternate subcommand: those could weaken the read-only boundary.
if [ "${CODEX_EXEC_ARGS:-exec}" != "exec" ]; then
  advisory_down "CODEX_EXEC_ARGS may only be the literal 'exec'; command overrides cannot weaken the read-only review sandbox."
fi

if [ "$CHECK" -eq 1 ]; then
  echo "codex-review: auth OK (subscription); $PLAN_LABEL is ready through the $REVIEW_ROUTE route with the qofi-review-readonly permission profile, hooks/rules/plugins/apps/MCP/web/shell disabled, and ephemeral storage."
  exit 0
fi

# The manager route performs the same ephemeral tool-less root-runner review
# after reaping its shared upstream. With no manager socket, preserve the
# original hardened root-runner/operator invocation byte-for-byte.
if [ "$MANAGER_REVIEW" -eq 1 ]; then
  { printf '%s\n\n--- %s ---\n%s\n' "$PROMPT" "$INPUT_LABEL" "$PAYLOAD"; } \
    | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" \
        --timeout 190 --max-input 5242880 --max-output 1048576 --sanitize-terminal -- \
        /usr/bin/env -i HOME="$REAL_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        USER="$USER_NAME" LOGNAME="$USER_NAME" \
        "$PYTHON_BIN" -I -B "$MANAGER_CONTROL" --socket "$MANAGER_SOCKET" review 2>&1
else
  # The host helper cleans and owns `<runtime_home>/.tmp/review`, replaces
  # caller cwd options with that empty directory, and passes input on stdin.
  { printf '%s\n\n--- %s ---\n%s\n' "$PROMPT" "$INPUT_LABEL" "$PAYLOAD"; } \
    | "$PYTHON_BIN" -I -B "$REVIEW_RUNNER" --cwd "$ORIGINAL_CWD" \
        --timeout 180 --max-input 5242880 --max-output 1048576 --sanitize-terminal -- \
        /usr/bin/env -i HOME="$REAL_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        USER="$USER_NAME" LOGNAME="$USER_NAME" \
        "$PYTHON_BIN" -I -B "$HOST_PREFLIGHT" "$HOST_EXEC_MODE" "$ORIGINAL_CWD" "$SWARM_HOME_ROOT" -- \
        exec --ignore-user-config --ignore-rules --ephemeral \
        --skip-git-repo-check -C "$ORIGINAL_CWD" \
        --disable hooks --disable plugins --disable plugin_sharing \
        --disable remote_plugin --disable apps --disable browser_use \
        --disable browser_use_external --disable browser_use_full_cdp_access \
        --disable in_app_browser --disable computer_use --disable image_generation \
        --disable skill_mcp_dependency_install --disable tool_call_mcp_elicitation \
        --disable auth_elicitation --disable tool_suggest --disable code_mode_host \
        --disable goals --disable memories --disable chronicle --disable multi_agent \
        --disable workspace_dependencies --disable shell_snapshot \
        --disable shell_tool --disable unified_exec \
        -c 'default_permissions="qofi-review-readonly"' \
        -c 'permissions.qofi-review-readonly.filesystem={":root"="deny",":minimal"="read",":workspace_roots"={"."="deny"},":tmpdir"="deny",":slash_tmp"="deny"}' \
        -c 'permissions.qofi-review-readonly.network.enabled=false' \
        -c 'allow_login_shell=false' -c 'web_search="disabled"' \
        -c 'approval_policy="never"' -c 'forced_login_method="chatgpt"' \
        -c 'cli_auth_credentials_store="file"' \
        -c 'project_doc_max_bytes=0' \
        -c 'mcp_servers={}' \
        -c 'shell_environment_policy.inherit="core"' \
        -c 'shell_environment_policy.ignore_default_excludes=false' \
        -c 'model="gpt-5.6-sol"' \
        -c 'model_reasoning_effort="ultra"' review - 2>&1
fi
codex_rc=$?
if [ "$codex_rc" -ne 0 ]; then
  advisory_down "Codex invocation failed (exit $codex_rc); no advisory result was produced."
fi
echo ""
echo "codex-review: advisory output above — input to your judgment, NEVER a gate (TEAM_LEAD.md §Codex contrarian review lane). Disagreement escalates to the operator; it never loops."
exit 0
