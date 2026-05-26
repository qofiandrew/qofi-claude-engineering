#!/usr/bin/env bash
# permission-gate.sh — PermissionRequest hook for the swarm.
#
# Composed from three fragments per archetype (see manifest.tsv):
#   _base/hooks/permission-gate-prelude.sh   (this file: universal floor + tool-level allows)
#   <archetype>/hooks/permission-gate-policy.sh  (archetype-specific deny + allow)
#   _base/hooks/permission-gate-tail.sh      (universal MCP allow + defer)
#
# Fires when a tool wants approval. It does one of three things:
#   ALLOW    — auto-approve a known-safe action, so the team keeps moving.
#   DENY     — block a hard-floor action and tell the agent to escalate.
#   (silent) — emit no decision -> normal flow runs (lead/human decides).
#
# SAFETY CONTRACT (do not weaken):
#   * Default is NOT allow. Anything not explicitly safe falls through to a human.
#   * On any error / parse failure, we fall through to a human. NEVER fail open.
#   * The DENY list mirrors ESCALATION.md's "hard floor" exactly.
#
# Uses python3 (ships with macOS) — no jq dependency.

set -uo pipefail

EVENT="$(cat)"

# Parse the fields we need with python3, one field per line (newlines stripped so
# each field is exactly one line — avoids read's whitespace-coalescing). On any
# failure all fields are empty and we fall through to a human, never auto-allow.
TOOL=""; CMD=""; FILE=""; CWD=""
{
  IFS= read -r TOOL
  IFS= read -r CMD
  IFS= read -r FILE
  IFS= read -r CWD
} < <(printf '%s' "$EVENT" | python3 -c '
import sys, json
try:
    e = json.load(sys.stdin); ti = e.get("tool_input") or {}
    c = lambda s: ("" if s is None else str(s)).replace("\n"," ").replace("\r"," ")
    for v in [e.get("tool_name"), ti.get("command"), ti.get("file_path") or ti.get("path"), e.get("cwd")]:
        print(c(v))
except Exception:
    print(); print(); print(); print()
' 2>/dev/null)

allow() { printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'; exit 0; }
deny()  { printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"permission-gate blocked ($1). Hard-floor action; escalate to the human per ESCALATION.md instead of retrying.\"}}}"; exit 0; }
defer() { exit 0; }   # no decision -> normal permission flow (lead / human)

# ---------------------------------------------------------------------------
# UNIVERSAL HARD FLOOR — always block. Mirrors ESCALATION.md "never auto-decide".
# Archetype-specific denies (e.g. git push for engineering-cto) live in the
# archetype's policy fragment that follows this prelude.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])rm[[:space:]]+-[a-zA-Z]*[rf]'                       && deny "recursive/forced delete"
    printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])sudo([[:space:]]|$)'                                && deny "sudo"
    printf '%s' "$CMD" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sh|bash|zsh)'                          && deny "pipe-to-shell"
    printf '%s' "$CMD" | grep -Eq '(\.env|/\.ssh/|credential|secret|api[_-]?key|token)'                  && deny "touches secrets/credentials"
    # The watcher's state dir ($STATE_DIR, default ~/.config/swarm/) holds the
    # heartbeat state files AND the CTO-raised attention flags. The ONLY
    # supported way for an agent to touch it is via $SWARM_HOME/bin/swarm-
    # attention.sh (narrowly allowlisted in archetype policy if used). Direct
    # redirects into the dir would bypass the helper's validation and could
    # corrupt watcher state. Block them universally.
    printf '%s' "$CMD" | grep -Eq '>[[:space:]>]*("?\$HOME"?|~|/Users/[^/]+|/home/[^/]+)/\.config/swarm/' && deny "direct write to swarm state dir — use \"\$SWARM_HOME\"/bin/swarm-attention.sh"
    ;;
  Edit|Write|MultiEdit|NotebookEdit)
    case "$FILE" in
      *access.json|*settings.json|*settings.local.json|*.env|*/.ssh/*|*credential*|*secret*)
        deny "edit of security/credential file" ;;
    esac
    printf '%s' "$FILE" | grep -q '\.\.' && deny "path traversal (..)"
    case "$FILE" in
      /*) [ -n "$CWD" ] && [ "${FILE#"$CWD"/}" = "$FILE" ] && deny "write outside project dir" ;;
    esac
    ;;
esac

# ---------------------------------------------------------------------------
# UNIVERSAL TOOL-LEVEL ALLOWS — known-safe regardless of archetype.
# Bash command-level allows live in the archetype policy fragment (each
# archetype decides its own set of safe shell commands).
# ---------------------------------------------------------------------------
case "$TOOL" in
  Read|Glob|Grep|LS|NotebookRead) allow ;;          # read-only, always safe
  Edit|Write|MultiEdit|NotebookEdit) allow ;;       # passed the floor -> in-project, non-secret
  Bash)
    # Universally-safe shell utilities (read-only or local-only mutation).
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(ls|cat|grep|rg|find|echo|pwd|head|tail|wc|which|mkdir|touch)([[:space:]]|$)' && allow
    ;;
esac
# ---------------------------------------------------------------------------
# ENGINEERING-CTO ARCHETYPE POLICY — Bash deny + allow rules specific to a
# product-engineering swarm (where the CTO commits + merges locally, the
# operator pushes to main, and teammate worktrees + npm test runners are the
# normal cadence). The universal floor + tool-level allows sit in
# _base/hooks/permission-gate-prelude.sh.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    # Archetype-specific HARD FLOOR — deny git push, npm publish, deploy/prod
    # commands. The CTO commits locally; pushing main is operator-only.
    printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push'                                                 && deny "git push"
    printf '%s' "$CMD" | grep -Eqi '(npm[[:space:]]+publish|yarn[[:space:]]+publish|deploy|--prod|production)' && deny "publish/deploy/prod"

    # Plain git ops (read-only + add/commit/stash + checkout/switch). Note:
    # `branch` is intentionally NOT in this group — branch operations have
    # their own narrowly-scoped block below so that `git branch -D dev` /
    # `git branch -D main` are NOT silently allowed by a bare `branch` token.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+(status|diff|log|show|add|commit|stash|restore|checkout|switch)([[:space:]]|$)' && allow
    # Branch ops — read-only/listing always allowed; deletion ONLY of
    # worktree-* branches (CTO routine teardown after merge to dev — see
    # TEAM_LEAD.md §Worktree teardown). dev / main / any non-worktree branch
    # deletion, branch rename (-m), and bare `git branch <name>` creation
    # still defer to the human. `git checkout -b` (above) covers branch
    # creation in the routine flow.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]*$' && allow
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]+(-v|--verbose|-vv|-a|--all|-r|--remotes|-l|--list|--show-current|--merged|--no-merged|--contains)([[:space:]]|$)' && allow
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]+(-[dD]|--delete)[[:space:]]+worktree-[a-zA-Z0-9_-]+[[:space:]]*$' && allow
    # Worktree ops — CTO routinely runs add (provisioning), remove
    # (teardown after merge), list (read-only), prune (clear stale
    # registrations). Other subcommands (move, lock, unlock, repair)
    # defer to the human.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+worktree[[:space:]]+(add|remove|list|prune)([[:space:]]|$)' && allow
    # Test runners + node + npm install/ci/run — engineering build cadence.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(node[[:space:]]+--test|npm[[:space:]]+(test|run[[:space:]]+test)|bun[[:space:]]+test|pnpm[[:space:]]+test|jest|vitest)([[:space:]]|$)' && allow
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(node|npm[[:space:]]+(install|ci|run))([[:space:]]|$)' && allow
    # CTO attention flag — the ONE scoped capability for writing into the
    # watcher's state dir. Doctrine (templates/ESCALATION.md §Attention flag)
    # pins the quoted-$SWARM_HOME form as canonical:
    #     "$SWARM_HOME/bin/swarm-attention.sh" raise "<reason>"
    # The regex also tolerates the env-quoted, unquoted, and absolute-path
    # equivalents as belt-and-suspenders against shell-quoting drift. Only
    # the three documented subcommands (raise|clear|status) match; anything
    # else with this script path defers to a human.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*("\$SWARM_HOME/bin/swarm-attention\.sh"|"\$SWARM_HOME"/bin/swarm-attention\.sh|\$SWARM_HOME/bin/swarm-attention\.sh|/[^[:space:]"]+/bin/swarm-attention\.sh)[[:space:]]+(raise|clear|status)([[:space:]]|$)' && allow
    ;;
esac
# ---------------------------------------------------------------------------
# UNIVERSAL MCP ALLOWS — Discord channel reply/react/edit, so the agent can
# talk back without a prompt. Confirmed name from /mcp:
#   mcp__plugin_discord-b2b_discord__reply
# The narrow *__reply / *__react / *__edit_message suffixes catch the safe
# channel tools WITHOUT a broad *discord* glob (which would wrongly auto-
# allow e.g. a delete tool).
# ---------------------------------------------------------------------------
case "$TOOL" in
  mcp__plugin_discord-b2b_discord__reply|*__reply|*__react|*__edit_message) allow ;;
esac

# ---------------------------------------------------------------------------
# GRAY ZONE — not clearly safe, not the hard floor -> a human decides.
# Default-deny-to-human, never default-allow. (v2: replace this with a
# model-judgment call that attaches a recommendation to the escalation — but
# auto-approve here only after you trust those recommendations.)
# ---------------------------------------------------------------------------
defer
