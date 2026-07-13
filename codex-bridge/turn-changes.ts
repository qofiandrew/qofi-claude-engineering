import { createHash } from 'crypto'
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync, readdirSync, realpathSync } from 'fs'
import type { BigIntStats } from 'fs'
import { join, relative, resolve, sep } from 'path'
import { isOperatorOwnedRelativePath } from './workspace.ts'

const SKIP_DIRS = new Set([
  '.git', '.codex', '.agents', '.claude',
  'node_modules', '.venv', 'venv', 'dist', 'build', 'coverage', '.next', 'target', 'vendor',
])

export type WorkspaceSnapshot = {
  root: string
  files: Readonly<Record<string, string>>
  maxFileBytes: number
}

export type CaptureSnapshotOptions = {
  maxEntries?: number
  maxDepth?: number
  maxFileBytes?: number
  maxTotalBytes?: number
}

/**
 * Oversized regular files are visible to the snapshot without becoming a
 * commit capability. The Git broker independently rejects this sentinel and
 * every file whose descriptor-bound size exceeds its per-file limit.
 */
export const INELIGIBLE_OVERSIZE_FINGERPRINT = 'ineligible:oversize'
export const AGGREGATE_METADATA_FINGERPRINT_PREFIX = 'deferred:aggregate:'

const AGGREGATE_METADATA_FINGERPRINT =
  /^deferred:aggregate:100(?:644|755):\d+:\d+:\d+:\d+:\d+$/

type OpenFileFingerprint = {
  fingerprint: string
  metadataFingerprint: string
  hashedBytes: number
}

function fileMode(stat: BigIntStats): '100644' | '100755' {
  return (stat.mode & 0o111n) !== 0n ? '100755' : '100644'
}

function aggregateMetadataFingerprint(stat: BigIntStats): string {
  return [
    AGGREGATE_METADATA_FINGERPRINT_PREFIX.slice(0, -1),
    fileMode(stat),
    stat.dev,
    stat.ino,
    stat.size,
    stat.mtimeNs,
    stat.ctimeNs,
  ].join(':')
}

function isAggregateMetadataFingerprint(value: string | undefined): value is string {
  return typeof value === 'string' && AGGREGATE_METADATA_FINGERPRINT.test(value)
}

function boundedInteger(value: number | undefined, fallback: number, label: string): number {
  const resolved = value ?? fallback
  if (!Number.isSafeInteger(resolved) || resolved < 0) {
    throw new Error(`${label} must be a non-negative safe integer`)
  }
  return resolved
}

function fingerprintOpenFile(
  path: string,
  maxFileBytes: number,
  hashBudgetBytes: number,
  options: { forceHash?: boolean; expectedMetadata?: string } = {},
): OpenFileFingerprint {
  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  const fd = openSync(path, constants.O_RDONLY | noFollow)
  try {
    const before = fstatSync(fd, { bigint: true })
    if (!before.isFile()) throw new Error('turn snapshot path is not a regular file')
    const metadataFingerprint = aggregateMetadataFingerprint(before)
    if (options.expectedMetadata && options.expectedMetadata !== metadataFingerprint) {
      throw new Error('turn snapshot metadata changed before re-fingerprint')
    }
    if (before.size > BigInt(maxFileBytes)) {
      return {
        fingerprint: INELIGIBLE_OVERSIZE_FINGERPRINT,
        metadataFingerprint,
        hashedBytes: 0,
      }
    }
    if (!options.forceHash && before.size > BigInt(hashBudgetBytes)) {
      return {
        fingerprint: metadataFingerprint,
        metadataFingerprint,
        hashedBytes: 0,
      }
    }
    const hash = createHash('sha256')
    const buffer = Buffer.allocUnsafe(64 * 1024)
    let read = 0
    let totalRead = 0n
    while ((read = readSync(fd, buffer, 0, buffer.length, null)) > 0) {
      totalRead += BigInt(read)
      if (totalRead > before.size || totalRead > BigInt(maxFileBytes)) {
        throw new Error('turn snapshot file grew while hashing')
      }
      hash.update(buffer.subarray(0, read))
    }
    const after = fstatSync(fd, { bigint: true })
    if (totalRead !== before.size || aggregateMetadataFingerprint(after) !== metadataFingerprint) {
      throw new Error('turn snapshot file changed while hashing')
    }
    return {
      fingerprint: `${fileMode(before)}:${hash.digest('hex')}`,
      metadataFingerprint,
      hashedBytes: Number(before.size),
    }
  } finally {
    closeSync(fd)
  }
}

