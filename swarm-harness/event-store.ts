import { randomBytes } from 'crypto'
import {
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  lstatSync,
  linkSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { isAbsolute, join, relative, resolve } from 'path'
import {
  parseNormalizedEvent,
  type NormalizedSwarmEvent,
} from './events.ts'
import { RoadmapStore, type RoadmapDocument } from './roadmap.ts'

export const NORMALIZED_EVENT_FILE_BYTES = 4096
export const DEFAULT_EVENT_STORE_MAX_EVENTS = 100_000
export const DEFAULT_EVENT_STORE_MAX_BYTES = 64 * 1024 * 1024

const EVENT_FILE = /^([a-f0-9]{64})\.json$/

export type NormalizedEventStoreOptions = {
  /** Required authority boundary: the event directory must be outside this repo. */
  repoRoot: string
  maxEvents?: number
  maxBytes?: number
  expectedUid?: number
}

function assertInteger(value: number, minimum: number, maximum: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${label} is invalid`)
  return value
}

function exactEventBytes(event: NormalizedSwarmEvent): string {
  const parsed = parseNormalizedEvent(event)
  const bytes = JSON.stringify(parsed) + '\n'
  if (Buffer.byteLength(bytes) > NORMALIZED_EVENT_FILE_BYTES) throw new Error('normalized event exceeds file bound')
  return bytes
}

/**
 * Owner-private, content-free normalized event journal. One atomically linked
 * file per digest makes append replay-safe and naturally idempotent.
 */
export class NormalizedEventStore {
  readonly directory: string
  readonly repoRoot: string
  readonly maxEvents: number
  readonly maxBytes: number
  readonly expectedUid: number

  constructor(directory: string, options: NormalizedEventStoreOptions) {
    if (!isAbsolute(directory) || !isAbsolute(options.repoRoot)) {
      throw new Error('normalized event store and repo paths must be absolute')
    }
    this.directory = resolve(directory)
    this.repoRoot = resolve(options.repoRoot)
    this.maxEvents = assertInteger(
      options.maxEvents ?? DEFAULT_EVENT_STORE_MAX_EVENTS,
      1,
      DEFAULT_EVENT_STORE_MAX_EVENTS,
      'normalized event count bound',
    )
    this.maxBytes = assertInteger(
      options.maxBytes ?? DEFAULT_EVENT_STORE_MAX_BYTES,
      NORMALIZED_EVENT_FILE_BYTES,
      DEFAULT_EVENT_STORE_MAX_BYTES,
      'normalized event byte bound',
    )
    const uid = options.expectedUid ?? process.getuid?.()
    if (uid === undefined || !Number.isSafeInteger(uid) || uid < 0) throw new Error('normalized event store uid is invalid')
    this.expectedUid = uid
    this.assertBoundary()
  }

  private assertBoundary(): void {
    const stat = lstatSync(this.directory)
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== this.expectedUid || (stat.mode & 0o777) !== 0o700) {
      throw new Error('normalized event store must be an owner-real mode 0700 directory')
    }
    const realDirectory = realpathSync(this.directory)
    const realRepo = realpathSync(this.repoRoot)
    const rel = relative(realRepo, realDirectory)
    if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) {
      throw new Error('normalized event store must live outside the repository')
    }
  }

  private names(): string[] {
    this.assertBoundary()
    const names = readdirSync(this.directory).sort()
    if (names.length > this.maxEvents) throw new Error('normalized event store exceeds event bound')
    for (const name of names) {
      if (!EVENT_FILE.test(name)) throw new Error('normalized event store contains an unknown entry')
    }
    return names
  }

  private readOne(name: string): { event: NormalizedSwarmEvent, bytes: Buffer } {
    const match = name.match(EVENT_FILE)
    if (!match) throw new Error('normalized event filename is invalid')
    const path = join(this.directory, name)
    const before = lstatSync(path)
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
      || before.uid !== this.expectedUid || (before.mode & 0o777) !== 0o600
      || before.size < 2 || before.size > NORMALIZED_EVENT_FILE_BYTES) {
      throw new Error('normalized event file has unsafe identity, mode, or size')
    }
    const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    try {
      const opened = fstatSync(fd)
      if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
        || opened.uid !== before.uid || opened.mode !== before.mode || opened.nlink !== before.nlink) {
        throw new Error('normalized event file changed while opening')
      }
      const bytes = readFileSync(fd)
      const after = fstatSync(fd)
      if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
        || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) {
        throw new Error('normalized event file changed while reading')
      }
      let raw: unknown
      try { raw = JSON.parse(bytes.toString('utf8')) } catch { throw new Error('normalized event file is invalid JSON') }
      const event = parseNormalizedEvent(raw)
      if (event.event_id !== match[1] || exactEventBytes(event) !== bytes.toString('utf8')) {
        throw new Error('normalized event filename or canonical bytes do not match event')
      }
      return { event, bytes }
    } finally {
      closeSync(fd)
    }
  }

  /** Append exactly once. Returns `duplicate` only for byte-identical replay. */
  append(candidate: NormalizedSwarmEvent): 'created' | 'duplicate' {
    this.assertBoundary()
    const event = parseNormalizedEvent(candidate)
    const bytes = exactEventBytes(event)
    const name = `${event.event_id}.json`
    const target = join(this.directory, name)
    try {
      const existing = this.readOne(name)
      if (existing.bytes.toString('utf8') !== bytes) throw new Error('normalized event digest collision')
      return 'duplicate'
    } catch (error) {
      const missing = error instanceof Error
        && 'code' in error
        && (error as NodeJS.ErrnoException).code === 'ENOENT'
      if (!missing) throw error
    }

    const names = this.names()
    if (names.length >= this.maxEvents) throw new Error('normalized event store exceeds event bound')
    let usedBytes = 0
    for (const existing of names) usedBytes += this.readOne(existing).bytes.length
    if (usedBytes + Buffer.byteLength(bytes) > this.maxBytes) {
      throw new Error('normalized event store exceeds byte bound')
    }

    const temp = join(
      this.directory,
      `.${event.event_id}.tmp.${process.pid}.${randomBytes(8).toString('hex')}`,
    )
    let fd: number | undefined
    try {
      fd = openSync(
        temp,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0),
        0o600,
      )
      writeFileSync(fd, bytes)
      fsyncSync(fd)
      closeSync(fd)
      fd = undefined
      try {
        // Same-directory hard-link publication is atomic and refuses overwrite.
        linkSync(temp, target)
      } catch (error) {
        const exists = error instanceof Error
          && 'code' in error
          && (error as NodeJS.ErrnoException).code === 'EEXIST'
        if (!exists) throw error
        const existing = this.readOne(name)
        if (existing.bytes.toString('utf8') !== bytes) throw new Error('normalized event digest collision')
        return 'duplicate'
      }
      unlinkSync(temp)
      const directoryFd = openSync(this.directory, constants.O_RDONLY)
      try { fsyncSync(directoryFd) } finally { closeSync(directoryFd) }
      return 'created'
    } finally {
      if (fd !== undefined) try { closeSync(fd) } catch {}
      try { unlinkSync(temp) } catch {}
    }
  }

  /** Strict bounded replay. Any unknown, loose, linked, or malformed entry refuses the view. */
  replay(): NormalizedSwarmEvent[] {
    const names = this.names()
    let total = 0
    const events: NormalizedSwarmEvent[] = []
    for (const name of names) {
      const entry = this.readOne(name)
      total += entry.bytes.length
      if (total > this.maxBytes) throw new Error('normalized event store exceeds byte bound')
      events.push(entry.event)
    }
    return events.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts) || a.event_id.localeCompare(b.event_id))
  }
}

/** Rebuild from the complete private journal; never from a latest-event delta. */
export function rebuildRoadmapFromEventStore(
  eventStore: NormalizedEventStore,
  roadmapStore: RoadmapStore,
): RoadmapDocument {
  return roadmapStore.writeDerived(eventStore.replay())
}
