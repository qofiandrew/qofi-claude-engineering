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
