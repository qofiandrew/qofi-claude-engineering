import { createHash, randomBytes } from 'node:crypto'
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import type { WorkspaceSnapshot } from '../codex-bridge/turn-changes.ts'
import {
  canonicalAuthorityJsonLine,
  readPrivateCanonicalAuthorityRecord,
} from './parity-adoption.ts'

export const HARNESS_TASK_BASELINE_SCHEMA = 'qofi-harness-task-baseline/v1' as const
export const MAX_HARNESS_TASK_BASELINE_BYTES = 8 * 1024 * 1024

const SAFE_RUNTIME = new Set(['claude', 'codex'])
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$/
const SNAPSHOT_VALUE = /^(?:100(?:644|755):[a-f0-9]{64}|ineligible:oversize|deferred:aggregate:100(?:644|755):\d+:\d+:\d+:\d+:\d+)$/

export type HarnessTaskBaseline = Readonly<{
  schema: typeof HARNESS_TASK_BASELINE_SCHEMA
  runtime: 'claude' | 'codex'
  swarm: string
  scope_id: string
  parent_task_id: string
  started_at: string
  snapshot: WorkspaceSnapshot
}>

function inside(root: string, child: string): boolean {
  const rel = relative(root, child)
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

function assertPrivateDirectory(path: string): void {
  const info = lstatSync(path)
  const uid = process.getuid?.()
  if (!info.isDirectory() || info.isSymbolicLink() || uid === undefined || info.uid !== uid
    || (info.mode & 0o777) !== 0o700) {
    throw new Error(`${basename(path)} must be an authority-owned real mode 0700 directory`)
  }
}

export function ensurePrivateAuthorityChild(root: string, ...parts: string[]): string {
  const canonicalRoot = resolve(root)
  assertPrivateDirectory(canonicalRoot)
  let cursor = canonicalRoot
  for (const part of parts) {
    if (!/^[A-Za-z0-9._-]+$/.test(part) || part === '.' || part === '..') {
      throw new Error('authority child name is invalid')
    }
    cursor = join(cursor, part)
    if (!inside(canonicalRoot, cursor)) throw new Error('authority child escaped its root')
    try { mkdirSync(cursor, { mode: 0o700 }) } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
    assertPrivateDirectory(cursor)
  }
  return cursor
}

export function atomicCanonicalAuthorityRecord(
  path: string,
  value: unknown,
  maximum = MAX_HARNESS_TASK_BASELINE_BYTES,
): void {
  const parent = dirname(path)
  assertPrivateDirectory(parent)
  const bytes = canonicalAuthorityJsonLine(value)
  if (Buffer.byteLength(bytes) < 2 || Buffer.byteLength(bytes) > maximum) {
    throw new Error('authority record exceeds its byte bound')
  }
  if (existsSync(path)) {
    const prior = lstatSync(path)
    const uid = process.getuid?.()
    if (!prior.isFile() || prior.isSymbolicLink() || prior.nlink !== 1
      || uid === undefined || prior.uid !== uid || (prior.mode & 0o777) !== 0o600) {
      throw new Error('authority record target is unsafe')
    }
  }
  const temp = join(parent, `.${basename(path)}.tmp.${process.pid}.${randomBytes(8).toString('hex')}`)
  let fd: number | undefined
  try {
    fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0), 0o600)
    chmodSync(temp, 0o600)
    writeFileSync(fd, bytes)
    fsyncSync(fd)
    const prepared = fstatSync(fd)
    const uid = process.getuid?.()
    if (!prepared.isFile() || prepared.nlink !== 1 || uid === undefined || prepared.uid !== uid
      || (prepared.mode & 0o777) !== 0o600 || prepared.size !== Buffer.byteLength(bytes)) {
      throw new Error('authority record temp identity is unsafe')
    }
    closeSync(fd)
    fd = undefined
    renameSync(temp, path)
    const directoryFd = openSync(parent, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    try { fsyncSync(directoryFd) } finally { closeSync(directoryFd) }
    const published = readPrivateCanonicalAuthorityRecord(path, 'harness authority record', maximum)
    if (!published.bytes.equals(Buffer.from(bytes))) throw new Error('authority record publication changed')
  } finally {
    if (fd !== undefined) try { closeSync(fd) } catch {}
    rmSync(temp, { force: true })
  }
}

