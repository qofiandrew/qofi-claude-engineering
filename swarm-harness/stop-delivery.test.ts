import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  DiscordRestSender,
  STOP_EVENT_SCHEMA,
  StopDeliveryPipeline,
  StopStateStore,
  formatStopMessage,
  type MessageSender,
  type NormalizedStopEvent,
} from './stop-delivery'
import { ClaudeStopAdapter, CodexStopAdapter, enforceRuntimeStop } from './runtime-adapters'

const roots: string[] = []
afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true })
})

function root(): string {
  const path = mkdtempSync(join(tmpdir(), 'qofi-stop-'))
  chmodSync(path, 0o700)
  roots.push(path)
  return path
}

function event(overrides: Partial<NormalizedStopEvent> = {}): NormalizedStopEvent {
  return {
    schema: STOP_EVENT_SCHEMA,
    eventId: 'a'.repeat(64),
    runtime: 'claude',
    swarm: 'press-backend',
    taskId: 'task-17',
    channelId: '1508921858165047390',
    fallbackChannelId: '1510301812434141194',
    summary: 'Implemented the boundary and ran 17 tests.',
    occurredAtMs: 1_000,
    ...overrides,
  }
}

class FakeSender implements MessageSender {
  calls: Array<{ channelId: string; text: string }> = []
  failures: number
  constructor(failures = 0, private readonly prefix = 'receipt') { this.failures = failures }
  async send(channelId: string, text: string) {
    this.calls.push({ channelId, text })
    if (this.calls.length <= this.failures) throw new Error(`transient failure ${this.calls.length}`)
    return { messageId: `${this.prefix}-${this.calls.length}` }
  }
}

