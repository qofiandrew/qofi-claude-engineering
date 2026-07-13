import { createHash } from 'crypto'
import {
  constants,
  fchownSync,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  closeSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'fs'
import { dirname, isAbsolute, join, relative, resolve } from 'path'
import {
  NORMALIZED_EVENT_SCHEMA,
  SWARM_STATES,
  parseNormalizedEvent,
  type NormalizedSwarmEvent,
  type ResultStatus,
  type SwarmState,
} from './events.ts'

export const ROADMAP_SCHEMA = 'qofi-swarm-roadmap/v1' as const
export const ROADMAP_AUTHORITY_SCHEMA = 'qofi-swarm-roadmap-authority/v1' as const
export const ROADMAP_FILENAME = '.swarm-roadmap.json' as const
export const RUNTIME_PARITY_MATRIX_PATH = 'docs/RUNTIME-PARITY.md' as const
export type RoadmapStatus = SwarmState | 'UNKNOWN'

export type RoadmapGrounding = {
  latest_ms: number | null
  previous_ms: number | null
  delta_ms: number | null
  samples: number
  gap_reports: number
}

export type RoadmapResultCounts = Record<ResultStatus, number>

export type RoadmapItem = {
  status: RoadmapStatus
  owning_swarm: string
  last_activity: string
  last_result_status: ResultStatus | null
  result_sets: RoadmapResultCounts
  grounding: RoadmapGrounding
}

export type RoadmapDocument = {
  schema: typeof ROADMAP_SCHEMA
  parity_matrix: typeof RUNTIME_PARITY_MATRIX_PATH
  generated_at: string | null
  items: Record<string, RoadmapItem>
}

type MutableItem = RoadmapItem & { groundingSamples: number[] }
type AuthorityRecord = {
  schema: typeof ROADMAP_AUTHORITY_SCHEMA
  roadmap_path_sha256: string
  accepted_sha256: string | null
  pending_sha256: string | null
}

const ADR = /^ADR-[0-9]{4}$/
const SWARM = /^[a-z][a-z0-9-]{0,63}$/
const UNSAFE_SWARM_LABEL = /^(?:(?:acct|account|profile|provider|user|org|organization)-|xox[baprs]-|sk-(?:proj-|ant-|live-|test-)?)/i
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/
const SHA256 = /^[a-f0-9]{64}$/
const MAX_ITEMS = 4096
const MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
const MAX_GROUNDING_MS = 7 * 24 * 60 * 60 * 1000

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, allowed: readonly string[], label: string): void {
  const set = new Set(allowed)
  for (const key of Object.keys(value)) if (!set.has(key)) throw new Error(`${label} contains unsupported field ${key}`)
}

function defaultCounts(): RoadmapResultCounts {
  return { passed: 0, failed: 0, pending: 0, blocked: 0 }
}

function defaultGrounding(): RoadmapGrounding {
  return { latest_ms: null, previous_ms: null, delta_ms: null, samples: 0, gap_reports: 0 }
}

function emptyItem(event: NormalizedSwarmEvent): MutableItem {
  return {
    status: 'UNKNOWN',
    owning_swarm: event.swarm,
    last_activity: event.ts,
    last_result_status: null,
    result_sets: defaultCounts(),
    grounding: defaultGrounding(),
    groundingSamples: [],
  }
}

function applyGroundingSample(item: MutableItem, elapsed: number): void {
  if (!Number.isSafeInteger(elapsed) || elapsed < 0 || elapsed > MAX_GROUNDING_MS) return
  item.groundingSamples.push(elapsed)
  // Bound retained derivation state even if a journal contains years of tasks.
  if (item.groundingSamples.length > 256) item.groundingSamples.shift()
  const latest = item.groundingSamples.at(-1) ?? null
  const previous = item.groundingSamples.at(-2) ?? null
  item.grounding = {
    ...item.grounding,
    latest_ms: latest,
    previous_ms: previous,
    delta_ms: latest !== null && previous !== null ? latest - previous : null,
    samples: item.grounding.samples + 1,
  }
}

function eventOrder(a: NormalizedSwarmEvent, b: NormalizedSwarmEvent): number {
  return Date.parse(a.ts) - Date.parse(b.ts) || a.event_id.localeCompare(b.event_id)
}

