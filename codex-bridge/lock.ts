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
  readdirSync,
  readFileSync,
  realpathSync,
} from 'fs'
import { isAbsolute, join, resolve } from 'path'
import { assertNoExtendedAcl } from './security.ts'

const LOCK_SCHEMA = 'codex-bridge-lock/v1' as const
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

type LockOwner = {
  schema: typeof LOCK_SCHEMA
  pid: number
  token: string
  started_at: string
}

type LockRecord = {
  owner: LockOwner
  lockDev: number
  lockIno: number
  ownerDev: number
  ownerIno: number
  ownerSha256: string
}

type AtomicHelperResult = {
  status: number | null
  error?: unknown
  stderr?: string | Buffer | null
}

type AtomicHelperOptions = {
  input: string
  encoding: 'utf8'
  timeout: number
  maxBuffer: number
  env: NodeJS.ProcessEnv
}

/** @internal Test seam; production always uses spawnSync with a pinned command. */
export type AtomicLockHelperRunner = (
  command: string,
  args: readonly string[],
  options: AtomicHelperOptions,
) => AtomicHelperResult

export class DaemonAlreadyRunningError extends Error {
  constructor(readonly ownerPid: number | null) {
    super(ownerPid
      ? `codex-bridge daemon already owns this state directory (pid ${ownerPid})`
      : 'codex-bridge daemon lock is currently initializing')
    this.name = 'DaemonAlreadyRunningError'
  }
}

export class DaemonStaleLockError extends Error {
  constructor(readonly ownerPid: number | null) {
    super(
      `codex-bridge found a stale or malformed daemon lock${ownerPid ? ` (dead pid ${ownerPid})` : ''}; verify no daemon is alive, then remove daemon.lock explicitly`,
    )
    this.name = 'DaemonStaleLockError'
  }
}

function currentUid(): number | null {
  return typeof process.getuid === 'function' ? process.getuid() : null
}

function exactOwnerKeys(value: Record<string, unknown>): boolean {
  return Object.keys(value).sort().join(',') === [
    'pid', 'schema', 'started_at', 'token',
  ].sort().join(',')
}

function stableStatEqual(
  left: ReturnType<typeof fstatSync>,
  right: ReturnType<typeof fstatSync>,
): boolean {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.size === right.size
    && left.mode === right.mode
    && left.uid === right.uid
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs
}

function readLockRecord(lockDir: string, ownerFile: string): LockRecord | null {
  try {
    const lockBefore = lstatSync(lockDir)
    const uid = currentUid()
    if (
      !lockBefore.isDirectory()
      || lockBefore.isSymbolicLink()
      || realpathSync(lockDir) !== lockDir
      || (uid !== null && lockBefore.uid !== uid)
      || (lockBefore.mode & 0o777) !== 0o700
      || readdirSync(lockDir).sort().join(',') !== 'owner.json'
    ) return null
    assertNoExtendedAcl(lockDir, 'daemon lock directory')

    const ownerBefore = lstatSync(ownerFile)
    if (
      !ownerBefore.isFile()
      || ownerBefore.isSymbolicLink()
      || (uid !== null && ownerBefore.uid !== uid)
      || (ownerBefore.mode & 0o777) !== 0o600
      || ownerBefore.size < 2
      || ownerBefore.size > 16 * 1024
    ) return null
    assertNoExtendedAcl(ownerFile, 'daemon lock owner')

    const fd = openSync(ownerFile, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    let raw: Buffer
    let opened: ReturnType<typeof fstatSync>
    try {
      opened = fstatSync(fd)
      if (!stableStatEqual(opened, ownerBefore)) return null
      raw = Buffer.from(readFileSync(fd))
      const after = fstatSync(fd)
      if (!stableStatEqual(opened, after) || raw.length !== opened.size) return null
    } finally {
      closeSync(fd)
    }

    const ownerAfter = lstatSync(ownerFile)
    const lockAfter = lstatSync(lockDir)
    if (
      !stableStatEqual(opened!, ownerAfter)
      || lockAfter.dev !== lockBefore.dev
      || lockAfter.ino !== lockBefore.ino
      || lockAfter.mode !== lockBefore.mode
      || lockAfter.uid !== lockBefore.uid
      || readdirSync(lockDir).sort().join(',') !== 'owner.json'
    ) return null
    assertNoExtendedAcl(lockDir, 'daemon lock directory')
    assertNoExtendedAcl(ownerFile, 'daemon lock owner')

    const value = JSON.parse(raw!.toString('utf8')) as Record<string, unknown>
    if (
      !exactOwnerKeys(value)
      || value.schema !== LOCK_SCHEMA
      || !Number.isSafeInteger(value.pid)
      || (value.pid as number) <= 0
      || typeof value.token !== 'string'
      || !UUID_V4.test(value.token)
      || typeof value.started_at !== 'string'
      || !Number.isFinite(Date.parse(value.started_at))
    ) return null
    return {
      owner: value as LockOwner,
      lockDev: lockBefore.dev,
      lockIno: lockBefore.ino,
      ownerDev: ownerBefore.dev,
      ownerIno: ownerBefore.ino,
      ownerSha256: createHash('sha256').update(raw!).digest('hex'),
    }
  } catch {
    return null
  }
}

function atomicHelperPath(): string {
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
  ) throw new Error('atomic daemon lock authority is unsafe')
  return helper
}

