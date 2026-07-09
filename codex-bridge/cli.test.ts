import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { runCli } from './cli.ts'
import { AccessStore, defaultAccess } from './gate.ts'

let dir: string
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-bridge-cli-')) })
afterEach(() => rmSync(dir, { recursive: true, force: true }))

const load = () => new AccessStore(dir).load()

describe('cli', () => {
  test('status on empty state shows defaults', () => {
    const out = runCli([], dir)
    expect(out).toContain('dmPolicy: pairing')
    expect(out).toContain('allowFrom (0)')
  })

  test('pair approves a pending sender and drops the approval marker with the DM chat id', () => {
    const store = new AccessStore(dir)
    const a = defaultAccess()
    a.pending['abc123'] = {
      senderId: 'u9', chatId: 'dm-77',
      createdAt: Date.now(), expiresAt: Date.now() + 3600_000, replies: 1,
    }
    store.save(a)

    const out = runCli(['pair', 'abc123'], dir)
    expect(out).toContain('approved sender u9')
    expect(load().allowFrom).toEqual(['u9'])
    expect(load().pending['abc123']).toBeUndefined()
    // approved/<senderId> contents = DM channel id — the daemon polls this
    expect(readFileSync(join(dir, 'approved', 'u9'), 'utf8')).toBe('dm-77')
  })

  test('pair rejects unknown and expired codes', () => {
    expect(runCli(['pair', 'nosuch'], dir)).toContain('no pending')
    const store = new AccessStore(dir)
    const a = defaultAccess()
    a.pending['old111'] = {
      senderId: 'u1', chatId: 'dm-1',
      createdAt: 0, expiresAt: 1, replies: 1,
    }
    store.save(a)
    expect(runCli(['pair', 'old111'], dir)).toContain('expired')
    expect(load().allowFrom).toEqual([])
    expect(existsSync(join(dir, 'approved', 'u1'))).toBe(false)
  })

  test('deny discards a pending code without allowlisting', () => {
    const store = new AccessStore(dir)
    const a = defaultAccess()
    a.pending['abc123'] = {
      senderId: 'u9', chatId: 'dm-77',
      createdAt: Date.now(), expiresAt: Date.now() + 3600_000, replies: 1,
    }
    store.save(a)
    runCli(['deny', 'abc123'], dir)
    expect(load().pending['abc123']).toBeUndefined()
    expect(load().allowFrom).toEqual([])
  })

  test('allow/remove edit the allowlist with dedupe', () => {
    runCli(['allow', 'u1'], dir)
    runCli(['allow', 'u1'], dir)
    expect(load().allowFrom).toEqual(['u1'])
    runCli(['remove', 'u1'], dir)
    expect(load().allowFrom).toEqual([])
  })

  test('policy validates and sets dmPolicy', () => {
    expect(runCli(['policy', 'bogus'], dir)).toContain('usage')
    runCli(['policy', 'allowlist'], dir)
    expect(load().dmPolicy).toBe('allowlist')
  })

  test('group add with flags, group rm', () => {
    runCli(['group', 'add', 'chan1', '--require-mention', '--allow', 'a,b'], dir)
    expect(load().groups['chan1']).toEqual({ requireMention: true, allowFrom: ['a', 'b'] })
    runCli(['group', 'rm', 'chan1'], dir)
    expect(load().groups['chan1']).toBeUndefined()
  })

  test('set validates delivery keys', () => {
    runCli(['set', 'ackReaction', '👀'], dir)
    runCli(['set', 'replyToMode', 'all'], dir)
    runCli(['set', 'textChunkLimit', '1500'], dir)
    runCli(['set', 'chunkMode', 'newline'], dir)
    runCli(['set', 'mentionPatterns', '["^hey codex\\\\b"]'], dir)
    const a = load()
    expect(a.ackReaction).toBe('👀')
    expect(a.replyToMode).toBe('all')
    expect(a.textChunkLimit).toBe(1500)
    expect(a.chunkMode).toBe('newline')
    expect(a.mentionPatterns).toEqual(['^hey codex\\b'])
    expect(runCli(['set', 'replyToMode', 'sometimes'], dir)).toContain('off|first|all')
    expect(runCli(['set', 'mentionPatterns', 'not-json'], dir)).toContain('JSON array')
  })
})
