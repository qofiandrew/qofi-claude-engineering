# ---------------------------------------------------------------------------
# CPO ARCHETYPE POLICY — Bash deny + allow rules specific to the CPO swarm
# (a conversational product agent whose primary write action is editing
# markdown in its own product-vision repo and pushing to that repo's remote).
#
# DIVERGES FROM engineering-cto:
#   - git push is ALLOWED (vision-repo push is the cpo's function).
#   - destructive push variants (--force / --delete / --mirror / --all) still
#     deny — they're not part of the cpo's normal cadence.
#   - no test runners, no worktree management, no swarm-attention.sh (the cpo
#     surfaces directly via Discord per SURFACING.md, not via attention flags).
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    # Archetype-specific HARD FLOOR — destructive push variants are NOT part
    # of the cpo's normal cadence (it commits + pushes incrementally to its
    # own vision repo; force-push or branch deletion is operator-only).
    printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push[[:space:]].*(--force|--force-with-lease|--delete|--mirror|--all)([[:space:]]|$)' && deny "destructive git push (--force/--delete/--mirror/--all)"
    printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push[[:space:]]+(-f|-F)([[:space:]]|$)' && deny "destructive git push (-f)"

    # Plain git ops INCLUDING push to the cpo's own vision repo. The cpo's
    # writes (refined product specs, decision records) are committed locally
    # and pushed so the operator can read the repo to see exactly what is
    # stored (see MEMORY.md §write mechanism).
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+(status|diff|log|show|add|commit|stash|restore|checkout|switch|push|pull|fetch)([[:space:]]|$)' && allow

    # Branch ops — read-only/listing only. Cpo does not manage worktree
    # branches; branch creation/deletion defers to a human.
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]*$' && allow
    printf '%s' "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+branch[[:space:]]+(-v|--verbose|-vv|-a|--all|-r|--remotes|-l|--list|--show-current|--merged|--no-merged|--contains)([[:space:]]|$)' && allow
    ;;
esac