/**
 * Capture regular workspace files without following links. Broker-eligible
 * content is hashed within a deterministic aggregate budget. Oversized files
 * receive an ineligible sentinel; eligible files beyond the aggregate budget
 * receive a descriptor-metadata sentinel and are hashed only if that metadata
 * changes across a turn.
 */
export function captureWorkspaceSnapshot(
  cwd: string,
  options: CaptureSnapshotOptions = {},
): WorkspaceSnapshot {
  const root = realpathSync(resolve(cwd))
  if (!lstatSync(root).isDirectory()) throw new Error('workspace root is not a directory')
  const maxEntries = boundedInteger(options.maxEntries, 50_000, 'maxEntries')
  const maxDepth = boundedInteger(options.maxDepth, 32, 'maxDepth')
  const maxFileBytes = boundedInteger(options.maxFileBytes, 10 * 1024 * 1024, 'maxFileBytes')
  const maxTotalBytes = boundedInteger(options.maxTotalBytes, 64 * 1024 * 1024, 'maxTotalBytes')
  const files: Record<string, string> = Object.create(null)
  let visited = 0
  let totalBytes = 0

  const walk = (dir: string, depth: number): void => {
    if (depth > maxDepth) throw new Error(`turn snapshot exceeded depth ${maxDepth}`)
    const entries = readdirSync(dir, { withFileTypes: true }).sort((left, right) => (
      left.name < right.name ? -1 : left.name > right.name ? 1 : 0
    ))
    for (const entry of entries) {
      visited++
      if (visited > maxEntries) throw new Error(`turn snapshot exceeded ${maxEntries} entries`)
      const absolute = join(dir, entry.name)
      const relativePath = relative(root, absolute).split(sep).join('/')
      if (isOperatorOwnedRelativePath(relativePath)) continue
      if (entry.isSymbolicLink()) continue
      if (entry.isDirectory()) {
        if (!SKIP_DIRS.has(entry.name)) walk(absolute, depth + 1)
        continue
      }
      if (!entry.isFile()) continue
      const result = fingerprintOpenFile(absolute, maxFileBytes, maxTotalBytes - totalBytes)
      totalBytes += result.hashedBytes
      files[relativePath] = result.fingerprint
    }
  }
  walk(root, 0)
  return { root, files, maxFileBytes }
}

/** Return exact post-turn fingerprints or ineligible sentinels for changed paths. */
export function diffWorkspaceSnapshots(
  before: WorkspaceSnapshot,
  after: WorkspaceSnapshot,
  maxChanges = 256,
): Record<string, string | null> {
  if (before.root !== after.root) throw new Error('workspace root changed across turn')
  if (before.maxFileBytes !== after.maxFileBytes) {
    throw new Error('workspace per-file bound changed across turn')
  }
  const changed: Record<string, string | null> = Object.create(null)
  const paths = new Set([...Object.keys(before.files), ...Object.keys(after.files)])
  for (const path of paths) {
    const oldValue = before.files[path]
    const newValue = after.files[path]
    if (oldValue === newValue) continue
    if (newValue === undefined) {
      changed[path] = null
    } else if (newValue === INELIGIBLE_OVERSIZE_FINGERPRINT) {
      changed[path] = newValue
    } else if (
      isAggregateMetadataFingerprint(oldValue)
      || isAggregateMetadataFingerprint(newValue)
    ) {
      const absolute = resolve(after.root, path)
      const normalized = relative(after.root, absolute).split(sep).join('/')
      if (normalized !== path || normalized.startsWith('../') || isOperatorOwnedRelativePath(path)) {
        throw new Error('turn snapshot contains an invalid metadata path')
      }
      const refreshed = fingerprintOpenFile(absolute, after.maxFileBytes, after.maxFileBytes, {
        forceHash: true,
        expectedMetadata: isAggregateMetadataFingerprint(newValue) ? newValue : undefined,
      })
      if (refreshed.fingerprint === INELIGIBLE_OVERSIZE_FINGERPRINT) {
        throw new Error('aggregate-excluded file became oversized before re-fingerprint')
      }
      if (!isAggregateMetadataFingerprint(newValue) && refreshed.fingerprint !== newValue) {
        throw new Error('aggregate-excluded file changed after post-turn snapshot')
      }
      if (
        (isAggregateMetadataFingerprint(oldValue)
          && refreshed.metadataFingerprint === oldValue)
        || refreshed.fingerprint === oldValue
      ) continue
      changed[path] = refreshed.fingerprint
    } else {
      changed[path] = newValue
    }
    if (Object.keys(changed).length > maxChanges) {
      throw new Error(`turn changed more than ${maxChanges} snapshot-tracked files`)
    }
  }
  return changed
}
