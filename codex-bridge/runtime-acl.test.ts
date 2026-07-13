import { spawnSync } from 'child_process'
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'fs'
import { tmpdir, userInfo } from 'os'
import { join } from 'path'
import { describe, expect, test } from 'bun:test'
import {
  baseRuntimeAclEntries,
  grantBaseRuntimeAccess,
  grantTurnRuntimeAccess,
  revokeBaseRuntimeAccess,
  turnRuntimeAclEntries,
  type RuntimeAclCommand,
  type RuntimeAclInspector,
  verifyBaseRuntimeAccess,
} from './runtime-acl.ts'
import { listExtendedAclEntries } from './security.ts'

function memoryAclHost(
  calls: string[][],
  failAdd?: (count: number) => boolean,
  failClear?: (count: number) => boolean,
): {
  acl: Map<string, string[]>
  command: RuntimeAclCommand
  inspector: RuntimeAclInspector
} {
  const acl = new Map<string, string[]>()
  let additions = 0
  let clears = 0
  return {
    acl,
    command: args => {
      calls.push([...args])
      if (args[0] === '-N') {
        clears++
        if (failClear?.(clears)) return { status: 1, stderr: 'injected revoke' }
        acl.set(args[1], [])
        return { status: 0, stderr: '' }
      }
      if (args[0] === '+a') {
        additions++
        if (failAdd?.(additions)) return { status: 1, stderr: 'injected grant' }
        acl.set(args[2], [...(acl.get(args[2]) ?? []), args[1]])
        return { status: 0, stderr: '' }
      }
      return { status: 1, stderr: 'unexpected command' }
    },
    inspector: path => acl.get(path) ?? [],
  }
}