const defaultAtomicHelperRunner: AtomicLockHelperRunner = (command, args, options) => (
  spawnSync(command, [...args], options)
)

function invokeAtomicHelper(
  helper: string,
  args: readonly string[],
  input: string,
  runner: AtomicLockHelperRunner = defaultAtomicHelperRunner,
): AtomicHelperResult {
  return runner('/usr/bin/python3', ['-I', '-B', helper, ...args], {
    input,
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 64 * 1024,
    env: { PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
  })
}

function validateStateDirectory(stateDir: string): string {
  if (!isAbsolute(stateDir) || resolve(stateDir) !== stateDir) {
    throw new Error('daemon state directory must be absolute and normalized')
  }
  mkdirSync(stateDir, { recursive: true, mode: 0o700 })
  const before = lstatSync(stateDir)
  const uid = currentUid()
  if (
    !before.isDirectory()
    || before.isSymbolicLink()
    || realpathSync(stateDir) !== stateDir
    || (uid !== null && before.uid !== uid)
  ) throw new Error('daemon state directory is unsafe')
  chmodSync(stateDir, 0o700)
  const after = lstatSync(stateDir)
  if (
    after.dev !== before.dev
    || after.ino !== before.ino
    || !after.isDirectory()
    || after.isSymbolicLink()
    || (after.mode & 0o777) !== 0o700
    || (uid !== null && after.uid !== uid)
  ) throw new Error('daemon state directory changed while preparing it')
  return stateDir
}

function classifyExisting(
  lockDir: string,
  ownerFile: string,
  initializingGraceMs: number,
): never {
  const record = readLockRecord(lockDir, ownerFile)
  if (record) {
    if (isPidAlive(record.owner.pid)) throw new DaemonAlreadyRunningError(record.owner.pid)
    throw new DaemonStaleLockError(record.owner.pid)
  }

  // Compatibility for an older starter observed between mkdir and owner
  // publication. Locks emitted by this implementation are never ownerless.
  try {
    const lock = lstatSync(lockDir)
    const uid = currentUid()
    const entries = readdirSync(lockDir)
    if (
      lock.isDirectory()
      && !lock.isSymbolicLink()
      && (uid === null || lock.uid === uid)
      && (lock.mode & 0o777) === 0o700
      && entries.length === 0
      && Date.now() - lock.mtimeMs < initializingGraceMs
    ) throw new DaemonAlreadyRunningError(null)
  } catch (err) {
    if (err instanceof DaemonAlreadyRunningError) throw err
  }
  throw new DaemonStaleLockError(null)
}

export function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM'
  }
}

