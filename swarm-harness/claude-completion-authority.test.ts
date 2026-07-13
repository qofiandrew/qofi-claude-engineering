import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import {
  claudeCompletionEnvelopePath,
  CLAUDE_COMPLETION_ARTIFACT_SCHEMA,
  CLAUDE_COMPLETION_ENVELOPE_SCHEMA,
  readClaudeCompletionGateState,
} from './claude-completion-authority.ts'
import {
  completionReviewPolicySha256,
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
  type ReviewVerdict,
} from './completion-review-policy.ts'
import {
  canonicalAuthorityJsonLine,
  HARNESS_PARITY_ADOPTION_CONTRACT,
  HARNESS_PARITY_ADOPTION_SCHEMA,
  readHarnessParityAdoption,
} from './parity-adoption.ts'
import { ClaudeStopAdapter } from './runtime-adapters.ts'
import {
  StopDeliveryPipeline,
  StopStateStore,
  type MessageSender,
} from './stop-delivery.ts'
import { enforceTaskCompletionBoundary } from './task-boundary.ts'

const CHANNEL = '1508921858165047390'
const HASH = 'd'.repeat(64)
const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(import.meta.dir, 'completion-review-policy.json'), 'utf8',
)))
const roots: string[] = []

afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true })
})

class Sender implements MessageSender {
  calls: string[] = []
  async send(_channelId: string, text: string) {
    this.calls.push(text)
    return { messageId: `receipt-${this.calls.length}` }
  }
}

function fixture(verdict: ReviewVerdict = 'approve') {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-claude-authority-')))
  chmodSync(root, 0o700)
  roots.push(root)
  const authority = join(root, 'receipt-authority')
  const state = join(root, 'state')
  const workspace = join(root, 'workspace')
  for (const path of [authority, state, workspace]) mkdirSync(path, { mode: 0o700 })
  const receiptPath = join(authority, 'parity.json')
  writeFileSync(receiptPath, canonicalAuthorityJsonLine({
    schema: HARNESS_PARITY_ADOPTION_SCHEMA,
    contract: HARNESS_PARITY_ADOPTION_CONTRACT,
    swarm: 'press-backend',
    runtimes: ['claude', 'codex'],
    state_root: state,
    roadmap_repo_root: workspace,
    dr_refs: ['ADR-0022', 'ADR-0023'],
    completion_policy_sha256: completionReviewPolicySha256(policy),
  }), { mode: 0o600 })
  const adoption = readHarnessParityAdoption(
    { SWARM_HARNESS_PARITY_RECEIPT: receiptPath },
    {
      expectedSwarm: 'press-backend', workspaceRoot: workspace,
      expectedCompletionPolicySha256: completionReviewPolicySha256(policy),
    },
  )
  if (!adoption.enabled) throw new Error('fixture adoption did not enable')
  const adapter = new ClaudeStopAdapter({
    env: {
      SWARM_NAME: 'press-backend', CLAUDE_PROJECT_DIR: workspace,
      DISCORD_BOUND_CHANNEL: CHANNEL,
    },
    now: () => 4_000,
  })
  const input = {
    hook_event_name: 'Stop', session_id: 'session-1', task_id: 'task-1',
    stop_event_id: 'native-stop-1', last_assistant_message: 'verified summary',
    occurred_at_ms: 4_000,
  }
  const event = adapter.normalizeStop(input)
  const envelope = {
    schema: CLAUDE_COMPLETION_ENVELOPE_SCHEMA,
    adoption_receipt_sha256: adoption.receiptSha256,
    runtime: 'claude',
    swarm: event.swarm,
    task_id: event.taskId,
    stop_event_id: event.eventId,
    final_diff_sha256: HASH,
    reviewed_paths: ['src/change.ts'],
    artifact: {
      schema: CLAUDE_COMPLETION_ARTIFACT_SCHEMA,
      artifact_id: 'review-result-1',
      task_id: event.taskId,
      phase: 'completion',
      reviewed_diff_sha256: HASH,
      verdict,
    },
  } as const
  const envelopePath = claudeCompletionEnvelopePath(adoption, event)
  const writeEnvelope = (value: unknown = envelope) => {
    mkdirSync(dirname(envelopePath), { recursive: true, mode: 0o700 })
    // Recursive creation respects the test process umask, but pin every
    // harness-owned child used by the descriptor-bound reader.
    for (const path of [
      join(state, 'completion-authority'),
      join(state, 'completion-authority', 'claude'),
      join(state, 'completion-authority', 'claude', event.swarm),
    ]) chmodSync(path, 0o700)
    writeFileSync(envelopePath, canonicalAuthorityJsonLine(value), { mode: 0o600 })
  }
  const sender = new Sender()
  const pipeline = new StopDeliveryPipeline({
    sender, store: new StopStateStore(join(state, 'stops')), now: () => 5_000,
  })
  return {
    adoption, adapter, input, event, envelope, envelopePath, writeEnvelope,
    sender, pipeline,
  }
}

