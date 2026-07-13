import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { createHash } from 'node:crypto'
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
import { join } from 'node:path'
import { parseCompletionReviewPolicy } from '../swarm-harness/completion-review-policy.ts'
import { completionReviewPolicySha256 } from '../swarm-harness/completion-review-policy.ts'
import {
  canonicalAuthorityJsonLine,
  HARNESS_PARITY_ADOPTION_CONTRACT,
  HARNESS_PARITY_ADOPTION_SCHEMA,
} from '../swarm-harness/parity-adoption.ts'
import { NormalizedEventStore } from '../swarm-harness/event-store.ts'
import { RoadmapStore } from '../swarm-harness/roadmap.ts'
import {
  StopDeliveryPipeline,
  StopStateStore,
  type MessageSender,
} from '../swarm-harness/stop-delivery.ts'
import type { FableReviewArtifact } from './review-artifacts.ts'
import {
  DaemonHarnessLifecycle,
  EMPTY_COMPLETION_REVIEW_MATERIAL,
  deriveCompletionReviewMaterial,
  parseDaemonHarnessAdoption,
} from './daemon-lifecycle.ts'

const CHANNEL = '1508921858165047390'
const TASK = 'discord-message-1'
const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(import.meta.dir, '..', 'swarm-harness', 'completion-review-policy.json'),
  'utf8',
)))

class Sender implements MessageSender {
  calls: Array<{ channel: string, text: string }> = []
  failures = 0

  async send(channel: string, text: string) {
    this.calls.push({ channel, text })
    if (this.failures-- > 0) throw new Error('fixture Discord failure')
    return { messageId: `receipt-${this.calls.length}` }
  }
}

function artifact(hash: string, verdict: FableReviewArtifact['result']['verdict'] = 'approve'):
FableReviewArtifact {
  return {
    schema: 'qofi-fable-review-artifact/v1',
    reviewer: 'claude-fable',
    model: 'claude-fable-5',
    swarm: 'press-backend',
    profile: 'default',
    task_id: TASK,
    mode: 'code',
    reviewed_diff_sha256: hash,
    created_at: '2026-07-13T10:11:12.123456Z',
    result: verdict === 'approve'
      ? {
        schema: 'qofi-adversarial-review-output/v2', verdict,
        summary: 'No material finding from the supplied post-state.',
        checked: ['exact named-file payload'], not_checked: ['runtime execution'],
        findings: [], next_steps: [],
      }
      : verdict === 'review-unavailable' ? {
        schema: 'qofi-adversarial-review-output/v2', verdict,
        summary: 'The reviewer lane was unavailable.',
        checked: [], not_checked: ['exact named-file payload'],
        findings: [], next_steps: ['Retry review.'],
      } : {
        schema: 'qofi-adversarial-review-output/v2', verdict,
        summary: 'A falsifiable advisory finding remains.',
        checked: ['exact named-file payload'], not_checked: ['runtime execution'],
        findings: [{
          severity: verdict === 'block' ? 'critical' : 'medium',
          locus: 'src.ts', claim: 'fixture claim', evidence: 'fixture evidence',
          suggested_test: 'run the focused fixture',
        }],
        next_steps: ['Ratify or address the advisory finding.'],
      },
  }
}

describe('explicit Codex harness parity adoption', () => {
  const options = (workspaceRoot: string) => ({
    expectedSwarm: 'press-backend',
    workspaceRoot,
    expectedCompletionPolicySha256: completionReviewPolicySha256(policy),
  })

  test('is off by default and refuses legacy Codex-only activation', () => {
    const workspace = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-adoption-workspace-')))
    expect(parseDaemonHarnessAdoption({}, options(workspace))).toEqual({ enabled: false })
    expect(() => parseDaemonHarnessAdoption({
      CODEX_BRIDGE_HARNESS_STATE_DIR: '/private/state',
    }, options(workspace))).toThrow('operator receipt')
    expect(() => parseDaemonHarnessAdoption({
      CODEX_BRIDGE_HARNESS_ADOPTION: 'codex-only',
    }, options(workspace))).toThrow('operator receipt')
    rmSync(workspace, { recursive: true, force: true })
  })

  test('accepts only an owner-private receipt atomically scoped to Claude and Codex', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-adoption-')))
    chmodSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const state = join(root, 'state')
    const authority = join(root, 'authority')
    for (const directory of [workspace, state, authority]) mkdirSync(directory, { mode: 0o700 })
    const receipt = join(authority, 'parity.json')
    writeFileSync(receipt, canonicalAuthorityJsonLine({
      schema: HARNESS_PARITY_ADOPTION_SCHEMA,
      contract: HARNESS_PARITY_ADOPTION_CONTRACT,
      swarm: 'press-backend',
      runtimes: ['claude', 'codex'],
      state_root: state,
      roadmap_repo_root: workspace,
      dr_refs: ['ADR-0022', 'ADR-0023'],
      completion_policy_sha256: completionReviewPolicySha256(policy),
    }), { mode: 0o600 })
    const adopted = parseDaemonHarnessAdoption({
      SWARM_HARNESS_PARITY_RECEIPT: receipt,
    }, options(workspace))
    expect(adopted).toMatchObject({
      enabled: true,
      receiptPath: receipt,
      stateRoot: state,
      roadmapRepoRoot: workspace,
      drRefs: ['ADR-0022', 'ADR-0023'],
      swarm: 'press-backend',
    })
    expect(adopted.enabled && adopted.receiptSha256).toMatch(/^[0-9a-f]{64}$/)
    rmSync(root, { recursive: true, force: true })
  })
})