function parseBaseline(value: unknown): HarnessTaskBaseline {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('task baseline is malformed')
  const raw = value as Record<string, unknown>
  if (JSON.stringify(Object.keys(raw).sort()) !== JSON.stringify([
    'parent_task_id', 'runtime', 'schema', 'scope_id', 'snapshot', 'started_at', 'swarm',
  ])) throw new Error('task baseline shape is invalid')
  if (raw.schema !== HARNESS_TASK_BASELINE_SCHEMA || !SAFE_RUNTIME.has(String(raw.runtime))
    || typeof raw.swarm !== 'string' || !SAFE_LABEL.test(raw.swarm)
    || typeof raw.scope_id !== 'string' || !SAFE_LABEL.test(raw.scope_id)
    || typeof raw.parent_task_id !== 'string' || !SAFE_LABEL.test(raw.parent_task_id)
    || typeof raw.started_at !== 'string' || Number.isNaN(Date.parse(raw.started_at))) {
    throw new Error('task baseline scope is invalid')
  }
  const snapshot = raw.snapshot
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) throw new Error('task baseline snapshot is invalid')
  const snap = snapshot as Record<string, unknown>
  if (JSON.stringify(Object.keys(snap).sort()) !== JSON.stringify(['files', 'maxFileBytes', 'root'])
    || typeof snap.root !== 'string' || !isAbsolute(snap.root)
    || !Number.isSafeInteger(snap.maxFileBytes) || Number(snap.maxFileBytes) < 1
    || !snap.files || typeof snap.files !== 'object' || Array.isArray(snap.files)
    || Object.keys(snap.files as object).length > 50_000) {
    throw new Error('task baseline snapshot contract is invalid')
  }
  for (const [path, fingerprint] of Object.entries(snap.files as Record<string, unknown>)) {
    if (!path || path.startsWith('/') || path.includes('\\') || path.split('/').includes('..')
      || typeof fingerprint !== 'string' || !SNAPSHOT_VALUE.test(fingerprint)) {
      throw new Error('task baseline file identity is invalid')
    }
  }
  return raw as unknown as HarnessTaskBaseline
}

export function baselineKey(runtime: 'claude' | 'codex', swarm: string, scopeId: string): string {
  return createHash('sha256').update(runtime).update('\0').update(swarm).update('\0').update(scopeId).digest('hex')
}

export function baselinePath(
  stateRoot: string,
  runtime: 'claude' | 'codex',
  swarm: string,
  scopeId: string,
): string {
  const directory = ensurePrivateAuthorityChild(stateRoot, 'task-baselines', runtime, swarm)
  return join(directory, `${baselineKey(runtime, swarm, scopeId)}.json`)
}

export function writeTaskBaseline(stateRoot: string, baseline: HarnessTaskBaseline): string {
  const parsed = parseBaseline(baseline)
  const path = baselinePath(stateRoot, parsed.runtime, parsed.swarm, parsed.scope_id)
  atomicCanonicalAuthorityRecord(path, parsed)
  return path
}

export function readTaskBaseline(
  stateRoot: string,
  runtime: 'claude' | 'codex',
  swarm: string,
  scopeId: string,
): HarnessTaskBaseline {
  const path = baselinePath(stateRoot, runtime, swarm, scopeId)
  return parseBaseline(readPrivateCanonicalAuthorityRecord(
    path, 'harness task baseline', MAX_HARNESS_TASK_BASELINE_BYTES,
  ).value)
}

export function removeTaskBaseline(
  stateRoot: string,
  runtime: 'claude' | 'codex',
  swarm: string,
  scopeId: string,
): void {
  const path = baselinePath(stateRoot, runtime, swarm, scopeId)
  const info = lstatSync(path)
  const uid = process.getuid?.()
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1
    || uid === undefined || info.uid !== uid || (info.mode & 0o777) !== 0o600) {
    throw new Error('task baseline removal target is unsafe')
  }
  unlinkSync(path)
  const directoryFd = openSync(dirname(path), constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try { fsyncSync(directoryFd) } finally { closeSync(directoryFd) }
}
