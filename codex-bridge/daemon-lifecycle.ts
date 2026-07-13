/**
 * Harness-owned lifecycle seam for the Discord Codex daemon.
 *
 * This module contains no Discord gateway or process-spawn policy.  The daemon
 * supplies a runtime adapter and transport; the shared harness owns lifecycle
 * events, completion-review admission, stop delivery, and roadmap derivation.
 * Production adoption is deliberately explicit and parity-scoped (see
 * parseDaemonHarnessAdoption): merely installing these bytes enables nothing.
 */

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
import { relative, resolve, sep } from 'node:path'
import {
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
  recordTaskReviewArtifact,
  requestTaskReview,
  type CompletionReviewPolicy,
  type ReviewVerdict,
} from '../swarm-harness/completion-review-policy.ts'
import { makeHarnessEvent, type NormalizedSwarmEvent } from '../swarm-harness/events.ts'
import {
  type NormalizedEventStore,
  rebuildRoadmapFromEventStore,
} from '../swarm-harness/event-store.ts'
import { type RoadmapStore } from '../swarm-harness/roadmap.ts'
import { CodexStopAdapter } from '../swarm-harness/runtime-adapters.ts'
import { type StopDeliveryPipeline } from '../swarm-harness/stop-delivery.ts'
import {
  enforceTaskCompletionBoundary,
  type TaskBoundaryResult,
} from '../swarm-harness/task-boundary.ts'
import type { FableReviewArtifact } from './review-artifacts.ts'
import {
  HARNESS_PARITY_ADOPTION_CONTRACT,
  readHarnessParityAdoption,
  type HarnessParityAdoption,
} from '../swarm-harness/parity-adoption.ts'

export const CODEX_HARNESS_PARITY_ADOPTION = HARNESS_PARITY_ADOPTION_CONTRACT
export const EMPTY_COMPLETION_REVIEW_MATERIAL =
  'qofi completion review: no workspace file changes' as const
export const MAX_COMPLETION_REVIEW_BYTES = 2 * 1024 * 1024

const SHA256 = /^[0-9a-f]{64}$/
const FINGERPRINT = /^(100644|100755):([0-9a-f]{64})$/
export type DaemonHarnessAdoption = HarnessParityAdoption

/**
 * Codex consumes the same operator-issued, owner-private receipt as Claude.
 * The receipt contains both runtime scopes atomically; legacy environment-only
 * assertion is refused rather than enabling a Codex-only completion gate.
 */
export function parseDaemonHarnessAdoption(
  env: NodeJS.ProcessEnv,
  options: Readonly<{
    expectedSwarm: string
    workspaceRoot: string
    expectedCompletionPolicySha256: string
  }>,
): DaemonHarnessAdoption {
  return readHarnessParityAdoption(env, options)
}

export type CompletionReviewMaterial = Readonly<{
  hash: string
  paths: readonly string[]
  /** Diagnostic shape only; file contents never enter event/roadmap state. */
  kind: 'empty' | 'named-files'
  bytes: number
  /**
   * Bounded post-turn bytes retained only in this host process until the
   * manager-owned completion reviewer has consumed them.  They are never
   * projected into normalized events, receipts, roadmap state, or Discord.
   */
  reviewInput: CompletionReviewInput
}>

export type CompletionReviewInput = Readonly<{
  diff_or_files: string | Readonly<{
    files: readonly Readonly<{ path: string, content: string }>[]
  }>
  context_refs: readonly []
  mode: 'code'
}>

function inside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root.endsWith(sep) ? root : `${root}${sep}`)
}

function strictUtf8(bytes: Buffer): string {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  if (text.includes('\0')) throw new Error('completion review file contains NUL data')
  return text
}

