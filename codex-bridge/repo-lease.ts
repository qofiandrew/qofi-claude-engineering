import { createHash, randomUUID } from 'crypto'
import { spawnSync } from 'child_process'
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
} from 'fs'
import { basename, dirname, isAbsolute, join, resolve } from 'path'
import { assertNoExtendedAcl } from './security.ts'
import { isPidAlive } from './lock.ts'

export const REPO_LEASE_SCHEMA = 'qofi-codex-repo-lease/v1' as const

export type RepoLeaseOperation = 'startup' | 'turn' | 'git'

type RepoIdentity = {
  path: string
  dev: number
  ino: number
}

type RepoLeaseOwner = {
  schema: typeof REPO_LEASE_SCHEMA
  pid: number
  token: string
  repo_dev: number
  repo_ino: number
  repo_path: string
  swarm_name: string
  state_dir: string
  operation: RepoLeaseOperation
  started_at: string
}

type OwnerRecord = {
  owner: RepoLeaseOwner
  dev: number
  ino: number
  sha256: string
}

type AtomicPublisherResult = {
  status: number | null
  error?: unknown
  stderr?: string | Buffer | null
}

type AtomicPublisherOptions = {
  input: string
  encoding: 'utf8'
  timeout: number
  maxBuffer: number
  env: NodeJS.ProcessEnv
}

/** @internal Test seam; production always uses the pinned Python helper. */
export type AtomicRepoLeasePublisher = (
  command: string,
  args: readonly string[],
  options: AtomicPublisherOptions,
) => AtomicPublisherResult

export class RepoLeaseBusyError extends Error {
  constructor(readonly ownerPid: number) {
    super(`repository is still leased by a live Codex daemon (pid ${ownerPid})`)
    this.name = 'RepoLeaseBusyError'
  }
}

export class RepoLeaseStaleError extends Error {
  constructor(readonly ownerPid: number | null) {
    super(
      `repository has a stale or malformed Codex lease${ownerPid ? ` (dead pid ${ownerPid})` : ''}; audit it with swarm-recover.sh before retrying`,
    )
    this.name = 'RepoLeaseStaleError'
  }
}

function currentUid(): number | null {
  return typeof process.getuid === 'function' ? process.getuid() : null
}

function exactKeys(value: Record<string, unknown>): boolean {
  return Object.keys(value).sort().join(',') === [
    'operation', 'pid', 'repo_dev', 'repo_ino', 'repo_path', 'schema',
    'started_at', 'state_dir', 'swarm_name', 'token',
  ].sort().join(',')
}

function safeCanonicalDirectory(path: string, mode: number): string {
  const lexical = resolve(path)
  const stat = lstatSync(lexical)
  const uid = currentUid()
  if (
    !isAbsolute(path)
    || lexical !== path
    || !stat.isDirectory()
    || stat.isSymbolicLink()
    || realpathSync(lexical) !== lexical
    || (uid !== null && stat.uid !== uid)
    || (stat.mode & 0o777) !== mode
  ) throw new Error(`unsafe repository lease directory: ${path}`)
  assertNoExtendedAcl(lexical, 'repository lease directory')
  return lexical
}

function repoIdentity(cwd: string): RepoIdentity {
  const path = realpathSync(resolve(cwd))
  if (path !== resolve(cwd)) throw new Error('repository lease path must be canonical')
  const stat = lstatSync(path)
  if (
    !stat.isDirectory()
    || stat.isSymbolicLink()
    || !Number.isSafeInteger(stat.dev)
    || stat.dev < 0
    || !Number.isSafeInteger(stat.ino)
    || stat.ino <= 0
  ) throw new Error('repository lease requires a real directory with bounded identity')
  return { path, dev: stat.dev, ino: stat.ino }
}

const defaultAtomicPublisher: AtomicRepoLeasePublisher = (command, args, options) => (
  spawnSync(command, [...args], options)
)

