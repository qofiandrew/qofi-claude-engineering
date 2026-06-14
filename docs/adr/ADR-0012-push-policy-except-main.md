# ADR-0012 — Permission gate: allow push everywhere except a protected branch (push-policy-except-main)

**Status:** accepted
**Date:** 2026-06-13
**Reversibility:** two-way (permission-gate logic + doctrine text; no persistent surface).
**Escalated:** yes — operator decision, given as the directive that prompted this change.

---

## Context

The `permission-gate.sh` hook (the swarm's only local guard — swarms run as the
user under tmux with no OS sandbox) treated `git push` as a blanket hard floor:

- **engineering-cto** denied **every** push (`grep -Eq 'git[[:space:]]+push' && deny`).
- **cpo** allowed push but denied only destructive variants — and therefore
  **allowed `git push origin main`** on its vision repo (a real gap).

The blanket engineering-cto deny is friction for the actual cadence the doctrine
already endorses: teammates push their `worktree-<name>` branch to signal "ready"
(`CLAUDE.md` §*Scope & branches*), and the CTO pushes `dev` (staging) continuously
— which is also crash-safety, since unpushed work in a tmux RAM-only session is
lost if it dies. The gate over-denied relative to ESCALATION's actual floor, which
has always been **`main` is operator-only**, not "all push."

The operator decided: **pushing is allowed to everything — worktrees, feature
branches, and `dev` (a staging cloud environment) — except `main`, which is
reached only via a PR the operator approves.** The load-bearing control is
**server-side GitHub branch protection on `main`** (unbypassable, binds even the
operator); the local gate is fast-fail convenience that mirrors that floor.

## Decision

**Narrow the gate's git-push floor from "all push" to "push to a protected branch,
force-push, or destructive push"; auto-allow routine branch/`dev` push; defer
anything ambiguous — never fail open.** The classification is a single shared
helper, `_git_push_class`, in `templates/_base/hooks/permission-gate-prelude.sh`,
called identically by both archetype policy fragments (engineering-cto and cpo).
The push policy no longer diverges by archetype.

Classifier verdicts (`allow` | `deny:<reason>` | `defer`):

1. **DENY — protected branch.** Any push whose **destination** ref is
   `main`/`master`, in every form: `main`, `HEAD:main`, `dev:main`,
   `refs/heads/main`, `heads/main`, `+main`, `:main` (delete), `-u origin main`,
   and a **bare push while the current branch is `main`** (resolved via
   `git rev-parse --abbrev-ref HEAD`), and a `HEAD`/`@` refspec that resolves to a
   protected branch. `master` is protected alongside `main` as the default/release
   branch (a deny-biased default; trivially narrowed to `main`-only).

2. **DENY — force-push.** `--force`, `-f` (incl. clusters like `-fu`),
   `--force-with-lease`, `--force-if-includes`, or a `+refspec`. **[SUPERSEDED by
   the 2026-06-14 amendment below: force-push is now denied only to a *protected*
   branch and allowed to a non-protected feature/worktree branch; an unresolved
   force target defers.]** Also note: the protected set is repo-aware per the
   amendment, not just `main`/`master`.

3. **DENY — broad/destructive.** `--mirror`, `--all`, `--delete`/`-d`, `--prune`,
   and `:ref` deletions — they touch many/other refs (incl. protected) or destroy
   remote history.

4. **ALLOW — proven-safe push.** A single, fully-parsed push whose destination(s)
   are non-protected branches, with no force/destructive flag (e.g.
   `git push origin feature`, `git push origin dev`, `git push -u origin worktree-x`,
   bare push on a non-protected branch).

5. **DEFER — cannot statically prove safe.** Compound commands (`&&`/`||`/`;`/`|`),
   command substitution (`$(…)`/backticks), unknown options, options that take a
   value (`-o`), detached `HEAD`, an unresolvable `HEAD`/`@`, or a
   `-C`/`--git-dir`-redirected repo. A human decides; never auto-allow.
   **Backstop:** if a *compound* command contains a push that classifies as deny
   (e.g. `… && git push origin main`), the whole command is **denied**, not
   deferred.

The unchanged floors (`rm -rf`, `sudo`, pipe-to-shell, secret/credential
reads/edits, `npm/yarn publish`, `deploy`/`--prod`/`production`, the swarm
state-dir write guard, repo-scope confinement) are untouched — this edits only the
git-push rule.

## Architecture — strict-allow, because parsing shell is a fail-open trap

The gate is a security boundary with no OS sandbox behind it; a parser that
tokenizes *differently from bash* is a fail-open hole. Adversarial review proved
this repeatedly: an early "parse the push precisely" implementation was bypassed by
glued operators (`echo x;git push origin main` — `shlex` keeps `x;` as one token),
ANSI-C quoting (`git push origin $'main'` — `shlex` yields `$main`, bash yields
`main`), `$VAR` expansion, and a pre-existing prelude hole where the safe-util
fast-path (`echo|cat|…`) auto-allowed any command merely *starting* with a util,
short-circuiting the whole policy (this also defeated the `npm publish` deny).

