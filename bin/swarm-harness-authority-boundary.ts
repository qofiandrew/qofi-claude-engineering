#!/usr/bin/env bun
/** Root-owned lifecycle coordinator invoked only by qofi-harness-lifecycle-broker. */

import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  atomicCanonicalAuthorityRecord,
  ensurePrivateAuthorityChild,
} from '../swarm-harness/authority-state.ts'
import {
  completionReviewPolicySha256,
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
  recordTaskReviewArtifact,
  requestTaskReview,
  type ReviewVerdict,
} from '../swarm-harness/completion-review-policy.ts'
import { NormalizedEventStore, rebuildRoadmapFromEventStore } from '../swarm-harness/event-store.ts'
import { projectCompletionEvents } from '../swarm-harness/events.ts'
import {
  canonicalAuthorityJson,
  readHarnessParityAdoption,
  type HarnessParityAdoption,
} from '../swarm-harness/parity-adoption.ts'
import { RoadmapStore } from '../swarm-harness/roadmap.ts'
import { CodexStopAdapter } from '../swarm-harness/runtime-adapters.ts'
import {
  DiscordRestSender,
  StopDeliveryPipeline,
  StopStateStore,
  type NormalizedStopEvent,
  type StopOutcome,
} from '../swarm-harness/stop-delivery.ts'
import { enforceTaskCompletionBoundary } from '../swarm-harness/task-boundary.ts'

process.umask(0o077)

const MAX_INPUT = 1_048_576
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/

function safeLabel(value: unknown, fallback: string): string {
  const selected = String(value ?? '').trim()
  return SAFE_LABEL.test(selected) ? selected : fallback
}

async function stdin(): Promise<Buffer> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of process.stdin) {
    const bytes = Buffer.from(chunk)
    total += bytes.length
    if (total > MAX_INPUT) throw new Error('lifecycle boundary input exceeds its bound')
    chunks.push(bytes)
  }
  return Buffer.concat(chunks)
}

function object(raw: Buffer): Record<string, unknown> {
  const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw))
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('lifecycle boundary input is not an object')
  }
  return value as Record<string, unknown>
}

function iso(ms = Date.now()): string {
  if (!Number.isSafeInteger(ms) || ms < 0) throw new Error('lifecycle timestamp is invalid')
  return new Date(ms).toISOString()
}

function lifecycleStores(adoption: Extract<HarnessParityAdoption, { enabled: true }>, operatorUid: number) {
  // Construct the publication boundary first. Cross-owner publication is
  // currently restricted, and that refusal must happen before creating state
  // children, consuming result material, delivering Discord, or writing a
  // result set.
  const roadmapStore = new RoadmapStore(
    adoption.roadmapRepoRoot,
    join(adoption.stateRoot, 'roadmap', 'authority.json'),
    { authorityUid: process.getuid?.(), roadmapOwnerUid: operatorUid },
  )
  const events = ensurePrivateAuthorityChild(adoption.stateRoot, 'events')
  ensurePrivateAuthorityChild(adoption.stateRoot, 'roadmap')
  const eventStore = new NormalizedEventStore(events, {
    repoRoot: adoption.roadmapRepoRoot,
    expectedUid: process.getuid?.(),
  })
  return { eventStore, roadmapStore }
}

function recordCompletionEvents(options: Readonly<{
  adoption: Extract<HarnessParityAdoption, { enabled: true }>
  operatorUid: number
  event: NormalizedStopEvent
  outcome: StopOutcome
  verdict: ReviewVerdict
  startedAt: string
  stores: ReturnType<typeof lifecycleStores>
}>): void {
  const { adoption, event, outcome } = options
  const stores = options.stores
  const terminal = Math.max(2, outcome.completedAtMs)
  const projected = projectCompletionEvents({
    runtime: event.runtime,
    swarm: adoption.swarm,
    task_id: event.taskId,
    dr_refs: [...adoption.drRefs],
    started_at: options.startedAt,
    completed_at_ms: terminal,
    stopped: outcome.stopped,
    delivery_disposition: outcome.disposition,
    review_verdict: options.verdict,
  })
  for (const item of projected) stores.eventStore.append(item)
  rebuildRoadmapFromEventStore(stores.eventStore, stores.roadmapStore)
}

const raw = await stdin()
const input = object(raw)
const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(import.meta.dir, '..', 'swarm-harness', 'completion-review-policy.json'), 'utf8',
)))
const expectedSwarm = safeLabel(process.env.SWARM_NAME, 'invalid-swarm')
const repoRoot = String(process.env.CLAUDE_PROJECT_DIR ?? process.cwd())
const adoption = readHarnessParityAdoption(process.env, {
  expectedSwarm,
  workspaceRoot: repoRoot,
  expectedCompletionPolicySha256: completionReviewPolicySha256(policy),
})
if (!adoption.enabled) throw new Error('root lifecycle entry requires atomic parity adoption')
const operatorUid = Number(process.env.SWARM_HARNESS_OPERATOR_UID)
if (!Number.isSafeInteger(operatorUid) || operatorUid < 1) throw new Error('registered operator uid is invalid')

