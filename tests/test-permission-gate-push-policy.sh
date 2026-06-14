#!/usr/bin/env bash
# test-permission-gate-push-policy.sh — pins the git-push policy added to the
# permission gate (ADR-0012): pushing is allowed to feature/worktree/topic
# branches and non-force to `dev` (staging), but DENIED to a protected branch
# (main/master), for any force-push, and for broad/destructive push; anything
# the classifier cannot statically prove safe DEFERS to a human (never fail
# open). The logic lives in the shared _git_push_class helper in
# templates/_base/hooks/permission-gate-prelude.sh and is exercised here through
# the COMPOSED gate (prelude + archetype policy + tail) — what a stamped repo
# actually runs — for BOTH archetypes, since the push policy is identical.
#
# Run from $SWARM_HOME:  bash tests/test-permission-gate-push-policy.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../templates"

# --- compose both archetype gates into temp files ---------------------------
ECTO_GATE="$(mktemp -t pg-push-ecto.XXXXXX)" || exit 1
CPO_GATE="$(mktemp -t pg-push-cpo.XXXXXX)"   || exit 1
WORK="$(mktemp -d -t pg-push-repo.XXXXXX)"   || exit 1
trap 'rm -f "$ECTO_GATE" "$CPO_GATE"; rm -rf "$WORK"' EXIT INT TERM

compose() {  # compose POLICY_FRAGMENT > OUTFILE
  cat "$TEMPLATES/_base/hooks/permission-gate-prelude.sh" \
      "$TEMPLATES/$1" \
      "$TEMPLATES/_base/hooks/permission-gate-tail.sh"
}
compose engineering-cto/hooks/permission-gate-policy.sh > "$ECTO_GATE"
compose cpo/hooks/permission-gate-policy.sh             > "$CPO_GATE"

# --- a real git repo so bare-push current-branch resolution is deterministic --
git -C "$WORK" init -q
git -C "$WORK" config user.email t@t
git -C "$WORK" config user.name  t
git -C "$WORK" commit -q --allow-empty -m init
git -C "$WORK" checkout -q -B feature-sample
on_branch() { git -C "$WORK" checkout -q -B "$1"; }

PASS=0; FAIL=0; FAILURES=""
# decide GATE CMD -> allow | deny | defer   (CWD is the temp git repo)
decide() {
  local gate="$1" cmd="$2" event out
  event="$(python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))
' "$cmd" "$WORK")"
  out="$(printf '%s' "$event" | bash "$gate" 2>/dev/null)"
  if   [ -z "$out" ]; then echo defer
  elif printf '%s' "$out" | grep -q '"behavior":"allow"'; then echo allow
  elif printf '%s' "$out" | grep -q '"behavior":"deny"';  then echo deny
  else echo "unknown:$out"; fi
}
# assert EXPECT CMD LABEL   — runs against BOTH archetype gates (policy is shared)
assert() {
  local exp="$1" cmd="$2" label="$3" g1 g2
  g1="$(decide "$ECTO_GATE" "$cmd")"
  g2="$(decide "$CPO_GATE" "$cmd")"
  if [ "$g1" = "$exp" ] && [ "$g2" = "$exp" ]; then
    printf '  PASS  [%s] %s\n' "$exp" "$label"; PASS=$((PASS+1))
  else
    printf '  FAIL  expected=%s ecto=%s cpo=%s  %s\n' "$exp" "$g1" "$g2" "$label" >&2
    FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $label (expected=$exp ecto=$g1 cpo=$g2)"
  fi
}
# assert_ecto / assert_cpo — single-archetype assertion
assert_one() {  # GATE EXPECT CMD LABEL
  local gate="$1" exp="$2" cmd="$3" label="$4" got
  got="$(decide "$gate" "$cmd")"
  if [ "$got" = "$exp" ]; then printf '  PASS  [%s] %s\n' "$exp" "$label"; PASS=$((PASS+1))
  else printf '  FAIL  expected=%s got=%s  %s\n' "$exp" "$got" "$label" >&2
    FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $label (expected=$exp got=$got)"; fi
}

echo "=== DENY: push to a protected branch (every refspec form) ==="
assert deny 'git push origin main'              'origin main'
assert deny 'git push origin master'            'origin master (master also protected)'
assert deny 'git push origin HEAD:main'         'HEAD:main'
assert deny 'git push origin dev:main'          'dev:main (dst is main)'
assert deny 'git push origin refs/heads/main'   'refs/heads/main'
assert deny 'git push origin heads/main'        'heads/main shorthand'
assert deny 'git push origin +main'             '+main (force + protected)'
assert deny 'git push origin :main'             ':main (delete main)'
assert deny 'git push -u origin main'           '-u origin main'