function readPostStateFile(
  root: string,
  path: string,
  expectedMode: string,
  expectedSha256: string,
): string {
  const absolute = resolve(root, path)
  if (!inside(root, absolute) || relative(root, absolute).split(sep).join('/') !== path) {
    throw new Error('completion review path escaped the workspace')
  }
  const before = lstatSync(absolute)
  const mode = (before.mode & 0o111) === 0 ? '100644' : '100755'
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1 || mode !== expectedMode
    || before.size > MAX_COMPLETION_REVIEW_BYTES) {
    throw new Error('completion review file identity, mode, link count, or size is unsafe')
  }
  const fd = openSync(absolute, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
      || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs) {
      throw new Error('completion review file changed while opening')
    }
    const bytes = readFileSync(fd)
    const after = fstatSync(fd)
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
      || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs
      || createHash('sha256').update(bytes).digest('hex') !== expectedSha256) {
      throw new Error('completion review file drifted from the post-turn snapshot')
    }
    return strictUtf8(bytes)
  } finally {
    closeSync(fd)
  }
}

/**
 * Reproduce qofi-fable-reviewer-mcp.py's named-file hash exactly.  Python's
 * sort_keys=True writes inner keys as content,path; paths are sorted here so
 * caller order cannot weaken the task-delta binding.  Deletions use a literal
 * path suffix, preventing a deleted file from hashing like a present empty
 * file.  Existing files are descriptor-rebound to the exact snapshot hash.
 */
export function deriveCompletionReviewMaterial(
  repoRoot: string,
  changes: Readonly<Record<string, string | null>>,
): CompletionReviewMaterial {
  const root = realpathSync(resolve(repoRoot))
  const paths = Object.keys(changes).sort((left, right) => (
    Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'))
  ))
  if (paths.length === 0) {
    return {
      hash: createHash('sha256').update(EMPTY_COMPLETION_REVIEW_MATERIAL).digest('hex'),
      paths,
      kind: 'empty',
      bytes: Buffer.byteLength(EMPTY_COMPLETION_REVIEW_MATERIAL),
      reviewInput: {
        diff_or_files: EMPTY_COMPLETION_REVIEW_MATERIAL,
        context_refs: [],
        mode: 'code',
      },
    }
  }
  if (paths.length > 128) throw new Error('completion review path count exceeds the reviewer bound')
  const files: Array<{ content: string, path: string }> = []
  for (const path of paths) {
    const fingerprint = changes[path]
    if (fingerprint === null) {
      const absolute = resolve(root, path)
      if (!inside(root, absolute) || relative(root, absolute).split(sep).join('/') !== path) {
        throw new Error('completion review deletion escaped the workspace')
      }
      try {
        lstatSync(absolute)
        throw new Error('completion review deletion is present after the post-turn snapshot')
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      }
      files.push({ content: '', path: `${path} [deleted]` })
      continue
    }
    const match = fingerprint.match(FINGERPRINT)
    if (!match) throw new Error('completion review cannot admit an ineligible snapshot fingerprint')
    files.push({
      content: readPostStateFile(root, path, match[1]!, match[2]!),
      path,
    })
  }
  // Objects are intentionally constructed content,path to match Python's
  // recursive sort_keys=True compact serialization in the reviewer shim.
  const canonical = JSON.stringify({ files })
  const bytes = Buffer.byteLength(canonical)
  if (bytes > MAX_COMPLETION_REVIEW_BYTES) {
    throw new Error('completion review material exceeds the reviewer byte bound')
  }
  return {
    hash: createHash('sha256').update(canonical).digest('hex'),
    paths,
    kind: 'named-files',
    bytes,
    reviewInput: {
      diff_or_files: { files },
      context_refs: [],
      mode: 'code',
    },
  }
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  const object = value as Record<string, unknown>
  return `{${Object.keys(object).sort().map(key => (
    `${JSON.stringify(key)}:${canonicalJson(object[key])}`
  )).join(',')}}`
}

function artifactIdentity(artifact: FableReviewArtifact): { id: string, sha256: string } {
  const id = `fable-${artifact.created_at}`
  return {
    id,
    sha256: createHash('sha256').update(canonicalJson(artifact)).digest('hex'),
  }
}

