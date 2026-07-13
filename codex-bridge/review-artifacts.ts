/** Descriptor-bound intake for terminal Fable reviewer artifacts. */

import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
} from 'fs'
import { createHash } from 'crypto'
import { join } from 'path'
import { assertNoExtendedAcl } from './security.ts'

export const FABLE_REVIEW_ARTIFACT_SCHEMA = 'qofi-fable-review-artifact/v1' as const
export const ADVERSARIAL_REVIEW_OUTPUT_SCHEMA = 'qofi-adversarial-review-output/v2' as const
export const MAX_REVIEW_ARTIFACT_BYTES = 1024 * 1024
// A configured task may admit 32 reviews. One deterministic budget-status
// artifact is reserved so an exhausted/error retry cannot invalidate them.
export const MAX_REVIEW_ARTIFACTS_PER_TASK = 33

const SAFE_SWARM = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
const SAFE_PROFILE = /^[a-z][a-z0-9_-]{0,31}$/
const SAFE_TASK = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/
const ARTIFACT_NAME = /^(?:fable-review-[0-9]{8}T[0-9]{12}Z-[0-9a-f]{16}|fable-review-budget-exhausted)\.json$/
const SHA256 = /^[0-9a-f]{64}$/
const UTC_MICROSECONDS = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$/
const REVIEW_MODES = new Set(['code', 'security', 'design', 'directive'])
const VERDICTS = new Set(['approve', 'needs-changes', 'block', 'review-unavailable'])
const SEVERITIES = new Set(['critical', 'high', 'medium', 'low'])

type ReviewFinding = Readonly<{
  severity: 'critical' | 'high' | 'medium' | 'low'
  locus: string
  claim: string
  evidence: string
  suggested_test: string
}>

export type AdversarialReviewOutput = Readonly<{
  schema: typeof ADVERSARIAL_REVIEW_OUTPUT_SCHEMA
  verdict: 'approve' | 'needs-changes' | 'block' | 'review-unavailable'
  summary: string
  checked: readonly string[]
  not_checked: readonly string[]
  findings: readonly ReviewFinding[]
  next_steps: readonly string[]
}>

export type FableReviewArtifact = Readonly<{
  schema: typeof FABLE_REVIEW_ARTIFACT_SCHEMA
  reviewer: 'claude-fable'
  model: 'claude-fable-5'
  swarm: string
  profile: string
  task_id: string
  mode: 'code' | 'security' | 'design' | 'directive'
  reviewed_diff_sha256: string
  created_at: string
  result: AdversarialReviewOutput
}>

/** Exact pre-execution content hashes keyed by artifact filename. */
export type FableReviewArtifactBaseline = ReadonlyMap<string, string>

type FableReviewArtifactEntry = Readonly<{
  name: string
  digest: string
  artifact: FableReviewArtifact
}>

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  return Object.keys(value).length === expected.length
    && expected.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

function boundedText(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length >= 1 && value.length <= max && !value.includes('\0')
}

function boundedTextList(value: unknown, maxItems = 64): value is string[] {
  return Array.isArray(value) && value.length <= maxItems
    && value.every(item => boundedText(item, 1024))
}

function parseOutput(value: unknown): AdversarialReviewOutput {
  if (!object(value) || !exactKeys(value, [
    'schema', 'verdict', 'summary', 'checked', 'not_checked', 'findings', 'next_steps',
  ]) || value.schema !== ADVERSARIAL_REVIEW_OUTPUT_SCHEMA
    || !VERDICTS.has(String(value.verdict)) || !boundedText(value.summary, 4096)
    || !boundedTextList(value.checked) || !boundedTextList(value.not_checked)
    || !boundedTextList(value.next_steps) || !Array.isArray(value.findings)
    || value.findings.length > 64) {
    throw new Error('review artifact contains an invalid v2 verdict')
  }
  for (const finding of value.findings) {
    if (!object(finding) || !exactKeys(finding, [
      'severity', 'locus', 'claim', 'evidence', 'suggested_test',
    ]) || !SEVERITIES.has(String(finding.severity))
      || !boundedText(finding.locus, 1024) || !boundedText(finding.claim, 4096)
      || !boundedText(finding.evidence, 8192) || !boundedText(finding.suggested_test, 4096)) {
      throw new Error('review artifact contains an invalid finding')
    }
  }
  // An approval must preserve negative provenance; an empty account of what
  // was checked is a rubber stamp rather than a schema-valid approval.
  if (value.verdict === 'approve' && (
    (value.checked as unknown[]).length === 0
    || (value.not_checked as unknown[]).length === 0
    || (value.findings as unknown[]).length !== 0
  )) {
    throw new Error('approve review artifact lacks checked/not-checked provenance')
  }
  if ((value.verdict === 'needs-changes' || value.verdict === 'block')
    && (value.findings as unknown[]).length === 0) {
    throw new Error('adverse review verdict lacks a falsifiable finding')
  }
  if (value.verdict === 'review-unavailable' && (
    (value.findings as unknown[]).length !== 0 || (value.not_checked as unknown[]).length === 0
  )) {
    throw new Error('review-unavailable artifact lacks pending provenance')
  }
  return value as unknown as AdversarialReviewOutput
}

