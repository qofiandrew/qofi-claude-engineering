import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { describe, expect, test } from 'bun:test'
import {
  MAX_PARKED_TURNS,
  MAX_RETRY_NOTICES,
  MAX_RETRY_NOTICE_BYTES,
  ParkedTurnStore,
  RetryNoticeStore,
  retryNoticeText,
} from './retry-notices.ts'

const metadata = { senderId: 'sender', gateChannelId: 'channel', isDM: false }

describe('durable shutdown retry notices', () => {
  test('wording never claims an interrupted operation was unprocessed or safe to duplicate', () => {
    for (const kind of ['inbound', 'turn', 'git', 'active-turn', 'active-git'] as const) {
      const text = retryNoticeText(kind)
      expect(text.toLowerCase()).toContain('completion was not confirmed')
      expect(text).toContain('Inspect the current workspace')
      expect(text).not.toContain('before processing')
      expect(text).not.toContain('retry it now')
    }
    expect(retryNoticeText('active-turn')).toContain('active operation')
  })

  test('survives restart for an active job and a forced-timeout-sized backlog', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-retry-ledger-'))
    try {
      const store = new RetryNoticeStore(dir)
      store.register('channel', 'active-message', 'turn', metadata)
      for (let i = 0; i < 125; i++) store.register('channel', `queued-${i}`, 'inbound', metadata)
      const restarted = new RetryNoticeStore(dir)
      expect(restarted.list()).toHaveLength(126)
      expect(restarted.list()[0]).toMatchObject({
        message_id: 'active-message',
        kind: 'turn',
        sender_id: 'sender',
        gate_channel_id: 'channel',
        is_dm: false,
      })
      restarted.remove('active-message')
      expect(new RetryNoticeStore(dir).list()).toHaveLength(125)
      expect(readFileSync(join(dir, 'retry-notices.json')).byteLength).toBeLessThan(MAX_RETRY_NOTICE_BYTES)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('caps growth and refuses malformed state without overwriting it', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-retry-cap-'))
    const path = join(dir, 'retry-notices.json')
    try {
      const store = new RetryNoticeStore(dir)
      for (let i = 0; i < MAX_RETRY_NOTICES; i++) store.register('channel', `message-${i}`, 'turn', metadata)
      expect(() => store.register('channel', 'overflow', 'turn', metadata)).toThrow('full')
      writeFileSync(path, '{broken', { mode: 0o600 })
      chmodSync(path, 0o600)
      const before = readFileSync(path)
      expect(() => new RetryNoticeStore(dir).register('channel', 'new', 'turn', metadata)).toThrow()
      expect(readFileSync(path)).toEqual(before)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('durable quota-parked task replay metadata', () => {
  test('survives restart without persisting prompt or credential material', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-parked-ledger-'))
    try {
      const retryAtMs = Date.now() + 3_600_000
      const store = new ParkedTurnStore(dir)
      store.register('channel', 'message', metadata, retryAtMs, 2)
      expect(new ParkedTurnStore(dir).list()).toEqual([expect.objectContaining({
        channel_id: 'channel',
        message_id: 'message',
        sender_id: 'sender',
        gate_channel_id: 'channel',
        is_dm: false,
        retry_at_ms: retryAtMs,
        rotation_attempt: 2,
      })])
      const serialized = readFileSync(join(dir, 'parked-turns.json'), 'utf8')
      expect(serialized).not.toContain('prompt')
      expect(serialized).not.toContain('token')
      store.register('channel', 'message', metadata, retryAtMs + 1_000, 3)
      expect(store.list()).toHaveLength(1)
      expect(store.list()[0]).toMatchObject({ retry_at_ms: retryAtMs + 1_000, rotation_attempt: 3 })
      store.remove('message')
      expect(store.list()).toEqual([])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('caps growth and rejects unsafe or malformed replay state', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-parked-cap-'))
    const path = join(dir, 'parked-turns.json')
    try {
      const store = new ParkedTurnStore(dir)
      for (let i = 0; i < MAX_PARKED_TURNS; i++) {
        store.register('channel', `message-${i}`, metadata, Date.now() + i, 1)
      }
      expect(() => store.register('channel', 'overflow', metadata, Date.now(), 1)).toThrow('full')
      writeFileSync(path, '{broken', { mode: 0o600 })
      chmodSync(path, 0o600)
      const before = readFileSync(path)
      expect(() => new ParkedTurnStore(dir).list()).toThrow()
      expect(readFileSync(path)).toEqual(before)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
