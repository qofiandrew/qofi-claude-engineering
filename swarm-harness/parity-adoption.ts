import { createHash } from 'node:crypto'
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
} from 'node:fs'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'

export const HARNESS_PARITY_ADOPTION_SCHEMA = 'qofi-harness-parity-adoption/v1' as const
export const HARNESS_PARITY_ADOPTION_CONTRACT = 'claude-codex-v1' as const
export const HARNESS_PARITY_RECEIPT_ENV = 'SWARM_HARNESS_PARITY_RECEIPT' as const
export const MAX_HARNESS_AUTHORITY_RECORD_BYTES = 64 * 1024

const SAFE_SWARM = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
const SHA256 = /^[0-9a-f]{64}$/
const DR_REF = /^ADR-[0-9]{4}$/

export type HarnessParityAdoptionReceipt = Readonly<{
  schema: typeof HARNESS_PARITY_ADOPTION_SCHEMA
  contract: typeof HARNESS_PARITY_ADOPTION_CONTRACT
  swarm: string
  runtimes: readonly ['claude', 'codex']
  state_root: string
  roadmap_repo_root: string
  dr_refs: readonly string[]
  completion_policy_sha256: string
}>

export type HarnessParityAdoption = Readonly<{ enabled: false }> | Readonly<{
  enabled: true
  receiptPath: string
  receiptSha256: string
  stateRoot: string
  roadmapRepoRoot: string
  drRefs: readonly string[]
  completionPolicySha256: string
  swarm: string
}>

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length
    && keys.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