describe('host-derived completion review material', () => {
  let root: string
  beforeEach(() => { root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-daemon-material-'))) })
  afterEach(() => rmSync(root, { recursive: true, force: true }))

  test('matches the reviewer shim compact named-file hash and deletion representation', () => {
    writeFileSync(join(root, 'a.ts'), 'alpha\n', { mode: 0o644 })
    const fileHash = createHash('sha256').update('alpha\n').digest('hex')
    const material = deriveCompletionReviewMaterial(root, {
      'z.ts': null,
      'a.ts': `100644:${fileHash}`,
    })
    const exactShimBytes = JSON.stringify({
      files: [
        { content: 'alpha\n', path: 'a.ts' },
        { content: '', path: 'z.ts [deleted]' },
      ],
    })
    expect(material).toEqual({
      hash: createHash('sha256').update(exactShimBytes).digest('hex'),
      paths: ['a.ts', 'z.ts'],
      kind: 'named-files',
      bytes: Buffer.byteLength(exactShimBytes),
      reviewInput: {
        diff_or_files: { files: [
          { path: 'a.ts', content: 'alpha\n' },
          { path: 'z.ts [deleted]', content: '' },
        ] },
        context_refs: [], mode: 'code',
      },
    })
  })

  test('orders non-ASCII paths by UTF-8 bytes rather than JavaScript UTF-16 units', () => {
    const bmp = '\uE000.ts'
    const astral = '\u{10000}.ts'
    writeFileSync(join(root, bmp), 'bmp\n', { mode: 0o644 })
    writeFileSync(join(root, astral), 'astral\n', { mode: 0o644 })
    const material = deriveCompletionReviewMaterial(root, {
      [astral]: `100644:${createHash('sha256').update('astral\n').digest('hex')}`,
      [bmp]: `100644:${createHash('sha256').update('bmp\n').digest('hex')}`,
    })
    // UTF-8 EE (BMP private-use) sorts before F0 (supplementary plane), while
    // JS's default UTF-16 sort would put the astral high surrogate first.
    expect(material.paths).toEqual([bmp, astral])
    const canonical = JSON.stringify({ files: [
      { content: 'bmp\n', path: bmp },
      { content: 'astral\n', path: astral },
    ] })
    expect(material.hash).toBe(createHash('sha256').update(canonical).digest('hex'))
  })

  test('binds empty work and refuses drift, links, binary data, or a false deletion', () => {
    expect(deriveCompletionReviewMaterial(root, {})).toEqual({
      hash: createHash('sha256').update(EMPTY_COMPLETION_REVIEW_MATERIAL).digest('hex'),
      paths: [], kind: 'empty', bytes: Buffer.byteLength(EMPTY_COMPLETION_REVIEW_MATERIAL),
      reviewInput: {
        diff_or_files: EMPTY_COMPLETION_REVIEW_MATERIAL,
        context_refs: [], mode: 'code',
      },
    })
    writeFileSync(join(root, 'file.ts'), 'before\n', { mode: 0o644 })
    const before = createHash('sha256').update('before\n').digest('hex')
    writeFileSync(join(root, 'file.ts'), 'after\n', { mode: 0o644 })
    expect(() => deriveCompletionReviewMaterial(root, {
      'file.ts': `100644:${before}`,
    })).toThrow('drifted')
    expect(() => deriveCompletionReviewMaterial(root, { 'file.ts': null })).toThrow('present')

    writeFileSync(join(root, 'binary'), Buffer.from([0xff, 0xfe]), { mode: 0o644 })
    const binary = createHash('sha256').update(Buffer.from([0xff, 0xfe])).digest('hex')
    expect(() => deriveCompletionReviewMaterial(root, {
      binary: `100644:${binary}`,
    })).toThrow()
  })
})

describe('Codex daemon common lifecycle boundary', () => {
  let root: string
  let repo: string
  let eventDir: string
  let authorityDir: string
  let sender: Sender
  let lifecycle: DaemonHarnessLifecycle
  let eventStore: NormalizedEventStore
  let roadmapStore: RoadmapStore
  let now: number

  beforeEach(() => {
    root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-daemon-lifecycle-')))
    repo = join(root, 'repo')
    eventDir = join(root, 'private', 'events')
    authorityDir = join(root, 'private', 'roadmap')
    mkdirSync(repo, { mode: 0o755 })
    mkdirSync(eventDir, { recursive: true, mode: 0o700 })
    mkdirSync(authorityDir, { mode: 0o700 })
    chmodSync(eventDir, 0o700)
    chmodSync(authorityDir, 0o700)
    eventStore = new NormalizedEventStore(eventDir, { repoRoot: repo })
    roadmapStore = new RoadmapStore(repo, join(authorityDir, 'authority.json'))
    sender = new Sender()
    now = Date.parse('2026-07-13T10:00:00Z')
    lifecycle = new DaemonHarnessLifecycle({
      eventStore, roadmapStore, policy, repoRoot: repo,
      swarm: 'press-backend', drRefs: ['ADR-0023'], now: () => now,
    })
  })
  afterEach(() => rmSync(root, { recursive: true, force: true }))

  const pipeline = () => new StopDeliveryPipeline({
    sender,
    store: new StopStateStore(join(root, 'private', 'stops')),
    now: () => now,
    sleep: async () => {},
  })

  test('records ground-truth task/activity/result state and completes only after exact review evidence', async () => {
    writeFileSync(join(repo, 'src.ts'), 'export const live = true\n', { mode: 0o644 })
    const fileHash = createHash('sha256').update('export const live = true\n').digest('hex')
    lifecycle.startTask(TASK)
    lifecycle.recordRuntimeActivity(TASK)
    const material = lifecycle.deriveCompletionMaterial({
      'src.ts': `100644:${fileHash}`,
    })
    const result = await lifecycle.completeTask({
      taskId: TASK, turnId: 'turn-1', channelId: CHANNEL,
      summary: 'Verified implementation complete.', material,
      artifacts: [artifact(material.hash)], pipeline: pipeline(),
    })
    expect(result).toMatchObject({
      reviewArtifactAccepted: true,
      reviewReason: 'review-artifact-recorded',
      boundary: { accepted: true, review_status: 'complete', stop: { disposition: 'delivered' } },
    })
    expect(sender.calls).toHaveLength(1)
    expect(sender.calls[0]!.text).toContain('Verified implementation complete.')
    expect(roadmapStore.read().items['ADR-0023']).toMatchObject({
      status: 'STOOD_DOWN', owning_swarm: 'press-backend',
      result_sets: { passed: 2, failed: 0, pending: 0, blocked: 0 },
    })
    const serialized = JSON.stringify(eventStore.replay())
    expect(serialized).not.toContain('Verified implementation complete.')
    expect(serialized).not.toContain('export const live')
  })

  test('rejects and audits done when the artifact is missing or reviews different bytes', async () => {
    lifecycle.startTask(TASK)
    const material = lifecycle.deriveCompletionMaterial({})
    const missing = await lifecycle.completeTask({
      taskId: TASK, turnId: 'turn-1', channelId: CHANNEL,
      summary: 'unproven done claim', material, artifacts: [], pipeline: pipeline(),
    })
    expect(missing).toMatchObject({
      reviewArtifactAccepted: false,
      boundary: {
        accepted: false, review_status: 'missing',
        gate: { reason: 'completion-verdict-or-artifact-missing' },
        stop: { disposition: 'blocked', stopped: false },
      },
    })
    expect(sender.calls).toHaveLength(0)
    expect(roadmapStore.read().items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')
    const missingEvents = eventStore.replay().filter(event => event.task_id === TASK)
    expect(missingEvents.some(event => event.type === 'task.finished')).toBe(false)
    expect(missingEvents).toContainEqual(expect.objectContaining({
      type: 'state.transitioned', previous_state: 'DRIVING', state: 'WAITING_FOR_OPERATOR',
    }))

    // A second fixture is required because the first task is now terminal in
    // the derived journal.  The mismatch itself is refused before transport.
    const second = 'discord-message-2'
    lifecycle.startTask(second)
    const wrongArtifact = { ...artifact('f'.repeat(64)), task_id: second }
    const mismatch = await lifecycle.completeTask({
      taskId: second, turnId: 'turn-2', channelId: CHANNEL,
      summary: 'wrong review payload', material, artifacts: [wrongArtifact], pipeline: pipeline(),
    })
    expect(mismatch.reviewReason).toBe('reviewed-diff-hash-mismatch')
    expect(mismatch.boundary.accepted).toBe(false)
    expect(sender.calls).toHaveLength(0)
    const mismatchEvents = eventStore.replay().filter(event => event.task_id === second)
    expect(mismatchEvents.some(event => event.type === 'task.finished')).toBe(false)
    expect(mismatchEvents.some(event => event.type === 'state.transitioned'
      && event.state === 'WAITING_FOR_OPERATOR')).toBe(true)
  })

  test('needs-changes and block remain advisory result states, not lifecycle vetoes or false passes', async () => {
    for (const [index, verdict] of (['needs-changes', 'block'] as const).entries()) {
      const taskId = `advisory-${index}`
      lifecycle.startTask(taskId)
      const material = lifecycle.deriveCompletionMaterial({})
      const candidate = { ...artifact(material.hash, verdict), task_id: taskId }
      const result = await lifecycle.completeTask({
        taskId, turnId: `turn-${index}`, channelId: CHANNEL,
        summary: `${verdict} advisory summary`, material,
        artifacts: [candidate], pipeline: pipeline(),
      })
      expect(result.boundary.accepted).toBe(true)
      expect(result.reviewArtifactAccepted).toBe(true)
      const reviewEvent = eventStore.replay().find(event => (
        event.task_id === taskId && event.type === 'result.landed' && event.result_kind === 'review'
      ))
      expect(reviewEvent?.result_status).toBe(verdict === 'block' ? 'blocked' : 'failed')
      expect(reviewEvent?.result_status).not.toBe('passed')
      expect(eventStore.replay().some(event => (
        event.task_id === taskId && event.type === 'task.finished' && event.outcome === 'completed'
      ))).toBe(true)
    }
    expect(roadmapStore.read().items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')
  })

  test('one earlier exception artifact cannot replace or obstruct the exact completion artifact', async () => {
    lifecycle.startTask(TASK)
    const material = lifecycle.deriveCompletionMaterial({})
    const early = {
      ...artifact('e'.repeat(64), 'approve'),
      created_at: '2026-07-13T10:10:00.000001Z',
    }
    const completion = artifact(material.hash, 'approve')
    const result = await lifecycle.completeTask({
      taskId: TASK, turnId: 'turn-1', channelId: CHANNEL,
      summary: 'early review did not replace completion', material,
      artifacts: [early, completion], pipeline: pipeline(),
    })
    expect(result).toMatchObject({
      reviewArtifactAccepted: true,
      boundary: { accepted: true, review_status: 'complete' },
    })
    const reviews = eventStore.replay().filter(event => (
      event.task_id === TASK && event.type === 'result.landed' && event.result_kind === 'review'
    ))
    expect(reviews).toHaveLength(1)
    expect(reviews[0]!.result_status).toBe('passed')
  })

  test('runtime failure waits for operator without fabricating a terminal stop', () => {
    lifecycle.startTask(TASK)
    lifecycle.failTask(TASK)
    const events = eventStore.replay().filter(event => event.task_id === TASK)
    expect(events.some(event => event.type === 'task.finished')).toBe(false)
    expect(events).toContainEqual(expect.objectContaining({
      type: 'state.transitioned', previous_state: 'DRIVING', state: 'WAITING_FOR_OPERATOR',
    }))
    expect(roadmapStore.read().items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')
  })

  test('durable stop queue is terminal delivery evidence but leaves roadmap reviewable', async () => {
    lifecycle.startTask(TASK)
    const material = lifecycle.deriveCompletionMaterial({})
    sender.failures = 99
    const result = await lifecycle.completeTask({
      taskId: TASK, turnId: 'turn-1', channelId: CHANNEL,
      summary: 'verified but Discord unavailable', material,
      artifacts: [artifact(material.hash, 'review-unavailable')], pipeline: pipeline(),
    })
    expect(result.boundary).toMatchObject({
      accepted: true, review_status: 'pending',
      stop: { disposition: 'queued', stopped: true },
    })
    expect(sender.calls).toHaveLength(3)
    expect(roadmapStore.read().items['ADR-0023']).toMatchObject({
      status: 'WAITING_FOR_OPERATOR',
      result_sets: { passed: 0, failed: 0, pending: 2, blocked: 0 },
    })
  })
})