/**
 * Rebuild a roadmap solely from normalized ground-truth events. No agent summary,
 * model prose, profile, account, Discord id, or credential enters the artifact.
 */
export function deriveRoadmap(input: readonly NormalizedSwarmEvent[]): RoadmapDocument {
  if (input.length > 100_000) throw new Error('roadmap event journal exceeds bound')
  const byId = new Map<string, NormalizedSwarmEvent>()
  for (const candidate of input) {
    const event = parseNormalizedEvent(candidate)
    if (event.schema !== NORMALIZED_EVENT_SCHEMA) throw new Error('roadmap event schema mismatch')
    const prior = byId.get(event.event_id)
    if (prior && JSON.stringify(prior) !== JSON.stringify(event)) throw new Error('event id collision')
    byId.set(event.event_id, event)
  }
  const events = [...byId.values()].sort(eventOrder)
  const items = new Map<string, MutableItem>()
  const groundingStarts = new Map<string, number>()
  const firstEdits = new Set<string>()
  const taskReviewStatus = new Map<string, ResultStatus>()

  for (const event of events) {
    const taskKey = `${event.swarm}\0${event.task_id}`
    if (event.type === 'task.started' || event.type === 'grounding.started') {
      groundingStarts.set(taskKey, Date.parse(event.ts))
      firstEdits.delete(taskKey)
    }

    for (const dr of event.dr_refs) {
      const item = items.get(dr) ?? emptyItem(event)
      if (item.owning_swarm !== event.swarm && event.type !== 'task.started') {
        throw new Error(`roadmap ownership conflict for ${dr}`)
      }
      if (Date.parse(event.ts) >= Date.parse(item.last_activity)) item.last_activity = event.ts
      switch (event.type) {
        case 'task.started':
          if (item.status === 'DRIVING' && item.owning_swarm !== event.swarm) {
            throw new Error(`roadmap active ownership conflict for ${dr}`)
          }
          item.owning_swarm = event.swarm
          item.status = 'DRIVING'
          item.last_result_status = null
          break
        case 'task.finished':
          item.status = event.outcome === 'completed' && (
            taskReviewStatus.get(taskKey) !== 'passed'
            || (item.last_result_status !== null
              && ['blocked', 'failed', 'pending'].includes(item.last_result_status))
          )
            ? 'WAITING_FOR_OPERATOR'
            : event.state ?? (event.outcome === 'completed' ? 'STOOD_DOWN' : 'WAITING_FOR_OPERATOR')
          break
        case 'state.transitioned':
          item.status = event.state ?? item.status
          break
        case 'result.landed':
          if (event.result_status) {
            item.result_sets[event.result_status]++
            item.last_result_status = event.result_status
            if (['blocked', 'failed', 'pending'].includes(event.result_status)) {
              item.status = 'WAITING_FOR_OPERATOR'
            }
            if (event.result_kind === 'review') taskReviewStatus.set(taskKey, event.result_status)
          }
          break
        case 'grounding.gap_reported':
          item.grounding.gap_reports++
          break
        case 'edit.substantive': {
          const started = groundingStarts.get(taskKey)
          if (started !== undefined && !firstEdits.has(taskKey)) {
            applyGroundingSample(item, Date.parse(event.ts) - started)
          }
          break
        }
      }
      items.set(dr, item)
      if (items.size > MAX_ITEMS) throw new Error('roadmap item count exceeds bound')
    }
    if (event.type === 'edit.substantive') firstEdits.add(taskKey)
    if (event.type === 'task.finished') groundingStarts.delete(taskKey)
  }

  const output: Record<string, RoadmapItem> = {}
  for (const [dr, mutable] of [...items.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const { groundingSamples: _, ...item } = mutable
    output[dr] = item
  }
  return {
    schema: ROADMAP_SCHEMA,
    parity_matrix: RUNTIME_PARITY_MATRIX_PATH,
    generated_at: events.at(-1)?.ts ?? null,
    items: output,
  }
}

function parseCount(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} is invalid`)
  }
  return value as number
}

function parseNullableDuration(value: unknown, label: string): number | null {
  if (value === null) return null
  const number = parseCount(value, label)
  if (number > MAX_GROUNDING_MS) throw new Error(`${label} exceeds bound`)
  return number
}

/** Validate a roadmap before display or CAS adoption. */
export function parseRoadmap(value: unknown): RoadmapDocument {
  if (!isRecord(value)) throw new Error('roadmap must be an object')
  exactKeys(value, ['schema', 'parity_matrix', 'generated_at', 'items'], 'roadmap')
  if (value.schema !== ROADMAP_SCHEMA) throw new Error('roadmap schema is invalid')
  if (value.parity_matrix !== RUNTIME_PARITY_MATRIX_PATH) throw new Error('roadmap parity matrix link is invalid')
  if (value.generated_at !== null && (
    typeof value.generated_at !== 'string'
    || !ISO_TIMESTAMP.test(value.generated_at)
    || Number.isNaN(Date.parse(value.generated_at))
  )) throw new Error('roadmap generated_at is invalid')
  if (!isRecord(value.items) || Object.keys(value.items).length > MAX_ITEMS) throw new Error('roadmap items are invalid')
  const items: Record<string, RoadmapItem> = {}
  for (const dr of Object.keys(value.items).sort()) {
    if (!ADR.test(dr)) throw new Error('roadmap item key is invalid')
    const raw = value.items[dr]
    if (!isRecord(raw)) throw new Error(`roadmap item ${dr} is invalid`)
    exactKeys(raw, [
      'status', 'owning_swarm', 'last_activity', 'last_result_status', 'result_sets', 'grounding',
    ], `roadmap item ${dr}`)
    if (![...SWARM_STATES, 'UNKNOWN'].includes(raw.status as RoadmapStatus)) {
      throw new Error(`roadmap item ${dr} status is invalid`)
    }
    if (typeof raw.owning_swarm !== 'string'
      || !SWARM.test(raw.owning_swarm)
      || UNSAFE_SWARM_LABEL.test(raw.owning_swarm)) {
      throw new Error(`roadmap item ${dr} owner is invalid`)
    }
    if (typeof raw.last_activity !== 'string' || !ISO_TIMESTAMP.test(raw.last_activity)) {
      throw new Error(`roadmap item ${dr} activity is invalid`)
    }
    if (raw.last_result_status !== null
      && !['passed', 'failed', 'pending', 'blocked'].includes(String(raw.last_result_status))) {
      throw new Error(`roadmap item ${dr} result status is invalid`)
    }
    if (!isRecord(raw.result_sets)) throw new Error(`roadmap item ${dr} result counts are invalid`)
    exactKeys(raw.result_sets, ['passed', 'failed', 'pending', 'blocked'], `roadmap item ${dr} result counts`)
    const result_sets = {
      passed: parseCount(raw.result_sets.passed, `${dr} passed count`),
      failed: parseCount(raw.result_sets.failed, `${dr} failed count`),
      pending: parseCount(raw.result_sets.pending, `${dr} pending count`),
      blocked: parseCount(raw.result_sets.blocked, `${dr} blocked count`),
    }
    if (!isRecord(raw.grounding)) throw new Error(`roadmap item ${dr} grounding is invalid`)
    exactKeys(
      raw.grounding,
      ['latest_ms', 'previous_ms', 'delta_ms', 'samples', 'gap_reports'],
      `roadmap item ${dr} grounding`,
    )
    const latest_ms = parseNullableDuration(raw.grounding.latest_ms, `${dr} latest grounding`)
    const previous_ms = parseNullableDuration(raw.grounding.previous_ms, `${dr} previous grounding`)
    const delta = raw.grounding.delta_ms
    if (delta !== null && (!Number.isSafeInteger(delta) || Math.abs(delta as number) > MAX_GROUNDING_MS)) {
      throw new Error(`${dr} grounding delta is invalid`)
    }
    const delta_ms = delta as number | null
    if (delta_ms !== (latest_ms !== null && previous_ms !== null ? latest_ms - previous_ms : null)) {
      throw new Error(`${dr} grounding delta is inconsistent`)
    }
    items[dr] = {
      status: raw.status as RoadmapStatus,
      owning_swarm: raw.owning_swarm,
      last_activity: raw.last_activity,
      last_result_status: raw.last_result_status as ResultStatus | null,
      result_sets,
      grounding: {
        latest_ms,
        previous_ms,
        delta_ms,
        samples: parseCount(raw.grounding.samples, `${dr} grounding sample count`),
        gap_reports: parseCount(raw.grounding.gap_reports, `${dr} gap report count`),
      },
    }
  }
  return {
    schema: ROADMAP_SCHEMA,
    parity_matrix: RUNTIME_PARITY_MATRIX_PATH,
    generated_at: value.generated_at,
    items,
  }
}

export function serializeRoadmap(document: RoadmapDocument): string {
  const parsed = parseRoadmap(document)
  const bytes = JSON.stringify(parsed, null, 2) + '\n'
  if (Buffer.byteLength(bytes) > MAX_DOCUMENT_BYTES) throw new Error('roadmap exceeds size bound')
  return bytes
}

function sha256(bytes: string | Buffer): string {
  return createHash('sha256').update(bytes).digest('hex')
}

function atomicWrite(
  path: string,
  bytes: string,
  mode: number,
  ownerUid: number,
  parentUid: number,
  expectedExistingSha256?: string | null,
): void {
  if (ownerUid !== parentUid) {
    throw new Error('privileged roadmap publication requires a descriptor-bound root helper')
  }
  const parent = dirname(path)
  const name = path.split('/').at(-1)!
  const parentFd = openSync(
    parent,
    constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0),
  )
  const parentInfo = fstatSync(parentFd)
  if (!parentInfo.isDirectory() || parentInfo.uid !== parentUid || (parentInfo.mode & 0o022) !== 0) {
    closeSync(parentFd)
    throw new Error('roadmap atomic parent is not authority-controlled')
  }
  const assertParentStillBound = (): void => {
    const current = lstatSync(parent)
    const opened = fstatSync(parentFd)
    if (!current.isDirectory() || current.isSymbolicLink()
      || current.dev !== parentInfo.dev || current.ino !== parentInfo.ino
      || opened.dev !== parentInfo.dev || opened.ino !== parentInfo.ino
      || current.uid !== parentUid || (current.mode & 0o022) !== 0) {
      throw new Error('roadmap atomic parent identity changed')
    }
  }
  const target = path
  assertParentStillBound()
  if (expectedExistingSha256 !== undefined) {
    try {
      const current = assertRegular(target, mode, ownerUid)
      if (expectedExistingSha256 === null || sha256(current) !== expectedExistingSha256) {
        throw new Error('roadmap changed after CAS validation')
      }
    } catch (error) {
      const missing = error instanceof Error && 'code' in error
        && (error as NodeJS.ErrnoException).code === 'ENOENT'
      if (!missing || expectedExistingSha256 !== null) {
        closeSync(parentFd)
        throw error
      }
    }
  }
  const tempName = `.${name}.tmp.${process.pid}.${Date.now()}`
  const temp = join(parent, tempName)
  let fd: number | undefined
  try {
    assertParentStillBound()
    fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, mode)
    if (fstatSync(fd).uid !== ownerUid) fchownSync(fd, ownerUid, -1)
    fchmodSync(fd, mode)
    writeFileSync(fd, bytes)
    fsyncSync(fd)
    const prepared = fstatSync(fd)
    if (!prepared.isFile() || prepared.nlink !== 1 || prepared.uid !== ownerUid
      || (prepared.mode & 0o777) !== mode || prepared.size !== Buffer.byteLength(bytes)) {
      throw new Error('roadmap atomic temp identity is invalid')
    }
    closeSync(fd)
    fd = undefined
    assertParentStillBound()
    renameSync(temp, target)
    assertParentStillBound()
    fsyncSync(parentFd)
    const published = lstatSync(target)
    if (!published.isFile() || published.isSymbolicLink() || published.nlink !== 1
      || published.uid !== ownerUid || (published.mode & 0o777) !== mode) {
      throw new Error('roadmap atomic publication identity is invalid')
    }
  } finally {
    if (fd !== undefined) try { closeSync(fd) } catch {}
    try { rmSync(temp, { force: true }) } catch {}
    closeSync(parentFd)
  }
}

function assertOwnedDirectory(path: string, mode: number | null, ownerUid: number): void {
  const stat = lstatSync(path)
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== ownerUid) {
    throw new Error(`roadmap boundary ${path} must be an owner-real directory`)
  }
  if (mode !== null && (stat.mode & 0o777) !== mode) throw new Error(`roadmap boundary ${path} must be mode 0${mode.toString(8)}`)
}

function assertRegular(path: string, mode: number, ownerUid: number): Buffer {
  const stat = lstatSync(path)
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.uid !== ownerUid) {
    throw new Error(`roadmap file ${path} must be owner-regular single-link`)
  }
  if ((stat.mode & 0o777) !== mode || stat.size > MAX_DOCUMENT_BYTES) {
    throw new Error(`roadmap file ${path} has unsafe mode or size`)
  }
  return readFileSync(path)
}

function parseAuthority(bytes: Buffer, pathDigest: string): AuthorityRecord {
  if (bytes.length > 4096) throw new Error('roadmap authority exceeds bound')
  let value: unknown
  try { value = JSON.parse(bytes.toString('utf8')) } catch { throw new Error('roadmap authority is invalid JSON') }
  if (!isRecord(value)) throw new Error('roadmap authority is invalid')
  exactKeys(value, ['schema', 'roadmap_path_sha256', 'accepted_sha256', 'pending_sha256'], 'roadmap authority')
  if (value.schema !== ROADMAP_AUTHORITY_SCHEMA || value.roadmap_path_sha256 !== pathDigest) {
    throw new Error('roadmap authority binding is invalid')
  }
  for (const field of ['accepted_sha256', 'pending_sha256'] as const) {
    if (value[field] !== null && (typeof value[field] !== 'string' || !SHA256.test(value[field]))) {
      throw new Error(`roadmap authority ${field} is invalid`)
    }
  }
  return value as AuthorityRecord
}

function serializeAuthority(value: AuthorityRecord): string {
  return JSON.stringify(value) + '\n'
}

/**
 * CAS-protected writer for the in-repo living artifact. The private authority
 * file must live outside the repository; untracked manual/agent edits cause a
 * refusal instead of being overwritten. Operator reconciliation is explicit.
 */
export class RoadmapStore {
  readonly repoRoot: string
  readonly roadmapFile: string
  readonly authorityFile: string
  readonly authorityUid: number
  readonly roadmapOwnerUid: number
  private readonly pathDigest: string

  constructor(
    repoRoot: string,
    authorityFile: string,
    options: Readonly<{ authorityUid?: number, roadmapOwnerUid?: number }> = {},
  ) {
    this.repoRoot = resolve(repoRoot)
    this.roadmapFile = join(this.repoRoot, ROADMAP_FILENAME)
    this.authorityFile = resolve(authorityFile)
    const currentUid = process.getuid?.()
    this.authorityUid = options.authorityUid ?? currentUid ?? -1
    this.roadmapOwnerUid = options.roadmapOwnerUid ?? currentUid ?? -1
    if (!Number.isSafeInteger(this.authorityUid) || this.authorityUid < 0
      || !Number.isSafeInteger(this.roadmapOwnerUid) || this.roadmapOwnerUid < 0) {
      throw new Error('roadmap ownership contract is invalid')
    }
    // Node/Bun does not expose renameat(2) with directory descriptors.  A root
    // writer targeting an operator-writable repository would otherwise reopen
    // mutable absolute child paths after validation.  Keep that cross-owner
    // publication unavailable until a fixed privileged helper owns openat +
    // renameat and temporarily revokes worker mutation for the whole commit.
    if (this.authorityUid !== this.roadmapOwnerUid) {
      throw new Error('privileged roadmap publication requires a descriptor-bound root helper')
    }
    if (!isAbsolute(authorityFile)) throw new Error('roadmap authority path must be absolute')
    const rel = relative(this.repoRoot, this.authorityFile)
    if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) {
      throw new Error('roadmap authority must live outside the repository')
    }
    this.pathDigest = sha256(this.roadmapFile)
  }

  writeDerived(events: readonly NormalizedSwarmEvent[]): RoadmapDocument {
    const document = deriveRoadmap(events)
    this.write(document)
    return document
  }

  write(document: RoadmapDocument): void {
    assertOwnedDirectory(this.repoRoot, null, this.roadmapOwnerUid)
    const authorityDir = dirname(this.authorityFile)
    // Provisioning owns this private boundary. Never mkdir/chmod through an
    // attacker-substitutable path while processing a task event.
    assertOwnedDirectory(authorityDir, 0o700, this.authorityUid)
    const lock = `${this.authorityFile}.lock`
    try {
      mkdirSync(lock, { mode: 0o700 })
    } catch {
      throw new Error('roadmap update is already in progress')
    }
    try {
      const bytes = serializeRoadmap(document)
      const nextDigest = sha256(bytes)
      const roadmapExists = (() => { try { return statSync(this.roadmapFile).isFile() } catch { return false } })()
      const authorityExists = (() => { try { return statSync(this.authorityFile).isFile() } catch { return false } })()
      let currentDigest: string | null = null
      let authority: AuthorityRecord = {
        schema: ROADMAP_AUTHORITY_SCHEMA,
        roadmap_path_sha256: this.pathDigest,
        accepted_sha256: null,
        pending_sha256: null,
      }
      if (roadmapExists) currentDigest = sha256(assertRegular(
        this.roadmapFile, 0o644, this.roadmapOwnerUid,
      ))
      if (authorityExists) authority = parseAuthority(
        assertRegular(this.authorityFile, 0o600, this.authorityUid), this.pathDigest,
      )
      if (roadmapExists && !authorityExists) {
        throw new Error('roadmap exists without private authority; operator reconciliation required')
      }
      if (!roadmapExists && authority.accepted_sha256 !== null) {
        throw new Error('roadmap disappeared after authority was established')
      }
      if (authority.pending_sha256 !== null) {
        if (currentDigest === authority.pending_sha256) {
          authority = { ...authority, accepted_sha256: authority.pending_sha256, pending_sha256: null }
          atomicWrite(
            this.authorityFile, serializeAuthority(authority), 0o600,
            this.authorityUid, this.authorityUid,
          )
        } else if (currentDigest === authority.accepted_sha256) {
          authority = { ...authority, pending_sha256: null }
          atomicWrite(
            this.authorityFile, serializeAuthority(authority), 0o600,
            this.authorityUid, this.authorityUid,
          )
        } else {
          throw new Error('roadmap interrupted update cannot be reconciled automatically')
        }
      }
      if (currentDigest !== authority.accepted_sha256) {
        throw new Error('roadmap changed outside the harness; operator reconciliation required')
      }
      if (nextDigest === currentDigest) return
      const pending = { ...authority, pending_sha256: nextDigest }
      atomicWrite(
        this.authorityFile, serializeAuthority(pending), 0o600,
        this.authorityUid, this.authorityUid,
      )
      atomicWrite(
        this.roadmapFile, bytes, 0o644,
        this.roadmapOwnerUid, this.roadmapOwnerUid, currentDigest,
      )
      atomicWrite(
        this.authorityFile,
        serializeAuthority({ ...pending, accepted_sha256: nextDigest, pending_sha256: null }),
        0o600,
        this.authorityUid,
        this.authorityUid,
      )
    } finally {
      rmSync(lock, { recursive: true, force: true })
    }
  }

  read(): RoadmapDocument {
    const bytes = assertRegular(this.roadmapFile, 0o644, this.roadmapOwnerUid)
    if (bytes.length > MAX_DOCUMENT_BYTES) throw new Error('roadmap exceeds size bound')
    const authority = parseAuthority(
      assertRegular(this.authorityFile, 0o600, this.authorityUid), this.pathDigest,
    )
    if (authority.pending_sha256 !== null || authority.accepted_sha256 !== sha256(bytes)) {
      throw new Error('roadmap authority does not match artifact')
    }
    let value: unknown
    try { value = JSON.parse(bytes.toString('utf8')) } catch { throw new Error('roadmap is invalid JSON') }
    return parseRoadmap(value)
  }
}
