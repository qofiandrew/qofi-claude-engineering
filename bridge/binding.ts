// binding.ts — pure helpers for the inbound channel binding.
//
// DISCORD_BOUND_CHANNEL scopes which channel(s) a bot RESPONDS in, independent
// of the shared access.json (which lists groups for every swarm's channel). The
// value is a comma-separated list of channel ids:
//   unset / empty  -> no binding (legacy single-channel-by-access behavior)
//   "<id>"         -> bound to exactly that one channel (unchanged single case)
//   "<id>,<id>"    -> bound to several (e.g. the CPO: operator channel + bus)
//
// Kept pure and dependency-free so the membership rule is unit-tested without a
// live gateway. server.ts imports both.

/** Parse the DISCORD_BOUND_CHANNEL env into a list of ids (trimmed, de-blanked). */
export function parseBoundChannels(raw: string | undefined | null): string[] {
  if (!raw) return []
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
}

/**
 * Should an inbound message be DROPPED by the channel binding?
 * Drop iff a binding exists (non-empty list) AND this channel is not in it.
 * An empty list means "unbound" → never drops on this rule.
 */
export function isBoundDrop(bound: string[], channelId: string): boolean {
  return bound.length > 0 && !bound.includes(channelId)
}
