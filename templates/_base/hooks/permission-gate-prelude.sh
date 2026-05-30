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
# REPO-SCOPE HELPERS — confine a swarm to its own repo.
# A swarm's $CWD is its repo root. Reads/writes that stay under $CWD are safe;
# anything outside is NOT auto-allowed — it falls through to a human (defer),
# except a narrow allowlist of read-only system/tooling roots (so `cat`-ing a
# system file or the swarm helper dir doesn't need a prompt). Writes get a
# stricter allowlist (cwd + temp only) than reads.
# ---------------------------------------------------------------------------
_under() {  # _under <path> <root>: true if path == root or is under root/
  case "$1" in "$2"|"$2"/*) return 0 ;; esac
  return 1
}
_read_root_ok() {  # absolute path readable without a prompt?
  local p="$1"
  [ -n "$CWD" ] && _under "$p" "$CWD" && return 0
  [ -n "${SWARM_HOME:-}" ] && _under "$p" "$SWARM_HOME/bin" && return 0
  case "$p" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    /usr/*|/bin/*|/sbin/*|/opt/*|/Library/*|/System/*|/etc/*|/private/etc/*) return 0 ;;
    /dev/null|/dev/stdin|/dev/stdout|/dev/stderr|/dev/fd/*) return 0 ;;
  esac
  return 1
}
_write_root_ok() {  # absolute path writable without a prompt? (stricter than read)
  local p="$1"
  [ -n "$CWD" ] && _under "$p" "$CWD" && return 0
  case "$p" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    /dev/null|/dev/stdout|/dev/stderr|/dev/fd/*) return 0 ;;
  esac
  return 1
}
# Auto-allow a safe Bash utility ONLY if every path it touches stays in scope
# and it contains no parent-dir traversal. A redirect (>) or mkdir/touch makes
# it a write -> the stricter write scope applies. Tokenized with shlex (not a
# regex) so a slash inside a relative path (src/app.js) isn't mistaken for an
# absolute path, and ~/… or $HOME/… can't smuggle a path past the check.
# NOTE: the allowlist roots here MUST stay in sync with _read_root_ok /
# _write_root_ok above (used by the read-tool branch).
_bash_util_in_scope() {
  CWD="$CWD" SWARM_HOME="${SWARM_HOME:-}" python3 - "$1" <<'PY' 2>/dev/null
import os, sys, shlex
cmd = sys.argv[1]
cwd = os.environ.get("CWD", "")
swarm = os.environ.get("SWARM_HOME", "")
if ".." in cmd:                      # any parent-dir traversal -> human
    sys.exit(1)
try:
    toks = shlex.split(cmd, posix=True)
except Exception:
    sys.exit(1)                      # unparseable -> human
write = any(t in (">", ">>") for t in toks) or any(t in ("mkdir", "touch") for t in toks)
def under(p, root):
    return bool(root) and (p == root or p.startswith(root.rstrip("/") + "/"))
READ_ROOTS = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
              "/usr/", "/bin/", "/sbin/", "/opt/", "/Library/", "/System/", "/etc/", "/private/etc/")
WRITE_ROOTS = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
def read_ok(p):
    if under(p, cwd): return True
    if swarm and under(p, swarm + "/bin"): return True
    if any(p.startswith(r) for r in READ_ROOTS): return True
    return p in ("/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr") or p.startswith("/dev/fd/")
def write_ok(p):
    if under(p, cwd): return True
    if any(p.startswith(r) for r in WRITE_ROOTS): return True
    return p in ("/dev/null", "/dev/stdout", "/dev/stderr") or p.startswith("/dev/fd/")
for t in toks:
    if t.startswith("/"):
        if not (write_ok(t) if write else read_ok(t)): sys.exit(1)
    elif "/" in t and (t.startswith("~") or t.startswith("$")):
        sys.exit(1)                  # home/var-relative path we can't verify -> human
sys.exit(0)
PY
}

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
  Read|Glob|Grep|LS|NotebookRead)
    # Read-only — but confined to the repo. In-repo secret files stay denied
    # even though their path is in scope (the read-tool path bypasses the Bash
    # secret-regex and the Edit floor, so it needs its own guard).
    case "$FILE" in
      *.example|*.sample) : ;;   # *.env.example etc. are templates, safe to read
      *.env|*/.env|*.env.*|*/.env.*|*tokens.env|*access.json|*/.ssh/*|*/.aws/*|*/.gnupg/*|*.pem|*id_rsa*|*id_ed25519*)
        deny "read of secret/credential file" ;;
    esac
    case "$FILE" in
      "")    allow ;;                                  # no path -> defaults to cwd
      *..*)  defer ;;                                  # traversal -> human
      /*)    _read_root_ok "$FILE" && allow || defer ;; # absolute -> must be in scope
      *)     allow ;;                                  # relative, no .. -> under cwd
    esac
    ;;
  Edit|Write|MultiEdit|NotebookEdit) allow ;;       # passed the floor -> in-project, non-secret
  Bash)
    # Universally-safe shell utilities — auto-allowed only while they stay in
    # the repo scope (closes the `cat ../other-repo` read and `echo > /outside`
    # write escapes). Out-of-scope falls through to the archetype policy / human.
    if printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(ls|cat|grep|rg|find|echo|pwd|head|tail|wc|which|mkdir|touch)([[:space:]]|$)'; then
      _bash_util_in_scope "$CMD" && allow
    fi
    ;;
esac