/** Stable, recursive JSON used for operator receipts and task envelopes. */
export function canonicalAuthorityJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalAuthorityJson).join(',')}]`
  const record = value as Record<string, unknown>
  return `{${Object.keys(record).sort().map(key => (
    `${JSON.stringify(key)}:${canonicalAuthorityJson(record[key])}`
  )).join(',')}}`
}

export function canonicalAuthorityJsonLine(value: unknown): string {
  return `${canonicalAuthorityJson(value)}\n`
}

function trustedSystemSymlink(path: string): boolean {
  const link = lstatSync(path)
  if (!link.isSymbolicLink() || link.uid !== 0) return false
  const target = realpathSync(path)
  const targetInfo = lstatSync(target)
  return targetInfo.isDirectory() && !targetInfo.isSymbolicLink()
    && targetInfo.uid === 0 && (targetInfo.mode & 0o022) === 0
}

function assertNoUntrustedPathIndirection(path: string): void {
  let cursor = sep
  for (const component of resolve(path).split(sep).filter(Boolean)) {
    cursor = join(cursor, component)
    const info = lstatSync(cursor)
    if (info.isSymbolicLink() && !trustedSystemSymlink(cursor)) {
      throw new Error('harness authority path contains untrusted symlink indirection')
    }
  }
}

export function assertOwnerPrivateAuthorityDirectory(path: string, label = 'harness authority'): string {
  if (!isAbsolute(path) || resolve(path) !== path) {
    throw new Error(`${label} path must be canonical absolute`)
  }
  assertNoUntrustedPathIndirection(path)
  const canonical = realpathSync(path)
  const info = lstatSync(canonical)
  const uid = process.getuid?.()
  if (!info.isDirectory() || info.isSymbolicLink() || uid === undefined || info.uid !== uid
    || (info.mode & 0o777) !== 0o700) {
    throw new Error(`${label} must be an owner-real mode 0700 directory`)
  }
  return canonical
}

export type PrivateCanonicalRecord = Readonly<{
  value: unknown
  bytes: Buffer
  sha256: string
}>

/**
 * Descriptor-bound read of an immutable owner-private authority record.  The
 * immediate parent is the write authority; it must be a real 0700 directory.
 */
export function readPrivateCanonicalAuthorityRecord(
  path: string,
  label: string,
  maxBytes = MAX_HARNESS_AUTHORITY_RECORD_BYTES,
): PrivateCanonicalRecord {
  if (!isAbsolute(path) || resolve(path) !== path) {
    throw new Error(`${label} path must be canonical absolute`)
  }
  const parent = assertOwnerPrivateAuthorityDirectory(dirname(path), `${label} parent`)
  assertNoUntrustedPathIndirection(path)
  const beforeParent = lstatSync(parent)
  const before = lstatSync(path)
  const uid = process.getuid?.()
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
    || uid === undefined || before.uid !== uid || (before.mode & 0o777) !== 0o600
    || before.size < 2 || before.size > maxBytes) {
    throw new Error(`${label} must be an owner-real single-link mode 0600 bounded file`)
  }
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.uid !== before.uid
      || opened.mode !== before.mode || opened.nlink !== 1 || opened.size !== before.size
      || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs) {
      throw new Error(`${label} changed while opening`)
    }
    const bytes = readFileSync(fd)
    const after = fstatSync(fd)
    const afterParent = lstatSync(parent)
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.nlink !== 1
      || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs
      || after.ctimeMs !== opened.ctimeMs || afterParent.dev !== beforeParent.dev
      || afterParent.ino !== beforeParent.ino || afterParent.mtimeMs !== beforeParent.mtimeMs
      || bytes.byteLength !== opened.size || bytes.byteLength > maxBytes) {
      throw new Error(`${label} changed while reading`)
    }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    if (text.includes('\0')) throw new Error(`${label} contains NUL data`)
    let value: unknown
    try { value = JSON.parse(text) } catch { throw new Error(`${label} is not JSON`) }
    if (text !== canonicalAuthorityJsonLine(value)) {
      throw new Error(`${label} bytes are not canonical`)
    }
    return {
      value,
      bytes,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    }
  } finally {
    closeSync(fd)
  }
}

function canonicalExistingDirectory(path: unknown, label: string): string {
  if (typeof path !== 'string' || !isAbsolute(path) || resolve(path) !== path) {
    throw new Error(`${label} must be a canonical absolute path`)
  }
  const canonical = realpathSync(path)
  if (canonical !== path) throw new Error(`${label} must not contain symlink indirection`)
  const info = lstatSync(canonical)
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`${label} must be a real directory`)
  return canonical
}

function parseReceipt(value: unknown): HarnessParityAdoptionReceipt {
  if (!object(value) || !exactKeys(value, [
    'schema', 'contract', 'swarm', 'runtimes', 'state_root', 'roadmap_repo_root',
    'dr_refs', 'completion_policy_sha256',
  ]) || value.schema !== HARNESS_PARITY_ADOPTION_SCHEMA
    || value.contract !== HARNESS_PARITY_ADOPTION_CONTRACT
    || typeof value.swarm !== 'string' || !SAFE_SWARM.test(value.swarm)
    || !Array.isArray(value.runtimes)
    || JSON.stringify(value.runtimes) !== JSON.stringify(['claude', 'codex'])
    || !Array.isArray(value.dr_refs) || value.dr_refs.length > 32
    || value.dr_refs.some(item => typeof item !== 'string' || !DR_REF.test(item))
    || JSON.stringify(value.dr_refs) !== JSON.stringify([...value.dr_refs].sort())
    || new Set(value.dr_refs).size !== value.dr_refs.length
    || typeof value.completion_policy_sha256 !== 'string'
    || !SHA256.test(value.completion_policy_sha256)) {
    throw new Error('harness parity adoption receipt is malformed or not atomically scoped')
  }
  const stateRoot = assertOwnerPrivateAuthorityDirectory(
    String(value.state_root), 'harness parity state root',
  )
  const roadmapRepoRoot = canonicalExistingDirectory(
    value.roadmap_repo_root, 'harness parity roadmap repository',
  )
  return {
    schema: HARNESS_PARITY_ADOPTION_SCHEMA,
    contract: HARNESS_PARITY_ADOPTION_CONTRACT,
    swarm: value.swarm,
    runtimes: ['claude', 'codex'],
    state_root: stateRoot,
    roadmap_repo_root: roadmapRepoRoot,
    dr_refs: [...value.dr_refs] as string[],
    completion_policy_sha256: value.completion_policy_sha256,
  }
}

function inside(parent: string, child: string): boolean {
  const rel = relative(parent, child)
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

export function readHarnessParityAdoption(
  env: NodeJS.ProcessEnv,
  options: Readonly<{
    expectedSwarm: string
    workspaceRoot: string
    expectedCompletionPolicySha256: string
  }>,
): HarnessParityAdoption {
  const receiptPath = String(env[HARNESS_PARITY_RECEIPT_ENV] ?? '').trim()
  const legacyConfigured = [
    env.CODEX_BRIDGE_HARNESS_ADOPTION,
    env.CODEX_BRIDGE_HARNESS_STATE_DIR,
    env.CODEX_BRIDGE_HARNESS_ROADMAP_REPO_ROOT,
    env.CODEX_BRIDGE_HARNESS_DR_REFS,
  ].some(value => value !== undefined && value !== '')
  if (!receiptPath) {
    if (legacyConfigured) {
      throw new Error('legacy self-asserted harness adoption is refused; an operator receipt is required')
    }
    return { enabled: false }
  }
  if (legacyConfigured) {
    throw new Error('operator receipt cannot be combined with legacy partial adoption variables')
  }
  if (!SAFE_SWARM.test(options.expectedSwarm)) throw new Error('expected swarm scope is invalid')
  if (!SHA256.test(options.expectedCompletionPolicySha256)) {
    throw new Error('expected completion policy identity is invalid')
  }
  const read = readPrivateCanonicalAuthorityRecord(
    receiptPath, 'harness parity adoption receipt',
  )
  const receipt = parseReceipt(read.value)
  if (receipt.swarm !== options.expectedSwarm) {
    throw new Error('harness parity adoption receipt has the wrong swarm scope')
  }
  if (receipt.completion_policy_sha256 !== options.expectedCompletionPolicySha256) {
    throw new Error('harness parity adoption receipt has the wrong completion policy identity')
  }
  const workspace = canonicalExistingDirectory(options.workspaceRoot, 'worker workspace')
  const canonicalReceipt = realpathSync(receiptPath)
  if (inside(workspace, canonicalReceipt)) {
    throw new Error('harness parity adoption receipt must be outside the worker workspace')
  }
  if (inside(workspace, receipt.state_root)) {
    throw new Error('harness parity state root must be outside the worker workspace')
  }
  return {
    enabled: true,
    receiptPath,
    receiptSha256: read.sha256,
    stateRoot: receipt.state_root,
    roadmapRepoRoot: receipt.roadmap_repo_root,
    drRefs: receipt.dr_refs,
    completionPolicySha256: receipt.completion_policy_sha256,
    swarm: receipt.swarm,
  }
}