describe('harness-owned stop delivery', () => {
  const secretSummary = 'used ghp_abcdefghijklmnopqrstuvwxyz123456 and person@example.com'

  test('verified primary receipt is audited before stopped=true', async () => {
    const sender = new FakeSender()
    const store = new StopStateStore(root())
    const outcome = await new StopDeliveryPipeline({ sender, store, now: () => 2_000 }).execute(event())

    expect(outcome).toMatchObject({ disposition: 'delivered', stopped: true, attempts: 1 })
    expect(outcome.receiptId).toBe('receipt-1')
    expect(sender.calls).toHaveLength(1)
    const audit = JSON.parse(readFileSync(join(store.root, 'audit', `${event().eventId}.json`), 'utf8'))
    expect(audit.outcome.disposition).toBe('delivered')
    expect(statSync(join(store.root, 'audit', `${event().eventId}.json`)).mode & 0o077).toBe(0)
  })

  test('successful durable outcome never retains raw secret-bearing summary bytes', async () => {
    const store = new StopStateStore(root())
    await new StopDeliveryPipeline({ sender: new FakeSender(), store }).execute(event({
      summary: secretSummary,
    }))
    const persisted = readFileSync(
      join(store.root, 'outcomes', `${event().eventId}.json`), 'utf8',
    )
    expect(persisted).not.toContain('ghp_')
    expect(persisted).not.toContain('person@example.com')
    expect(persisted).toContain('[REDACTED]')
  })

  test('transient send failures retry with bounded backoff and require a receipt', async () => {
    const sender = new FakeSender(2)
    const sleeps: number[] = []
    const outcome = await new StopDeliveryPipeline({
      sender,
      store: new StopStateStore(root()),
      maxAttempts: 3,
      backoffMs: [10, 25],
      sleep: async ms => { sleeps.push(ms) },
    }).execute(event())

    expect(outcome.disposition).toBe('delivered')
    expect(outcome.attempts).toBe(3)
    expect(sleeps).toEqual([10, 25])
  })

  test('exhausted primary is dead-lettered then escalated over fallback', async () => {
    const primary = new FakeSender(99)
    const fallback = new FakeSender(0, 'fallback')
    const store = new StopStateStore(root())
    const outcome = await new StopDeliveryPipeline({
      sender: primary,
      fallbackSender: fallback,
      store,
      maxAttempts: 3,
      sleep: async () => {},
      now: () => 5_000,
    }).execute(event({ summary: secretSummary }))

    expect(outcome).toMatchObject({
      disposition: 'queued', stopped: true, attempts: 3, fallback: 'delivered',
    })
    expect(outcome.fallbackReceiptId).toBe('fallback-1')
    const dead = JSON.parse(readFileSync(join(store.root, 'dead-letter', `${event().eventId}.json`), 'utf8'))
    expect(dead.schema).toBe('qofi.swarm.stop-dead-letter/v1')
    expect(dead.event.summary).toContain('[REDACTED]')
    const persisted = [
      readFileSync(join(store.root, 'dead-letter', `${event().eventId}.json`), 'utf8'),
      readFileSync(join(store.root, 'outcomes', `${event().eventId}.json`), 'utf8'),
    ].join('\n')
    expect(persisted).not.toContain('ghp_')
    expect(persisted).not.toContain('person@example.com')
    expect(fallback.calls[0].text).not.toContain(secretSummary)
  })

  test('fallback failure does not erase a verified durable queue record', async () => {
    const store = new StopStateStore(root())
    const outcome = await new StopDeliveryPipeline({
      sender: new FakeSender(99),
      fallbackSender: new FakeSender(99),
      store,
      maxAttempts: 2,
      fallbackMaxAttempts: 2,
      sleep: async () => {},
    }).execute(event())
    expect(outcome).toMatchObject({ disposition: 'queued', stopped: true, fallback: 'failed' })
    expect(statSync(join(store.root, 'dead-letter', `${event().eventId}.json`)).mode & 0o077).toBe(0)
  })

  test('event replay returns its durable outcome without a duplicate Discord send', async () => {
    const sender = new FakeSender()
    const pipeline = new StopDeliveryPipeline({ sender, store: new StopStateStore(root()) })
    const first = await pipeline.execute(event())
    const replay = await pipeline.execute(event({ summary: 'changed self-report must not replace durable truth' }))
    expect(replay).toEqual(expect.objectContaining({ eventId: first.eventId, receiptId: first.receiptId }))
    expect(sender.calls).toHaveLength(1)
  })

  test('a reused event id cannot inherit an outcome across normalized task scopes', async () => {
    const sender = new FakeSender()
    const pipeline = new StopDeliveryPipeline({ sender, store: new StopStateStore(root()) })
    await pipeline.execute(event({ taskId: 'task-one' }))
    const collision = await pipeline.execute(event({ taskId: 'task-two' }))
    expect(collision).toMatchObject({ disposition: 'blocked', stopped: false, attempts: 0 })
    expect(collision.error).toContain('different normalized scope')
    expect(sender.calls).toHaveLength(1)
  })

  test('hard-linked durable state is refused instead of trusted as an outcome', async () => {
    const sender = new FakeSender()
    const store = new StopStateStore(root())
    const pipeline = new StopDeliveryPipeline({ sender, store })
    await pipeline.execute(event())
    const outcomePath = join(store.root, 'outcomes', `${event().eventId}.json`)
    linkSync(outcomePath, join(store.root, 'outcomes', 'attacker-link.json'))
    const replay = await pipeline.execute(event())
    expect(replay).toMatchObject({ disposition: 'blocked', stopped: false })
    expect(replay.error).toContain('private real file')
    expect(sender.calls).toHaveLength(1)
  })

  test('symlink-indirected state roots are refused without weakening the target', () => {
    const parent = mkdtempSync(join(tmpdir(), 'qofi-stop-parent.'))
    const target = join(parent, 'target')
    const link = join(parent, 'link')
    mkdirSync(target, { mode: 0o700 })
    symlinkSync(target, link)
    expect(() => new StopStateStore(join(link, 'state'))).toThrow('untrusted symlink indirection')
    expect(statSync(target).mode & 0o777).toBe(0o700)
  })

  test('invalid boundary cannot be considered stopped', async () => {
    const store = new StopStateStore(root())
    const outcome = await new StopDeliveryPipeline({
      sender: new FakeSender(), store,
    }).execute(event({ channelId: 'not-a-channel' }))
    expect(outcome).toMatchObject({ disposition: 'blocked', stopped: false })
    const audit = JSON.parse(readFileSync(join(store.root, 'audit', `${event().eventId}.json`), 'utf8'))
    expect(audit.outcome).toMatchObject({ disposition: 'blocked', stopped: false })
  })

  test('completion-gate refusal is privately audited, idempotent, and sends nothing', async () => {
    const sender = new FakeSender()
    const store = new StopStateStore(root())
    const pipeline = new StopDeliveryPipeline({ sender, store, now: () => 9_000 })
    const first = await pipeline.recordBlockedAttempt(event(), 'completion review artifact is missing')
    const replay = await pipeline.recordBlockedAttempt(event(), 'different replay prose is ignored')

    expect(first).toMatchObject({
      disposition: 'blocked', stopped: false, attempts: 0, error: 'completion review artifact is missing',
    })
    expect(replay).toEqual(first)
    expect(sender.calls).toHaveLength(0)
    expect(statSync(join(store.root, 'outcomes', `${event().eventId}.json`)).mode & 0o077).toBe(0)
    expect(statSync(join(store.root, 'audit', `${event().eventId}.json`)).mode & 0o077).toBe(0)
    expect(() => statSync(join(store.root, 'dead-letter', `${event().eventId}.json`))).toThrow()
  })

  test('outbound summary redacts credentials and account identities', () => {
    const message = formatStopMessage(event({
      summary: secretSummary,
    }))
    expect(message).not.toContain('ghp_')
    expect(message).not.toContain('person@example.com')
    expect(message.match(/\[REDACTED\]/g)?.length).toBe(2)
  })

  test('Discord REST success is verified from the returned message id', async () => {
    const fetchImpl = (async () => new Response(JSON.stringify({ id: 'discord-42' }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })) as typeof fetch
    const sender = new DiscordRestSender({ token: 'test-only', fetchImpl })
    await expect(sender.send('1508921858165047390', 'hello')).resolves.toEqual({ messageId: 'discord-42' })
  })

  test('Discord 429 retry hint is honored within the Stop timeout ceiling', async () => {
    let calls = 0
    const fetchImpl = (async () => {
      calls += 1
      return calls === 1
        ? new Response(JSON.stringify({ retry_after: 60 }), {
          status: 429, headers: { 'content-type': 'application/json' },
        })
        : new Response(JSON.stringify({ id: 'discord-after-limit' }), {
          status: 200, headers: { 'content-type': 'application/json' },
        })
    }) as typeof fetch
    const sleeps: number[] = []
    const pipeline = new StopDeliveryPipeline({
      sender: new DiscordRestSender({ token: 'test-only', fetchImpl }),
      store: new StopStateStore(root()),
      backoffMs: [10],
      sleep: async ms => { sleeps.push(ms) },
    })
    const outcome = await pipeline.execute(event())
    expect(outcome.disposition).toBe('delivered')
    expect(sleeps).toEqual([5_000])
  })
})

describe('runtime parity at the stop boundary', () => {
  test.each(['claude', 'codex'] as const)('%s adapter uses the identical delivery policy', async runtime => {
    const channelId = '1508921858165047390'
    const adapter = runtime === 'claude'
      ? new ClaudeStopAdapter({
        env: { SWARM_NAME: 'press-backend', DISCORD_BOUND_CHANNEL: channelId },
        now: () => 100,
      })
      : new CodexStopAdapter(() => 100)
    const input = runtime === 'claude'
      ? {
        session_id: 'session-1', task_id: 'task-1', last_assistant_message: 'boundary summary',
      }
      : {
        swarm: 'press-backend', taskId: 'task-1', turnId: 'turn-1', channelId,
        summary: 'boundary summary',
      }
    const sender = new FakeSender()
    const pipeline = new StopDeliveryPipeline({
      sender, store: new StopStateStore(root()), now: () => 200,
    })
    const outcome = await enforceRuntimeStop(adapter as any, pipeline, input as any)
    expect(outcome).toMatchObject({ disposition: 'delivered', stopped: true, attempts: 1 })
    expect(sender.calls[0].text).toContain('boundary summary')
  })
})