/**
 * Atomic per-state-dir singleton lock. The helper publishes owner.json and its
 * containing directory as one rename-no-replace operation; all existing stale
 * state remains explicit recovery evidence.
 */
export class DaemonLock {
  readonly lockDir: string
  readonly ownerFile: string
  private released = false

  private constructor(
    readonly stateDir: string,
    private readonly token: string,
    private readonly lockDev: number,
    private readonly lockIno: number,
    private readonly ownerDev: number,
    private readonly ownerIno: number,
    private readonly ownerSha256: string,
  ) {
    this.lockDir = join(stateDir, 'daemon.lock')
    this.ownerFile = join(this.lockDir, 'owner.json')
  }

  static acquire(
    rawStateDir: string,
    options: {
      pid?: number
      now?: Date
      initializingGraceMs?: number
      /** @internal Deterministic helper-status fault injection for tests. */
      atomicHelperRunner?: AtomicLockHelperRunner
    } = {},
  ): DaemonLock {
    const stateDir = validateStateDirectory(rawStateDir)
    const pid = options.pid ?? process.pid
    if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('daemon lock PID is invalid')
    const now = options.now ?? new Date()
    const startedAt = now.toISOString()
    const initializingGraceMs = options.initializingGraceMs ?? 30_000
    if (!Number.isFinite(initializingGraceMs) || initializingGraceMs < 0) {
      throw new Error('daemon lock initialization grace is invalid')
    }

    const token = randomUUID()
    const lockDir = join(stateDir, 'daemon.lock')
    const ownerFile = join(lockDir, 'owner.json')
    const owner: LockOwner = {
      schema: LOCK_SCHEMA,
      pid,
      token,
      started_at: startedAt,
    }
    const ownerRaw = JSON.stringify(owner, null, 2) + '\n'
    const helper = atomicHelperPath()
    let result: AtomicHelperResult
    try {
      result = invokeAtomicHelper(
        helper, [lockDir, 'owner.json'], ownerRaw, options.atomicHelperRunner,
      )
    } catch (error) {
      // A command runner can lose control after rename but before collecting
      // status. Resolve that ambiguity from the exact published owner below.
      result = { status: null, error }
    }

    if (result.status === 17 && !result.error) {
      return classifyExisting(lockDir, ownerFile, initializingGraceMs)
    }

    const published = readLockRecord(lockDir, ownerFile)
    if (
      published
      && published.owner.pid === pid
      && published.owner.token === token
      && published.owner.started_at === startedAt
    ) {
      return new DaemonLock(
        stateDir, token,
        published.lockDev, published.lockIno,
        published.ownerDev, published.ownerIno, published.ownerSha256,
      )
    }

    // Never pathname-delete after a failed or ambiguous publication. Another
    // starter may own whatever is visible now, and malformed state is valuable
    // evidence for the explicit recovery workflow.
    if (result.status === 0 && !result.error) {
      throw new Error('atomically published daemon lock owner could not be revalidated')
    }
    try {
      lstatSync(lockDir)
      return classifyExisting(lockDir, ownerFile, initializingGraceMs)
    } catch (err) {
      if (err instanceof DaemonAlreadyRunningError || err instanceof DaemonStaleLockError) throw err
      const detail = String(result.stderr || result.error || `exit ${result.status}`).slice(0, 500)
      throw new Error(`daemon lock publication failed: ${detail}`)
    }
  }

  /** Release only the exact lock/owner inodes and ownership token acquired here. */
  release(): boolean {
    if (this.released) return true
    try {
      const helper = atomicHelperPath()
      const result = invokeAtomicHelper(helper, [
        'release', this.lockDir, 'owner.json',
        String(this.lockDev), String(this.lockIno),
        String(this.ownerDev), String(this.ownerIno), this.ownerSha256, this.token,
      ], '')
      if (result.error || result.status !== 0) return false
      this.released = true
      return true
    } catch {
      return false
    }
  }
}