describe('Claude exact-final-diff completion authority', () => {
  test('enabled missing artifact blocks and sends nothing', async () => {
    const f = fixture()
    const result = await enforceTaskCompletionBoundary({
      adapter: f.adapter,
      pipeline: f.pipeline,
      input: f.input,
      gateState: createCompletionReviewGate(f.event.taskId, policy),
      policy,
    })
    expect(result).toMatchObject({
      accepted: false, review_status: 'missing',
      stop: { disposition: 'blocked', stopped: false, attempts: 0 },
    })
    expect(f.sender.calls).toHaveLength(0)
  })

  test('mismatched artifact is refused before any send', () => {
    const f = fixture()
    f.writeEnvelope({
      ...f.envelope,
      artifact: { ...f.envelope.artifact, reviewed_diff_sha256: 'e'.repeat(64) },
    })
    expect(() => readClaudeCompletionGateState({
      adoption: f.adoption, event: f.event, policy,
    })).toThrow('not bound to the final task diff')
    expect(f.sender.calls).toHaveLength(0)
  })

  test('valid exact artifact crosses the common gate and delivers', async () => {
    const f = fixture()
    f.writeEnvelope()
    const gate = readClaudeCompletionGateState({
      adoption: f.adoption, event: f.event, policy,
    })
    const result = await enforceTaskCompletionBoundary({
      adapter: f.adapter, pipeline: f.pipeline, input: f.input, gateState: gate, policy,
    })
    expect(result).toMatchObject({
      accepted: true, review_status: 'complete',
      stop: { disposition: 'delivered', stopped: true },
    })
    expect(f.sender.calls).toHaveLength(1)
  })

  test('review-unavailable remains pending but may stop after verified delivery', async () => {
    const f = fixture('review-unavailable')
    f.writeEnvelope()
    const gate = readClaudeCompletionGateState({
      adoption: f.adoption, event: f.event, policy,
    })
    const result = await enforceTaskCompletionBoundary({
      adapter: f.adapter, pipeline: f.pipeline, input: f.input, gateState: gate, policy,
    })
    expect(result).toMatchObject({
      accepted: true, review_status: 'pending',
      stop: { disposition: 'delivered', stopped: true },
    })
    expect(f.sender.calls).toHaveLength(1)
  })

  test('wrong receipt binding and noncanonical bytes are rejected', () => {
    const wrong = fixture()
    wrong.writeEnvelope({ ...wrong.envelope, adoption_receipt_sha256: 'f'.repeat(64) })
    expect(() => readClaudeCompletionGateState({
      adoption: wrong.adoption, event: wrong.event, policy,
    })).toThrow('wrong receipt or stop scope')

    const noncanonical = fixture()
    mkdirSync(dirname(noncanonical.envelopePath), { recursive: true, mode: 0o700 })
    writeFileSync(noncanonical.envelopePath, `${JSON.stringify(noncanonical.envelope)}\n`, { mode: 0o600 })
    expect(() => readClaudeCompletionGateState({
      adoption: noncanonical.adoption, event: noncanonical.event, policy,
    })).toThrow('not canonical')
  })
})
