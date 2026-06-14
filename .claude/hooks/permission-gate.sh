#!/usr/bin/env bash
# permission-gate.sh — PermissionRequest hook for the swarm.
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
#
# Deploy carefully: first run it as deny-everything to confirm it actually gates,
# then enable the allow rules. Tune the tool names/patterns to your environment.

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
# GIT-PUSH CLASSIFIER — resolve a `git push` invocation to allow|deny|defer.
# Called by the archetype policy fragment for any command containing `git push`.
#
# POLICY: DENY any push (force or not) whose destination is a PROTECTED branch;
# ALLOW non-force push AND force-push (rebase/squash) to non-protected branches;
# DENY broad/destructive push (--mirror/--all/--delete/--prune/wildcard/ref-delete);
# DEFER anything not statically provable. The protected set is repo-aware (see
# protected_set(): {main,master} ∪ the repo's release branch, fail-safe +dev).
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
# broad-destructive signal) or defer (incl. an unresolved force target). The
# durable floor is server-side GitHub branch protection; this gate is fast-fail
# convenience. Prints exactly one token: "allow" | "deny:<reason>" | "defer".
# ---------------------------------------------------------------------------
_git_push_class() {
  python3 - "$1" "${2:-}" <<'PY' 2>/dev/null || printf 'defer'
import sys, os, re, subprocess

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
cwd = sys.argv[2] if len(sys.argv) > 2 else ""

def protected_set():
    # Repo-aware protected branches = {main, master} ∪ the repo's release branch.
    # main/master are ALWAYS protected. The release branch is resolved from, in
    # order: (1) an explicit override — env SWARM_PROTECTED_BRANCHES or the file
    # .claude/protected-branches (a list; main/master kept regardless); (2) the
    # repo's default branch via origin/HEAD; (3) FAIL-SAFE — when neither resolves
    # we protect MORE by adding `dev`, never less. This is the single knob the
    # operator flips per repo (e.g. to mark a repo's `dev` staging-and-pushable,
    # write its real release branch(es) to .claude/protected-branches).
    prot = set(["main", "master"])
    raw = os.environ.get("SWARM_PROTECTED_BRANCHES")
    if raw is None and cwd:
        try:
            with open(os.path.join(cwd, ".claude", "protected-branches"), encoding="utf-8") as fh:
                raw = fh.read()
        except Exception:
            raw = None
    if raw is not None:                          # explicit override present
        for line in raw.splitlines():
            for tok in line.split("#", 1)[0].split():
                prot.add(tok.lower())
        return frozenset(prot)
    if cwd:                                       # dynamic: repo default (release) branch
        try:
            r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short",
                                "refs/remotes/origin/HEAD"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            if r.returncode == 0:
                d = r.stdout.decode("utf-8", "replace").strip()
                if d.startswith("origin/"):
                    d = d[len("origin/"):]
                if d:
                    prot.add(d.lower())
                    return frozenset(prot)
        except Exception:
            pass
    prot.add("dev")                               # fail-safe: protect more, never less
    return frozenset(prot)

PROTECTED = protected_set()

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
    # Force-push is ALLOWED to a non-protected branch (routine rebase/squash of a
    # feature/worktree branch). A force-push to a protected branch was already
    # denied by the dst check above; an unresolvable force target defers below.
    # (`force` is parsed so the flags are recognized, but no longer auto-denies.)
    if not refspecs:                        # bare `git push` / `git push <remote>`
        cur = current_branch()
        if cur is None:
            return ("defer", "")
        if cur.lower() in PROTECTED:
            return ("deny", "push to protected branch %s" % cur)
        # (remote.<r>.push / remote.<r>.mirror redirects are handled before the
        # strict-allow gate, so by here no push-refspec config is in play.)
        # The DESTINATION of a bare push depends on push.default — the current
        # branch NAME is the real dst only for current/simple. With
        # `upstream`/`tracking` the dst is branch.<cur>.merge, which can be a
        # PROTECTED branch even when the current branch is not (so a bare push
        # writes the protected branch); `matching` can push many refs. Resolve the
        # real dst and defer on anything unresolved.
        def _cfg(key):
            try:
                r = subprocess.run(["git", "-C", cwd, "config", "--get", key],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            except Exception:
                return None                 # subprocess failure -> caller defers
            return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""
        pd = _cfg("push.default")
        if pd is None:
            return ("defer", "")
        pd = pd or "simple"                 # git's default since 2.0
        if pd == "matching":
            return ("defer", "")            # can push multiple refs incl protected
        if pd in ("upstream", "tracking"):
            up = _cfg("branch.%s.merge" % cur)
            if not up:                      # None (error) or unset upstream -> human
                return ("defer", "")
            if norm(up).lower() in PROTECTED:
                return ("deny", "bare push targets protected upstream %s (push.default=%s)"
                        % (norm(up), pd))
            return ("allow", "")
        if pd in ("current", "simple", "nothing"):
            # current: dst = current branch (already checked non-protected).
            # simple: dst = current branch's SAME-NAME upstream; git refuses on a
            #   name mismatch, so the only ref it writes is `cur` (non-protected).
            # nothing: a bare push needs an explicit refspec -> git errors, no write.
            return ("allow", "")
        return ("defer", "")                # unknown push.default -> human
    return ("allow", "")

# DESTINATION-REDIRECTING CONFIG — these ignore the command-line dst and redirect
# the push to a ref the command doesn't name, so they affect EXPLICIT-refspec pushes
# too and must be checked BEFORE the strict-allow gate:
#   remote.<r>.mirror=true   mirror-pushes ALL refs (incl protected) on any push to
#                            that remote — the config form of `--mirror`         -> DENY
#   remote.<r>.push=SRC:DST  redirects even `git push origin <ref>` to DST when SRC
#                            matches (DST can be a protected branch)             -> DEFER
# A subprocess failure to read config -> defer (never auto-allow).
def _cfg_regexp(pat):
    if not cwd:
        return []                           # no repo context -> no such config in play
    try:
        r = subprocess.run(["git", "-C", cwd, "config", "--get-regexp", pat],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    except Exception:
        return None                         # couldn't run git at all -> can't verify
    if r.returncode != 0:                   # no match (1) / not a git repo (128)
        return []
    return [ln for ln in r.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]

_mlines = _cfg_regexp(r"^remote\..*\.mirror$")
if _mlines is None:
    out("defer")
for _ln in _mlines:
    _parts = _ln.split(None, 1)
    _val = _parts[1].strip().lower() if len(_parts) > 1 else "true"
    if _val not in ("false", "no", "off", "0"):
        out("deny:remote mirror push (remote.*.mirror) writes all refs incl protected")
_plines = _cfg_regexp(r"^remote\..*\.push$")
if _plines is None:
    out("defer")
if _plines:
    out("defer")                            # a configured push refspec can redirect -> human

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
_prot_alt = "|".join(re.escape(b) for b in sorted(PROTECTED))
if re.search(r"(^|[^a-z0-9_./-])(" + _prot_alt + r")([^a-z0-9_./-]|$)", low):
    out("deny:push to a protected branch (complex command)")
# Broadly destructive — target-independent, always deny.
if (re.search(r"(^|[^A-Za-z0-9])(--mirror|--all|--delete|-d|--prune)([^A-Za-z0-9]|$)", cmd)
        or re.search(r"[^A-Za-z0-9.]:[A-Za-z0-9._/]", cmd)
        or "*" in cmd):
    out("deny:broad/destructive push (complex command)")
# Everything else — incl. a pure force-push (--force/-f/+ref) whose target we can't
# resolve in a complex command — DEFERS: force is allowed to non-protected branches,
# so an unresolved force target goes to a human, never auto-allow and never auto-deny.
out("defer")
PY
}

# ---------------------------------------------------------------------------
# HARD FLOOR — always block. Mirrors ESCALATION.md "never auto-decide".
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])rm[[:space:]]+-[a-zA-Z]*[rf]'                       && deny "recursive/forced delete"
    # git-push policy (ADR-0012): allow push to non-protected branches incl
    # force; deny push/force to protected (main/master + repo release branch);
    # deny broad/destructive; defer the rest. Repo-aware + strict-allow; runs in
    # the hard floor (before the util-allow) so a compound push can't be smuggled.
    if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+push([[:space:]]|$)'; then
      _pc="$(_git_push_class "$CMD" "$CWD")"
      case "$_pc" in
        allow)  allow ;;
        deny:*) deny "${_pc#deny:}" ;;
        *)      defer ;;
      esac
    fi
    printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])sudo([[:space:]]|$)'                                && deny "sudo"
    printf '%s' "$CMD" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sh|bash|zsh)'                          && deny "pipe-to-shell"
    printf '%s' "$CMD" | grep -Eqi '(npm[[:space:]]+publish|yarn[[:space:]]+publish|deploy|--prod|production)' && deny "publish/deploy/prod"
    printf '%s' "$CMD" | grep -Eq '(\.env|/\.ssh/|credential|secret|api[_-]?key|token)'                  && deny "touches secrets/credentials"
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
# ALLOWLIST — known-safe, auto-approve so the team isn't blocked.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Read|Glob|Grep|LS|NotebookRead) allow ;;          # read-only, always safe
  Edit|Write|MultiEdit|NotebookEdit) allow ;;       # passed the floor -> in-project, non-secret
  Bash)
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(node[[:space:]]+--test|npm[[:space:]]+(test|run[[:space:]]+test)|bun[[:space:]]+test|pnpm[[:space:]]+test|jest|vitest)([[:space:]]|$)' && allow
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
    # Single simple util only: reject shell control/expansion metacharacters so a
    # leading safe util cannot smuggle a second command past this allow.
    if printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(ls|cat|grep|rg|find|echo|pwd|head|tail|wc|which|mkdir|touch|node|npm[[:space:]]+(install|ci|run))([[:space:]]|$)' \
       && ! printf '%s' "$CMD" | grep -Eq '[;&|`$(){}]'; then
      allow
    fi
    ;;
esac

# Channel reply/react/edit tools, so the CTO can talk back without a prompt.
# Confirmed name from /mcp: mcp__plugin_discord-b2b_discord__reply. The narrow
# *__reply/__react/__edit_message suffixes catch the safe channel tools WITHOUT a
# broad *discord* glob (which would wrongly auto-allow e.g. a delete tool).
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