function publishLockDirectory(
  lockDir: string,
  owner: RepoLeaseOwner,
  publisher: AtomicRepoLeasePublisher = defaultAtomicPublisher,
): 'acquired' | 'exists' {
  const helper = resolve(import.meta.dir, '..', 'bin', 'atomic-directory-lock.py')
  const stat = lstatSync(helper)
  const uid = currentUid()
  if (
    !stat.isFile()
    || stat.isSymbolicLink()
    || realpathSync(helper) !== helper
    || (uid !== null && stat.uid !== uid && stat.uid !== 0)
    || (stat.mode & 0o022) !== 0
    || stat.size <= 0
    || stat.size > 128 * 1024
  ) throw new Error('atomic repository lease publisher is unsafe')
  const result = publisher('/usr/bin/python3', [
    '-I', '-B', helper, lockDir, 'owner.json',
  ], {
    input: JSON.stringify(owner, null, 2) + '\n',
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 64 * 1024,
    env: { PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
  })
  if (result.error) {
    // rename-no-replace may have succeeded before a timeout or parent-fsync
    // error became observable. Adopt only this exact generated capability;
    // otherwise leave every ambiguous artifact for audited recovery.
    const identity = { path: owner.repo_path, dev: owner.repo_dev, ino: owner.repo_ino }
    try {
      safeCanonicalDirectory(lockDir, 0o700)
      const published = readOwnerRecord(join(lockDir, 'owner.json'), identity)
      if (published?.owner.token === owner.token
        && published.owner.state_dir === owner.state_dir
        && published.owner.swarm_name === owner.swarm_name
        && published.owner.operation === owner.operation) return 'acquired'
    } catch {}
    throw new Error(`repository lease publication failed: ${result.error}`)
  }
  if (result.status === 17) return 'exists'
  if (result.status !== 0) {
    const identity = { path: owner.repo_path, dev: owner.repo_dev, ino: owner.repo_ino }
    try {
      safeCanonicalDirectory(lockDir, 0o700)
      const published = readOwnerRecord(join(lockDir, 'owner.json'), identity)
      if (published?.owner.token === owner.token
        && published.owner.state_dir === owner.state_dir
        && published.owner.swarm_name === owner.swarm_name
        && published.owner.operation === owner.operation) return 'acquired'
    } catch {}
    throw new Error(`repository lease publication failed: ${String(result.stderr).slice(0, 500)}`)
  }
  return 'acquired'
}

function readOwnerRecord(ownerFile: string, identity: RepoIdentity): OwnerRecord | null {
  try {
    const stat = lstatSync(ownerFile)
    const uid = currentUid()
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || (uid !== null && stat.uid !== uid)
      || (stat.mode & 0o777) !== 0o600
      || stat.size < 2
      || stat.size > 16 * 1024
    ) return null
    assertNoExtendedAcl(ownerFile, 'repository lease owner')
    const fd = openSync(ownerFile, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    let raw: Buffer
    try {
      const opened = fstatSync(fd)
      if (
        opened.dev !== stat.dev || opened.ino !== stat.ino
        || opened.size !== stat.size || opened.mtimeMs !== stat.mtimeMs
        || opened.ctimeMs !== stat.ctimeMs
      ) return null
      raw = Buffer.from(readFileSync(fd))
      const after = fstatSync(fd)
      if (
        after.dev !== opened.dev || after.ino !== opened.ino
        || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs
        || after.ctimeMs !== opened.ctimeMs
      ) return null
    } finally {
      closeSync(fd)
    }
    assertNoExtendedAcl(ownerFile, 'repository lease owner')
    const value = JSON.parse(raw.toString('utf8')) as Record<string, unknown>
    if (
      !exactKeys(value)
      || value.schema !== REPO_LEASE_SCHEMA
      || !Number.isSafeInteger(value.pid) || (value.pid as number) <= 0
      || typeof value.token !== 'string'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value.token)
      || value.repo_dev !== identity.dev
      || value.repo_ino !== identity.ino
      || value.repo_path !== identity.path
      || typeof value.swarm_name !== 'string'
      || !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(value.swarm_name)
      || typeof value.state_dir !== 'string'
      || !isAbsolute(value.state_dir)
      || resolve(value.state_dir) !== value.state_dir
      || realpathSync(value.state_dir) !== value.state_dir
      || dirname(value.state_dir) !== dirname(dirname(dirname(ownerFile)))
      || basename(value.state_dir) !== `discord-${value.swarm_name}`
      || (value.operation !== 'startup' && value.operation !== 'turn' && value.operation !== 'git')
      || typeof value.started_at !== 'string'
      || !Number.isFinite(Date.parse(value.started_at))
    ) return null
    return {
      owner: value as RepoLeaseOwner,
      dev: stat.dev,
      ino: stat.ino,
      sha256: createHash('sha256').update(raw).digest('hex'),
    }
  } catch {
    return null
  }
}

function readOwner(ownerFile: string, identity: RepoIdentity): RepoLeaseOwner | null {
  return readOwnerRecord(ownerFile, identity)?.owner ?? null
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolveDelay, reject) => {
    if (signal?.aborted) {
      reject(signal.reason ?? new Error('repository lease wait aborted'))
      return
    }
    const onAbort = () => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      reject(signal.reason ?? new Error('repository lease wait aborted'))
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolveDelay()
    }, ms)
    signal?.addEventListener('abort', onAbort, { once: true })
    if (signal?.aborted) onAbort()
  })
}

/**
 * Cross-daemon, physical-repository lease. Atomic mkdir provides exclusion;
 * crashes deliberately leave an auditable dead-owner lock instead of guessing
 * that a half-finished turn is safe to overlap.
 */
export class RepoLease {
  private released = false

