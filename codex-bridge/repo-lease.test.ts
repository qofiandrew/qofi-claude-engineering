import { lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'fs'
import { spawnSync } from 'child_process'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  type AtomicRepoLeasePublisher,
  RepoLease,
  RepoLeaseStaleError,
} from './repo-lease.ts'

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'codex-repo-lease-')))
  const channels = join(root, 'channels')
  const stateA = join(channels, 'discord-a')
  const stateB = join(channels, 'discord-b')
  const repo = join(root, 'repo')
  for (const path of [channels, stateA, stateB, repo]) mkdirSync(path, { mode: 0o700 })
  return { root, stateA, stateB, repo, leaseRoot: join(channels, 'repo-locks') }
}

describe('physical repository lease', () => {
  test('serializes separate swarm state directories and releases by token', async () => {
    const f = fixture()
    try {
      const first = await RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 100,
      })
      let acquired = false
      const secondPromise = RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateB,
        swarmName: 'b', operation: 'git', waitMs: 1000, pollMs: 25,
      }).then(lease => { acquired = true; return lease })
      await Bun.sleep(75)
      expect(acquired).toBe(false)
      expect(first.verifyOwnership()).toBe(true)
      expect(first.release()).toBe(true)
      expect(first.verifyOwnership()).toBe(false)
      const second = await secondPromise
      expect(second.release()).toBe(true)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('a dead exact owner fails closed for audited recovery', async () => {
    const f = fixture()
    try {
      const identity = lstatSync(f.repo)
      const lock = join(f.leaseRoot, `${identity.dev}-${identity.ino}.lock`)
      mkdirSync(f.leaseRoot, { mode: 0o700 })
      mkdirSync(lock, { mode: 0o700 })
      writeFileSync(join(lock, 'owner.json'), JSON.stringify({
        schema: 'qofi-codex-repo-lease/v1', pid: 2147483647,
        token: '00000000-0000-4000-8000-000000000000',
        repo_dev: identity.dev, repo_ino: identity.ino, repo_path: f.repo,
        swarm_name: 'a', state_dir: f.stateA, operation: 'turn',
        started_at: new Date(0).toISOString(),
      }, null, 2) + '\n', { mode: 0o600 })
      await expect(RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 50,
      })).rejects.toBeInstanceOf(RepoLeaseStaleError)
      expect(readFileSync(join(lock, 'owner.json'), 'utf8')).toContain('2147483647')
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('replacement owner token prevents release', async () => {
    const f = fixture()
    try {
      const lease = await RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 50,
      })
      const ownerFile = join(lease.lockDir, 'owner.json')
      const owner = JSON.parse(readFileSync(ownerFile, 'utf8'))
      writeFileSync(ownerFile, JSON.stringify({
        ...owner, token: '00000000-0000-4000-8000-000000000000',
      }, null, 2) + '\n', { mode: 0o600 })
      expect(lease.verifyOwnership()).toBe(false)
      expect(lease.release()).toBe(false)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('an aborted waiter never removes the live owner', async () => {
    const f = fixture()
    try {
      const first = await RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 100,
      })
      const abort = new AbortController()
      const waiting = RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateB,
        swarmName: 'b', operation: 'turn', waitMs: 1000, pollMs: 25,
        signal: abort.signal,
      })
      abort.abort(new Error('stop'))
      await expect(waiting).rejects.toThrow('stop')
      expect(readFileSync(first.ownerFile, 'utf8')).toContain('"swarm_name": "a"')
      expect(first.release()).toBe(true)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('adopts only its exact lease after an ambiguous helper completion', async () => {
    const f = fixture()
    try {
      const publisher: AtomicRepoLeasePublisher = (command, args, options) => {
        const actual = spawnSync(command, [...args], options)
        expect(actual.status).toBe(0)
        return { status: null, error: new Error('lost publisher status') }
      }
      const lease = await RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 50,
        atomicPublisher: publisher,
      })
      expect(JSON.parse(readFileSync(lease.ownerFile, 'utf8')).swarm_name).toBe('a')
      expect(lease.release()).toBe(true)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('ambiguous publication never adopts or removes another exact owner', async () => {
    const f = fixture()
    const replacement = '44444444-4444-4444-8444-444444444444'
    try {
      const publisher: AtomicRepoLeasePublisher = (command, args, options) => {
        const requested = JSON.parse(options.input)
        const actual = spawnSync(command, [...args], {
          ...options,
          input: JSON.stringify({ ...requested, token: replacement }, null, 2) + '\n',
        })
        expect(actual.status).toBe(0)
        return { status: null, error: new Error('lost publisher status') }
      }
      await expect(RepoLease.acquire({
        root: f.leaseRoot, cwd: f.repo, stateDir: f.stateA,
        swarmName: 'a', operation: 'turn', waitMs: 50,
        atomicPublisher: publisher,
      })).rejects.toThrow('publication failed')
      const identity = lstatSync(f.repo)
      const ownerFile = join(f.leaseRoot, `${identity.dev}-${identity.ino}.lock`, 'owner.json')
      expect(JSON.parse(readFileSync(ownerFile, 'utf8')).token).toBe(replacement)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })
})
