#!/usr/bin/env bun
import { createHash } from 'node:crypto'
import { closeSync, fstatSync, openSync, readFileSync, readSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import {
  DiscordRestSender,
  StopDeliveryPipeline,
  StopStateStore,
  type MessageSender,
  type StopOutcome,
} from '../swarm-harness/stop-delivery'
import { ClaudeStopAdapter, type ClaudeStopHookInput } from '../swarm-harness/runtime-adapters'
import {
  completionReviewPolicySha256,
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
} from '../swarm-harness/completion-review-policy'
import { readClaudeCompletionGateState } from '../swarm-harness/claude-completion-authority'
import {
  HARNESS_PARITY_RECEIPT_ENV,
  readHarnessParityAdoption,
  type HarnessParityAdoption,
} from '../swarm-harness/parity-adoption'
import { enforceTaskCompletionBoundary } from '../swarm-harness/task-boundary'

process.umask(0o077)

class UnavailableSender implements MessageSender {
  async send(): Promise<never> {
    throw new Error('Discord sender is unavailable')
  }
}

async function readStdin(): Promise<string> {
  const limit = 1_048_576
  const chunks: Buffer[] = []
  const digest = createHash('sha256')
  let kept = 0
  let total = 0
  let overflow = false
  for await (const value of process.stdin) {
    const chunk = Buffer.from(value)
    total += chunk.length
    digest.update(chunk)
    if (kept < limit) {
      const slice = chunk.subarray(0, Math.max(0, limit - kept))
      chunks.push(slice)
      kept += slice.length
    }
    if (total > limit) overflow = true
  }
  if (overflow) return `oversized-hook-input:${digest.digest('hex')}`
  return Buffer.concat(chunks).toString('utf8')
}

function readTranscriptTail(path: string): string {
  const maxBytes = 8 * 1_024 * 1_024
  const fd = openSync(path, 'r')
  try {
    const size = fstatSync(fd).size
    const length = Math.min(size, maxBytes)
    const buffer = Buffer.alloc(length)
    let offset = 0
    while (offset < length) {
      const read = readSync(fd, buffer, offset, length - offset, size - length + offset)
      if (read <= 0) break
      offset += read
    }
    let text = buffer.subarray(0, offset).toString('utf8')
    if (size > length) {
      const firstBreak = text.indexOf('\n')
      text = firstBreak >= 0 ? text.slice(firstBreak + 1) : ''
    }
    return text
  } finally {
    closeSync(fd)
  }
}

function parseInput(raw: string): ClaudeStopHookInput {
  try {
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed
  } catch {}
  return {
    session_id: 'malformed-hook-input',
    task_id: 'malformed-hook-input',
    stop_event_id: createHash('sha256').update(raw).digest('hex'),
    last_assistant_message: 'Stop boundary payload was malformed; the harness queued this deterministic notice.',
  }
}

const raw = await readStdin()
const input = parseInput(raw)
const adapter = new ClaudeStopAdapter({
  env: process.env,
  readTranscript: readTranscriptTail,
})
const event = adapter.normalizeStop(input)

let adoption: HarnessParityAdoption = { enabled: false }
let completionPolicy: ReturnType<typeof parseCompletionReviewPolicy> | null = null
const adoptionRequested = Boolean(String(process.env[HARNESS_PARITY_RECEIPT_ENV] ?? '').trim())
  || [
    process.env.CODEX_BRIDGE_HARNESS_ADOPTION,
    process.env.CODEX_BRIDGE_HARNESS_STATE_DIR,
    process.env.CODEX_BRIDGE_HARNESS_ROADMAP_REPO_ROOT,
    process.env.CODEX_BRIDGE_HARNESS_DR_REFS,
  ].some(value => value !== undefined && value !== '')
if (adoptionRequested) {
  try {
    completionPolicy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
      join(import.meta.dir, '..', 'swarm-harness', 'completion-review-policy.json'),
      'utf8',
    )))
    adoption = readHarnessParityAdoption(process.env, {
      expectedSwarm: event.swarm,
      workspaceRoot: process.env.CLAUDE_PROJECT_DIR || process.cwd(),
      expectedCompletionPolicySha256: completionReviewPolicySha256(completionPolicy),
    })
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    const reason = `completion parity adoption authority is invalid: ${detail}`
    process.stdout.write(`${JSON.stringify({ decision: 'block', reason })}\n`)
    process.stderr.write(`swarm-stop-hook: BLOCKED — ${reason}\n`)
    process.exit(2)
  }
}

const stateRoot = adoption.enabled
  ? join(adoption.stateRoot, 'stops')
  : process.env.SWARM_HARNESS_STATE_DIR
    || join(homedir(), '.config', 'swarm', 'harness', event.swarm, 'stop-delivery')

let store: StopStateStore
try {
  store = new StopStateStore(stateRoot)
} catch {
  const reason = 'private stop delivery state is unavailable'
  process.stdout.write(`${JSON.stringify({ decision: 'block', reason })}\n`)
  process.stderr.write(`swarm-stop-hook: BLOCKED — ${reason}\n`)
  process.exit(2)
}

let sender: MessageSender = new UnavailableSender()
try {
  if (process.env.DISCORD_BOT_TOKEN) {
    sender = new DiscordRestSender({ token: process.env.DISCORD_BOT_TOKEN })
  }
} catch {}

const pipeline = new StopDeliveryPipeline({
  sender,
  fallbackSender: sender,
  store,
})
let outcome: StopOutcome
let reviewStatus: 'complete' | 'pending' | 'missing' | null = null
let authorityError: string | null = null
if (adoption.enabled) {
  const policy = completionPolicy!
  let gate = createCompletionReviewGate(event.taskId, policy)
  try {
    gate = readClaudeCompletionGateState({ adoption, event, policy })
  } catch (error) {
    authorityError = error instanceof Error ? error.message : String(error)
  }
  const boundary = await enforceTaskCompletionBoundary({
    // The authority envelope was matched to this descriptor-derived event.
    // Re-reading a growing transcript here would create a second identity and
    // reopen a TOCTOU gap between review admission and durable stop delivery.
    adapter: { runtime: adapter.runtime, normalizeStop: () => event },
    pipeline,
    input,
    gateState: gate,
    policy,
  })
  outcome = boundary.stop
  reviewStatus = boundary.review_status
} else {
  // Byte-for-byte legacy policy: no receipt means the already-deployed stop
  // delivery behavior remains unchanged until atomic parity adoption.
  outcome = await pipeline.execute(event)
}

if (outcome.stopped && (outcome.disposition === 'delivered' || outcome.disposition === 'queued')) {
  process.stderr.write(
    `swarm-stop-hook: ${outcome.disposition} event ${outcome.eventId.slice(0, 12)} `
    + `(attempts=${outcome.attempts}, fallback=${outcome.fallback}`
    + `${reviewStatus ? `, review=${reviewStatus}` : ''})\n`,
  )
  process.exit(0)
}

const reason = adoption.enabled && authorityError
  ? `completion authority refused Stop: ${authorityError}`
  : `stop delivery has neither a verified receipt nor a durable queue record: ${outcome.error ?? 'unknown error'}`
process.stdout.write(`${JSON.stringify({ decision: 'block', reason })}\n`)
process.stderr.write(`swarm-stop-hook: BLOCKED — ${reason}\n`)
process.exit(2)