function reviewResultStatus(verdict: ReviewVerdict): 'passed' | 'failed' | 'pending' | 'blocked' {
  switch (verdict) {
    case 'approve': return 'passed'
    case 'needs-changes': return 'failed'
    case 'review-unavailable': return 'pending'
    case 'block': return 'blocked'
  }
}

export type DaemonCompletionResult = Readonly<{
  boundary: TaskBoundaryResult
  material: CompletionReviewMaterial
  reviewArtifactAccepted: boolean
  reviewReason: string
}>

export type DaemonHarnessLifecycleOptions = Readonly<{
  eventStore: NormalizedEventStore
  roadmapStore: RoadmapStore
  policy: CompletionReviewPolicy
  repoRoot: string
  swarm: string
  drRefs: readonly string[]
  now?: () => number
}>

/** Runtime-blind state and evidence integration for one daemon/swarm. */
export class DaemonHarnessLifecycle {
  private readonly eventStore: NormalizedEventStore
  private readonly roadmapStore: RoadmapStore
  private readonly policy: CompletionReviewPolicy
  private readonly repoRoot: string
  private readonly swarm: string
  private readonly drRefs: readonly string[]
  private readonly now: () => number
  private lastTimestampMs = -1
  private readonly sourceSequences = new Map<string, number>()

  constructor(options: DaemonHarnessLifecycleOptions) {
    this.eventStore = options.eventStore
    this.roadmapStore = options.roadmapStore
    this.policy = parseCompletionReviewPolicy(options.policy)
    this.repoRoot = realpathSync(resolve(options.repoRoot))
    this.swarm = options.swarm
    this.drRefs = [...new Set(options.drRefs)].sort()
    this.now = options.now ?? Date.now
  }

  private timestamp(): string {
    const observed = this.now()
    if (!Number.isSafeInteger(observed) || observed < 0) throw new Error('harness clock is invalid')
    const next = Math.max(observed, this.lastTimestampMs + 1)
    this.lastTimestampMs = next
    return new Date(next).toISOString()
  }

  private append(event: NormalizedSwarmEvent): void {
    this.eventStore.append(event)
  }

  private event(input: Omit<Parameters<typeof makeHarnessEvent>[0], 'runtime' | 'swarm' | 'dr_refs'>): void {
    this.append(makeHarnessEvent({
      ...input,
      runtime: 'codex',
      swarm: this.swarm,
      dr_refs: [...this.drRefs],
    }))
  }

  startTask(taskId: string): void {
    this.sourceSequences.set(taskId, 0)
    this.event({
      ts: this.timestamp(), type: 'task.started', source: 'harness', task_id: taskId,
      state: 'DRIVING',
    })
    this.rebuildRoadmap()
  }

  recordRuntimeActivity(taskId: string): void {
    const sourceSequence = this.sourceSequences.get(taskId) ?? 0
    if (sourceSequence > 1_000_000) throw new Error('Codex lifecycle activity exceeds its event bound')
    this.event({
      ts: this.timestamp(), type: 'runtime.activity', source: 'codex-rollout', task_id: taskId,
      source_seq: sourceSequence,
    })
    this.sourceSequences.set(taskId, sourceSequence + 1)
  }

  deriveCompletionMaterial(changes: Readonly<Record<string, string | null>>): CompletionReviewMaterial {
    return deriveCompletionReviewMaterial(this.repoRoot, changes)
  }