describe('dedicated runtime ACL scope', () => {
  test('grants only traversal, immutable shims, and the exact active turn paths', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-state-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    mkdirSync(state, { recursive: true, mode: 0o700 })
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(inbox)
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      const base = baseRuntimeAclEntries(home, state, inbox, temp, shims)
      expect(base.map(entry => entry.path)).toEqual([
        realpathSync(home),
        realpathSync(join(home, '.codex')),
        realpathSync(join(home, '.codex', 'channels')),
        realpathSync(state),
        realpathSync(inbox),
        realpathSync(temp),
        realpathSync(shims),
        realpathSync(join(shims, 'mktemp')),
      ])
      expect(base.slice(0, 4).every(entry => !entry.permissions.includes('list'))).toBe(true)
      expect(base.some(entry => entry.path.endsWith('access.json'))).toBe(false)

      const attachment = join(inbox, 'message', 'attachment.txt')
      mkdirSync(join(inbox, 'message'))
      mkdirSync(join(temp, 'message'))
      writeFileSync(attachment, 'attachment')
      const active = turnRuntimeAclEntries(join(temp, 'message'), join(inbox, 'message'), [attachment])
      expect(active.map(entry => entry.path)).toEqual([
        realpathSync(join(temp, 'message')), realpathSync(join(inbox, 'message')), realpathSync(attachment),
      ])
      expect(active[0].permissions).toContain('add_file')
      expect(active[2].permissions).toStartWith('read,')
      expect(active[2].permissions).not.toContain('write')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('leaves a public home and its protective ACL outside the managed plan', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-public-home-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(home, { mode: 0o755 })
    chmodSync(home, 0o755)
    mkdirSync(inbox, { recursive: true, mode: 0o700 })
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      const canonicalHome = realpathSync(home)
      const privateCodex = realpathSync(join(home, '.codex'))
      const privateChannels = realpathSync(join(home, '.codex', 'channels'))
      const canonicalState = realpathSync(state)
      const entries = baseRuntimeAclEntries(home, state, inbox, temp, shims)
      expect(entries.map(entry => entry.path)).toEqual([
        privateCodex,
        privateChannels,
        canonicalState,
        realpathSync(inbox),
        realpathSync(temp),
        realpathSync(shims),
        realpathSync(join(shims, 'mktemp')),
      ])

      const calls: string[][] = []
      const inspected: string[] = []
      const host = memoryAclHost(calls)
      const inspector: RuntimeAclInspector = path => {
        inspected.push(path)
        if (path === canonicalHome) return ['group:everyone deny delete']
        return host.inspector(path)
      }

      grantBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, inspector,
      )
      verifyBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, inspector,
      )
      expect(inspected).not.toContain(canonicalHome)
      expect(calls.every(args => args.at(-1) !== canonicalHome)).toBe(true)
      expect(calls).toContainEqual(['-N', canonicalState])
      expect(calls).not.toContainEqual(['-N', privateCodex])
      expect(calls).not.toContainEqual(['-N', privateChannels])

      const beforeRevoke = calls.length
      revokeBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, inspector,
      )
      const revoked = calls.slice(beforeRevoke)
      expect(revoked).toContainEqual(['-N', canonicalState])
      expect(revoked).not.toContainEqual(['-N', privateCodex])
      expect(revoked).not.toContainEqual(['-N', privateChannels])
      expect(host.inspector(canonicalState)).toEqual([])
      for (const entry of entries.slice(0, 2)) {
        expect(host.inspector(entry.path)).toEqual([
          `user:runtime_user allow ${entry.permissions}`,
        ])
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('failed grants retain shared traversal but roll back every state-local and turn ACE', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-rollback-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(inbox, { recursive: true, mode: 0o700 })
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      const calls: string[][] = []
      let host = memoryAclHost(calls, count => count === 6)
      expect(() => grantBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
      )).toThrow('injected grant')
      const entries = baseRuntimeAclEntries(home, state, inbox, temp, shims)
      expect(calls.filter(args => args[0] === '-N').slice(-2).map(args => args[1]))
        .toEqual([entries[4].path, entries[3].path])
      for (const entry of entries.slice(0, 3)) {
        expect(host.acl.get(entry.path)).toEqual([`user:runtime_user allow ${entry.permissions}`])
      }
      for (const entry of entries.slice(3)) expect(host.inspector(entry.path)).toEqual([])

      const turnInbox = join(inbox, 'turn')
      const turnTemp = join(temp, 'turn')
      mkdirSync(turnInbox)
      mkdirSync(turnTemp)
      const attachment = join(turnInbox, 'a.txt')
      writeFileSync(attachment, 'a')
      calls.length = 0
      host = memoryAclHost(calls, count => count === 3)
      expect(() => grantTurnRuntimeAccess(
        'runtime_user', turnTemp, turnInbox, [attachment], host.command, host.inspector,
      )).toThrow('injected grant')
      const turnEntries = turnRuntimeAclEntries(turnTemp, turnInbox, [attachment])
      expect(calls.filter(args => args[0] === '-N').slice(-2).map(args => args[1]))
        .toEqual([turnEntries[1].path, turnEntries[0].path])
      expect([...host.acl.values()].every(entries => entries.length === 0)).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('revocation attempts every state-local ACE, preserves shared traversal, and aggregates failure', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-revoke-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(inbox, { recursive: true, mode: 0o700 })
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      const calls: string[][] = []
      const host = memoryAclHost(calls, undefined, count => count === 1)
      const entries = baseRuntimeAclEntries(home, state, inbox, temp, shims)
      for (const entry of entries) {
        host.acl.set(entry.path, [`user:runtime_user allow ${entry.permissions}`])
      }
      expect(() => revokeBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
      )).toThrow('revocation incomplete')
      expect(calls).toHaveLength(entries.length - 3)
      expect(calls.every(args => !entries.slice(0, 3).some(entry => args.at(-1) === entry.path))).toBe(true)
      for (const entry of entries.slice(0, 3)) {
        expect(host.acl.get(entry.path)).toEqual([`user:runtime_user allow ${entry.permissions}`])
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('refuses every unrelated or broader ACE before mutating the plan', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-refuse-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(inbox, { recursive: true, mode: 0o700 })
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      for (const unexpected of [
        'group:everyone allow list,add_file',
        'user:runtime_user allow search,readattr,readextattr,readsecurity,list',
        'user:runtime_user inherited allow search,readattr,readextattr,readsecurity',
      ]) {
        const calls: string[][] = []
        const host = memoryAclHost(calls)
        host.acl.set(realpathSync(state), [unexpected])
        expect(() => grantBaseRuntimeAccess(
          'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
        )).toThrow('unrelated or over-broad')
        expect(calls).toEqual([])
        expect(host.acl.get(realpathSync(state))).toEqual([unexpected])
      }

      const ancestorCalls: string[][] = []
      const ancestorHost = memoryAclHost(ancestorCalls)
      const privateAncestor = realpathSync(join(home, '.codex'))
      const foreignAncestorAce = 'group:everyone deny delete'
      ancestorHost.acl.set(privateAncestor, [foreignAncestorAce])
      expect(() => grantBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims,
        ancestorHost.command, ancestorHost.inspector,
      )).toThrow('unrelated or over-broad')
      expect(ancestorCalls).toEqual([])
      expect(ancestorHost.acl.get(privateAncestor)).toEqual([foreignAncestorAce])

      const calls: string[][] = []
      const host = memoryAclHost(calls)
      const shared = baseRuntimeAclEntries(home, state, inbox, temp, shims)[0]
      const exact = `user:runtime_user allow ${shared.permissions}`
      host.acl.set(shared.path, [exact, exact])
      expect(() => grantBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
      )).toThrow('duplicate exact persistent runtime ACL')
      expect(calls).toEqual([])
      expect(host.acl.get(shared.path)).toEqual([exact, exact])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('replaces duplicate exact stale state ACEs while keeping shared traversal persistent', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-acl-stale-'))
    const home = join(root, 'home')
    const state = join(home, '.codex', 'channels', 'discord')
    const inbox = join(state, 'inbox')
    const temp = join(state, 'tool-tmp')
    const shims = join(state, 'tool-shims')
    mkdirSync(inbox, { recursive: true, mode: 0o700 })
    mkdirSync(temp)
    mkdirSync(shims)
    writeFileSync(join(shims, 'mktemp'), 'shim')
    try {
      const calls: string[][] = []
      const host = memoryAclHost(calls)
      const entries = baseRuntimeAclEntries(home, state, inbox, temp, shims)
      const stale = entries.find(entry => entry.path === realpathSync(state))!
      const ace = `user:runtime_user allow ${stale.permissions}`
      host.acl.set(stale.path, [ace, ace])
      grantBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
      )
      expect(host.acl.get(stale.path)).toEqual([ace])
      verifyBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.inspector,
      )
      revokeBaseRuntimeAccess(
        'runtime_user', home, state, inbox, temp, shims, host.command, host.inspector,
      )
      for (const entry of entries.slice(0, 3)) {
        expect(host.acl.get(entry.path)).toEqual([`user:runtime_user allow ${entry.permissions}`])
      }
      for (const entry of entries.slice(3)) expect(host.inspector(entry.path)).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('two daemon lifecycles share idempotent traversal ACEs without revoking each other', () => {
    for (const revokeFirst of ['alpha', 'beta'] as const) {
      const root = mkdtempSync(join(tmpdir(), `codex-acl-siblings-${revokeFirst}-`))
      const home = join(root, 'home')
      const makeDaemon = (name: 'alpha' | 'beta') => {
        const state = join(home, '.codex', 'channels', name)
        const inbox = join(state, 'inbox')
        const temp = join(state, 'tool-tmp')
        const shims = join(state, 'tool-shims')
        mkdirSync(inbox, { recursive: true, mode: 0o700 })
        mkdirSync(temp)
        mkdirSync(shims)
        writeFileSync(join(shims, 'mktemp'), 'shim')
        return { state, inbox, temp, shims }
      }
      const alpha = makeDaemon('alpha')
      const beta = makeDaemon('beta')
      const calls: string[][] = []
      const host = memoryAclHost(calls)
      try {
        const args = (daemon: typeof alpha) => [
          'runtime_user', home, daemon.state, daemon.inbox, daemon.temp, daemon.shims,
          host.command, host.inspector,
        ] as const
        const alphaEntries = baseRuntimeAclEntries(home, alpha.state, alpha.inbox, alpha.temp, alpha.shims)
        const betaEntries = baseRuntimeAclEntries(home, beta.state, beta.inbox, beta.temp, beta.shims)
        const betaPaths = new Set(betaEntries.map(entry => entry.path))
        const shared = alphaEntries.filter(entry => betaPaths.has(entry.path))
        expect(shared.map(entry => entry.path)).toEqual([
          realpathSync(home),
          realpathSync(join(home, '.codex')),
          realpathSync(join(home, '.codex', 'channels')),
        ])

        grantBaseRuntimeAccess(...args(alpha))
        const beforeSecondGrant = calls.length
        grantBaseRuntimeAccess(...args(beta))
        expect(calls.slice(beforeSecondGrant).every(
          command => !shared.some(entry => command.at(-1) === entry.path),
        )).toBe(true)
        verifyBaseRuntimeAccess('runtime_user', home, alpha.state, alpha.inbox, alpha.temp, alpha.shims, host.inspector)
        verifyBaseRuntimeAccess('runtime_user', home, beta.state, beta.inbox, beta.temp, beta.shims, host.inspector)

        const first = revokeFirst === 'alpha' ? alpha : beta
        const sibling = revokeFirst === 'alpha' ? beta : alpha
        const beforeFirstRevoke = calls.length
        revokeBaseRuntimeAccess(...args(first))
        expect(calls.slice(beforeFirstRevoke).every(
          command => !shared.some(entry => command.at(-1) === entry.path),
        )).toBe(true)
        verifyBaseRuntimeAccess(
          'runtime_user', home, sibling.state, sibling.inbox, sibling.temp, sibling.shims, host.inspector,
        )
        for (const entry of shared) {
          expect(host.acl.get(entry.path)).toEqual([`user:runtime_user allow ${entry.permissions}`])
        }

        revokeBaseRuntimeAccess(...args(sibling))
        for (const entry of shared) {
          expect(host.acl.get(entry.path)).toEqual([`user:runtime_user allow ${entry.permissions}`])
        }
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    }
  })

  const liveUser = userInfo().username
  test.skipIf(process.platform !== 'darwin' || !/^[a-z_][a-z0-9_-]{0,31}$/.test(liveUser))(
    'live macOS ACL refusal and revocation preserve only shared traversal ACEs',
    () => {
      const root = mkdtempSync(join(tmpdir(), 'codex-acl-live-'))
      const home = join(root, 'home')
      const state = join(home, '.codex', 'channels', 'discord')
      const inbox = join(state, 'inbox')
      const temp = join(state, 'tool-tmp')
      const shims = join(state, 'tool-shims')
      mkdirSync(inbox, { recursive: true, mode: 0o700 })
      mkdirSync(temp, { mode: 0o700 })
      mkdirSync(shims, { mode: 0o700 })
      writeFileSync(join(shims, 'mktemp'), 'shim', { mode: 0o700 })
      const chmod = (...args: string[]) => spawnSync('/bin/chmod', args, { encoding: 'utf8' })
      try {
        expect(chmod('+a', 'everyone allow read,write', state).status).toBe(0)
        expect(() => grantBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims))
          .toThrow('unrelated or over-broad')

        // State-local revocation is allowed to clean an injected ACE.
        revokeBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims)
        expect(listExtendedAclEntries(state)).toEqual([])

        grantBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims)
        verifyBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims)
        expect(chmod('+a', 'everyone allow read,write', state).status).toBe(0)
        expect(() => verifyBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims))
          .toThrow('exact dedicated runtime ACL')
        revokeBaseRuntimeAccess(liveUser, home, state, inbox, temp, shims)
        const entries = baseRuntimeAclEntries(home, state, inbox, temp, shims)
        for (const entry of entries.slice(0, 3)) {
          expect(listExtendedAclEntries(entry.path)).toHaveLength(1)
        }
        for (const entry of entries.slice(3)) {
          expect(listExtendedAclEntries(entry.path)).toEqual([])
        }
      } finally {
        spawnSync('/bin/chmod', ['-RN', root])
        rmSync(root, { recursive: true, force: true })
      }
    },
  )
})
