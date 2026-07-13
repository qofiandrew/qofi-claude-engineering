import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
  recordTaskReviewArtifact,
  requestTaskReview,
} from './completion-review-policy.ts'
import { ClaudeStopAdapter, CodexStopAdapter } from './runtime-adapters.ts'
import {
  StopDeliveryPipeline,
  StopStateStore,
  type MessageSender,
} from './stop-delivery.ts'
import { enforceTaskCompletionBoundary } from './task-boundary.ts'

const CHANNEL = '1508921858165047390'
const HASH = 'a'.repeat(64)
const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(import.meta.dir, 'completion-review-policy.json'), 'utf8',
)))

class Sender implements MessageSender {
  calls: string[] = []
  async send(_channel: string, text: string) {
    this.calls.push(text)
    return { messageId: `receipt-${this.calls.length}` }
  }
}

function completedGate(taskId: string) {
  let state = createCompletionReviewGate(taskId, policy)
  state = requestTaskReview(state, policy, 'completion', ['src/change.ts'], HASH).state
  state = recordTaskReviewArtifact(state, policy, {
    artifactId: 'review-result', artifactSha256: 'b'.repeat(64), taskId,
    phase: 'completion', reviewedDiffSha256: HASH, verdict: 'approve',
  }).state
  return state
}

function fixture(runtime: 'claude' | 'codex') {
  const sender = new Sender()
  const store = new StopStateStore(mkdtempSync(join(tmpdir(), `qofi-boundary-${runtime}.`)))
  const pipeline = new StopDeliveryPipeline({ sender, store, now: () => 5_000 })
  if (runtime === 'claude') {
    return {
      sender, store, pipeline,
      adapter: new ClaudeStopAdapter({
        env: { SWARM_NAME: 'press-backend', DISCORD_BOUND_CHANNEL: CHANNEL },
        now: () => 4_000,
      }),
      input: {
        session_id: 'session-1', task_id: 'task-1', stop_event_id: '1'.repeat(64),
        last_assistant_message: 'verified summary',
      },
    }
  }
  return {
    sender, store, pipeline,
    adapter: new CodexStopAdapter(() => 4_000),
    input: {
      swarm: 'press-backend', taskId: 'task-1', turnId: 'turn-1', channelId: CHANNEL,
      summary: 'verified summary',
    },
  }
}

for (const runtime of ['claude', 'codex'] as const) {
  describe(`${runtime} common task-completion boundary`, () => {
    test('refuses and audits stop without a completion verdict artifact', async () => {
      const f = fixture(runtime)
      const result = await enforceTaskCompletionBoundary({
        adapter: f.adapter as any,
        pipeline: f.pipeline,
        input: f.input as any,
        gateState: createCompletionReviewGate('task-1', policy),
        policy,
      })
      expect(result).toMatchObject({
        accepted: false,
        review_status: 'missing',
        gate: { reason: 'completion-review-not-requested' },
        stop: { disposition: 'blocked', stopped: false },
      })
      expect(result.gate_state.terminal).toBe('open')
      expect(f.sender.calls).toHaveLength(0)
      expect(f.store.hasAudit(result.stop.eventId)).toBe(true)
    })

    test('delivers only after the artifact-bound gate accepts', async () => {
      const f = fixture(runtime)
      const result = await enforceTaskCompletionBoundary({
        adapter: f.adapter as any,
        pipeline: f.pipeline,
        input: f.input as any,
        gateState: completedGate('task-1'),
        policy,
      })
      expect(result).toMatchObject({
        accepted: true,
        review_status: 'complete',
        stop: { disposition: 'delivered', stopped: true },
      })
      expect(result.gate_state.terminal).toBe('stop')
      expect(f.sender.calls).toHaveLength(1)
    })
  })
}