  async completeTask(options: Readonly<{
    taskId: string
    turnId: string
    channelId: string
    fallbackChannelId?: string | null
    summary: string
    material: CompletionReviewMaterial
    artifacts: readonly FableReviewArtifact[]
    pipeline: StopDeliveryPipeline
  }>): Promise<DaemonCompletionResult> {
    if (!SHA256.test(options.material.hash)) throw new Error('completion review material hash is invalid')
    let gate = createCompletionReviewGate(options.taskId, this.policy)
    const request = requestTaskReview(
      gate,
      this.policy,
      'completion',
      options.material.paths,
      options.material.hash,
    )
    if (!request.ok) throw new Error(`completion review request was refused: ${request.reason}`)
    gate = request.state

    let reviewArtifactAccepted = false
    let reviewReason = options.artifacts.length === 0
      ? 'completion-verdict-or-artifact-missing'
      : 'completion-review-artifact-count-invalid'
    const matchingArtifacts = options.artifacts.filter(artifact => (
      artifact.reviewed_diff_sha256 === options.material.hash
    ))
    // One doctrine-authorized early review may coexist with the one mandatory
    // completion review. It never satisfies completion, so select the sole
    // exact-final-diff candidate. A lone mismatched artifact is still passed
    // through the gate to retain the precise mismatch audit reason.
    const artifact = options.artifacts.length === 1
      ? options.artifacts[0]!
      : options.artifacts.length === 2 && matchingArtifacts.length === 1
        ? matchingArtifacts[0]!
        : null
    if (artifact) {
      const identity = artifactIdentity(artifact)
      const admitted = recordTaskReviewArtifact(gate, this.policy, {
        artifactId: identity.id,
        artifactSha256: identity.sha256,
        taskId: options.taskId,
        phase: 'completion',
        reviewedDiffSha256: artifact.reviewed_diff_sha256,
        verdict: artifact.result.verdict,
      })
      reviewReason = admitted.reason
      if (admitted.ok) {
        gate = admitted.state
        reviewArtifactAccepted = true
        this.event({
          ts: this.timestamp(), type: 'result.landed', source: 'result-set',
          task_id: options.taskId, result_kind: 'review',
          result_status: reviewResultStatus(artifact.result.verdict),
        })
      }
    }

    const boundary = await enforceTaskCompletionBoundary({
      adapter: new CodexStopAdapter(this.now),
      pipeline: options.pipeline,
      input: {
        swarm: this.swarm,
        taskId: options.taskId,
        turnId: options.turnId,
        channelId: options.channelId,
        fallbackChannelId: options.fallbackChannelId ?? null,
        summary: options.summary,
      },
      gateState: gate,
      policy: this.policy,
    })

    this.event({
      ts: this.timestamp(), type: 'result.landed', source: 'result-set',
      task_id: options.taskId, result_kind: 'delivery',
      result_status: boundary.stop.disposition === 'delivered'
        ? 'passed'
        : boundary.stop.disposition === 'queued' ? 'pending' : 'failed',
    })
    if (boundary.accepted) {
      this.event({
        ts: this.timestamp(), type: 'task.finished', source: 'harness', task_id: options.taskId,
        outcome: 'completed', state: 'STOOD_DOWN',
      })
    } else {
      // A rejected done/Stop boundary is not a finished task. Preserve it as
      // active-but-waiting so watcher replay can re-ping/escalate instead of
      // mistaking a missing or stale verdict for terminal inactivity.
      this.event({
        ts: this.timestamp(), type: 'state.transitioned', source: 'harness',
        task_id: options.taskId, previous_state: 'DRIVING', state: 'WAITING_FOR_OPERATOR',
      })
    }
    this.rebuildRoadmap()
    this.sourceSequences.delete(options.taskId)
    return { boundary, material: options.material, reviewArtifactAccepted, reviewReason }
  }

  failTask(taskId: string): void {
    // A failed runtime/transport is evidence that work cannot continue, not
    // evidence that the worker satisfied the review+stop terminal contract.
    // Keep the task active for watcher check-in and operator recovery.
    this.event({
      ts: this.timestamp(), type: 'state.transitioned', source: 'harness', task_id: taskId,
      previous_state: 'DRIVING', state: 'WAITING_FOR_OPERATOR',
    })
    this.rebuildRoadmap()
    this.sourceSequences.delete(taskId)
  }

  rebuildRoadmap(): void {
    rebuildRoadmapFromEventStore(this.eventStore, this.roadmapStore)
  }
}
