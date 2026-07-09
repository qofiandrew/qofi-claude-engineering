import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { AccessStore, gate, defaultAccess, type Access, type InboundMeta } from './gate.ts'

let dir: string
let store: AccessStore

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'codex-bridge-gate-'))
  store = new AccessStore(dir)
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

const dm = (senderId: string, chatId = 'dm-chan-1'): InboundMeta => ({
  senderId,
  isDM: true,
  gateChannelId: chatId,
  isMentioned: async () => false,
})

const guild = (senderId: string, channelId: string, mentioned = false): InboundMeta => ({
  senderId,
  isDM: false,
  gateChannelId: channelId,
  isMentioned: async () => mentioned,
})

const deps = (over: Partial<Parameters<typeof gate>[1]> = {}) => ({
  store,
  boundChannels: [] as string[],
  ...over,
})

describe('DM gating', () => {
  test('unknown sender in pairing mode gets a code, persisted with DM chat id', async () => {
    const r = await gate(dm('u1', 'dmchan'), deps({ makeCode: () => 'abc123' }))
    expect(r).toEqual({ action: 'pair', code: 'abc123', isResend: false })
    const a = store.load()
    expect(a.pending['abc123'].senderId).toBe('u1')
    expect(a.pending['abc123'].chatId).toBe('dmchan')
  })

  test('second DM resends the same code, third goes silent', async () => {
    await gate(dm('u1'), deps({ makeCode: () => 'abc123' }))
    const r2 = await gate(dm('u1'), deps())
    expect(r2).toEqual({ action: 'pair', code: 'abc123', isResend: true })
    const r3 = await gate(dm('u1'), deps())
    expect(r3.action).toBe('drop')
  })

  test('pending cap of 3 drops further strangers silently', async () => {
    for (const [i, u] of ['a', 'b', 'c'].entries()) {
      await gate(dm(u), deps({ makeCode: () => `code0${i}` }))
    }
    const r = await gate(dm('d'), deps())
    expect(r.action).toBe('drop')
  })

  test('expired codes are pruned and re-pairing works', async () => {
    const t0 = 1_000_000
    await gate(dm('u1'), deps({ makeCode: () => 'old111', now: () => t0 }))
    const r = await gate(
      dm('u1'),
      deps({ makeCode: () => 'new222', now: () => t0 + 61 * 60 * 1000 }),
    )
    expect(r).toEqual({ action: 'pair', code: 'new222', isResend: false })
    expect(store.load().pending['old111']).toBeUndefined()
  })

  test('allowlisted sender delivers', async () => {
    const a = defaultAccess()
    a.allowFrom = ['u1']
    store.save(a)
    const r = await gate(dm('u1'), deps())
    expect(r.action).toBe('deliver')
  })

  test('allowlist policy drops strangers without a code', async () => {
    const a = defaultAccess()
    a.dmPolicy = 'allowlist'
    store.save(a)
    const r = await gate(dm('u1'), deps())
    expect(r.action).toBe('drop')
  })

  test('disabled policy drops even allowlisted senders', async () => {
    const a = defaultAccess()
    a.dmPolicy = 'disabled'
    a.allowFrom = ['u1']
    store.save(a)
    const r = await gate(dm('u1'), deps())
    expect(r.action).toBe('drop')
  })
})

describe('guild gating', () => {
  const withGroup = (channelId: string, policy: Partial<Access['groups'][string]> = {}) => {
    const a = store.load()
    a.groups[channelId] = { requireMention: false, allowFrom: [], ...policy }
    store.save(a)
  }

  test('message in a channel with no group entry drops', async () => {
    const r = await gate(guild('u1', 'chan1'), deps())
    expect(r.action).toBe('drop')
  })

  test('opted-in channel delivers', async () => {
    withGroup('chan1')
    const r = await gate(guild('u1', 'chan1'), deps())
    expect(r.action).toBe('deliver')
  })

  test('bound channel list drops other channels even when opted in', async () => {
    withGroup('chan1')
    withGroup('chan2')
    const r1 = await gate(guild('u1', 'chan1'), deps({ boundChannels: ['chan2'] }))
    expect(r1.action).toBe('drop')
    const r2 = await gate(guild('u1', 'chan2'), deps({ boundChannels: ['chan2'] }))
    expect(r2.action).toBe('deliver')
  })

  test('group allowFrom restricts senders', async () => {
    withGroup('chan1', { allowFrom: ['vip'] })
    expect((await gate(guild('vip', 'chan1'), deps())).action).toBe('deliver')
    expect((await gate(guild('rando', 'chan1'), deps())).action).toBe('drop')
  })

  test('requireMention drops unmentioned, delivers mentioned', async () => {
    withGroup('chan1', { requireMention: true })
    expect((await gate(guild('u1', 'chan1', false), deps())).action).toBe('drop')
    expect((await gate(guild('u1', 'chan1', true), deps())).action).toBe('deliver')
  })
})

describe('AccessStore', () => {
  test('missing file yields defaults', () => {
    expect(store.load()).toEqual(defaultAccess())
  })

  test('corrupt file is moved aside and defaults returned', () => {
    writeFileSync(join(dir, 'access.json'), '{not json')
    expect(store.load().dmPolicy).toBe('pairing')
  })

  test('static mode downgrades pairing to allowlist and ignores writes', () => {
    const a = defaultAccess()
    a.allowFrom = ['u1']
    store.save(a)
    const staticStore = new AccessStore(dir, true)
    expect(staticStore.load().dmPolicy).toBe('allowlist')
    const mutated = staticStore.load()
    mutated.allowFrom.push('u2')
    staticStore.save(mutated)
    // On-disk file unchanged by static-mode save
    const onDisk = JSON.parse(readFileSync(join(dir, 'access.json'), 'utf8'))
    expect(onDisk.allowFrom).toEqual(['u1'])
  })
})
