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