if (process.env.SWARM_HARNESS_BROKER_OPERATION === 'task-complete'
  && process.env.SWARM_HARNESS_BROKER_RUNTIME === 'codex') {
  const stores = lifecycleStores(adoption, operatorUid)
  const manager = input.manager_receipt
  const request = input.request
  if (input.schema !== 'qofi-harness-internal-codex-completion/v1'
    || !manager || typeof manager !== 'object' || Array.isArray(manager)
    || !request || typeof request !== 'object' || Array.isArray(request)) {
    throw new Error('internal Codex completion handoff is malformed')
  }
  const receipt = manager as Record<string, unknown>
  const external = request as Record<string, unknown>
  const payload = external.payload as Record<string, unknown>
  const taskId = safeLabel(receipt.taskId, 'invalid-task')
  const turnId = safeLabel(payload.turn_id, taskId)
  const hash = String(receipt.reviewedDiffSha256 ?? '')
  const verdict = String(receipt.verdict ?? '') as ReviewVerdict
  if (receipt.schema !== 'qofi-codex-completion-review-receipt/v1'
    || receipt.swarm !== adoption.swarm || receipt.repoRoot !== repoRoot
    || external.swarm !== adoption.swarm || payload.task_id !== taskId
    || !/^[a-f0-9]{64}$/.test(hash)
    || !['approve', 'needs-changes', 'block', 'review-unavailable'].includes(verdict)) {
    throw new Error('internal Codex completion receipt has the wrong scope')
  }
  let gate = createCompletionReviewGate(taskId, policy)
  const requested = requestTaskReview(gate, policy, 'completion', [], hash)
  if (!requested.ok) throw new Error(`Codex completion review request refused: ${requested.reason}`)
  gate = requested.state
  const recorded = recordTaskReviewArtifact(gate, policy, {
    artifactId: safeLabel(receipt.artifactName, `fable-${hash.slice(0, 16)}`),
    artifactSha256: String(receipt.artifactSha256),
    taskId,
    phase: 'completion',
    reviewedDiffSha256: hash,
    verdict,
  })
  if (!recorded.ok) throw new Error(`Codex manager review receipt refused: ${recorded.reason}`)
  const sender = new DiscordRestSender({ token: String(process.env.DISCORD_BOT_TOKEN ?? '') })
  const stopStore = new StopStateStore(join(adoption.stateRoot, 'stops'))
  const pipeline = new StopDeliveryPipeline({ sender, fallbackSender: sender, store: stopStore })
  const channelId = String(process.env.DISCORD_BOUND_CHANNEL ?? '')
  const fallback = String(process.env.SWARM_STOP_FALLBACK_CHANNEL ?? '')
  const boundary = await enforceTaskCompletionBoundary({
    adapter: new CodexStopAdapter(),
    pipeline,
    input: {
      swarm: adoption.swarm,
      taskId,
      turnId,
      channelId,
      fallbackChannelId: fallback,
      summary: String(payload.summary ?? ''),
    },
    gateState: recorded.state,
    policy,
  })
  const event = new CodexStopAdapter().normalizeStop({
    swarm: adoption.swarm,
    taskId,
    turnId,
    channelId,
    fallbackChannelId: fallback,
    summary: String(payload.summary ?? ''),
    occurredAtMs: boundary.stop.completedAtMs,
  })
  const resultDir = ensurePrivateAuthorityChild(adoption.stateRoot, 'result-sets', 'review', 'codex', adoption.swarm)
  atomicCanonicalAuthorityRecord(join(resultDir, `${event.eventId}.json`), {
    schema: 'qofi-harness-manager-review-receipt/v1',
    runtime: 'codex',
    swarm: adoption.swarm,
    task_id: taskId,
    reviewed_diff_sha256: hash,
    verdict,
    artifact_name: receipt.artifactName,
    artifact_sha256: receipt.artifactSha256,
  })
  recordCompletionEvents({
    adoption,
    operatorUid,
    event,
    outcome: boundary.stop,
    verdict,
    startedAt: iso(Math.max(0, boundary.stop.completedAtMs - 3)),
    stores,
  })
  const result = {
    schema: 'qofi-harness-broker-result/v1',
    accepted: boundary.accepted,
    task_id: taskId,
    receipt_sha256: createHash('sha256').update(canonicalAuthorityJson(receipt)).digest('hex'),
    stop_disposition: boundary.stop.disposition,
  }
  process.stdout.write(`${JSON.stringify(result, Object.keys(result).sort())}\n`)
  process.exit(boundary.accepted ? 0 : 2)
}

// Raw Claude hook JSON and its paths are worker-controlled. It cannot be a
// lifecycle authority, and there is no root-attested exact-final Codex
// reviewer for a supervised Claude print worker yet. Refuse every Claude
// completion entry instead of fabricating review-unavailable evidence.
if (process.env.SWARM_HARNESS_BROKER_RUNTIME === 'claude') {
  throw new Error('restricted-no-attested-exact-final-reviewer')
}
throw new Error('generic lifecycle operation is not admitted by this boundary entry')