echo ""
echo "=== DENY: force-push and broad/destructive push (any target) ==="
assert deny 'git push --force origin feature'           '--force to feature'
assert deny 'git push -f origin feature'                '-f to feature'
assert deny 'git push --force-with-lease origin feature' '--force-with-lease'
assert deny 'git push origin +feature'                  '+feature (leading + = force)'
assert deny 'git push --mirror origin'                  '--mirror'
assert deny 'git push --all origin'                     '--all'
assert deny 'git push --delete origin feature'          '--delete'
assert deny 'git push -d origin feature'                '-d (delete)'
assert deny 'git push --prune origin feature'           '--prune'
assert deny 'git push origin :feature'                  ':feature (delete ref)'
assert deny 'git push origin refs/heads/*:refs/heads/*'  'wildcard refspec (pushes all branches incl main)'
assert deny 'git push -fu origin feature'               '-fu combined cluster (force)'
assert deny 'git push --repo=origin main'               '--repo=origin main (--repo shifts positionals; dst=main)'
assert deny 'git push --repo origin main'               '--repo origin main (space form; dst=main)'

echo ""
echo "=== ALLOW: routine push to a feature/worktree/topic branch + non-force dev ==="
assert allow 'git push origin feature'          'origin feature'
assert allow 'git push origin dev'              'origin dev (staging, non-force)'
assert allow 'git push origin worktree-alice'   'origin worktree-alice'
assert allow 'git push -u origin feature'       '-u origin feature (set-upstream)'
assert allow 'git push origin HEAD:feature'     'HEAD:feature'
assert allow 'git push origin main:dev'         'main:dev (src main, dst dev — dst is safe)'
assert allow 'git push origin feature --dry-run' 'feature --dry-run (known opt)'
assert allow 'git push --repo=origin feature'   '--repo=origin feature (dst=feature via --repo)'

echo ""
echo "=== ALLOW/DENY: bare push resolves the current branch ==="
on_branch feature-sample
assert allow 'git push'                 'bare push on a feature branch -> allow'
assert allow 'git push origin'          'remote-only push on a feature branch -> allow'
assert allow 'git push origin HEAD'     'HEAD push on a feature branch -> allow'
on_branch main
assert deny  'git push'                 'bare push while on main -> deny'
assert deny  'git push origin'          'remote-only push while on main -> deny'
assert deny  'git push origin HEAD'     'HEAD push while on main -> deny (HEAD resolves to main)'
on_branch feature-sample

echo ""
echo "=== DEFER: ambiguous / cannot statically prove safe (never fail open) ==="
assert defer 'git add -A && git push origin feature'  'compound push (non-main) -> defer'
assert defer 'git push $(echo origin) feature'        'command substitution -> defer'
assert defer 'git push --weird-flag origin feature'   'unknown long option -> defer'
assert defer 'git push -o ci.skip origin feature'     '-o push-option (takes value) -> defer'
assert defer 'git push -x origin feature'             'unknown short flag -> defer'

echo ""
echo "=== DENY backstop: a compound that contains a push-to-main is denied ==="
assert deny 'git add -A && git push origin main'      'compound w/ push-to-main -> deny (not defer)'
assert deny 'true; git push --force origin main'      'compound w/ force-to-main -> deny'

echo ""
echo "=== Regression: non-push git ops still behave; cpo main-push bug is fixed ==="
assert allow 'git status'                'git status -> allow (both archetypes)'
assert allow 'git commit -m wip'         'git commit -> allow (both archetypes)'
# Before ADR-0012 the cpo gate ALLOWED push to main (it only denied destructive
# variants). Pin that it is now denied on the cpo gate specifically.
assert_one "$CPO_GATE" deny  'git push origin main'  'cpo: push-to-main now DENIED (was a bug)'
assert_one "$CPO_GATE" allow 'git push origin feature' 'cpo: vision-repo branch push still allowed'

