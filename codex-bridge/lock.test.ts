import { describe, expect, test } from 'bun:test'
import { spawnSync } from 'child_process'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  renameSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  type AtomicLockHelperRunner,
  DaemonAlreadyRunningError,
  DaemonLock,
  DaemonStaleLockError,
} from './lock.ts'

describe('DaemonLock', () => {
  test('excludes a live second owner and releases private lock state', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-')))
    try {
      const first = DaemonLock.acquire(dir)
      expect(() => DaemonLock.acquire(dir)).toThrow(DaemonAlreadyRunningError)
      expect(statSync(first.lockDir).mode & 0o777).toBe(0o700)
      expect(statSync(first.ownerFile).mode & 0o777).toBe(0o600)
      expect(first.release()).toBe(true)
      expect(existsSync(first.lockDir)).toBe(false)
      expect(DaemonLock.acquire(dir).release()).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('dead-owner state fails closed until explicitly removed', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-stale-lock-')))
    const lockDir = join(dir, 'daemon.lock')
    try {
      mkdirSync(lockDir, { mode: 0o700 })
      writeFileSync(join(lockDir, 'owner.json'), JSON.stringify({
        schema: 'codex-bridge-lock/v1',
        pid: 2_147_483_647,
        token: '11111111-1111-4111-8111-111111111111',
        started_at: new Date(0).toISOString(),
      }), { mode: 0o600 })
      expect(() => DaemonLock.acquire(dir)).toThrow(DaemonStaleLockError)
      expect(JSON.parse(readFileSync(join(lockDir, 'owner.json'), 'utf8')).token)
        .toBe('11111111-1111-4111-8111-111111111111')
      rmSync(lockDir, { recursive: true, force: true })
      expect(DaemonLock.acquire(dir).release()).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('concurrent starters cannot race-delete the same stale lock', async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-stale-race-')))
    const lockDir = join(dir, 'daemon.lock')
    try {
      mkdirSync(lockDir, { mode: 0o700 })
      writeFileSync(join(lockDir, 'owner.json'), JSON.stringify({
        schema: 'codex-bridge-lock/v1',
        pid: 2_147_483_647,
        token: '22222222-2222-4222-8222-222222222222',
        started_at: new Date(0).toISOString(),
      }), { mode: 0o600 })
      const modulePath = join(import.meta.dir, 'lock.ts')
      const source = `const {DaemonLock}=await import(${JSON.stringify(modulePath)});try{DaemonLock.acquire(${JSON.stringify(dir)});console.log('ACQUIRED')}catch{process.exit(2)}`
      const first = Bun.spawn(['bun', '-e', source], { stdout: 'pipe', stderr: 'pipe' })
      const second = Bun.spawn(['bun', '-e', source], { stdout: 'pipe', stderr: 'pipe' })
      const [firstCode, secondCode] = await Promise.all([first.exited, second.exited])
      expect([firstCode, secondCode]).toEqual([2, 2])
      expect(existsSync(lockDir)).toBe(true)
      expect(JSON.parse(readFileSync(join(lockDir, 'owner.json'), 'utf8')).token)
        .toBe('22222222-2222-4222-8222-222222222222')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('an old instance cannot release a replacement owner', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-owner-')))
    try {
      const lock = DaemonLock.acquire(dir)
      const owner = JSON.parse(readFileSync(lock.ownerFile, 'utf8'))
      writeFileSync(lock.ownerFile, JSON.stringify({ ...owner, token: 'replacement' }))
      expect(lock.release()).toBe(false)
      expect(existsSync(lock.lockDir)).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('adopts an exact complete publication when helper status is ambiguous', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-ambiguous-')))
    try {
      const ambiguousRunner: AtomicLockHelperRunner = (command, args, options) => {
        const actual = spawnSync(command, [...args], options)
        expect(actual.status).toBe(0)
        return { status: null, error: new Error('lost helper exit status') }
      }
      const lock = DaemonLock.acquire(dir, { atomicHelperRunner: ambiguousRunner })
      expect(JSON.parse(readFileSync(lock.ownerFile, 'utf8')).pid).toBe(process.pid)
      expect(lock.release()).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('ambiguous publication never deletes a different complete owner', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-other-owner-')))
    const lockDir = join(dir, 'daemon.lock')
    const replacementToken = '33333333-3333-4333-8333-333333333333'
    try {
      const ambiguousRunner: AtomicLockHelperRunner = (command, args, options) => {
        const requested = JSON.parse(options.input)
        const other = JSON.stringify({ ...requested, token: replacementToken }, null, 2) + '\n'
        const actual = spawnSync(command, [...args], { ...options, input: other })
        expect(actual.status).toBe(0)
        return { status: null, error: new Error('lost helper exit status') }
      }
      expect(() => DaemonLock.acquire(dir, { atomicHelperRunner: ambiguousRunner }))
        .toThrow(DaemonAlreadyRunningError)
      expect(JSON.parse(readFileSync(join(lockDir, 'owner.json'), 'utf8')).token)
        .toBe(replacementToken)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('an exact-token directory replacement cannot trigger pathname ABA deletion', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-aba-')))
    const displaced = join(dir, 'daemon.lock.displaced')
    try {
      const lock = DaemonLock.acquire(dir)
      const exactOwner = readFileSync(lock.ownerFile, 'utf8')
      renameSync(lock.lockDir, displaced)
      mkdirSync(lock.lockDir, { mode: 0o700 })
      writeFileSync(lock.ownerFile, exactOwner, { mode: 0o600 })

      expect(lock.release()).toBe(false)
      expect(existsSync(lock.lockDir)).toBe(true)
      expect(existsSync(displaced)).toBe(true)
      expect(readFileSync(lock.ownerFile, 'utf8')).toBe(exactOwner)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('an exact-token owner-file replacement cannot trigger inode-blind deletion', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'codex-bridge-lock-owner-aba-')))
    try {
      const lock = DaemonLock.acquire(dir)
      const exactOwner = readFileSync(lock.ownerFile, 'utf8')
      rmSync(lock.ownerFile)
      writeFileSync(lock.ownerFile, exactOwner, { mode: 0o600 })

      expect(lock.release()).toBe(false)
      expect(existsSync(lock.lockDir)).toBe(true)
      expect(readFileSync(lock.ownerFile, 'utf8')).toBe(exactOwner)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
