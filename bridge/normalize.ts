/**
 * Pure message-normalization helpers, factored out of server.ts so they can be
 * unit-tested without booting the Discord gateway (importing server.ts calls
 * client.login()). No discord.js client state is touched here.
 */

import type { Attachment, Message } from 'discord.js'

// Attachment names are attacker-controlled — strip chars that would break the
// `name (type, size)` listing format or let a sender forge a second entry.
export function safeAttName(att: Attachment): string {
  return (att.name ?? att.id).replace(/[\[\]\r\n;]/g, '_')
}

/**
 * Render the text of a forwarded message (Discord's "Forward" feature).
 *
 * Forwarded messages arrive with an EMPTY top-level `msg.content`; the original
 * text lives in `msg.messageSnapshots` (a Collection of Message-shaped objects).
 * The snapshot payload is a deliberate Pick of the source message that OMITS the
 * author (see discord-api-types `APIMessageSnapshotFields`), so `snap.author` is
 * null for cross-channel forwards and we can only label generically. If a future
 * API revision starts including the author we surface it automatically.
 *
 * Multiple snapshots (a forward of a forward, or a multi-message forward) are
 * rendered in Collection order. Image/embed-only forwards — which have no text —
 * get a short note so they aren't silently dropped.
 *
 * `channelName` is the resolved name of the source channel (from
 * msg.reference.channelId — see resolveForwardChannel in server.ts). When known
 * it is prepended as `[<channel>]`; when not (cross-server forward the bot can't
 * see) it is omitted rather than showing a raw snowflake.
 *
 * Returns '' when the message carries no forwarded snapshots.
 */
export function forwardedContent(msg: Message, channelName?: string): string {
  if (msg.messageSnapshots.size === 0) return ''

  // Channel names are restricted but could contain chars that break the
  // bracket format — strip the structural ones.
  const chan = channelName ? `[${channelName.replace(/[\[\]\r\n]/g, '_')}] ` : ''

  const blocks: string[] = []
  for (const snap of msg.messageSnapshots.values()) {
    const who = snap.author?.username
    const label = who ? `Forwarded message from ${who}` : 'Forwarded message'

    const parts: string[] = []
    if (snap.content) parts.push(snap.content)

    const extras: string[] = []
    for (const att of snap.attachments.values()) {
      extras.push(`${safeAttName(att)} (${att.contentType ?? 'unknown'})`)
    }
    if (snap.embeds.length > 0) extras.push(`${snap.embeds.length} embed(s)`)
    if (extras.length > 0) parts.push(`(${extras.join('; ')})`)

    blocks.push(`${chan}[${label}]: ${parts.join(' ').trim() || '(no text)'}`)
  }
  return blocks.join('\n')
}
