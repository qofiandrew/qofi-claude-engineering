import { createHash } from 'node:crypto'
import { join } from 'node:path'
import {
  createCompletionReviewGate,
  recordTaskReviewArtifact,
  requestTaskReview,
  type CompletionReviewGateState,
  type CompletionReviewPolicy,
  type ReviewVerdict,
} from './completion-review-policy.ts'
import {
  canonicalAuthorityJson,
  readPrivateCanonicalAuthorityRecord,
  type HarnessParityAdoption,
} from './parity-adoption.ts'
import type { NormalizedStopEvent } from './stop-delivery.ts'

export const CLAUDE_COMPLETION_ENVELOPE_SCHEMA = 'qofi-claude-completion-envelope/v1' as const
export const CLAUDE_COMPLETION_ARTIFACT_SCHEMA = 'qofi-harness-review-evidence/v1' as const
export const MAX_CLAUDE_COMPLETION_ENVELOPE_BYTES = 1024 * 1024

const SHA256 = /^[0-9a-f]{64}$/
const SAFE_TASK = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/
const SAFE_ARTIFACT = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$/
const SAFE_PATH = /^(?!\/)(?!\.\/)(?!.*(?:^|\/)\.\.(?:\/|$))(?!.*\/\/)(?!.*\\)(?!.*\0).{1,512}$/

export type ClaudeCompletionReviewEvidence = Readonly<{
  schema: typeof CLAUDE_COMPLETION_ARTIFACT_SCHEMA
  artifact_id: string
  task_id: string
  phase: 'completion'
  reviewed_diff_sha256: string
  verdict: ReviewVerdict
}>

export type ClaudeCompletionEnvelope = Readonly<{
  schema: typeof CLAUDE_COMPLETION_ENVELOPE_SCHEMA
  adoption_receipt_sha256: string
  runtime: 'claude'
  swarm: string
  task_id: string
  stop_event_id: string
  final_diff_sha256: string
  reviewed_paths: readonly string[]
  artifact: ClaudeCompletionReviewEvidence
}>

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length
    && keys.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

function compareUtf8(left: string, right: string): number {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'))
}

function parseEvidence(value: unknown): ClaudeCompletionReviewEvidence {
  if (!object(value) || !exactKeys(value, [
    'schema', 'artifact_id', 'task_id', 'phase', 'reviewed_diff_sha256', 'verdict',
  ]) || value.schema !== CLAUDE_COMPLETION_ARTIFACT_SCHEMA
    || typeof value.artifact_id !== 'string' || !SAFE_ARTIFACT.test(value.artifact_id)
    || typeof value.task_id !== 'string' || !SAFE_TASK.test(value.task_id)
    || value.phase !== 'completion'
    || typeof value.reviewed_diff_sha256 !== 'string'
    || !SHA256.test(value.reviewed_diff_sha256)
    || !['approve', 'needs-changes', 'block', 'review-unavailable'].includes(String(value.verdict))) {
    throw new Error('Claude completion artifact evidence is malformed')
  }
  return value as unknown as ClaudeCompletionReviewEvidence
}

function parseEnvelope(value: unknown): ClaudeCompletionEnvelope {
  if (!object(value) || !exactKeys(value, [
    'schema', 'adoption_receipt_sha256', 'runtime', 'swarm', 'task_id',
    'stop_event_id', 'final_diff_sha256', 'reviewed_paths', 'artifact',
  ]) || value.schema !== CLAUDE_COMPLETION_ENVELOPE_SCHEMA
    || value.runtime !== 'claude'
    || typeof value.swarm !== 'string'
    || typeof value.task_id !== 'string' || !SAFE_TASK.test(value.task_id)
    || typeof value.adoption_receipt_sha256 !== 'string'
    || !SHA256.test(value.adoption_receipt_sha256)
    || typeof value.stop_event_id !== 'string' || !SHA256.test(value.stop_event_id)
    || typeof value.final_diff_sha256 !== 'string' || !SHA256.test(value.final_diff_sha256)
    || !Array.isArray(value.reviewed_paths) || value.reviewed_paths.length > 128
    || value.reviewed_paths.some(path => typeof path !== 'string' || !SAFE_PATH.test(path))
    || new Set(value.reviewed_paths).size !== value.reviewed_paths.length
    || JSON.stringify(value.reviewed_paths) !== JSON.stringify(
      [...value.reviewed_paths].sort(compareUtf8),
    )) {
    throw new Error('Claude completion authority envelope is malformed')
  }
  const artifact = parseEvidence(value.artifact)
  if (artifact.task_id !== value.task_id
    || artifact.reviewed_diff_sha256 !== value.final_diff_sha256) {
    throw new Error('Claude completion artifact is not bound to the final task diff')
  }
  return { ...value, artifact } as unknown as ClaudeCompletionEnvelope
}

export function claudeCompletionEnvelopePath(
  adoption: Extract<HarnessParityAdoption, { enabled: true }>,
  event: NormalizedStopEvent,
): string {
  if (event.runtime !== 'claude') throw new Error('Claude authority cannot admit another runtime')
  return join(
    adoption.stateRoot,
    'completion-authority',
    'claude',
    event.swarm,
    `${event.taskId}.json`,
  )
}

/**
 * Read the harness-owned exact-final-diff envelope and derive gate state from
 * its evidence. No path, hash, verdict, or task identity is accepted from the
 * hook payload beyond matching it against the independently stored envelope.
 */
export function readClaudeCompletionGateState(options: Readonly<{
  adoption: Extract<HarnessParityAdoption, { enabled: true }>
  event: NormalizedStopEvent
  policy: CompletionReviewPolicy
}>): CompletionReviewGateState {
  const { adoption, event, policy } = options
  const path = claudeCompletionEnvelopePath(adoption, event)
  const read = readPrivateCanonicalAuthorityRecord(
    path, 'Claude completion authority envelope', MAX_CLAUDE_COMPLETION_ENVELOPE_BYTES,
  )
  const envelope = parseEnvelope(read.value)
  if (envelope.adoption_receipt_sha256 !== adoption.receiptSha256
    || envelope.swarm !== adoption.swarm || envelope.swarm !== event.swarm
    || envelope.task_id !== event.taskId || envelope.stop_event_id !== event.eventId) {
    throw new Error('Claude completion authority envelope has the wrong receipt or stop scope')
  }

  let gate = createCompletionReviewGate(event.taskId, policy)
  const requested = requestTaskReview(
    gate,
    policy,
    'completion',
    envelope.reviewed_paths,
    envelope.final_diff_sha256,
  )
  if (!requested.ok) throw new Error(`Claude completion review request refused: ${requested.reason}`)
  gate = requested.state
  const evidenceBytes = canonicalAuthorityJson(envelope.artifact)
  const recorded = recordTaskReviewArtifact(gate, policy, {
    artifactId: envelope.artifact.artifact_id,
    artifactSha256: createHash('sha256').update(evidenceBytes).digest('hex'),
    taskId: envelope.task_id,
    phase: 'completion',
    reviewedDiffSha256: envelope.artifact.reviewed_diff_sha256,
    verdict: envelope.artifact.verdict,
  })
  if (!recorded.ok) throw new Error(`Claude completion artifact refused: ${recorded.reason}`)
  return recorded.state
}
