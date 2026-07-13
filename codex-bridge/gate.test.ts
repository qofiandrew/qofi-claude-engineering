import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import { spawnSync } from 'child_process'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  readFileSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  AccessStore,
  gate,
  defaultAccess,
  revalidateDeliveryAuthorization,
  type Access,
  type InboundMeta,
} from './gate.ts'

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
    a.groups[channelId] = { requireMention: false, allowFrom: ['u1'], ...policy }
    store.save(a)
    return a
  }

  test('disabling DMs does not disable an explicitly allowed guild channel', async () => {
    const a = withGroup('c1')
    a.dmPolicy = 'disabled'
    store.save(a)
    const r = await gate(guild('u1', 'c1'), deps())
    expect(r.action).toBe('deliver')
  })

  test('message in a channel with no group entry drops', async () => {
    const r = await gate(guild('u1', 'chan1'), deps())
    expect(r.action).toBe('drop')
  })

  test('opted-in channel delivers', async () => {
    withGroup('chan1')
    const r = await gate(guild('u1', 'chan1'), deps())
    expect(r.action).toBe('deliver')
  })

  test('empty guild allowFrom fails closed', async () => {
    withGroup('chan1', { allowFrom: [] })
    const r = await gate(guild('u1', 'chan1'), deps())
    expect(r).toEqual({ action: 'drop', reason: 'group allowFrom is empty (fail closed)' })
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

describe('live canonical authorization ceiling', () => {
  test.skipIf(process.platform !== 'darwin')(
    'rejects live extended ACL drift on the canonical file and parent',
    async () => {
      const parent = join(dir, 'canonical-private')
      mkdirSync(parent, { mode: 0o700 })
      chmodSync(parent, 0o700)
      const canonical = join(parent, 'access.json')
      writeFileSync(canonical, JSON.stringify({
        dmPolicy: 'allowlist', allowFrom: ['operator'], groups: {}, pending: {},
      }), { mode: 0o600 })
      chmodSync(canonical, 0o600)
      const local = defaultAccess()
      local.allowFrom = ['operator']
      store.save(local)
      const canonicalDeps = deps({ canonicalAccessFile: realpathSync(canonical) })
      const message = dm('operator')
      expect((await gate(message, canonicalDeps)).action).toBe('deliver')

      const chmod = (...args: string[]) => spawnSync('/bin/chmod', args, { encoding: 'utf8' })
      try {
        expect(chmod('+a', 'everyone allow read,write', canonical).status).toBe(0)
        expect(await gate(message, canonicalDeps)).toEqual({
          action: 'drop', reason: 'canonical access unavailable or invalid (fail closed)',
        })
        expect((await revalidateDeliveryAuthorization(message, canonicalDeps)).ok).toBe(false)
        expect(chmod('-N', canonical).status).toBe(0)

        expect(chmod('+a', 'everyone allow read,write', parent).status).toBe(0)
        expect((await gate(message, canonicalDeps)).action).toBe('drop')
        expect((await revalidateDeliveryAuthorization(message, canonicalDeps)).ok).toBe(false)
      } finally {
        spawnSync('/bin/chmod', ['-RN', parent])
      }
    },
  )

  test('a queued delivery is revoked when canonical sender/channel access changes before execution', async () => {
    const canonical = join(dir, 'queued-canonical.json')
    const local = defaultAccess()
    local.groups.chan1 = { requireMention: false, allowFrom: ['watcher'] }
    store.save(local)
    const writeCanonical = (groups: Record<string, unknown>) => {
      writeFileSync(canonical, JSON.stringify({
        dmPolicy: 'allowlist', allowFrom: [], groups, pending: {},
      }), { mode: 0o600 })
    }
    writeCanonical({ chan1: { requireMention: false, allowFrom: ['watcher'] } })
    const queued = guild('watcher', 'chan1')
    const recheckDeps = {
      store,
      boundChannels: ['chan1'],
      canonicalAccessFile: realpathSync(canonical),
    }
    expect(await revalidateDeliveryAuthorization(queued, recheckDeps))
      .toMatchObject({ ok: true })

    writeCanonical({ chan1: { requireMention: false, allowFrom: ['operator'] } })
    expect(await revalidateDeliveryAuthorization(queued, recheckDeps)).toEqual({
      ok: false,
      reason: 'sender/channel revoked by canonical group policy',
    })
    writeCanonical({})
    expect((await revalidateDeliveryAuthorization(queued, recheckDeps)).ok).toBe(false)
  })

  test('freshly re-reads guild revocations and fails closed on malformed state', async () => {
    const canonical = join(dir, 'canonical.json')
    const local = defaultAccess()
    local.allowFrom = ['operator']
    local.groups.chan1 = { requireMention: false, allowFrom: ['operator', 'watcher'] }
    store.save(local)
    const writeCanonical = (allowFrom: string[]) => writeFileSync(canonical, JSON.stringify({
      dmPolicy: 'allowlist',
      allowFrom: ['operator'],
      groups: { chan1: { requireMention: false, allowFrom } },
      pending: {},
    }), { mode: 0o600 })
    writeCanonical(['operator', 'watcher'])
    const canonicalDeps = deps({ canonicalAccessFile: realpathSync(canonical) })
    expect((await gate(guild('watcher', 'chan1'), canonicalDeps)).action).toBe('deliver')

    writeCanonical(['operator'])
    expect(await gate(guild('watcher', 'chan1'), canonicalDeps)).toEqual({
      action: 'drop', reason: 'sender revoked by canonical group allowFrom',
    })
    writeFileSync(canonical, '{broken')
    expect(await gate(guild('operator', 'chan1'), canonicalDeps)).toEqual({
      action: 'drop', reason: 'canonical access unavailable or invalid (fail closed)',
    })
    rmSync(canonical)
    expect((await gate(guild('operator', 'chan1'), canonicalDeps)).action).toBe('drop')
  })

  test('local DM pairing/allowlist cannot override canonical revocation', async () => {
    const canonical = join(dir, 'canonical-dm.json')
    const local = defaultAccess()
    local.allowFrom = ['operator']
    store.save(local)
    writeFileSync(canonical, JSON.stringify({
      dmPolicy: 'allowlist', allowFrom: ['operator'], groups: {}, pending: {},
    }), { mode: 0o600 })
    const canonicalDeps = deps({ canonicalAccessFile: realpathSync(canonical) })
    expect((await gate(dm('operator'), canonicalDeps)).action).toBe('deliver')
    writeFileSync(canonical, JSON.stringify({
      dmPolicy: 'allowlist', allowFrom: [], groups: {}, pending: {},
    }))
    expect(await gate(dm('operator'), canonicalDeps)).toEqual({
      action: 'drop', reason: 'sender revoked by canonical DM allowFrom',
    })
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

  test('valid JSON with malformed shapes cannot broaden DM or guild access', async () => {
    writeFileSync(join(dir, 'access.json'), JSON.stringify({
      dmPolicy: 'pairing',
      allowFrom: 'u1',
      groups: {
        chan1: { requireMention: 'no', allowFrom: 'u1' },
      },
      pending: [],
      textChunkLimit: '999999',
    }))
    const loaded = store.load()
    expect(loaded.allowFrom).toEqual([])
    expect(loaded.groups.chan1).toEqual({ requireMention: true, allowFrom: [] })
    expect(loaded.pending).toEqual({})
    expect(loaded.textChunkLimit).toBeUndefined()
    expect((await gate(dm('u1'), deps({ makeCode: () => 'safe01' }))).action).toBe('pair')
    expect((await gate(guild('u1', 'chan1', true), deps())).action).toBe('drop')
  })

  test('non-object JSON is quarantined like invalid JSON', () => {
    writeFileSync(join(dir, 'access.json'), 'null')
    expect(store.load()).toEqual(defaultAccess())
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