The fix is architectural, not another patch. `_git_push_class` now emits `allow`
**only** when the command matches a **STRICT whitelist regex** —
`^\s*git\s+push(\s+[A-Za-z0-9._/@:+=-]+)*\s*$` — i.e. literally `git push` followed
by tokens drawn from a safe refspec/option charset with **no** shell metacharacter,
quote, operator, or expansion. For such a command `str.split()` is provably
identical to bash's argv, so the precise `classify_clean()` analysis (the verdicts
above) is sound. **Every other command** — any operator, quote, `$`, backtick, `*`,
leading non-`git`, or `-C`/`--git-dir` redirect — is "complex" and **can never reach
`allow`**: it gets a conservative `deny` (when a protected-branch or
force/destructive signal appears anywhere in the raw string) or `defer`. The
companion prelude fix makes the safe-util fast-path reject any shell
metacharacter, so it only auto-allows a single simple utility command.

This is deny-biased by construction: the blanket deny is preserved for the
dangerous core (`main`/force/destructive, in clean or complex form) and *relaxed
only* for pushes proven routine; complex commands fall to human review, never to
auto-allow.

## Adversarial review (3 rounds, multi-agent)

Before finalizing, the composed gate was red-teamed by independent agents across
attack lenses (protected-branch evasion, force/destructive evasion, fail-open,
shell-injection, git-refspec arcana, false-positive denials), each required to
*reproduce* findings against the live gate. Three rounds, run as a loop-until-dry:

- **Round 1** surfaced bypasses incl. the safe-util short-circuit, `--git-dir=`
  repo-redirect, empty-cwd fail-open, wildcard refspecs, and macOS case-folding
  (`Main`→`main`). All fixed and test-pinned.
- **Round 2** (against the patched gate) found the parser-differential class —
  glued operators, ANSI-C `$'…'`, `$VAR` — which motivated the strict-allow
  rewrite above rather than more point patches.
- **Round 3** confirms convergence on the rewritten gate.

The behaviors are pinned by `tests/test-permission-gate-push-policy.sh`
(74 assertions across both archetypes, including a dedicated regression block for
every reproduced bypass) plus `tests/test-cpo-archetype.sh`. **No agent and no
local gate is the durable floor** — server-side branch protection on `main` is
(see below).

## Reversibility & cost of change

Two-way. Reverting restores the blanket `deny "git push"` (engineering-cto) and
the destructive-only denies (cpo); there is no persistent state. The only judgment
surfaces — protecting `master` as well as `main`, and denying force-push to *all*
targets — are each a one-line change.

## Enforcement status (no overclaim)

- **Local gate:** deterministic deny/allow/defer, regenerated into both composed
  gate fixtures and pinned by `tests/test-permission-gate-push-policy.sh`
  (44 assertions across both archetypes).
- **Live source-repo gate (`.claude/hooks/permission-gate.sh`) NOT modified.** It
  is an older monolithic, curated version that diverges from the fragment
  architecture by design (this repo is not swarm-synced). Regenerating it would
  bundle unrelated repo-scope/refactor catch-up; the canonical change ships via
  the templates + fixtures and reaches stamped swarms on the operator's next sync.
- **The durable floor is GitHub branch protection on `main`**, which this ADR does
  not and cannot set — it is per-repo, operator-applied, and binds everyone
  (including the operator). The local gate mirrors it but does not replace it.

## Alternatives considered

- **Keep the blanket deny** — rejected: over-denies the doctrine's own
  branch/`dev` push cadence and the crash-safety of continuous pushing.
- **Inline the resolver per archetype** — rejected: two copies drift; the shared
  prelude helper is the single source of truth (mirrors `_bash_util_in_scope`).
- **Allow-list by regex only (no parse)** — rejected: refspec/option grammar
  (`HEAD:main`, `heads/main`, `+main`, `-fu`, `-o value`) is too rich for a safe
  regex; a tokenizing, deny-biased classifier with explicit defer is the floor.
- **Trust the local gate as the control** — rejected: a local hook is bypassable;
  server-side branch protection is the real floor, the gate is convenience.

---

## Amendment — 2026-06-14 (force relaxation, repo-aware protected, live gate)

Operator follow-up after the initial merge-pending review. Four refinements; the
strict-allow architecture and the 3-round adversarial soundness are unchanged.

1. **Force-push relaxed to protected-only.** Force-push (`--force`/`-f`/
   `--force-with-lease`/leading `+`) is no longer denied universally — it is
   **allowed to a non-protected branch** (routine rebase/squash of a feature/
   worktree branch) and **denied to a protected branch**. The deny-bias holds: a
   force-push whose target can't be statically resolved (a complex command, a bare
   force-push on a detached HEAD, `push.default=matching`) **defers**, never
   allows. In the complex-command path, pure force (no protected name, no broad-
   destructive flag) now defers rather than denies.

