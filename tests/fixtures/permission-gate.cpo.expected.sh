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
    c = lambda s: ("" if s is None else str(s)).replace("\r\n"," ; ").replace("\n"," ; ").replace("\r"," ; ")
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
# This fast-path auto-allows only a SINGLE simple util command (optionally with a
# `>` redirect). ANY shell control operator or expansion means it is not a pure
# util invocation — a leading safe util could otherwise smuggle an arbitrary
# command (e.g. `echo x; git push origin main`, glued or spaced) past this allow
# and short-circuit the archetype policy that follows. shlex does NOT faithfully
# tokenize glued operators (`x;git`) or $'...'/$VAR, so reject the raw
# metacharacters outright and fall through to the policy / human.
for _bad in (";", "|", "&", "`", "$", "(", ")", "{", "}", "\\", "\n", "\r"):
    if _bad in cmd:
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
# GIT-PUSH CLASSIFIER — resolve a `git push` invocation to allow|deny|defer.
# Called by the archetype policy fragment for any command containing `git push`.
#
# SECURITY-PARSER DISCIPLINE (why this is regex-gated, not a full shell parse):
# an analyzer that tokenizes differently from bash is a fail-open hole — glued
# operators (`x;git push`), ANSI-C quoting (`$'main'` -> bash `main`, shlex
# `$main`), and `$VAR` expansion all diverge under any Python tokenizer. So ALLOW
# is gated by a STRICT whitelist: the command must be EXACTLY `git push` followed
# by tokens from a safe refspec/option charset with NO shell metacharacter, quote,
# operator, or expansion — for which `str.split` is provably identical to bash's
# argv, making the precise classification below sound. EVERY other command
# (operators, quotes, $/backtick, *, leading non-git, -C/--git-dir redirect, ...)
# is "complex": NEVER allowed — only a conservative deny (on a protected-branch or
# force/destructive signal) or defer. The durable floor is server-side GitHub
# branch protection on `main`; this gate is fast-fail convenience.
# Prints exactly one token: "allow" | "deny:<reason>" | "defer".
# ---------------------------------------------------------------------------
_git_push_class() {
  python3 - "$1" "${2:-}" <<'PY' 2>/dev/null || printf 'defer'
import sys, re, subprocess

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
cwd = sys.argv[2] if len(sys.argv) > 2 else ""
PROTECTED = ("main", "master")          # default/release branches — gate-protected

def out(s):
    sys.stdout.write(s)
    raise SystemExit(0)

def current_branch():
    if not cwd:                         # no repo context -> can't resolve -> defer
        return None
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    b = r.stdout.decode("utf-8", "replace").strip()
    return None if b in ("", "HEAD") else b   # "" / detached HEAD -> unknown

def norm(ref):
    d = ref
    if d.startswith("+"):
        d = d[1:]
    for pre in ("refs/heads/", "refs/", "heads/"):
        if d.startswith(pre):
            d = d[len(pre):]
    return d.strip("/")

VALUE_OPTS = ("-o", "--push-option", "--repo", "--receive-pack", "--exec",
              "--recurse-submodules")
KNOWN_LONG = ("--set-upstream", "--tags", "--follow-tags", "--atomic", "--no-atomic",
              "--dry-run", "--porcelain", "--verbose", "--quiet", "--progress",
              "--no-progress", "--thin", "--no-thin", "--ipv4", "--ipv6", "--signed",
              "--no-signed", "--verify", "--no-verify", "--no-recurse-submodules")

def classify_clean(args):
    # args: clean tokens after `git push` (no operators / quotes / expansion, so
    # these are exactly bash's argv). -> ("allow"|"deny"|"defer", reason).
    force = False
    positionals = []
    skip = False
    repo_via_opt = False                     # --repo supplies the remote, so every
                                             # positional is then a refspec (no remote arg)
    for t in args:
        if skip:
            skip = False; continue
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            if name in ("--force", "--force-with-lease", "--force-if-includes"):
                force = True
            elif name in ("--mirror", "--all"):
                return ("deny", "broad push (%s) writes many refs incl protected" % name)
            elif name == "--delete":
                return ("deny", "remote ref deletion (--delete)")
            elif name == "--prune":
                return ("deny", "remote ref pruning (--prune)")
            elif name == "--repo":
                repo_via_opt = True
                if "=" not in t:
                    skip = True             # next token is the repo value
            elif name in VALUE_OPTS:
                if "=" not in t:
                    skip = True             # next token is this option's value
            elif name in KNOWN_LONG:
                pass
            else:
                return ("defer", "")        # unknown long option -> human
        elif t.startswith("-") and t != "-":
            for ch in t[1:]:
                if ch == "f":
                    force = True
                elif ch == "d":
                    return ("deny", "remote ref deletion (-d)")
                elif ch in ("u", "n", "q", "v"):
                    pass
                else:
                    return ("defer", "")    # -o (takes a value) or unknown short flag
        else:
            positionals.append(t)
    # With --repo, all positionals are refspecs; otherwise positionals[0] is the remote.
    refspecs = positionals[:] if repo_via_opt else (positionals[1:] if positionals else [])
    for rs in refspecs:
        if rs.startswith("+"):
            force = True
    for rs in refspecs:
        spec = rs[1:] if rs.startswith("+") else rs
        if ":" in spec:
            src, dst = spec.split(":", 1)
            if src == "":
                return ("deny", "remote ref deletion (:%s)" % (dst or "?"))
        else:
            dst = spec
        d = norm(dst)
        if d == "@" or d.upper() == "HEAD":  # resolves to the current branch
            d = current_branch()
            if d is None:
                return ("defer", "")
        if d.lower() in PROTECTED:           # case-insensitive: macOS folds Main->main
            return ("deny", "push to protected branch %s" % d)
    if force:
        return ("deny", "force-push (destructive, never autonomous)")
    if not refspecs:                        # bare `git push` / `git push <remote>`
        cur = current_branch()
        if cur is None:
            return ("defer", "")
        if cur.lower() in PROTECTED:
            return ("deny", "push to protected branch %s" % cur)
        try:                                # push.default=matching can push extra refs
            pd = subprocess.run(["git", "-C", cwd, "config", "--get", "push.default"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            if pd.returncode == 0 and pd.stdout.decode("utf-8", "replace").strip() == "matching":
                return ("defer", "")
        except Exception:
            pass
        return ("allow", "")
    return ("allow", "")

# STRICT ALLOW gate: `git push` + only safe refspec/option tokens, nothing else.
# This charset contains no shell metacharacter / quote / expansion, so the command
# runs exactly as written and `str.split()` == bash argv -> classify_clean is sound.
STRICT = re.compile(r"^[ \t]*git[ \t]+push(?:[ \t]+[A-Za-z0-9._/@:+=-]+)*[ \t]*$")
if STRICT.match(cmd):
    v = classify_clean(cmd.split()[2:])
    if v[0] == "deny":
        out("deny:" + v[1])
    if v[0] == "defer":
        out("defer")
    out("allow")

# COMPLEX command (any operator / quote / $ / backtick / * / leading non-git /
# -C redirect / ...): NEVER allow. Conservatively DENY on a protected-branch or
# force/destructive signal anywhere in the raw string; otherwise DEFER. Deny-biased:
# false positives here only affect unusual compound/expanded pushes (-> escalate).
low = cmd.lower()
if re.search(r"(^|[^a-z0-9_./-])(main|master)([^a-z0-9_./-]|$)", low):
    out("deny:push to a protected branch (complex command)")
if (re.search(r"(^|[^A-Za-z0-9])(-f|--force|--force-with-lease|--force-if-includes|--mirror|--all|--delete|-d|--prune)([^A-Za-z0-9]|$)", cmd)
        or re.search(r"[^A-Za-z0-9]\+[A-Za-z0-9._/]", cmd)
        or re.search(r"[^A-Za-z0-9.]:[A-Za-z0-9._/]", cmd)
        or "*" in cmd):
    out("deny:force/destructive push (complex command)")
out("defer")
PY
}

# ---------------------------------------------------------------------------
# UNIVERSAL HARD FLOOR — always block. Mirrors ESCALATION.md "never auto-decide".
# Archetype-specific denies (e.g. the git-push policy) live in the archetype's
# policy fragment that follows this prelude.
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
# ---------------------------------------------------------------------------
# CPO ARCHETYPE POLICY — Bash deny + allow rules specific to the CPO swarm
# (a conversational product agent whose primary write action is editing
# markdown in its own product-vision repo and pushing to that repo's remote).
#
# DIVERGES FROM engineering-cto only in cadence: it commits + pushes markdown
# (refined specs, decision records) to its own product-vision repo so the
# operator can read them, and it has no test runners / worktree management /
# swarm-attention.sh (it surfaces directly via Discord per SURFACING.md). The
# git-push policy is now IDENTICAL to engineering-cto's — routine branch/dev
# push allowed, push to main/master + force + destructive denied, ambiguous
# deferred — via the shared _git_push_class in the prelude. See ADR-0012.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    # Git-push policy — vision-repo push (the cpo's function) is auto-allowed
    # for branch/non-force pushes; push to main/master, any force-push, and
    # broad/destructive push are denied; anything ambiguous defers to a human.
    # Resolved by the shared _git_push_class in the prelude (deny-biased, never
    # fail-open). The real floor is GitHub branch protection on the vision
    # repo's main. See ESCALATION.md / ADR-0012.
    if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+push([[:space:]]|$)'; then
      _pc="$(_git_push_class "$CMD" "$CWD")"
      case "$_pc" in
        allow)  allow ;;
        deny:*) deny "${_pc#deny:}" ;;
        *)      defer ;;
      esac
    fi

    # Plain git ops (read-only + add/commit/stash + checkout/switch + pull/fetch).
    # `push` is classified above, NOT here — so an ambiguous push that the
    # classifier defers cannot be swept into a broad allow.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+(status|diff|log|show|add|commit|stash|restore|checkout|switch|pull|fetch)([[:space:]]|$)' && allow

    # Branch ops — read-only/listing only. Cpo does not manage worktree
    # branches; branch creation/deletion defers to a human.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]*$' && allow
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]+(-v|--verbose|-vv|-a|--all|-r|--remotes|-l|--list|--show-current|--merged|--no-merged|--contains)([[:space:]]|$)' && allow
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
