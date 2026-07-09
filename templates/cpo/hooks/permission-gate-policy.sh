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
# push allowed (incl. force to a non-protected, non-dev branch), push to
# main/master + force-to-dev + destructive denied, ambiguous deferred — via
# the shared _git_push_class in the prelude. See ADR-0012.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Bash)
    # Git-push policy — vision-repo push (the cpo's function) is auto-allowed
    # for branch pushes (incl. force to a non-protected, non-dev branch); push
    # to main/master, force-push to dev (shared integration history), and
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