2. **Protected set is repo-aware** (`protected_set()`): `{main, master}` ∪ the
   repo's **release branch**, resolved in order — (a) explicit override: env
   `SWARM_PROTECTED_BRANCHES` or the file `.claude/protected-branches` (a list;
   `main`/`master` always kept); (b) the repo's default branch via
   `git symbolic-ref refs/remotes/origin/HEAD`; (c) **fail-safe**: when neither
   resolves, protect *more* by adding `dev` — never less. This fixes the hardcoded
   main/dev assumption: `dev` is pushable where it is staging (release branch =
   main) and protected where it is the release branch.
   - **`qofi-ios-app`** (default branch `dev`): with no override its release
     branch resolves to `dev`, so `dev` is **protected** (push denied) — the
     deny-safe default until the operator confirms dev's role. The one-edit knob
     to flip it: write the real release branch(es) to `.claude/protected-branches`
     (e.g. `main`), which drops `dev` from the protected set.

3. **Live source-repo gate surgically refreshed.** The earlier note said the live
   `.claude/hooks/permission-gate.sh` was left stale to avoid ~700 lines of
   doctrine drift. Correction to the operator's premise: the live gate did **not**
   carry the smuggle hole for hard-floor actions — its `git push`/publish/secrets
   denies live in the *hard floor* (whole-command substring grep) which runs
   *before* the util-allow, so `echo x && git push origin main` was already
   **denied** there. The util-fast-path hole was narrower (it auto-allowed
   compounds whose dangerous part is *not* a hard-floor item, e.g.
   `echo x && rm file`). Still surgically applied to the live gate (no doctrine
   regen): the strict-allow `_git_push_class` (replacing the blanket push deny, in
   the hard floor), the metacharacter-hardened util fast-path, and the
   newline→`;` field-parser fix. The live gate now runs the same relaxed-but-safe
   push policy for this repo's manual sessions. It still lacks the composed gate's
   repo-scope confinement (a separate, pre-existing gap, intentionally out of
   scope here).

4. **Doctrine reconciled.** `_base/CLAUDE.md` §*Cost & blast radius* previously said
   force-push is *never* autonomous; it is now scoped to match the gate (force-push
   of a non-protected branch is routine; to a protected branch it is destruction).
   This is a conscious operator-approved doctrine change, logged here.

### Round-4 adversarial finding (bare-push destination resolution)

A 4th red-team round on the force/repo-aware delta found one **HIGH** fail-open the
earlier rounds missed (the deep verdict synthesis caught it; the finder lenses did
not): a **bare** `git push --force` with `push.default=upstream` and
`branch.<cur>.merge=refs/heads/main` force-pushes the current feature branch *onto*
`main` — git's own `--dry-run --porcelain` resolves it to
`refs/heads/feature:refs/heads/main` — yet the classifier allowed it, because the
bare-push branch checked only the *current branch name* and special-cased only
`push.default=matching`.

Fixed by resolving the **real** destination of a bare push from git config:
`current`/`simple` → current branch (simple refuses on a name mismatch, so it can
only write the same-name ref); `upstream`/`tracking` → `branch.<cur>.merge` (denied
if protected); `matching` → defer; unknown → defer. The sibling vector — a
configured push refspec `remote.<remote>.push` redirecting a bare push — is also
closed (any configured push refspec → defer). Explicit-refspec pushes are
unaffected (an explicit refspec overrides config). Pinned by
`tests/test-permission-gate-push-policy.sh` across `push.default` modes and the
`remote.push` config, on both the composed and live gates. This reinforces the
core lesson: the gate must resolve git's *actual* destination, not the apparent one.

### Round-5 adversarial finding (mirror-config bare/explicit push)

A 5th round on the bare-push destination class found another **HIGH** fail-open —
ground-truthed with a *real* (non-dry-run) push that overwrote `main` on a remote.
`remote.<remote>.mirror=true` makes **any** push to that remote behave as
`--mirror` — it writes *all* refs (overwriting protected `main`) and ignores
refspecs and `push.default` entirely. The decisive asymmetry: the `--mirror`
**flag** was already denied, but the equivalent **config** was never checked, so a
plain `git push` (or `git push origin feature`) slipped through to `allow`.

Fixed by checking `remote.*.mirror` at the **top** of the classifier (before the
strict-allow gate, since mirror overrides explicit refspecs too): any truthy
`remote.<r>.mirror` → **deny** (matching the `--mirror` flag). A subprocess failure
defers; a non-git-repo / no-config returns "not mirrored" so normal pushes are
unaffected. Pinned for bare, force, and explicit-refspec pushes on both gates.

**Process note.** Rounds 4 and 5 each found a real config-redirect bug that the
finder lenses *and* the author missed — only the verdict synthesis (which
ground-truths every ALLOW against `git push --dry-run --porcelain`) caught them.
The lesson generalized: for a bare push the gate must resolve git's *actual*
destination (push.default → branch.merge; remote.push; remote.mirror), not the
apparent current branch. The durable floor remains server-side branch protection —
these are defense-in-depth against an adversarial/unusual local git config.