echo ""
echo "=== RED-TEAM REGRESSIONS (bypasses found + fixed during adversarial review) ==="
# A) leading safe-util + control operator must NOT smuggle a push past the policy
#    (the prelude util-allow short-circuit). A push-to-main in a compound denies;
#    a safe compound push defers; an all-util compound still allows.
assert deny  'echo x && git push origin main'    'util-prefix && push-to-main -> DENY (not allow)'
assert deny  'ls && git push --force origin feat' 'util-prefix && force-push -> DENY'
assert deny  'echo x | git push origin main'      'util-prefix | push-to-main -> DENY'
assert defer 'echo x && git push origin feature'  'util-prefix && safe push -> DEFER (compound)'
# the fast-path now only auto-allows a SINGLE simple util command; any operator
# (incl a pipe of two utils) falls through to the policy -> defer. Safe direction.
assert_one "$ECTO_GATE" defer 'cat a.txt | grep foo' 'util pipe now DEFERS (fast-path is single-command only)'
# a non-util second command no longer rides a util prefix into allow
assert defer 'echo x && rm b'                     'util-prefix && rm -> DEFER (was allow: prelude hole)'
# command substitution EXECUTES the inner push -> must DENY (it really pushes main)
assert deny  'echo $(git push origin main)'       'util + command-substitution push-to-main -> DENY'
assert deny  'echo `git push origin main`'        'util + backtick-substitution push-to-main -> DENY'
assert defer 'echo $(git push origin feature)'    'util + substitution safe push -> DEFER'
# E) newline-injection: a multi-statement command (the field parser turns the
#    newline into a ';' separator so the second statement is analyzed, not merged).
assert deny  "$(printf 'echo x\ngit push origin main')"      'newline-injection push-to-main -> DENY'
assert deny  "$(printf 'echo x\ngit push --force origin f')" 'newline-injection force-push -> DENY'
assert defer "$(printf 'echo x\ngit push origin feature')"   'newline-injection safe push -> DEFER (compound)'
# F) GLUED shell operators (no surrounding space) — shlex tokenizes them differently
#    than bash; the strict-allow regex rejects them so they take the complex path.
assert deny  'echo x; git push origin main'       'glued ";" + push-to-main -> DENY'
assert deny  'git push origin main; echo x'       'leading-git glued ";" push-to-main -> DENY'
assert deny  'echo x| git push origin main'       'glued "|" + push-to-main -> DENY'
assert deny  'echo x;git push --force origin feat' 'glued ";" + force-push -> DENY'
assert defer 'echo x; git push origin feature'    'glued ";" + safe push -> DEFER (complex)'
# G) ANSI-C quoting $'...' : bash yields literal `main`, shlex yields `$main`.
#    Sent as raw events to avoid shell-quoting ambiguity in the assert helper.
ansi_check() {  # EXPECT CMD LABEL
  local exp="$1" c="$2" label="$3" ev out got
  ev="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$c" "$WORK")"
  out="$(printf '%s' "$ev" | bash "$ECTO_GATE" 2>/dev/null)"
  if   [ -z "$out" ]; then got=defer
  elif printf '%s' "$out" | grep -q '"deny"'; then got=deny
  elif printf '%s' "$out" | grep -q '"allow"'; then got=allow; fi
  if [ "$got" = "$exp" ]; then printf '  PASS  [%s] %s\n' "$exp" "$label"; PASS=$((PASS+1))
  else printf '  FAIL  expected=%s got=%s  %s\n' "$exp" "$got" "$label" >&2; FAIL=$((FAIL+1))
    FAILURES="${FAILURES}
  - $label (expected=$exp got=$got)"; fi
}
ansi_check deny "git push origin \$'main'"     "ANSI-C \$'main' -> DENY (resolves to main)"
ansi_check deny "git push \$'--force' origin f" "ANSI-C \$'--force' -> DENY (force)"
ansi_check deny "git push origin \$'master'"   "ANSI-C \$'master' -> DENY"
# B) repo-redirect: --git-dir/--work-tree (=form) on a bare push -> cannot resolve -> DEFER
assert defer 'git --git-dir=/tmp/elsewhere/.git push'        '--git-dir= bare push -> DEFER (redirected repo)'
assert defer 'git --work-tree=/tmp/wt --git-dir=/tmp/wt/.git push origin HEAD' '--git-dir= HEAD push -> DEFER'
# D) case-folding: macOS folds Main->main; treat case-variants as protected
assert deny  'git push origin Main'   'origin Main -> DENY (case-insensitive)'
assert deny  'git push origin MASTER' 'origin MASTER -> DENY (case-insensitive)'

# C) empty / missing cwd on a bare push must DEFER, never resolve the gate's own dir
emptycwd_event='{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":""}'
OUT_E="$(printf '%s' "$emptycwd_event" | bash "$ECTO_GATE" 2>/dev/null)"
if [ -z "$OUT_E" ]; then printf '  PASS  [defer] bare push with EMPTY cwd -> defer (no fail-open)\n'; PASS=$((PASS+1))
else printf '  FAIL  empty-cwd bare push expected defer got: %s\n' "$OUT_E" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - empty-cwd bare push (got $OUT_E)"; fi

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
