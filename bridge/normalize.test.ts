/**
 * Tests for forwarded-message normalization. Run with: `bun test` in bridge/.
 *
 * Fixtures are duck-typed to the shape forwardedContent() actually reads
 * (messageSnapshots: Map, each snapshot has content/author/attachments/embeds)
 * and cast to Message — no live gateway or real discord.js objects needed.
 */

import { test, expect } from 'bun:test'
import type { Message } from 'discord.js'
import { forwardedContent, safeAttName } from './normalize.ts'

// Minimal snapshot factory. Mirrors discord.js MessageSnapshot: a Message-shaped
// object whose author is null (Discord omits it from the snapshot payload).
function snapshot(opts: {
  content?: string
  author?: { username: string } | null
  attachments?: Array<{ name?: string | null; id: string; contentType?: string | null }>
  embeds?: unknown[]
}) {
  return {
    content: opts.content ?? '',
    author: opts.author ?? null,
    attachments: new Map((opts.attachments ?? []).map(a => [a.id, a])),
    embeds: opts.embeds ?? [],
  }
}

function msgWith(snapshots: ReturnType<typeof snapshot>[]): Message {
  return {
    messageSnapshots: new Map(snapshots.map((s, i) => [String(i), s])),
  } as unknown as Message
}

test('non-forwarded message yields empty string', () => {
  expect(forwardedContent(msgWith([]))).toBe('')
})

test('text-only forward is rendered with generic label (no author in snapshot)', () => {
  const msg = msgWith([snapshot({ content: 'hello from elsewhere' })])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: hello from elsewhere')
})

test('channel name is prepended in brackets when resolved', () => {
  const msg = msgWith([snapshot({ content: 'deploy is green' })])
  expect(forwardedContent(msg, 'reserve-backend-2')).toBe(
    '[reserve-backend-2] [Forwarded message]: deploy is green',
  )
})

test('channel prefix applies to every snapshot, structural chars stripped', () => {
  const msg = msgWith([snapshot({ content: 'a' }), snapshot({ content: 'b' })])
  expect(forwardedContent(msg, 'we[i]rd\nname')).toBe(
    '[we_i_rd_name] [Forwarded message]: a\n[we_i_rd_name] [Forwarded message]: b',
  )
})

test('author is used when present (forward-compatible with future API)', () => {
  const msg = msgWith([snapshot({ content: 'hi', author: { username: 'alice' } })])
  expect(forwardedContent(msg)).toBe('[Forwarded message from alice]: hi')
})

test('image-only forward (no text) notes the attachment instead of dropping', () => {
  const msg = msgWith([
    snapshot({ attachments: [{ id: '1', name: 'cat.png', contentType: 'image/png' }] }),
  ])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: (cat.png (image/png))')
})

test('embed-only forward is noted', () => {
  const msg = msgWith([snapshot({ embeds: [{}, {}] })])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: (2 embed(s))')
})

test('text + attachment forward combines both', () => {
  const msg = msgWith([
    snapshot({
      content: 'check this',
      attachments: [{ id: '1', name: 'doc.pdf', contentType: 'application/pdf' }],
    }),
  ])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: check this (doc.pdf (application/pdf))')
})

test('multiple snapshots render in order, newline-separated', () => {
  const msg = msgWith([
    snapshot({ content: 'first' }),
    snapshot({ content: 'second' }),
  ])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: first\n[Forwarded message]: second')
})

test('empty snapshot still produces a visible marker', () => {
  const msg = msgWith([snapshot({})])
  expect(forwardedContent(msg)).toBe('[Forwarded message]: (no text)')
})

test('safeAttName strips listing-breaking characters', () => {
  expect(safeAttName({ name: 'a[b];c\nd', id: 'x' } as never)).toBe('a_b__c_d')
  expect(safeAttName({ name: null, id: 'fallback' } as never)).toBe('fallback')
})