  private constructor(
    readonly root: string,
    readonly lockDir: string,
    readonly ownerFile: string,
    private readonly identity: RepoIdentity,
    private readonly stateDir: string,
    private readonly token: string,
    private readonly lockDev: number,
    private readonly lockIno: number,
    private readonly ownerDev: number,
    private readonly ownerIno: number,
    private readonly ownerSha256: string,
  ) {}

  static async acquire(options: {
    root: string
    cwd: string
    stateDir: string
    swarmName: string
    operation: RepoLeaseOperation
    signal?: AbortSignal
    waitMs?: number
    pollMs?: number
    pid?: number
    now?: Date
    /** @internal Tests only; production callers must omit this seam. */
    atomicPublisher?: AtomicRepoLeasePublisher
  }): Promise<RepoLease> {
    const identity = repoIdentity(options.cwd)
    const stateDir = realpathSync(resolve(options.stateDir))
    if (stateDir !== resolve(options.stateDir)) throw new Error('repository lease state path must be canonical')
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(options.swarmName)) {
      throw new Error('repository lease swarm name is invalid')
    }
    if (basename(options.root) !== 'repo-locks' || dirname(options.root) !== dirname(stateDir)) {
      throw new Error('repository lease root must be the shared sibling of per-swarm state')
    }
    let createdRoot = false
    try {
      mkdirSync(options.root, { mode: 0o700 })
      createdRoot = true
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
    }
    if (createdRoot) chmodSync(options.root, 0o700)
    const root = safeCanonicalDirectory(options.root, 0o700)
    const lockDir = join(root, `${identity.dev}-${identity.ino}.lock`)
    const ownerFile = join(lockDir, 'owner.json')
    const deadline = Date.now() + (options.waitMs ?? 30 * 60 * 1000)
    const pollMs = Math.max(25, Math.min(options.pollMs ?? 250, 5000))

    for (;;) {
      options.signal?.throwIfAborted()
      const token = randomUUID()
      const owner: RepoLeaseOwner = {
        schema: REPO_LEASE_SCHEMA,
        pid: options.pid ?? process.pid,
        token,
        repo_dev: identity.dev,
        repo_ino: identity.ino,
        repo_path: identity.path,
        swarm_name: options.swarmName,
        state_dir: stateDir,
        operation: options.operation,
        started_at: (options.now ?? new Date()).toISOString(),
      }
      if (publishLockDirectory(lockDir, owner, options.atomicPublisher) === 'exists') {
        let existing: RepoLeaseOwner | null = null
        try {
          safeCanonicalDirectory(lockDir, 0o700)
          existing = readOwner(ownerFile, identity)
        } catch {}
        if (!existing) throw new RepoLeaseStaleError(null)
        if (!isPidAlive(existing.pid)) throw new RepoLeaseStaleError(existing.pid)
        if (Date.now() >= deadline) throw new RepoLeaseBusyError(existing.pid)
        await delay(pollMs, options.signal)
        continue
      }

      const created = lstatSync(lockDir)
      try {
        safeCanonicalDirectory(lockDir, 0o700)
        const published = readOwnerRecord(ownerFile, identity)
        if (!published || published.owner.token !== token || published.owner.state_dir !== stateDir) {
          throw new Error('atomically published repository lease owner could not be revalidated')
        }
        return new RepoLease(
          root, lockDir, ownerFile, identity, stateDir, token, created.dev, created.ino,
          published.dev, published.ino, published.sha256,
        )
      } catch (err) {
        // Publication was atomic. Leave any validation failure as explicit,
        // receipt-recoverable evidence; never pathname-delete a possibly
        // replaced lock from an exception path.
        throw err
      }
    }
  }

  /** Reprove the exact on-disk capability without mutating or releasing it. */
  verifyOwnership(): boolean {
    if (this.released) return false
    try {
      safeCanonicalDirectory(this.root, 0o700)
      const lock = lstatSync(this.lockDir)
      if (lock.dev !== this.lockDev || lock.ino !== this.lockIno) return false
      const observed = readOwnerRecord(this.ownerFile, this.identity)
      return observed !== null
        && observed.dev === this.ownerDev
        && observed.ino === this.ownerIno
        && observed.sha256 === this.ownerSha256
        && observed.owner.token === this.token
        && observed.owner.state_dir === this.stateDir
    } catch {
      return false
    }
  }

  /** Release only the exact inode and unguessable owner token acquired here. */
  release(): boolean {
    if (this.released) return true
    try {
      const helper = resolve(import.meta.dir, '..', 'bin', 'atomic-directory-lock.py')
      const result = spawnSync('/usr/bin/python3', [
        '-I', '-B', helper, 'release', this.lockDir, 'owner.json',
        String(this.lockDev), String(this.lockIno),
        String(this.ownerDev), String(this.ownerIno), this.ownerSha256, this.token,
      ], {
        encoding: 'utf8', timeout: 5000, maxBuffer: 64 * 1024,
        env: { PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
      })
      if (result.error || result.status !== 0) return false
      this.released = true
      return true
    } catch {
      return false
    }
  }
}