function parseArtifact(
  value: unknown,
  expected: { swarm: string; profile: string; taskId: string },
): FableReviewArtifact {
  if (!object(value) || !exactKeys(value, [
    'schema', 'reviewer', 'model', 'swarm', 'profile', 'task_id', 'mode',
    'reviewed_diff_sha256', 'created_at', 'result',
  ]) || value.schema !== FABLE_REVIEW_ARTIFACT_SCHEMA
    || value.reviewer !== 'claude-fable' || value.model !== 'claude-fable-5'
    || value.swarm !== expected.swarm || value.profile !== expected.profile
    || value.task_id !== expected.taskId || !REVIEW_MODES.has(String(value.mode))
    || !SHA256.test(String(value.reviewed_diff_sha256))
    || !UTC_MICROSECONDS.test(String(value.created_at))
    || !Number.isFinite(Date.parse(String(value.created_at)))) {
    throw new Error('review artifact wrapper is invalid or outside the active task scope')
  }
  return { ...value, result: parseOutput(value.result) } as unknown as FableReviewArtifact
}

function assertPrivateDirectory(path: string): ReturnType<typeof lstatSync> {
  const info = lstatSync(path)
  const uid = typeof process.getuid === 'function' ? process.getuid() : info.uid
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== uid || (info.mode & 0o777) !== 0o700) {
    throw new Error('review artifact directory must be owner-real mode 0700')
  }
  assertNoExtendedAcl(path, 'review artifact directory')
  return info
}

/**
 * Read only the active task/profile directory. Every path is
 * lstat/open/fstat rebound, all directories are rechecked around each child
 * open, and files are private, bounded, immutable for the duration of the
 * descriptor read.
 */
function readFableReviewArtifactEntries(
  stateDir: string,
  taskId: string,
  swarm: string,
  profile: string,
): FableReviewArtifactEntry[] {
  if (!SAFE_TASK.test(taskId) || !SAFE_SWARM.test(swarm) || !SAFE_PROFILE.test(profile)) {
    throw new Error('review artifact scope label is invalid')
  }
  const root = join(stateDir, 'review-artifacts')
  const taskDir = join(root, taskId)
  const profileDir = join(taskDir, profile)
  try { assertPrivateDirectory(root) } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  let beforeDir: ReturnType<typeof lstatSync>
  try {
    beforeDir = assertPrivateDirectory(taskDir)
  } catch (error) {
    // A task that never called the optional reviewer has no task directory.
    // The shared root can still exist because an earlier task used it; absence
    // here is therefore an empty result set, not a malformed pending review.
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  let beforeProfileDir: ReturnType<typeof lstatSync>
  try {
    beforeProfileDir = assertPrivateDirectory(profileDir)
  } catch (error) {
    // The same task may already have artifacts from an earlier hard-limit
    // attempt on another profile. Absence of this profile is still empty.
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  const currentTaskDir = lstatSync(taskDir)
  if (currentTaskDir.dev !== beforeDir.dev || currentTaskDir.ino !== beforeDir.ino) {
    throw new Error('review artifact task directory changed while opening profile scope')
  }
  const dirFd = openSync(profileDir, constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0))
  try {
    const openedDir = fstatSync(dirFd)
    if (openedDir.dev !== beforeProfileDir.dev || openedDir.ino !== beforeProfileDir.ino) {
      throw new Error('review artifact profile directory changed while opening')
    }
    const names = readdirSync(profileDir).sort()
    if (names.length > MAX_REVIEW_ARTIFACTS_PER_TASK) throw new Error('too many review artifacts for task profile')
    const artifacts: FableReviewArtifactEntry[] = []
    for (const name of names) {
      if (!ARTIFACT_NAME.test(name)) throw new Error('review artifact filename is invalid')
      const path = join(profileDir, name)
      const before = lstatSync(path)
      const uid = typeof process.getuid === 'function' ? process.getuid() : before.uid
      if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1 || before.uid !== uid
        || (before.mode & 0o777) !== 0o600 || before.size > MAX_REVIEW_ARTIFACT_BYTES) {
        throw new Error('review artifact must be owner-regular mode 0600 and bounded')
      }
      assertNoExtendedAcl(path, 'review artifact')
      const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      try {
        const opened = fstatSync(fd)
        if (opened.dev !== before.dev || opened.ino !== before.ino || opened.nlink !== 1
          || opened.size !== before.size
          || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs) {
          throw new Error('review artifact changed while opening')
        }
        const bytes = readFileSync(fd)
        const after = fstatSync(fd)
        const currentDir = lstatSync(profileDir)
        if (currentDir.dev !== openedDir.dev || currentDir.ino !== openedDir.ino
          || after.nlink !== 1 || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs
          || bytes.byteLength > MAX_REVIEW_ARTIFACT_BYTES) {
          throw new Error('review artifact changed while reading')
        }
        assertNoExtendedAcl(path, 'review artifact')
        artifacts.push({
          name,
          digest: createHash('sha256').update(bytes).digest('hex'),
          artifact: parseArtifact(JSON.parse(bytes.toString('utf8')), { swarm, profile, taskId }),
        })
      } finally {
        closeSync(fd)
      }
    }
    return artifacts
  } finally {
    closeSync(dirFd)
  }
}

/**
 * Capture the exact active-profile artifact set before a turn. The per-task
 * budget remains global to the task; this baseline only prevents a retry on
 * the same profile from replaying verdicts that predate that attempt.
 */
export function snapshotFableReviewArtifactBaseline(
  stateDir: string,
  taskId: string,
  swarm: string,
  profile: string,
): FableReviewArtifactBaseline {
  return new Map(readFableReviewArtifactEntries(stateDir, taskId, swarm, profile)
    .map(entry => [entry.name, entry.digest] as const))
}

export function readFableReviewArtifacts(
  stateDir: string,
  taskId: string,
  swarm: string,
  profile: string,
  baseline?: FableReviewArtifactBaseline,
): FableReviewArtifact[] {
  return readFableReviewArtifactEntries(stateDir, taskId, swarm, profile)
    .filter(entry => baseline?.get(entry.name) !== entry.digest)
    .map(entry => entry.artifact)
}
