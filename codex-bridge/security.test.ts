import { spawnSync } from 'child_process'
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from 'fs'
import { describe, expect, test } from 'bun:test'
import { homedir, tmpdir } from 'os'
import { dirname, join, parse } from 'path'
import {
  resolveTrustedCodexExecutable,
  resolveTrustedCodexScript,
  listExtendedAclEntries,
  readPrivateDiscordTokenFile,
  validateCodexAuthBoundary,
  validatePrivateStateBoundary,
} from './security.ts'

describe('host trust boundaries', () => {
  const nodeBin = Bun.which('node')
  const codexBin = Bun.which('codex')
  const ownerControlledChain = (raw: string): boolean => {
    let current = realpathSync(raw)
    const uid = typeof process.getuid === 'function' ? process.getuid() : -1
    for (;;) {
      const stat = statSync(current)
      if (!stat.isFile() && !stat.isDirectory()) return false
      if (![0, uid].includes(stat.uid) || (stat.mode & 0o022) !== 0) return false
      const parent = dirname(current)
      if (current === parse(current).root || parent === current) return true
      current = parent
    }
  }
  const installedPlanAvailable = Boolean(
    nodeBin && codexBin && ownerControlledChain(nodeBin) && ownerControlledChain(codexBin),
  )

  test('required CI host trust plan cannot be silently skipped', () => {
    if (process.env.QOFI_REQUIRE_CODEX_SANDBOX === '1') {
      expect(
        installedPlanAvailable,
        'CI must stage owner-controlled Node and Codex paths for the live trust-boundary test',
      ).toBe(true)
    }
  })

  test.skipIf(!installedPlanAvailable)(
    'accepts the installed absolute Node + canonical codex.js plan', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-real-plan-'))
    const state = join(root, 'state')
    mkdirSync(state, { mode: 0o700 })
    try {
      expect(resolveTrustedCodexExecutable(nodeBin!, {
        workspaceRoot: root, stateDir: state,
      })).toBe(realpathSync(nodeBin!))
      expect(resolveTrustedCodexScript(realpathSync(codexBin!), {
        workspaceRoot: root, stateDir: state,
      })).toBe(realpathSync(codexBin!))
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
    },
  )

  test('rejects a workspace fake Codex even when it spoofs version/auth', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-fake-bin-'))
    const state = join(root, 'state')
    const bin = join(root, 'codex')
    mkdirSync(state, { mode: 0o700 })
    writeFileSync(bin, '#!/bin/sh\necho "codex-cli 0.144.1"\n', { mode: 0o755 })
    expect(() => resolveTrustedCodexExecutable(bin, {
      workspaceRoot: root, stateDir: state, trustedRoots: [root],
    })).toThrow()
    rmSync(root, { recursive: true, force: true })
  })

  test('requires an absolute native interpreter plus separately validated script', () => {
    const root = mkdtempSync(join(homedir(), '.codex-exec-plan-test-'))
    const workspace = join(root, 'workspace')
    const state = join(root, 'state')
    const script = join(root, 'codex.js')
    mkdirSync(workspace, { mode: 0o700 })
    mkdirSync(state, { mode: 0o700 })
    writeFileSync(script, '#!/usr/bin/env node\n', { mode: 0o755 })
    try {
      expect(() => resolveTrustedCodexExecutable(script, {
        workspaceRoot: workspace, stateDir: state, trustedRoots: [root],
      })).toThrow('interpreter indirection')
      expect(resolveTrustedCodexScript(script, {
        workspaceRoot: workspace, stateDir: state, trustedRoots: [root],
      })).toBe(script)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('rejects repo-controlled HOME and CODEX_HOME', () => {
    const root = mkdtempSync(join(homedir(), '.codex-auth-boundary-test-'))
    const account = join(root, 'account')
    const workspace = join(root, 'workspace')
    const state = join(root, 'state')
    mkdirSync(join(account, '.codex'), { recursive: true, mode: 0o700 })
    mkdirSync(workspace, { mode: 0o700 })
    mkdirSync(join(workspace, '.codex'), { mode: 0o700 })
    mkdirSync(state, { mode: 0o700 })
    try {
      expect(() => validateCodexAuthBoundary(
        { HOME: workspace }, workspace, state, [], account,
      )).toThrow('ambient HOME')
      expect(() => validateCodexAuthBoundary(
        { HOME: account, CODEX_HOME: join(workspace, '.codex') }, workspace, state, [], account,
      )).toThrow('Codex home override')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('rejects symlinked state roots and sensitive state files', () => {
    const root = mkdtempSync(join(homedir(), '.codex-state-boundary-test-'))
    chmodSync(root, 0o700)
    const real = join(root, 'real')
    const linked = join(root, 'linked')
    mkdirSync(real, { mode: 0o700 })
    symlinkSync(real, linked)
    try {
      expect(() => validatePrivateStateBoundary(linked)).toThrow('unsafe symlink')
      writeFileSync(join(real, 'access.json'), '{}', { mode: 0o600 })
      const victim = join(root, 'victim')
      writeFileSync(victim, '{}', { mode: 0o600 })
      rmSync(join(real, 'access.json'))
      symlinkSync(victim, join(real, 'access.json'))
      expect(() => validatePrivateStateBoundary(real)).toThrow('sensitive state file')
      rmSync(join(real, 'access.json'))
      writeFileSync(join(real, '.env'), 'TOKEN=x', { mode: 0o644 })
      expect(() => validatePrivateStateBoundary(real)).toThrow('mode 0600')
      rmSync(join(real, '.env'))
      mkdirSync(join(real, 'review-artifacts', 'task-123', 'default'), { recursive: true, mode: 0o700 })
      chmodSync(join(real, 'review-artifacts'), 0o700)
      chmodSync(join(real, 'review-artifacts', 'task-123'), 0o700)
      chmodSync(join(real, 'review-artifacts', 'task-123', 'default'), 0o700)
      writeFileSync(join(real, 'review-artifacts', 'task-123', 'default', 'fable-review-1.json'), '{}\n', { mode: 0o600 })
      mkdirSync(join(real, 'fable-review-tmp'), { mode: 0o700 })
      writeFileSync(join(real, 'fable-review-budget.json'), '{}\n', { mode: 0o600 })
      writeFileSync(join(real, 'fable-review-budget.lock'), '', { mode: 0o600 })
      expect(validatePrivateStateBoundary(real, false)).toBe(real)
      chmodSync(join(real, 'review-artifacts', 'task-123', 'default', 'fable-review-1.json'), 0o644)
      expect(() => validatePrivateStateBoundary(real, false)).toThrow('owner regular 0600')
      chmodSync(join(real, 'review-artifacts', 'task-123', 'default', 'fable-review-1.json'), 0o600)
      mkdirSync(join(real, 'tool-tmp'), { mode: 0o700 })
      mkdirSync(join(real, 'tool-tmp', 'npm-cache'), { mode: 0o755 })
      writeFileSync(join(real, 'tool-tmp', 'npm-cache', 'metadata'), '{}', { mode: 0o644 })
      expect(validatePrivateStateBoundary(real)).toBe(real)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('parses bounded macOS ACL output and rejects malformed listings', () => {
    const path = '/tmp/operator-state'
    expect(listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------+ 1 owner wheel 1 Jan 1 00:00 ${path}\n 0: group:everyone allow read,write\n`,
    }))).toEqual(['group:everyone allow read,write'])
    expect(listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------@ 1 owner wheel 1 Jan 1 00:00 ${path}\n 0: user:runtime allow read\n 1: group:everyone deny write\n`,
    }))).toEqual(['user:runtime allow read', 'group:everyone deny write'])
    expect(listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------@ 1 owner wheel 1 Jan 1 00:00 ${path}\n`,
    }))).toEqual([])
    expect(listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw------- 1 owner wheel 1 Jan 1 00:00 ${path}\n`,
    }))).toEqual([])
    expect(() => listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------+ 1 owner wheel 1 Jan 1 00:00 ${path}\n`,
    }))).toThrow('invalid extended ACL entry count')
    expect(() => listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------+ 1 owner wheel 1 Jan 1 00:00 ${path}\n 2: everyone allow read\n`,
    }))).toThrow('malformed extended ACL entry')
    expect(() => listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw-------@ 1 owner wheel 1 Jan 1 00:00 ${path}\n everyone allow read\n`,
    }))).toThrow('malformed extended ACL entry')
    expect(() => listExtendedAclEntries(path, () => ({
      status: 0,
      stdout: `-rw------- 1 owner wheel 1 Jan 1 00:00 ${path}\n 0: everyone allow read\n`,
    }))).toThrow('inconsistent extended ACL listing')
  })

  test.skipIf(process.platform !== 'darwin')(
    'live macOS sensitive state and token reads reject everyone ACLs',
    () => {
      const root = mkdtempSync(join(homedir(), '.codex-state-acl-live-'))
      const state = join(root, 'state')
      mkdirSync(state, { mode: 0o700 })
      chmodSync(root, 0o700)
      chmodSync(state, 0o700)
      const token = 'MTIzNDU2.Nzkw.safe_token_value_1234567890'
      const files: Record<string, string> = {
        'discord-token': `${token}\n`,
        'access.json': '{}\n',
        'sessions.json': '{}\n',
        'runtime.json': '{}\n',
        'events.jsonl': '{}\n',
      }
      for (const [name, content] of Object.entries(files)) {
        writeFileSync(join(state, name), content, { mode: 0o600 })
        chmodSync(join(state, name), 0o600)
      }
      const approved = join(state, 'approved')
      mkdirSync(approved, { mode: 0o700 })
      chmodSync(approved, 0o700)
      const chmod = (...args: string[]) => spawnSync('/bin/chmod', args, { encoding: 'utf8' })
      try {
        for (const name of Object.keys(files)) {
          const path = join(state, name)
          expect(chmod('+a', 'everyone allow read,write', path).status).toBe(0)
          expect(() => validatePrivateStateBoundary(state, false)).toThrow('extended ACL')
          if (name === 'discord-token') {
            expect(() => readPrivateDiscordTokenFile(state, path)).toThrow('extended ACL')
          }
          expect(chmod('-N', path).status).toBe(0)
          expect(listExtendedAclEntries(path)).toEqual([])
        }
        expect(chmod('+a', 'everyone allow read,write', approved).status).toBe(0)
        expect(() => validatePrivateStateBoundary(state, false)).toThrow('extended ACL')
        expect(chmod('-N', approved).status).toBe(0)
        expect(listExtendedAclEntries(approved)).toEqual([])
        expect(readPrivateDiscordTokenFile(state, join(state, 'discord-token'))).toBe(token)
      } finally {
        spawnSync('/bin/chmod', ['-RN', root])
        rmSync(root, { recursive: true, force: true })
      }
    },
  )

  test('Discord credential comes only from the exact private state token file', () => {
    const root = mkdtempSync(join(homedir(), '.codex-token-file-test-'))
    const state = join(root, 'state')
    mkdirSync(state, { mode: 0o700 })
    chmodSync(state, 0o700)
    const path = join(state, 'discord-token')
    const token = 'MTIzNDU2.Nzkw.safe_token_value_1234567890'
    writeFileSync(path, `${token}\n`, { mode: 0o600 })
    chmodSync(path, 0o600)
    try {
      expect(readPrivateDiscordTokenFile(state, path)).toBe(token)
      expect(() => readPrivateDiscordTokenFile(state, join(state, '.env')))
        .toThrow('must equal')
      chmodSync(path, 0o644)
      expect(() => readPrivateDiscordTokenFile(state, path)).toThrow('mode 0600')
      rmSync(path)
      const victim = join(root, 'victim')
      writeFileSync(victim, token, { mode: 0o600 })
      symlinkSync(victim, path)
      expect(() => readPrivateDiscordTokenFile(state, path)).toThrow()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
